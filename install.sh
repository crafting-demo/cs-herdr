#!/usr/bin/env bash
#
# Configure this machine so Crafting sandboxes are reachable from Herdr.
#
# Writes three things:
#   ~/.cs-herdr/bin/cs-herdr     a link to the binder in this checkout
#   ~/.ssh/config                the Host *.sandbox block whose ProxyCommand it is
#   a PATH line in your profile  so `cs herdr` finds it as a cs extension
#
# Nothing here touches Crafting. ./bootstrap.sh does that.
#
set -euo pipefail

CS_HERDR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export CS_HERDR_ROOT
# shellcheck source=lib/config.sh
. "$CS_HERDR_ROOT/lib/config.sh"

require_cs
resolve_config
ensure_dirs

SSH_CONFIG="$HOME/.ssh/config"
BEGIN_MARK="# >>> cs-herdr >>>"
END_MARK="# <<< cs-herdr <<<"

[ -n "$CS_HERDR_IDENTITY" ] || die "no Crafting client key found -- run 'cs login' first"
[ -n "$CS_HERDR_DNS_SUFFIX" ] || die "the Crafting system domain is unknown -- run 'cs login' first"

# ---------------------------------------------------------------------------
# The binder
#
# Linked rather than copied, so a `git pull` in this checkout updates what ssh
# actually runs. The link path is what goes into ~/.ssh/config, so it must not
# change when the checkout moves.
# ---------------------------------------------------------------------------

say "Installing the binder in $CS_HERDR_HOME/bin"
mkdir -p "$CS_HERDR_HOME/bin"
BINDER="$CS_HERDR_HOME/bin/cs-herdr"
chmod +x "$CS_HERDR_ROOT/bin/cs-herdr"
rm -f "$BINDER"
if ! ln -s "$CS_HERDR_ROOT/bin/cs-herdr" "$BINDER" 2>/dev/null; then
    cp "$CS_HERDR_ROOT/bin/cs-herdr" "$BINDER"
    warn "copied the binder instead of linking it; re-run ./install.sh after updates"
fi

# ---------------------------------------------------------------------------
# ~/.ssh/config
#
# One wildcard block. Its ProxyCommand resolves the short name, resumes the
# sandbox if Crafting suspended it, and hands the connection to `cs ssh-proxy`.
#
# cs itself already writes a `Host *-ORG.SYS-DOMAIN` block on login, which
# reaches a running sandbox by its full hostname. This block adds the two things
# that block cannot: a name short enough to type, and a resume.
# ---------------------------------------------------------------------------

say "Updating $SSH_CONFIG"
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh" 2>/dev/null || true
touch "$SSH_CONFIG"
cp "$SSH_CONFIG" "$SSH_CONFIG.cs-herdr.bak"

strip_block() {
    local begin="$1" end="$2" src="$3"
    awk -v b="$begin" -v e="$end" '
        $0 == b { skip = 1 }
        !skip   { print }
        $0 == e { skip = 0 }
    ' "$src"
}

strip_block "$BEGIN_MARK" "$END_MARK" "$SSH_CONFIG.cs-herdr.bak" > "$SSH_CONFIG.tmp"

# Trim trailing blank lines so repeated installs do not accumulate them.
awk 'BEGIN{n=0} {lines[NR]=$0} END{for(i=NR;i>0&&lines[i]=="";i--) n++; for(i=1;i<=NR-n;i++) print lines[i]}' \
    "$SSH_CONFIG.tmp" > "$SSH_CONFIG.tmp2" && mv "$SSH_CONFIG.tmp2" "$SSH_CONFIG.tmp"

{
    printf '\n%s\n' "$BEGIN_MARK"
    printf '# Herdr on Crafting sandboxes. Managed by cs-herdr; edits here are replaced.\n'
    printf '#   herdr --remote NAME.%s\n' "$CS_HERDR_SUFFIX"
    printf '#   herdr --remote WORKSPACE--NAME.%s\n' "$CS_HERDR_SUFFIX"
    printf 'Host *.%s\n' "$CS_HERDR_SUFFIX"
    printf '  ProxyCommand %s __proxy %%n\n' "$BINDER"
    printf '  User owner\n'
    printf '  IdentityFile %s\n' "$CS_HERDR_IDENTITY"
    # A separate known_hosts, and no strict checking, for one reason: these are
    # short aliases, not hostnames. `payments-fix.sandbox` is whichever sandbox
    # that name is bound to now, so deleting a sandbox and making another with
    # the same name legitimately changes the key, and strict checking would turn
    # that into a scary failure on a disposable box.
    #
    # The connection is not unauthenticated: cs ssh-proxy carries it inside an
    # authenticated HTTPS tunnel to the Crafting gateway, keyed by your cs
    # login, and only then reaches the sandbox. Keeping these entries out of the
    # keypair's own known_hosts also leaves what cs manages alone.
    printf '  UserKnownHostsFile %s/known_hosts\n' "$CS_HERDR_HOME"
    printf '  StrictHostKeyChecking no\n'
    printf '  HashKnownHosts no\n'
    # Waking a suspended sandbox takes about twenty seconds, most of it
    # Crafting's. The default 15s would give up in the middle of it.
    printf '  ConnectTimeout 90\n'
    # Herdr adds its own keepalives when it manages the ssh config, but a plain
    # `ssh NAME.%s` gets none, and an idle agent session behind NAT is
    # exactly the connection that gets dropped.
    printf '  ServerAliveInterval 15\n'
    printf '  ServerAliveCountMax 4\n'
    printf '%s\n' "$END_MARK"
} >> "$SSH_CONFIG.tmp"

mv "$SSH_CONFIG.tmp" "$SSH_CONFIG"
chmod 600 "$SSH_CONFIG" 2>/dev/null || true

# ---------------------------------------------------------------------------
# PATH
#
# `cs herdr` works by cs finding an executable named cs-herdr. It looks on PATH
# first, so putting the binder there is the whole integration.
# ---------------------------------------------------------------------------

on_path() {
    command -v cs-herdr >/dev/null 2>&1 || return 1
    [ "$(command -v cs-herdr)" = "$BINDER" ]
}

if on_path; then
    say "cs-herdr is already on PATH"
else
    PROFILE=""
    case "${SHELL:-}" in
        *zsh)  PROFILE="$HOME/.zshrc" ;;
        *bash) PROFILE="$HOME/.bashrc" ;;
        *)     PROFILE="$HOME/.profile" ;;
    esac
    LINE="export PATH=\"\$HOME/.cs-herdr/bin:\$PATH\"  # cs-herdr"
    if [ -f "$PROFILE" ] && grep -Fq "# cs-herdr" "$PROFILE" 2>/dev/null; then
        say "PATH line already present in $PROFILE"
    else
        printf '\n%s\n' "$LINE" >> "$PROFILE"
        say "Added $CS_HERDR_HOME/bin to PATH in $PROFILE"
    fi
    warn "open a new shell (or: export PATH=\"\$HOME/.cs-herdr/bin:\$PATH\") before 'cs herdr' resolves"
fi

say ""
say "Installed. Next:"
if [ -z "$CS_HERDR_TEMPLATE" ]; then
    say "  ./setup.sh              choose the template new sandboxes are built from"
else
    say "  cs herdr new            a new sandbox, then attach"
    say "  cs herdr NAME           back to one you already have"
fi
say "  ./doctor.sh             check everything"
