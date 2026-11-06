#!/usr/bin/env bash
# Herdr GUI / herdr-core transport. Bash 3.2 compatible.
# Unlike the old `herdr --remote` path this uses Crafting's supported `cs ssh`
# command, and needs neither the *.sandbox aliases nor a worker template.

find_hc() {
    local candidate
    for candidate in "${CS_HERDR_HC_BIN:-}" "$(command -v hc 2>/dev/null || true)" "$HOME/.local/bin/hc"; do
        [ -n "$candidate" ] && [ -x "$candidate" ] && { printf '%s' "$candidate"; return 0; }
    done
    return 1
}

# Quote one word for the local POSIX shell which hc uses to run --via.
# The remote shell line remains a separate, untouched final argument.
shell_word() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# Called afresh for probes, installation and every reconnect. Scope and sandbox
# name are recorded in the machine, not inherited from the GUI's environment
# or mutable cs-herdr.conf. Core itself checks the remote core's identity on
# reconnect, refusing a different machine after deletion/recreation.
cmd_gui_exec() {
    [ "$#" -eq 5 ] || fail "internal transport expects ORG FOLDER NAME WORKSPACE COMMAND"
    exec "$CS_BIN" -O "$1" --folder "$2" ssh -W "$3/$4" -- \
        -T -o BatchMode=yes -o ConnectTimeout=10 \
        -o ServerAliveInterval=15 -o ServerAliveCountMax=4 "$5"
}

# Sandbox readiness and Core connectivity are different: an existing machine
# can still be backing off after a failed hello when Crafting becomes ready.
gui_wait_connected() {
    local hc="$1" machine="$2" timeout="$3" deadline view state reason
    deadline=$(( $(date +%s) + timeout ))
    say "Waiting for Herdr Core connection, up to ${timeout}s"
    while :; do
        view="$("$hc" machine ls --json)" || return $?
        state="$(printf '%s' "$view" | jq -r --arg name "$machine" \
            'first(.machines[]? | select(.name == $name) | .state) // "missing"')"
        [ "$state" != connected ] || return 0
        reason="$(printf '%s' "$view" | jq -r --arg name "$machine" \
            'first(.machines[]? | select(.name == $name) | .why) // ""')"
        case "$state" in
            needs_login|needs_update|missing)
                fail "Herdr machine '$machine' is $state. $reason Check 'hc machine ls'." ;;
        esac
        if [ "$(date +%s)" -ge "$deadline" ]; then
            fail "Herdr machine '$machine' did not connect within ${timeout}s (state: $state). $reason Check 'hc machine ls'."
        fi
        sleep 1
    done
}

cmd_gui() {
    local arg="" machine="" install=0 open_gui=1 hc app json id state via word existing
    local CS_HERDR_ORG="$CS_HERDR_ORG" CS_HERDR_FOLDER="$CS_HERDR_FOLDER"
    local ready_timeout="${CS_HERDR_READY_TIMEOUT:-90}"
    local connect_timeout="${CS_HERDR_CONNECT_TIMEOUT:-60}"
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --org|--folder|--name)
                [ "$#" -ge 2 ] && [ -n "$2" ] || fail "$1 needs a value"
                case "$1" in
                    --org) CS_HERDR_ORG="$2" ;;
                    --folder) CS_HERDR_FOLDER="$2" ;;
                    --name) machine="$2" ;;
                esac
                shift 2 ;;
            --install) install=1; shift ;;
            --no-open) open_gui=0; shift ;;
            -*) fail "unknown GUI flag '$1' -- see 'cs herdr help'" ;;
            *) [ -z "$arg" ] || fail "only one sandbox target can be given"; arg="$1"; shift ;;
        esac
    done
    [ -n "$arg" ] || fail "usage: cs herdr gui NAME[/WORKSPACE] [--org ORG --folder FOLDER] [--install]"
    require_org
    case "$ready_timeout" in ''|*[!0-9]*) fail "CS_HERDR_READY_TIMEOUT must be a positive number of seconds" ;; esac
    [ "$ready_timeout" -gt 0 ] 2>/dev/null || fail "CS_HERDR_READY_TIMEOUT must be a positive number of seconds"
    case "$connect_timeout" in ''|*[!0-9]*) fail "CS_HERDR_CONNECT_TIMEOUT must be a positive number of seconds" ;; esac
    [ "$connect_timeout" -gt 0 ] 2>/dev/null || fail "CS_HERDR_CONNECT_TIMEOUT must be a positive number of seconds"
    parse_target "$arg"
    case "$TARGET_WORKSPACE" in ''|*[!a-z0-9-]*) fail "invalid workspace '$TARGET_WORKSPACE'" ;; esac
    hc="$(find_hc)" || fail "hc was not found -- install Herdr Core from https://herdr.dev/"
    if [ "$open_gui" = 1 ]; then
        app="$(command -v herdr-app 2>/dev/null || true)"
        [ -n "$app" ] || fail "herdr-app was not found -- install Herdr GUI, or pass --no-open"
    fi

    json="$(sandbox_json "$TARGET_NAME")" || fail "cannot read sandbox '$TARGET_NAME' in $CS_HERDR_ORG/$CS_HERDR_FOLDER"
    id="$(printf '%s' "$json" | jq -er '.meta.id')" || fail "sandbox has no id"
    printf '%s' "$json" | jq -e --arg ws "$TARGET_WORKSPACE" \
        'any(.spec.workloads[]?; .name == $ws and .workspace != null)' >/dev/null \
        || fail "no SSH workspace '$TARGET_WORKSPACE' in sandbox '$TARGET_NAME'"
    [ -n "$machine" ] || machine="$TARGET_NAME-$TARGET_WORKSPACE"
    # Fail before resuming or installing anything if the local name is invalid.
    case "$machine" in ''|[!a-z0-9]*|*[!a-z0-9_.-]*) fail "invalid machine name '$machine'" ;; esac
    [ "${#machine}" -le 32 ] || fail "machine name exceeds 32 characters; pass --name NAME"
    if [[ "$machine" =~ ^t[1-9][0123456789bcdfghjkmnpqrstvwxyz]*$ ]]; then
        fail "machine name '$machine' looks like a terminal id; pass --name NAME"
    fi

    # hc 0.1.18 has a 20 s hello deadline (and normal SSH uses a 10 s connect
    # timeout). Waking and readiness must finish before machine.add starts.
    # resume --wait-timeout ignores wait errors, so use the explicit wait verb.
    state="$(printf '%s' "$json" | jq -r '.spec.op_state.state // ""')"
    if [ "$state" = SUSPENDED ]; then
        say "Resuming $TARGET_NAME ($TARGET_WORKSPACE)"
        cs_run sandbox resume "$TARGET_NAME" --wait=false >&2 || fail "could not resume '$TARGET_NAME'"
    fi
    say "Waiting for $TARGET_NAME ($TARGET_WORKSPACE), up to ${ready_timeout}s"
    cs_run wait sandbox "$TARGET_NAME" --expect ready --timeout "${ready_timeout}s" >&2 \
        || fail "sandbox '$TARGET_NAME' did not become ready within ${ready_timeout}s"

    via="exec"
    for word in "$CS_HERDR_ROOT/bin/cs-herdr" __exec "$CS_HERDR_ORG" "$CS_HERDR_FOLDER" "$TARGET_NAME" "$TARGET_WORKSPACE"; do
        via="$via $(shell_word "$word")"
    done
    existing="$("$hc" machine ls --json)" || return $?
    if printf '%s' "$existing" | jq -e --arg name "$machine" 'any(.machines[]?; .name == $name)' >/dev/null; then
        printf '%s' "$existing" | jq -e --arg name "$machine" --arg via "$via" \
            'any(.machines[]?; .name == $name and .via == true and .target == $via and .session == null and .temporary != true)' >/dev/null \
            || fail "machine '$machine' already points elsewhere; choose another --name"
        say "Using existing Herdr GUI machine: $machine"
    else
        log "GUI name=$TARGET_NAME workspace=$TARGET_WORKSPACE id=$id machine=$machine"
        if [ "$install" = 1 ]; then
            "$hc" machine add --name "$machine" --via "$via" --install || return $?
        else
            "$hc" machine add --name "$machine" --via "$via" || return $?
        fi
    fi
    gui_wait_connected "$hc" "$machine" "$connect_timeout"
    say "Connected Herdr GUI machine: $machine"
    if [ "$open_gui" = 1 ]; then
        if [ "$(uname -s)" = Darwin ]; then
            # LaunchServices owns the app, so closing the invoking terminal or
            # its process group cannot tear down the GUI that was just opened.
            /usr/bin/open -a Herdr
        else
            nohup "$app" </dev/null >>"$LOG_DIR/gui.log" 2>&1 &
        fi
    fi
}
