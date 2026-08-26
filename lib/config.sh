#!/usr/bin/env bash
#
# Settings resolution, shared by every script here.
#
# A value is resolved in this order, first hit wins:
#
#   1. the environment              CS_HERDR_TEMPLATE=x cs herdr new
#   2. cs-herdr.conf                written by ./setup.sh
#   3. discovery from cs            org, folder, DNS suffix, client key
#   4. a default                    only where one is safe
#
# Nothing here is specific to one Crafting site: the org, the system domain and
# the client key are all discovered, so a self-hosted site works unchanged.
#
# Bash 3.2 compatible (stock macOS): no associative arrays, no ${var^^}, no
# read -i, no mapfile.

# shellcheck shell=bash

: "${CS_HERDR_HOME:=$HOME/.cs-herdr}"

CS_HERDR_CONF="${CS_HERDR_CONF:-$CS_HERDR_ROOT/cs-herdr.conf}"

# ---------------------------------------------------------------------------
# Output
#
# Everything here goes to stderr. The binder runs as an ssh ProxyCommand, where
# stdout is the SSH byte stream and a stray echo corrupts the connection.
# ---------------------------------------------------------------------------

say()  { printf '%s\n' "$*" >&2; }
warn() { printf 'cs-herdr: %s\n' "$*" >&2; }
die()  { printf 'cs-herdr: %s\n' "$*" >&2; exit 1; }

# Append to the binder log when one has been opened. A no-op otherwise, so the
# same library code works in scripts that have no log.
log() {
    [ -n "${LOG_FILE:-}" ] || return 0
    printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >> "$LOG_FILE" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# The cs CLI
# ---------------------------------------------------------------------------

# Find cs without relying on the caller's PATH. Cursor, Herdr and ssh all run
# helpers with environments that may not have Homebrew or /opt on PATH.
find_cs() {
    if [ -n "${CS_BIN:-}" ] && [ -x "$CS_BIN" ]; then
        printf '%s' "$CS_BIN"
        return 0
    fi
    local candidate
    for candidate in \
        "$(command -v cs 2>/dev/null || true)" \
        /opt/sandboxd/bin/cs \
        /opt/homebrew/bin/cs \
        /usr/local/bin/cs \
        "$HOME/.local/bin/cs"
    do
        [ -n "$candidate" ] && [ -x "$candidate" ] && { printf '%s' "$candidate"; return 0; }
    done
    return 1
}

require_cs() {
    CS_BIN="$(find_cs)" || die "the cs CLI was not found -- install it from your Crafting site's download page"
    export CS_BIN
}

# Run cs against the configured org and folder.
cs_run() {
    "$CS_BIN" -O "$CS_HERDR_ORG" --folder "$CS_HERDR_FOLDER" "$@"
}

# True when cs holds a usable session.
cs_logged_in() {
    "$CS_BIN" org list -o json >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# cs-herdr.conf
#
# A flat KEY=VALUE file, written by ./setup.sh and read by everything.
#
# It is read key by key rather than sourced, so the file cannot execute
# anything and an unrecognized line is simply never looked at. The keys that
# mean something are the ones resolve_config asks for, below.
# ---------------------------------------------------------------------------

conf_get() {
    local key="$1"
    [ -f "$CS_HERDR_CONF" ] || return 1
    local line
    line="$(grep -E "^${key}=" "$CS_HERDR_CONF" 2>/dev/null | tail -1)" || true
    [ -n "$line" ] || return 1
    printf '%s' "${line#*=}"
}

# Write a key, replacing any existing value. Used by setup.sh and set-template.
conf_set() {
    local key="$1" value="$2" tmp
    mkdir -p "$(dirname "$CS_HERDR_CONF")"
    touch "$CS_HERDR_CONF"
    tmp="$CS_HERDR_CONF.tmp.$$"
    grep -v -E "^${key}=" "$CS_HERDR_CONF" > "$tmp" 2>/dev/null || true
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
    mv "$tmp" "$CS_HERDR_CONF"
    chmod 600 "$CS_HERDR_CONF" 2>/dev/null || true
}

# Resolve one setting: keep an existing environment value, else the conf file,
# else the fallback given here.
resolve_one() {
    local key="$1" fallback="$2" current value
    eval "current=\${$key:-}"
    if [ -n "$current" ]; then
        return 0
    fi
    value="$(conf_get "$key" || true)"
    [ -n "$value" ] || value="$fallback"
    eval "$key=\$value"
    eval "export $key"
}

# ---------------------------------------------------------------------------
# Discovery
# ---------------------------------------------------------------------------

# The org cs would use by default. Inside a sandbox that is this sandbox's org;
# outside it is whatever cs resolves, which respects its own saved selection.
discover_org() {
    if [ -n "${SANDBOX_ORG:-}" ]; then
        printf '%s' "$SANDBOX_ORG"
        return 0
    fi
    local orgs
    orgs="$("$CS_BIN" org list -o json 2>/dev/null | jq -r '.[].meta.name' 2>/dev/null)" || true
    # Only safe to auto-pick when there is exactly one.
    if [ "$(printf '%s\n' "$orgs" | grep -c . 2>/dev/null || echo 0)" = "1" ]; then
        printf '%s' "$orgs"
        return 0
    fi
    return 1
}

# The system domain sandbox hostnames live under, e.g. crafting.sandboxes.site.
#
# Inside a sandbox the platform exports it. Outside, cs itself has already
# written a wildcard Host into ~/.ssh/config on login -- that line is the most
# reliable local record of the suffix, so read it back rather than guessing.
discover_dns_suffix() {
    if [ -n "${SANDBOX_SYSTEM_DOMAIN:-}" ]; then
        printf '%s' "$SANDBOX_SYSTEM_DOMAIN"
        return 0
    fi
    local host
    host="$(grep -E "^Host \*-${CS_HERDR_ORG}\." "$HOME/.ssh/config" 2>/dev/null | head -1)" || true
    if [ -n "$host" ]; then
        host="${host#Host \*-${CS_HERDR_ORG}.}"
        printf '%s' "$host"
        return 0
    fi
    return 1
}

# The keypair cs manages for workspace SSH. Its directory also holds the
# known_hosts file the sandbox host keys are pinned in.
discover_identity() {
    local dir
    for dir in \
        "${XDG_CONFIG_HOME:-$HOME/.config}/crafting/sandbox" \
        "$HOME/.config/crafting/sandbox" \
        "$HOME/.crafting/sandbox" \
        "$HOME/Library/Application Support/crafting/sandbox"
    do
        [ -f "$dir/id_client" ] && { printf '%s' "$dir/id_client"; return 0; }
    done
    return 1
}

# ---------------------------------------------------------------------------
# resolve_config
#
# Call once, after require_cs. Every CS_HERDR_* variable is set and exported
# afterwards. Missing values that have no safe default are left empty, and the
# command that needs one says so itself -- setup.sh and doctor.sh have to run
# before anything is configured.
# ---------------------------------------------------------------------------

resolve_config() {
    resolve_one CS_HERDR_ORG       "$(discover_org || true)"
    resolve_one CS_HERDR_FOLDER    "${SANDBOX_FOLDER:-lab}"

    # No default template on purpose: creating from a guessed template would
    # build the wrong thing quietly. `new` refuses until setup.sh has asked.
    resolve_one CS_HERDR_TEMPLATE  ""

    # The Crafting workspace inside the sandbox that runs herdr.
    resolve_one CS_HERDR_WORKSPACE "dev"

    resolve_one CS_HERDR_POOL      "herdr-worker-pool"

    # The SSH alias suffix. `foo.sandbox` is Joe's convention, kept as the
    # default so an existing muscle memory keeps working.
    resolve_one CS_HERDR_SUFFIX    "sandbox"

    # Prefix for generated sandbox names.
    resolve_one CS_HERDR_PREFIX    "hd"

    CS_HERDR_DNS_SUFFIX="${CS_HERDR_DNS_SUFFIX:-$(discover_dns_suffix || true)}"
    CS_HERDR_IDENTITY="${CS_HERDR_IDENTITY:-$(discover_identity || true)}"
    CS_HERDR_KNOWN_HOSTS=""
    [ -n "$CS_HERDR_IDENTITY" ] && CS_HERDR_KNOWN_HOSTS="$(dirname "$CS_HERDR_IDENTITY")/known_hosts"

    export CS_HERDR_DNS_SUFFIX CS_HERDR_IDENTITY CS_HERDR_KNOWN_HOSTS CS_HERDR_HOME

    BINDINGS_DIR="$CS_HERDR_HOME/bindings"
    LOG_DIR="$CS_HERDR_HOME/log"
    RUN_DIR="$CS_HERDR_HOME/run"

    # Where a failed resolution leaves its reason. resolve_sandbox cannot print
    # it, because in the binder stdout is the SSH stream.
    ERR_FILE="${ERR_FILE:-$RUN_DIR/last-error.$$}"

    export BINDINGS_DIR LOG_DIR RUN_DIR ERR_FILE
}

# Create the local state directories. Kept out of resolve_config so read-only
# callers (doctor.sh reporting on a machine that was never set up) do not
# create anything as a side effect.
ensure_dirs() {
    mkdir -p "$CS_HERDR_HOME" "$BINDINGS_DIR" "$LOG_DIR" "$RUN_DIR" 2>/dev/null || true
    chmod 700 "$CS_HERDR_HOME" 2>/dev/null || true
}

# Print the resolved settings. `./setup.sh --show` and doctor.sh use this.
config_show() {
    printf '  %-24s %s\n' org         "${CS_HERDR_ORG:-(unset)}"
    printf '  %-24s %s\n' folder      "${CS_HERDR_FOLDER:-(unset)}"
    printf '  %-24s %s\n' template    "${CS_HERDR_TEMPLATE:-(unset -- run ./setup.sh)}"
    printf '  %-24s %s\n' workspace   "${CS_HERDR_WORKSPACE:-(unset)}"
    printf '  %-24s %s\n' pool        "${CS_HERDR_POOL:-(unset)}"
    printf '  %-24s %s\n' "ssh alias" "*.${CS_HERDR_SUFFIX}"
    printf '  %-24s %s\n' "dns suffix" "${CS_HERDR_DNS_SUFFIX:-(unknown -- run cs login)}"
    printf '  %-24s %s\n' identity    "${CS_HERDR_IDENTITY:-(none -- run cs login)}"
    printf '  %-24s %s\n' conf        "$CS_HERDR_CONF"
    printf '  %-24s %s\n' state       "$CS_HERDR_HOME"
}
