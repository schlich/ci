# ci

`ci` is my personal workflow for managing testing, merging, and deployment in
an opinionated way. It is a semi-automated, human-in-the-loop agent workflow:
it sets guardrails and a protocol for keeping several lines of work in progress
at once, runs tests and gates merges at defined points, and records metadata
about each change, such as which session owns it, what it declares it affects,
and which release it shipped in.

I usually let the MCP server manage it hands-off, but every step is also an
ordinary terminal command.

It is built around my own repositories and machines, so it is not meant to be
adopted elsewhere as-is, but parts of it may spark ideas for your own custom workflows.

## How it works

Each line of work is a _topic_: one [Jujutsu](https://docs.jj-vcs.dev/) change,
or a short series of them, in its own workspace. `main` moves only by
fast-forward, and only to a commit whose checks passed on that exact commit.
Landings on a machine take turns on a single runway, so one landing never
invalidates the test results of another.

The workflow is written in [Nushell](https://www.nushell.sh). The protocol is a
[constraint-based specification](JjCi.qnt) whose safety properties are
model-checked exhaustively. A Rust state machine built with
[statig](https://crates.io/crates/statig) implements the same protocol, and its
tests check it against the specification. `ci tower` is a terminal UI that
shows every topic, run, and release as it changes.

```mermaid
flowchart LR
    new([ci new]) --> edit[edit]
    edit --> preflight[ci preflight]
    preflight --> dispatch[ci dispatch]
    dispatch --> land{ci land}
    land -- runway busy --> queue[ci queue] --> land
    land -- main moved --> rebase[rebase onto main] --> land
    land -- checks fail --> edit
    land -- checks pass --> main[(fast-forward main)]
    main --> release[tag a release if user-facing]
    release --> park([ci park])
```

## Commands

| Command | What it does |
| --- | --- |
| `ci new -m MSG` | Start a topic on trunk in the current workspace. |
| `ci preflight` | Run formatting and lint hooks on the current change. |
| `ci dispatch` | Rebase the topic onto trunk and push its branch for review. |
| `ci land` | Build every check on the exact head, fast-forward `main` to it, and tag a release for user-facing changes. |
| `ci park` | Confirm the topic landed, delete its branch, and free the workspace. |

The [full workflow](docs/workflow.md) documents the rest, including parallel
workspaces, the landing queue, impact classes, and recovery.

## Running it

Nix is the only prerequisite; the package brings its own Nushell, Jujutsu,
Git, and GitHub CLI. Install Nix, for example with the
[Determinate Nix Installer](https://github.com/DeterminateSystems/nix-installer),
then run this in a Jujutsu repository:

```nu
nix run github:schlich/ci -- status
```

## Design choices

### VCS

> **Why Jujutsu?** Git identifies work only by commit hash, and amending or
> rebasing a commit gives it a new hash, so nothing stable is left to attach
> review history or metadata to. Jujutsu separates changes from commits. A
> [change](https://docs.jj-vcs.dev/latest/glossary/#change) keeps one change
> ID as it is rewritten, and each rewrite gets a new commit ID.
> `ci` keys ownership, impact declarations, and review snapshots to change IDs,
> so they survive the rebases that every dispatch and landing performs. Stable
> change IDs are also what make
> [interdiff review](https://blog.tangled.org/stacking#the-interdiff-model)
> (comparing successive versions of a patch series) and
> [stacked pull requests](https://www.stacking.dev/) practical.

### Automation and scripting

> **Why Nushell?** Nushell is bash with types. Most of `ci` is glue between
> `jj`, `gh`, `nix`, `systemd`, and JSON state files. Nushell parses their
> output into structured records and tables, so the scripts work with named
> fields instead of parsing text.
