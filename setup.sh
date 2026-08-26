#!/usr/bin/env bash
#
# One command to set Herdr up against Crafting.
#
#   ./setup.sh                use a template you already have
#   ./setup.sh --example      create the bundled example template first
#   ./setup.sh --show         print the resolved settings and exit
#
# There is one real question -- which template new sandboxes are built from --
# and everything else is discovered or defaulted. Answer it and this runs
# bootstrap.sh (the Crafting side) and install.sh (this machine).
#
set -euo pipefail

CS_HERDR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export CS_HERDR_ROOT
# shellcheck source=lib/config.sh
. "$CS_HERDR_ROOT/lib/config.sh"

WANT_EXAMPLE=0
NON_INTERACTIVE=0
[ -t 0 ] || NON_INTERACTIVE=1

while [ $# -gt 0 ]; do
    case "$1" in
        --example) WANT_EXAMPLE=1; shift ;;
        --yes|-y)  NON_INTERACTIVE=1; shift ;;
        --show)    require_cs; resolve_config; printf 'cs-herdr settings\n'; config_show; exit 0 ;;
        -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)         die "unknown argument '$1'" ;;
    esac
done

# ---------------------------------------------------------------------------
# Requirements
#
# Checked up front, each with the command that fixes it, so setup does not get
# halfway through and stop.
# ---------------------------------------------------------------------------

require_cs
command -v jq >/dev/null 2>&1 \
    || die "jq is required -- 'brew install jq' or 'apt install jq'"
cs_logged_in \
    || die "cs is not logged in -- run 'cs login' first"

resolve_config
# shellcheck source=lib/sandbox.sh
. "$CS_HERDR_ROOT/lib/sandbox.sh"
ensure_dirs

[ -n "$CS_HERDR_ORG" ] || die "could not tell which Crafting org to use -- set CS_HERDR_ORG, or run 'cs login -O ORG'"

find_herdr_quiet() {
    command -v herdr >/dev/null 2>&1 && return 0
    [ -x "$HOME/.local/bin/herdr" ] && return 0
    [ -x /opt/homebrew/bin/herdr ] && return 0
    [ -x /usr/local/bin/herdr ] && return 0
    return 1
}

say "cs-herdr setup"
say "  org        $CS_HERDR_ORG"
say "  folder     $CS_HERDR_FOLDER"
say "  site       ${CS_HERDR_DNS_SUFFIX:-unknown}"
say ""

if ! find_herdr_quiet; then
    warn "herdr is not installed on this machine. cs-herdr needs it to attach:"
    warn "  curl -fsSL https://herdr.dev/install.sh | sh    (or: brew install herdr)"
    warn "Continuing -- everything else can be set up now."
    say ""
fi

# ---------------------------------------------------------------------------
# The one question
# ---------------------------------------------------------------------------

choose_template() {
    local existing choice count

    if [ "$WANT_EXAMPLE" = 1 ]; then
        say "Using the bundled example template (--example)."
        return 0
    fi

    existing="$(conf_get CS_HERDR_TEMPLATE || true)"
    if [ -n "$existing" ]; then
        say "Template already configured: $existing"
        say "Change it later with 'cs herdr set-template NAME'."
        CS_HERDR_TEMPLATE="$existing"
        return 0
    fi

    if [ "$NON_INTERACTIVE" = 1 ]; then
        die "no template configured. Re-run with --example to use the bundled one, or set CS_HERDR_TEMPLATE=NAME"
    fi

    say "Which template should 'cs herdr new' build sandboxes from?"
    say ""
    say "A Herdr worker template needs the herdr binary installed and a herdr"
    say "server daemon running. examples/herdr-worker.yaml shows what that means."
    say ""
    say "Templates in $CS_HERDR_ORG/$CS_HERDR_FOLDER:"
    cs_run template list 2>/dev/null | head -20 >&2 || true
    say ""
    say "Enter a template name, or press enter to create the bundled example:"
    printf '  template> ' >&2
    read -r choice || choice=""

    if [ -z "$choice" ]; then
        WANT_EXAMPLE=1
        return 0
    fi

    if ! cs_run template show "$choice" -o json >/dev/null 2>&1; then
        die "no template named '$choice' in $CS_HERDR_ORG/$CS_HERDR_FOLDER"
    fi
    conf_set CS_HERDR_TEMPLATE "$choice"
    CS_HERDR_TEMPLATE="$choice"
    say "Template: $choice"
}

# Which Crafting workspace inside the sandbox runs Herdr. Asked only when the
# chosen template makes it ambiguous, because on a single-workspace template
# there is nothing to decide.
choose_workspace() {
    local workspaces count first choice
    [ -n "$CS_HERDR_TEMPLATE" ] || return 0

    workspaces="$(template_workspaces "$CS_HERDR_TEMPLATE")" || true
    [ -n "$workspaces" ] || return 0

    count="$(printf '%s\n' "$workspaces" | grep -c .)"
    first="$(printf '%s\n' "$workspaces" | head -1)"

    if [ "$count" = "1" ]; then
        conf_set CS_HERDR_WORKSPACE "$first"
        CS_HERDR_WORKSPACE="$first"
        say "Workspace: $first"
        return 0
    fi

    if [ "$NON_INTERACTIVE" = 1 ]; then
        conf_set CS_HERDR_WORKSPACE "$first"
        CS_HERDR_WORKSPACE="$first"
        say "Workspace: $first (first of $count; change with CS_HERDR_WORKSPACE)"
        return 0
    fi

    say ""
    say "'$CS_HERDR_TEMPLATE' has $count workspaces. Which one runs herdr?"
    printf '%s\n' "$workspaces" | sed 's/^/  - /' >&2
    printf '  workspace [%s]> ' "$first" >&2
    read -r choice || choice=""
    [ -n "$choice" ] || choice="$first"
    conf_set CS_HERDR_WORKSPACE "$choice"
    CS_HERDR_WORKSPACE="$choice"
    say "Workspace: $choice"
}

conf_set CS_HERDR_ORG "$CS_HERDR_ORG"
conf_set CS_HERDR_FOLDER "$CS_HERDR_FOLDER"

choose_template

# ---------------------------------------------------------------------------
# Crafting, then this machine
# ---------------------------------------------------------------------------

say ""
say "Setting up the Crafting side..."
if [ "$WANT_EXAMPLE" = 1 ]; then
    "$CS_HERDR_ROOT/bootstrap.sh" --example
else
    "$CS_HERDR_ROOT/bootstrap.sh"
fi

# Re-read: bootstrap may have written the template name.
CS_HERDR_TEMPLATE="$(conf_get CS_HERDR_TEMPLATE || true)"
choose_workspace

say ""
say "Setting up this machine..."
"$CS_HERDR_ROOT/install.sh"

say ""
say "-------------------------------------------------------------"
say "Ready."
say ""
say "  cs herdr new              a new sandbox, then attach"
say "  cs herdr NAME             back to one you already have"
say "  cs herdr ls               what you have"
say "  ./doctor.sh               check everything"
say ""
if ! find_herdr_quiet; then
    say "First, install herdr on this machine:"
    say "  curl -fsSL https://herdr.dev/install.sh | sh"
    say ""
fi
say "'cs herdr' resolves in a new shell. In this one:"
say "  export PATH=\"\$HOME/.cs-herdr/bin:\$PATH\""
