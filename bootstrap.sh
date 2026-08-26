#!/usr/bin/env bash
#
# The Crafting side of setup: make sure the worker template exists, and keep a
# few sandboxes warm on it.
#
#   ./bootstrap.sh                 use the configured template, create the pool
#   ./bootstrap.sh --example       create or refresh examples/herdr-worker.yaml as a template
#   ./bootstrap.sh --no-pool       template only, no warm pool
#   ./bootstrap.sh --min N         how many warm sandboxes to keep (default 1)
#
# Safe to re-run: --example refreshes the bundled template from the yaml in
# this checkout; an existing pool is reported rather than replaced.
#
set -euo pipefail

CS_HERDR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export CS_HERDR_ROOT
# shellcheck source=lib/config.sh
. "$CS_HERDR_ROOT/lib/config.sh"

WANT_EXAMPLE=0
WANT_POOL=1
POOL_MIN=1
POOL_MAX=""

while [ $# -gt 0 ]; do
    case "$1" in
        --example)  WANT_EXAMPLE=1; shift ;;
        --no-pool)  WANT_POOL=0; shift ;;
        --min)      POOL_MIN="${2:-1}"; shift 2 ;;
        --max)      POOL_MAX="${2:-}"; shift 2 ;;
        -h|--help)  sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)          die "unknown argument '$1'" ;;
    esac
done

require_cs
resolve_config
cs_logged_in || die "cs is not logged in -- run 'cs login' first"
[ -n "$CS_HERDR_ORG" ] || die "no Crafting org resolved -- set CS_HERDR_ORG or pass -O to cs login"
[ -n "$POOL_MAX" ] || POOL_MAX="$POOL_MIN"

# ---------------------------------------------------------------------------
# The template
# ---------------------------------------------------------------------------

EXAMPLE_TEMPLATE_NAME="herdr-worker"

if [ "$WANT_EXAMPLE" = 1 ]; then
    say "Validating examples/herdr-worker.yaml"
    cs_run template validate "$CS_HERDR_ROOT/examples/herdr-worker.yaml" \
        || die "the example template did not validate against this site"
    if cs_run template show "$EXAMPLE_TEMPLATE_NAME" -o json >/dev/null 2>&1; then
        say "Updating template '$EXAMPLE_TEMPLATE_NAME' from examples/herdr-worker.yaml"
        cs_run template update "$EXAMPLE_TEMPLATE_NAME" "$CS_HERDR_ROOT/examples/herdr-worker.yaml" \
            || die "could not update the template"
        warn "already-running sandboxes and pooled instances still use the previous daemon; new ones pick this up"
    else
        say "Creating template '$EXAMPLE_TEMPLATE_NAME' in $CS_HERDR_ORG/$CS_HERDR_FOLDER"
        cs_run template create "$EXAMPLE_TEMPLATE_NAME" "$CS_HERDR_ROOT/examples/herdr-worker.yaml" \
            || die "could not create the template"
    fi
    conf_set CS_HERDR_TEMPLATE "$EXAMPLE_TEMPLATE_NAME"
    CS_HERDR_TEMPLATE="$EXAMPLE_TEMPLATE_NAME"
fi

[ -n "$CS_HERDR_TEMPLATE" ] \
    || die "no template configured -- run ./setup.sh, or ./bootstrap.sh --example to use the bundled one"

cs_run template show "$CS_HERDR_TEMPLATE" -o json >/dev/null 2>&1 \
    || die "no template named '$CS_HERDR_TEMPLATE' in $CS_HERDR_ORG/$CS_HERDR_FOLDER -- 'cs template list' shows yours"

say "Template: $CS_HERDR_TEMPLATE"

# ---------------------------------------------------------------------------
# The warm pool
#
# An optimization, not a prerequisite: `cs herdr new` passes --use-pool auto,
# which claims from a matching pool when one has a sandbox ready and falls back
# to a cold build when it does not.
# ---------------------------------------------------------------------------

if [ "$WANT_POOL" = 0 ]; then
    say "Skipping the warm pool (--no-pool). 'cs herdr new' will cold-build each time."
    exit 0
fi

if cs_run sandbox pool show "$CS_HERDR_POOL" -o json >/dev/null 2>&1; then
    say "Pool '$CS_HERDR_POOL' already exists; leaving it as it is."
    say "  size:   cs -O $CS_HERDR_ORG --folder $CS_HERDR_FOLDER sandbox pool update $CS_HERDR_POOL --min N"
    say "  health: cs -O $CS_HERDR_ORG --folder $CS_HERDR_FOLDER sandbox pool show $CS_HERDR_POOL"
    exit 0
fi

say "Creating warm pool '$CS_HERDR_POOL' on '$CS_HERDR_TEMPLATE' (min=$POOL_MIN max=$POOL_MAX)"

# --disable-standby keeps pooled sandboxes fully running instead of parking
# them in STANDBY. It costs more while they idle, and it is the difference
# between a claim that is usable immediately and one that has to start the
# herdr server -- which is the whole point of the pool. It only takes effect
# because the template sets detach_env.
if cs_run sandbox pool create "$CS_HERDR_POOL" \
        -t "$CS_HERDR_TEMPLATE" \
        --min "$POOL_MIN" \
        --max "$POOL_MAX" \
        --disable-standby \
        --enable >&2
then
    say ""
    say "Pool created. It takes a few minutes to build its first sandboxes;"
    say "until then 'cs herdr new' cold-builds, which still works."
    say ""
    # Creating the pool and being allowed to fill it are two different
    # permissions. In many orgs the create succeeds and every instance then
    # fails with "not allowed for action: admin", which is invisible unless you
    # look -- the only symptom is that claims stay slow.
    say "Check in a few minutes that it is actually filling:"
    say "  ./doctor.sh"
    say "If its instances error with 'not allowed for action: admin', the pool"
    say "needs an owner your org permits: recreate it with --as ADMIN@EXAMPLE.COM,"
    say "or ask an org admin to. cs-herdr works either way, just colder."
else
    warn "could not create the pool."
    warn "Pools are owned by whoever creates them, and some orgs only let admins"
    warn "create them. cs-herdr works without one -- 'cs herdr new' just cold-builds."
    warn "To retry later:  ./bootstrap.sh --min $POOL_MIN"
fi
