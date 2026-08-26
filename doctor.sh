#!/usr/bin/env bash
#
# Check every requirement, and name the fix for each failure.
#
#   ./doctor.sh              the checks that cost nothing
#   ./doctor.sh --probe      also open a real connection to a sandbox
#
# Written to be run by an agent as much as a human: each failure prints the
# exact command that fixes it, so there is nothing to infer and nothing to
# improvise. Checks run in dependency order, because a later failure is usually
# just an earlier one restated.
#
set -uo pipefail

CS_HERDR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export CS_HERDR_ROOT
# shellcheck source=lib/config.sh
. "$CS_HERDR_ROOT/lib/config.sh"

PROBE=0
[ "${1:-}" = "--probe" ] && PROBE=1

PASS=0
FAIL=0
WARN=0

ok()      { printf '  ok    %s\n' "$*"; PASS=$((PASS + 1)); }
bad()     { printf '  FAIL  %s\n' "$*"; FAIL=$((FAIL + 1)); }
soft()    { printf '  warn  %s\n' "$*"; WARN=$((WARN + 1)); }
fix()     { printf '        fix: %s\n' "$*"; }
section() { printf '\n%s\n' "$*"; }

printf 'cs-herdr doctor\n'

# ---------------------------------------------------------------------------
section "Tools"
# ---------------------------------------------------------------------------

if CS_BIN="$(find_cs)"; then
    export CS_BIN
    ok "cs               $CS_BIN"
else
    bad "cs not found"
    fix "install the cs CLI from your Crafting site's download page"
    printf '\nNothing else can be checked without cs.\n'
    exit 1
fi

if command -v jq >/dev/null 2>&1; then
    ok "jq               $(command -v jq)"
else
    bad "jq not found"
    fix "brew install jq   (or: apt install jq)"
fi

HERDR_BIN=""
for c in "$(command -v herdr 2>/dev/null || true)" "$HOME/.local/bin/herdr" /opt/homebrew/bin/herdr /usr/local/bin/herdr; do
    [ -n "$c" ] && [ -x "$c" ] && { HERDR_BIN="$c"; break; }
done
if [ -n "$HERDR_BIN" ]; then
    ok "herdr            $HERDR_BIN ($("$HERDR_BIN" --version 2>/dev/null | head -1))"
else
    bad "herdr not found on this machine"
    fix "curl -fsSL https://herdr.dev/install.sh | sh   (or: brew install herdr)"
fi

if command -v ssh >/dev/null 2>&1; then
    ok "ssh              $(command -v ssh)"
else
    bad "ssh not found"
    fix "install OpenSSH"
fi

# ---------------------------------------------------------------------------
section "Crafting"
# ---------------------------------------------------------------------------

if cs_logged_in; then
    ok "logged in"
else
    bad "cs is not logged in"
    fix "cs login"
    printf '\nStopping: the remaining checks all need a session.\n'
    exit 1
fi

resolve_config
# shellcheck source=lib/sandbox.sh
. "$CS_HERDR_ROOT/lib/sandbox.sh"

if [ -n "$CS_HERDR_ORG" ]; then
    ok "org              $CS_HERDR_ORG"
else
    bad "no org resolved"
    fix "cs login -O ORG   (or: set CS_HERDR_ORG in cs-herdr.conf)"
fi

if [ -n "$CS_HERDR_DNS_SUFFIX" ]; then
    ok "site domain      $CS_HERDR_DNS_SUFFIX"
else
    bad "could not work out the Crafting system domain"
    fix "cs login   (it writes the wildcard Host block this is read from)"
fi

if [ -n "$CS_HERDR_IDENTITY" ] && [ -f "$CS_HERDR_IDENTITY" ]; then
    ok "client key       $CS_HERDR_IDENTITY"
else
    bad "no Crafting SSH client key"
    fix "cs login"
fi

# ---------------------------------------------------------------------------
section "Configuration"
# ---------------------------------------------------------------------------

if [ -f "$CS_HERDR_CONF" ]; then
    ok "conf             $CS_HERDR_CONF"
else
    soft "no cs-herdr.conf yet (using discovered values and defaults)"
    fix "./setup.sh"
fi

if [ -n "$CS_HERDR_TEMPLATE" ]; then
    if cs_run template show "$CS_HERDR_TEMPLATE" -o json >/dev/null 2>&1; then
        ok "template         $CS_HERDR_TEMPLATE"

        # A template that cannot run Herdr produces a sandbox that fails at
        # attach with a Herdr platform error, which points nowhere near the
        # cause. Say it here instead.
        tpl_json="$(cs_run template show "$CS_HERDR_TEMPLATE" -o json 2>/dev/null)"
        if printf '%s' "$tpl_json" | grep -q 'herdr'; then
            ok "  mentions herdr (binary and server daemon presumed installed)"
        else
            soft "  the template definition never mentions herdr"
            fix "a worker needs the herdr binary installed and 'herdr server' running as owner -- see examples/herdr-worker.yaml"
        fi

        tpl_workspaces="$(template_workspaces "$CS_HERDR_TEMPLATE")"
        if [ -n "$tpl_workspaces" ]; then
            if printf '%s\n' "$tpl_workspaces" | grep -qx "$CS_HERDR_WORKSPACE"; then
                ok "workspace        $CS_HERDR_WORKSPACE"
            else
                bad "template '$CS_HERDR_TEMPLATE' has no workspace named '$CS_HERDR_WORKSPACE'"
                fix "set CS_HERDR_WORKSPACE to one of: $(printf '%s' "$tpl_workspaces" | tr '\n' ' ')"
            fi
        fi
    else
        bad "no template named '$CS_HERDR_TEMPLATE' in $CS_HERDR_ORG/$CS_HERDR_FOLDER"
        fix "cs herdr set-template NAME   ('cs template list' shows yours)"
    fi
else
    bad "no default template configured; 'cs herdr new' cannot run"
    fix "./setup.sh   (or: ./setup.sh --example to use the bundled one)"
fi

if [ -n "$CS_HERDR_POOL" ] && pool_json="$(cs_run sandbox pool show "$CS_HERDR_POOL" -o json 2>/dev/null)" \
   && [ -n "$pool_json" ]; then
    # Existing is not the same as working. A pool whose instances keep failing
    # reports itself perfectly happily, and the only visible symptom is that
    # `cs herdr new` quietly takes two minutes instead of five seconds.
    pool_err="$(printf '%s' "$pool_json" | jq -r '
        (if type == "array" then .[0] else . end)
        | [.instances[]? | select(.status.error.message) | .status.error.message]
        | first // empty' 2>/dev/null)"
    pool_ready="$(printf '%s' "$pool_json" | jq -r '
        (if type == "array" then .[0] else . end)
        | [.instances[]? | select(.status.state == "READY" or .status.state == "RUNNING")]
        | length' 2>/dev/null)"

    if [ -n "$pool_err" ]; then
        soft "pool '$CS_HERDR_POOL' exists but its sandboxes are failing to build"
        printf '        %s\n' "$pool_err"
        case "$pool_err" in
            *admin*|*permission_denied*)
                fix "pooled sandboxes need an owner allowed to create them: recreate with an owner your org permits, e.g. 'cs sandbox pool remove $CS_HERDR_POOL -f' then 'cs sandbox pool create $CS_HERDR_POOL -t $CS_HERDR_TEMPLATE --min 1 --disable-standby --as ADMIN@EXAMPLE.COM', or ask an org admin to create it" ;;
            *)
                fix "cs -O $CS_HERDR_ORG --folder $CS_HERDR_FOLDER sandbox pool show $CS_HERDR_POOL" ;;
        esac
        printf '        note: not fatal -- "cs herdr new" falls back to a cold build\n'
    elif [ "${pool_ready:-0}" -gt 0 ] 2>/dev/null; then
        ok "warm pool        $CS_HERDR_POOL ($pool_ready ready)"
    else
        soft "pool '$CS_HERDR_POOL' has no ready sandboxes yet"
        fix "wait a few minutes for it to build, or check: cs -O $CS_HERDR_ORG --folder $CS_HERDR_FOLDER sandbox pool show $CS_HERDR_POOL"
    fi
else
    soft "no warm pool '$CS_HERDR_POOL' -- 'cs herdr new' cold-builds (slower, still works)"
    fix "./bootstrap.sh --min 1"
fi

# ---------------------------------------------------------------------------
section "This machine"
# ---------------------------------------------------------------------------

BINDER="$CS_HERDR_HOME/bin/cs-herdr"
if [ -x "$BINDER" ]; then
    ok "binder           $BINDER"
else
    bad "the binder is not installed at $BINDER"
    fix "./install.sh"
fi

# The whole `cs herdr` spelling depends on this one thing: cs looks for an
# executable named cs-herdr on PATH.
if command -v cs-herdr >/dev/null 2>&1; then
    ok "on PATH          $(command -v cs-herdr)   ('cs herdr' resolves)"
else
    bad "cs-herdr is not on PATH, so 'cs herdr' will not resolve"
    fix "open a new shell, or: export PATH=\"\$HOME/.cs-herdr/bin:\$PATH\""
fi

SSH_CONFIG="$HOME/.ssh/config"
if grep -Fq "# >>> cs-herdr >>>" "$SSH_CONFIG" 2>/dev/null; then
    ok "ssh block        Host *.$CS_HERDR_SUFFIX in $SSH_CONFIG"
else
    bad "no cs-herdr block in $SSH_CONFIG"
    fix "./install.sh"
fi

# Ask ssh what it actually resolves, rather than trusting that the file says
# what we wrote: an earlier Host block can win, and that is invisible in a diff.
if command -v ssh >/dev/null 2>&1; then
    resolved="$(ssh -G "doctor-probe.$CS_HERDR_SUFFIX" 2>/dev/null | grep -i '^proxycommand ' | head -1)"
    case "$resolved" in
        *cs-herdr*__proxy*) ok "ssh resolution   the alias reaches the cs-herdr binder" ;;
        "")                 bad "ssh has no ProxyCommand for *.$CS_HERDR_SUFFIX"
                            fix "./install.sh" ;;
        *)                  bad "another config block claims *.$CS_HERDR_SUFFIX first: $resolved"
                            fix "move the cs-herdr block above the conflicting Host in $SSH_CONFIG (ssh uses the first match)" ;;
    esac
fi

# ---------------------------------------------------------------------------
section "Sandboxes"
# ---------------------------------------------------------------------------

count="$(binding_count)"
if [ "$count" -gt 0 ] 2>/dev/null; then
    ok "known here       $count"
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        state="$(sandbox_state "$name")"
        case "$state" in
            "")          soft "  $name -- gone from Crafting" ; fix "cs herdr rm $name" ;;
            SUSPENDED)   ok   "  $name (suspended; 'cs herdr $name' wakes it)" ;;
            *)           ok   "  $name ($state)" ;;
        esac
    done <<EOF
$(binding_names)
EOF
else
    soft "no sandboxes known from this machine yet"
    fix "cs herdr new"
fi

# ---------------------------------------------------------------------------
# The live probe
#
# Everything above is local inspection. This is the only check that proves the
# path end to end -- resolve, wake, tunnel, SSH, and herdr actually installed
# in the sandbox -- so it is opt-in rather than part of a routine run.
# ---------------------------------------------------------------------------

if [ "$PROBE" = 1 ]; then
    section "Live probe"
    target="$(last_used_read)"
    [ -n "$target" ] || target="$(binding_names | head -1)"

    if [ -z "$target" ]; then
        soft "nothing to probe"
        fix "cs herdr new, then re-run ./doctor.sh --probe"
    else
        printf '  probing %s ...\n' "$target"
        if out="$(ssh -o BatchMode=yes -o ConnectTimeout=90 \
                      "$target.$CS_HERDR_SUFFIX" \
                      'echo READY; command -v herdr || echo NO_HERDR; pgrep -f "herdr server" >/dev/null && echo SERVER_UP || echo SERVER_DOWN' \
                      2>&1)"
        then
            case "$out" in
                *READY*) ok "ssh              connected to $target" ;;
            esac
            case "$out" in
                *NO_HERDR*) bad "herdr is not installed in the sandbox"
                            fix "the template must install it -- see examples/herdr-worker.yaml, then rebuild: cs herdr rm $target --delete && cs herdr new $target" ;;
                *)          ok "herdr            installed in the sandbox" ;;
            esac
            case "$out" in
                *SERVER_UP*)   ok "herdr server     running (agents survive detach)" ;;
                *SERVER_DOWN*) soft "no herdr server running in the sandbox"
                               fix "add a 'herdr server' daemon to the template -- see examples/herdr-worker.yaml" ;;
            esac
        else
            bad "could not reach $target.$CS_HERDR_SUFFIX"
            printf '        %s\n' "$out" | head -5
            fix "check $LOG_DIR/binder.log, then: cs -O $CS_HERDR_ORG --folder $CS_HERDR_FOLDER sandbox show $target"
        fi
    fi
fi

# ---------------------------------------------------------------------------

printf '\n%s passed, %s warnings, %s failed\n' "$PASS" "$WARN" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
    printf 'Fix the failures above, in order, then re-run ./doctor.sh\n'
    exit 1
fi
if [ "$WARN" -gt 0 ]; then
    printf 'Usable. The warnings are optional improvements.\n'
fi
exit 0
