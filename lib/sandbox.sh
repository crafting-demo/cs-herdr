#!/usr/bin/env bash
#
# Sandbox resolution: name -> id -> workspace hostname, plus claiming, resuming
# and the locking that keeps two connections from claiming twice.
#
# Sourced by bin/cs-herdr after lib/config.sh. Nothing here prints to stdout
# except the one value a function is asked for, because the binder's stdout is
# the SSH byte stream.

# shellcheck shell=bash

# ---------------------------------------------------------------------------
# Reading a sandbox
# ---------------------------------------------------------------------------

# The full JSON for one sandbox, or non-zero if it does not exist.
sandbox_json() {
    local name="$1"
    cs_run sandbox show "$name" -o json 2>/dev/null
}

# SUSPENDED, or the first workload's reported state (READY, RUNNING, ...).
# Empty when the sandbox does not exist.
#
# spec.op_state.state is the authority for suspension: a suspended sandbox
# still reports stale workload states, so it has to be checked first.
sandbox_state() {
    local name="$1" json
    json="$(sandbox_json "$name")" || return 0
    [ -n "$json" ] || return 0
    printf '%s' "$json" | jq -r '
        if (.spec.op_state.state // "") == "SUSPENDED" then "SUSPENDED"
        else (.status.workloads[0].agent.overview.state
              // .status.workloads[0].status.state
              // "UNKNOWN") end' 2>/dev/null
}

sandbox_id() {
    local name="$1"
    sandbox_json "$name" | jq -r '.meta.id // empty' 2>/dev/null
}

# The workspace (workload) names the sandbox defines.
sandbox_workspaces() {
    local name="$1"
    sandbox_json "$name" | jq -r '.spec.workloads[]?.name // empty' 2>/dev/null
}

sandbox_exists() {
    local name="$1"
    [ -n "$(sandbox_id "$name")" ]
}

# ---------------------------------------------------------------------------
# Reading a template
#
# A template is shaped differently from a sandbox: it is {meta, definition} and
# its containers live at definition.workspaces, where a sandbox has them at
# spec.workloads. Both are checked so one helper serves either.
# ---------------------------------------------------------------------------

template_exists() {
    local name="$1"
    cs_run template show "$name" -o json >/dev/null 2>&1
}

template_workspaces() {
    local name="$1"
    cs_run template show "$name" -o json 2>/dev/null | jq -r '
        (if type == "array" then .[0] else . end)
        | (.definition.workspaces // .spec.workloads // [])
        | .[]?.name // empty' 2>/dev/null
}

# A state we can open an SSH connection to. SUSPENDED is usable only after a
# resume, which resolve_alias does before it gets here.
usable_state() {
    case "$1" in
        READY|RUNNING|ACTIVE) return 0 ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# The workspace SSH hostname
#
# Crafting's real form is WORKSPACE--SANDBOX-ORG.SYS-DOMAIN. The sandbox id is
# used rather than its name: ids are unique across folders, so a hostname built
# from one cannot be ambiguous the way `lab/foo` and `shared/foo` are.
# ---------------------------------------------------------------------------

worker_hostname() {
    local id="$1" workspace="$2"
    printf '%s--%s-%s.%s' "$workspace" "$id" "$CS_HERDR_ORG" "$CS_HERDR_DNS_SUFFIX"
}

# ---------------------------------------------------------------------------
# Locking
#
# flock where it exists, an mkdir lock on stock macOS (which has no flock).
# Held only around the fast bookkeeping, never around `cs sandbox create`, so
# two new sandboxes still provision concurrently.
# ---------------------------------------------------------------------------

lock_acquire() {
    local name="$1" lockdir waited
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$RUN_DIR/$name.lock"
        flock 9
        return 0
    fi
    lockdir="$RUN_DIR/$name.lock.d"
    waited=0
    while ! mkdir "$lockdir" 2>/dev/null; do
        # A lock older than a minute is a crashed holder, not a slow one.
        if [ -d "$lockdir" ] && [ -n "$(find "$lockdir" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
            rmdir "$lockdir" 2>/dev/null || true
            continue
        fi
        sleep 1
        waited=$((waited + 1))
        [ "$waited" -ge 60 ] && return 0
    done
    return 0
}

lock_release() {
    local name="$1"
    if command -v flock >/dev/null 2>&1; then
        exec 9>&- 2>/dev/null || true
        return 0
    fi
    rmdir "$RUN_DIR/$name.lock.d" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Bindings
#
# A binding is the cached answer to "where does this name live": the sandbox id
# and the hostname built from it. Resolution is confirmed against Crafting
# before every connection anyway; the cache only saves the id lookup.
# ---------------------------------------------------------------------------

binding_host()  { cat "$BINDINGS_DIR/$1.host" 2>/dev/null; }
binding_id()    { cat "$BINDINGS_DIR/$1.id" 2>/dev/null; }

binding_write() {
    local name="$1" id="$2" host="$3"
    mkdir -p "$BINDINGS_DIR" 2>/dev/null || true
    printf '%s' "$id"   > "$BINDINGS_DIR/$name.id"
    printf '%s' "$host" > "$BINDINGS_DIR/$name.host"
}

binding_forget() {
    local name="$1"
    rm -f "$BINDINGS_DIR/$name.id" "$BINDINGS_DIR/$name.host" 2>/dev/null || true
}

binding_names() {
    local f b
    [ -d "$BINDINGS_DIR" ] || return 0
    for f in "$BINDINGS_DIR"/*.id; do
        [ -f "$f" ] || continue
        b="$(basename "$f")"
        printf '%s\n' "${b%.id}"
    done
}

binding_count() {
    local n
    n="$(binding_names | grep -c . 2>/dev/null)" || n=0
    printf '%s' "${n:-0}"
}

# The name most recently connected to, for a bare `cs herdr` with no argument.
last_used_write() { printf '%s' "$1" > "$CS_HERDR_HOME/last-used" 2>/dev/null || true; }
last_used_read()  { cat "$CS_HERDR_HOME/last-used" 2>/dev/null; }

# ---------------------------------------------------------------------------
# Resolution
#
# Turn a sandbox name into a hostname that can be connected to right now,
# resuming the sandbox if Crafting suspended it.
#
# Prints "ID HOST" on success. On failure, prints nothing and writes the reason
# to ERR_FILE so the caller can show it to the user -- an error message on
# stdout would be fed into the SSH stream.
# ---------------------------------------------------------------------------

resolve_sandbox() {
    local name="$1" workspace="$2" state id host

    : > "$ERR_FILE"

    state="$(sandbox_state "$name")"
    if [ -z "$state" ]; then
        printf "no sandbox named '%s' in %s/%s -- 'cs herdr new %s' would create it\n" \
            "$name" "$CS_HERDR_ORG" "$CS_HERDR_FOLDER" "$name" > "$ERR_FILE"
        return 1
    fi

    if [ "$state" = "SUSPENDED" ]; then
        log "RESUME name=$name"
        if ! cs_run sandbox resume "$name" --wait >/dev/null 2>&1; then
            printf "sandbox '%s' is suspended and could not be resumed\n" "$name" > "$ERR_FILE"
            return 1
        fi
        state="$(sandbox_state "$name")"
    fi

    if ! usable_state "$state"; then
        printf "sandbox '%s' is not usable (state: %s)\n" "$name" "$state" > "$ERR_FILE"
        return 1
    fi

    id="$(sandbox_id "$name")"
    if [ -z "$id" ]; then
        printf "could not read the id of sandbox '%s'\n" "$name" > "$ERR_FILE"
        return 1
    fi

    if [ -z "$CS_HERDR_DNS_SUFFIX" ]; then
        printf "the Crafting system domain is unknown -- run 'cs login'\n" > "$ERR_FILE"
        return 1
    fi

    host="$(worker_hostname "$id" "$workspace")"
    binding_write "$name" "$id" "$host"
    printf '%s %s' "$id" "$host"
}

# ---------------------------------------------------------------------------
# Claiming
#
# `--use-pool auto` claims from a matching warm pool when one exists and falls
# back to a cold build when it does not, so the pool is an optimization rather
# than a prerequisite.
# ---------------------------------------------------------------------------

claim_sandbox() {
    local name="$1" template="$2"
    log "CLAIM name=$name template=$template"
    cs_run sandbox create "$name" -t "$template" --use-pool auto --wait >&2
}

# A short, readable, unique-enough name. Crafting caps sandbox names at 20
# characters, so the prefix plus one word pair has to fit inside that.
generate_name() {
    local adjectives="brave calm clever eager fair keen lively neat proud swift warm witty bold bright"
    local animals="otter finch heron ibex koala lynx moth newt owl puma quail raven seal tapir wren"
    local adj ani n i=0
    while [ "$i" -lt 20 ]; do
        adj="$(pick_word "$adjectives")"
        ani="$(pick_word "$animals")"
        n="$CS_HERDR_PREFIX-$adj-$ani"
        # Leave the 20-character cap intact rather than letting Crafting
        # silently shorten the name, which would break `cs herdr NAME`.
        if [ "${#n}" -le 20 ] && ! sandbox_exists "$n"; then
            printf '%s' "$n"
            return 0
        fi
        i=$((i + 1))
    done
    printf '%s-%s' "$CS_HERDR_PREFIX" "$(date +%s | tail -c 7)"
}

pick_word() {
    local words="$1" count idx
    # shellcheck disable=SC2086
    set -- $words
    count=$#
    idx=$(( (RANDOM % count) + 1 ))
    eval "printf '%s' \"\${$idx}\""
}
