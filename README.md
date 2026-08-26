# cs-herdr

Run [Herdr](https://herdr.dev/) on Crafting sandboxes. `cs herdr new` makes one
and attaches; `cs herdr NAME` takes you back. Agents keep working after you
detach, close the laptop, or lose the network.

A `cs` CLI extension, spelled `cs herdr`. Works with any Crafting site.

## Install

Needs `cs` logged in (`cs login`), `herdr` on this machine, `jq`, and a template
in your org. macOS and Linux.

```bash
git clone https://github.com/crafting-demo/cs-herdr && cd cs-herdr
./setup.sh
```

Asks which template to build from, starts a warm pool, and wires this machine.
`./setup.sh --example` creates a starter template if you have none.

Or paste this into an agent chat:

> Clone https://github.com/crafting-demo/cs-herdr and follow its SETUP.md to set
> up Herdr on Crafting sandboxes for me.

## Everyday use

```bash
cs herdr new                 # a new sandbox, then attach
cs herdr new payments-fix    # the same, named
cs herdr payments-fix        # back to that sandbox
cs herdr                     # back to the last one you used
```

`new` claims from the warm pool. `cs herdr NAME` resumes if Crafting suspended
the sandbox; it never creates — an unknown name is an error and a list.

Detach with `ctrl+b q`. The herdr server keeps running; `cs herdr NAME` returns
you to the same panes.

### What survives what

| | Agents keep running | Panes come back |
| --- | --- | --- |
| You detach, close the laptop, or lose the network | yes | yes |
| Crafting suspends the idle sandbox | no | yes |

A Crafting **suspend** freezes the container. The herdr server restarts on wake
and restores layout; processes inside panes are gone. Agent integrations
(`herdr integration install claude`) can restore their own sessions; anything
else you restart yourself. `cs herdr NAME` wakes a suspended sandbox.

Once attached, Herdr is ordinary Herdr. Extra spaces are `herdr` commands inside
the one sandbox, not extra sandboxes.

### The plain herdr command still works

Setup installs `Host *.sandbox` in `~/.ssh/config`, so any SSH client can reach
a sandbox by a short name and resume it on connect:

```bash
herdr --remote payments-fix.sandbox
herdr --remote db--payments-fix.sandbox   # a specific Crafting workspace
```

`cs herdr NAME` is that plus the resume-and-check. The alias also works for
`scp`, `git`, `rsync`, and editors.

## How it works

```mermaid
flowchart LR
    verb["cs herdr new / cs herdr NAME"] --> resolve["resolve: claim or resume"]
    resolve --> attach["exec herdr --remote NAME.sandbox"]
    attach --> stanza["Host *.sandbox"]
    stanza -->|ProxyCommand| binder["cs-herdr __proxy"]
    binder -->|"cs ssh-proxy"| box["the sandbox"]
    box --> server["herdr server"]
    server --> agents["your agents"]
```

Three different "workspaces":

| Layer | What it is | Who owns it |
| --- | --- | --- |
| Crafting sandbox | the machine | `cs herdr new` / `cs herdr NAME` |
| Crafting workspace | a container in that sandbox | chosen at setup; `NAME/ws` to override |
| Herdr space | a pane group inside the herdr server | you and your agents, after attach |

One sandbox holds the whole herd. Herdr's sidebar is how you see them.

## Commands

| Command | What it does |
| --- | --- |
| `cs herdr new [NAME]` | create from the default template and attach |
| `cs herdr new --template T` | the same, from another template, this once |
| `cs herdr NAME[/WORKSPACE]` | resume if needed and attach; never creates |
| `cs herdr ls` | your sandboxes, their state, and their hostname |
| `cs herdr rm NAME [--delete]` | forget a name; optionally delete its sandbox |
| `cs herdr set-template NAME` | change what `new` builds from, from now on |
| `cs herdr status` | the resolved settings |
| `./doctor.sh` | check every requirement, with a named fix per failure |
| `./uninstall.sh` | unwire this machine and leave your sandboxes alone |

## Speed

Warm-pool claim: a few seconds. Cold build: a couple of minutes. Reconnect to a
running sandbox: about a second. Wake a suspended one: about twenty seconds;
`cs herdr NAME` waits for you.

The `*.sandbox` ProxyCommand retries a wake after a cached hostname fails.
Herdr itself does not retry, and would otherwise stop with `remote platform
detection failed`.

The worker template ships `herdr` already installed and running as a daemon,
because Herdr will not install itself through a non-interactive ProxyCommand.
See [examples/herdr-worker.yaml](examples/herdr-worker.yaml).

## Layout

| Path | Purpose |
| --- | --- |
| `SETUP.md` | the wizard prompt an agent follows to install it for you |
| `bin/cs-herdr` | the two verbs, and the ProxyCommand binder behind them |
| `lib/config.sh` | env -> conf -> cs discovery -> default resolution |
| `lib/sandbox.sh` | name -> sandbox resolution, claiming, resuming, locking |
| `setup.sh` | one command for the whole install |
| `bootstrap.sh` | the Crafting side: the warm pool on your template |
| `install.sh` / `uninstall.sh` | this machine's `~/.ssh/config` and PATH |
| `examples/herdr-worker.yaml` | an example template, created by `--example` |
| `doctor.sh` | health checks with a named fix per failure |

MIT licensed.
