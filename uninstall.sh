#!/usr/bin/env bash
#
# Unwire this machine. Your sandboxes are left alone.
#
#   ./uninstall.sh            local only: ssh block, PATH line, ~/.cs-herdr
#   ./uninstall.sh --purge    also delete the pool and template bootstrap made
#
set -euo pipefail

CS_HERDR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export CS_HERDR_ROOT
# shellcheck source=lib/config.sh
. "$CS_HERDR_ROOT/lib/config.sh"

PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

require_cs
resolve_config

SSH_CONFIG="$HOME/.ssh/config"
BEGIN_MARK="# >>> cs-herdr >>>"
END_MARK="# <<< cs-herdr <<<"

# ---------------------------------------------------------------------------
# ~/.ssh/config
# ---------------------------------------------------------------------------

if [ -f "$SSH_CONFIG" ] && grep -Fq "$BEGIN_MARK" "$SSH_CONFIG" 2>/dev/null; then
    say "Removing the cs-herdr block from $SSH_CONFIG"
    cp "$SSH_CONFIG" "$SSH_CONFIG.cs-herdr.bak"
    awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
        $0 == b { skip = 1 }
        !skip   { print }
        $0 == e { skip = 0 }
    ' "$SSH_CONFIG.cs-herdr.bak" > "$SSH_CONFIG.tmp"

    # install.sh puts a blank line before its block; drop the trailing blanks it
    # leaves behind so uninstalling restores the file rather than just emptying
    # the block out of it.
    awk 'BEGIN{n=0} {lines[NR]=$0} END{for(i=NR;i>0&&lines[i]=="";i--) n++; for(i=1;i<=NR-n;i++) print lines[i]}' \
        "$SSH_CONFIG.tmp" > "$SSH_CONFIG.tmp2" && mv "$SSH_CONFIG.tmp2" "$SSH_CONFIG.tmp"

    mv "$SSH_CONFIG.tmp" "$SSH_CONFIG"
    chmod 600 "$SSH_CONFIG" 2>/dev/null || true
else
    say "No cs-herdr block in $SSH_CONFIG"
fi

# ---------------------------------------------------------------------------
# PATH
#
# Removed rather than left behind, since the directory it points at is about to
# stop existing.
# ---------------------------------------------------------------------------

for profile in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.profile"; do
    [ -f "$profile" ] || continue
    if grep -Fq "# cs-herdr" "$profile" 2>/dev/null; then
        say "Removing the PATH line from $profile"
        cp "$profile" "$profile.cs-herdr.bak"
        grep -Fv "# cs-herdr" "$profile.cs-herdr.bak" > "$profile.tmp"
        mv "$profile.tmp" "$profile"
    fi
done

# ---------------------------------------------------------------------------
# Local state
#
# Bindings are only a cache of which name maps to which sandbox, so removing
# them loses nothing that is not still in Crafting.
# ---------------------------------------------------------------------------

if [ -d "$CS_HERDR_HOME" ]; then
    say "Removing $CS_HERDR_HOME"
    rm -rf "$CS_HERDR_HOME"
fi

# ---------------------------------------------------------------------------
# The Crafting side
# ---------------------------------------------------------------------------

if [ "$PURGE" = 1 ]; then
    if [ -n "$CS_HERDR_POOL" ]; then
        say "Deleting pool $CS_HERDR_POOL"
        cs_run sandbox pool remove "$CS_HERDR_POOL" -f >/dev/null 2>&1 \
            || warn "could not delete pool $CS_HERDR_POOL (it may not exist)"
    fi
    say ""
    warn "templates and sandboxes were NOT deleted -- they may predate cs-herdr."
    warn "To see what is left:  cs -O $CS_HERDR_ORG --folder $CS_HERDR_FOLDER sandbox list"
    rm -f "$CS_HERDR_CONF"
    say "Removed $CS_HERDR_CONF"
fi

say ""
say "Done. The cs CLI and your cs login were left untouched."
[ "$PURGE" = 1 ] || say "Your sandboxes and the warm pool are still there; --purge removes the pool."
