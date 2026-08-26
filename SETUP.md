# Setting up Herdr on Crafting sandboxes

You are an agent setting this up for the person you are talking to. Read this
whole file first, then start at Step 0.

Ask one question, then go. Do not narrate each command; report what happened
when there is something to report. If something fails, run `./doctor.sh` and
follow the fix it names rather than improvising a workaround.

## What you are building

Two commands. `cs herdr new` makes a Crafting sandbox from a template and drops
the human into Herdr on it. `cs herdr NAME` takes them back to one they already
have, waking it first if Crafting suspended it. Agents keep running in the
sandbox while nobody is attached.

## Step 0: Requirements

Check all four before changing anything, and report any that are missing
together rather than one at a time:

| Need | Check | Fix |
| --- | --- | --- |
| `cs` CLI | `cs version` | download it from their Crafting site |
| logged in | `cs org list` | `cs login` |
| `jq` | `jq --version` | `brew install jq` or `apt install jq` |
| `herdr` | `herdr --version` | `curl -fsSL https://herdr.dev/install.sh \| sh` |

Herdr is needed to attach, not to install, so you can set everything else up
first if it is missing. Say so rather than silently skipping it.

## Step 1: Ask the one question

> Which Crafting template should new Herdr sandboxes be built from?

Show them what they have with `cs template list`. Two ways to answer:

- **They name a template.** Use it. It must have the `herdr` binary installed
  and a `herdr server` daemon running as `owner` — read
  `examples/herdr-worker.yaml`, which explains both requirements and why. If
  their template does not meet them, offer to add the two pieces to it, and say
  what you would be changing before you change anything of theirs.
- **They have nothing suitable, or are not sure.** Use the bundled example:
  `./setup.sh --example` creates it as a template named `herdr-worker`.

Do not ask anything else. The org, folder, site domain, and SSH key are
discovered from `cs`, and the Crafting workspace is only asked about when the
chosen template has more than one.

## Step 2: Run setup

```bash
./setup.sh              # or: ./setup.sh --example
```

That creates the template if asked, creates a warm pool on it, writes the
`Host *.sandbox` block into `~/.ssh/config`, and puts `cs-herdr` on PATH.

Pool creation can fail in orgs where only admins may create pools. That is not
fatal and setup says so: `cs herdr new` falls back to a cold build, which takes
a couple of minutes instead of seconds. Pass it along and move on.

## Step 3: Check

```bash
./doctor.sh
```

Every failure names its own fix. Work through them in order — later checks
assume the earlier ones pass.

## Step 4: Show them it works

`cs herdr` only resolves in a shell started after setup, so use an explicit
PATH in this one:

```bash
export PATH="$HOME/.cs-herdr/bin:$PATH"
cs herdr new
```

This takes over the terminal, so run it only where they can see it, or hand
them the command instead of running it yourself.

Once they are attached, tell them the three things that matter:

- Start an agent in a pane the way they normally would — `claude`, `codex`, and
  the rest. Herdr detects it and shows its state in the sidebar.
- `ctrl+b q` detaches. The agents keep working.
- `cs herdr NAME` comes back to it, from anywhere, however long later.

If they want their agent to drive Herdr in future sessions, point them at
`https://herdr.dev/agent-guide.md`.

## Notes for you

- **`new` and `NAME` are different verbs on purpose.** `cs herdr NAME` never
  creates. If a name is unknown it errors and lists what exists. Do not
  "helpfully" turn an unknown name into a `new` — landing in an empty sandbox
  that looks like the right one is the failure this design exists to prevent.
- **Do not hand-edit `~/.ssh/config`.** `install.sh` owns a marker-delimited
  block there and rewrites it wholesale. Re-run `./install.sh` instead.
- **Settings live in `cs-herdr.conf`** next to these scripts. Read it with
  `./setup.sh --show`. Any setting can be overridden per command with the
  matching `CS_HERDR_*` environment variable.
- **The `.sandbox` alias is not only for Herdr.** `ssh NAME.sandbox`, `scp`, and
  `rsync` work through the same block, and wake the sandbox the same way.
- **To undo everything local:** `./uninstall.sh`. It leaves their sandboxes
  alone; `--purge` also removes the warm pool.
