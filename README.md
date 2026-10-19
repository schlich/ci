# ci

**Trunk-based delivery for [Jujutsu](https://jj-vcs.github.io/jj/), built for
a repository that people and AI agents change at the same time.**

`ci` carries each change, a _topic_, from a fresh working copy to `main`. It
sequences the topic against the others in flight, tests the exact commit
`main` will receive, fast-forwards `main` to it, and tags a release when the
change alters a machine. Nothing else moves `main`, so every commit on it is
one that a check ran on, as it is.

```text
 ✈ ci tower   1 Board  2 Runs  3 Trunk   main 3409115 · ⚑ 2026.10.19.17 · checks idle
╭ ytnrvvzy · default ─────────────────────────────────────────────────  ✎ editing  ╮
│ land: return to the default checkout after parking its own workspace             │
│                                                                                  │
│  new       preflight     dispatch       clearance       land         park        │
│  ●━━━━━━━━━━━━━◉┄┄┄┄┄┄┄┄┄┄┄┄┄○┄┄┄┄┄┄┄┄┄┄┄┄┄┄○┄┄┄┄┄┄┄┄┄┄┄┄┄○┄┄┄┄┄┄┄┄┄┄┄┄┄○        │
│                                                                                  │
│ NEXT    run `ci preflight`, then `ci dispatch`                                   │
╰──────────────────────────────────────────────────────────────────────────────────╯
 NORMAL  j/k move  ␣ actions  l line  ⏎ runs  / filter  y yank id  ⇥ view
```

<sub>`ci tower`, the live terminal view of every topic, run, and release.</sub>

## Why it exists

Several agent sessions and a person working one repository at once break the
usual assumptions. Sessions moved each other's working copies, rebased topics
out from under one another, and raced to land. On one afternoon, landings that
took 4 minutes alone took 30 to 77 minutes each when five ran together, and
two never landed. `ci` is the protocol that made that traffic safe and fast.

## Design

- **Proven before it is coded.** The protocol is a
  [Quint](https://quint-lang.org) model, [`JjCi.qnt`](JjCi.qnt), checked
  exhaustively with TLC: `main` only ever moves to the exact head a gate
  passed, from the trunk that head was based on. A Rust
  [statig](https://crates.io/crates/statig) state machine in
  [`lifecycle/`](lifecycle) implements the same protocol, and its tests walk
  every state of the model to keep the two in step.
- **A runway, not a retry loop.** Landings take numbered tickets on one
  machine-wide runway. Queued topics fly as _trains_ that share one test run.
  When a train fails, `ci` bisects it in about log₂(N) runs, lands the good
  prefix, and names the culprit.
- **Agents as first-class users.** Each session owns one workspace and one
  topic. Hooks for Claude Code and Codex claim, guard, and hand off
  workspaces, and an [MCP](https://modelcontextprotocol.io) server runs every
  command as a durable job that survives the client restarting.
- **Releases that mean something.** Every change declares its impact. A
  `refactor` must leave every NixOS closure unchanged, and `ci`
  proves it. A `behavior` or `breaking` change cuts a CalVer release whose
  notes are the reviewed change itself.
- **Observable by default.** Every step is an OSC 7501 status, an
  OpenTelemetry log record, and a span in a per-landing trace, so you can see
  where a landing's time went.
- **Recoverable.** Every history rewrite records a checkpoint, and
  `ci recover` reverts only that rewrite's operations, leaving other
  workspaces' work intact.

## In a terminal

```nu
ci new -m "Fix login timeout"   # start a topic on trunk
ci impact set behavior          # declare what it does to the machines
ci preflight                    # lint and pre-activation checks
ci dispatch                     # push the topic for review
ci land                         # test the exact head, fast-forward main, tag
ci park                         # confirm the landing and free the workspace
```

## Built with

| | |
| --- | --- |
| [Nushell](https://www.nushell.sh) | the workflow, `ci.nu`, and its property-based test suites |
| Rust | the lifecycle state machine and `ci tower` ([ratatui](https://ratatui.rs)) |
| Quint and TLC | the formal model of the protocol |
| Nix | packaging, the build checks that gate landing, and closure proofs |
| Python | the MCP server |
| XState | the deterministic dispatch-and-landing agent |

Use it from another repository as a flake input. The package installs `ci`,
`ci tower`, `context-status`, and `ci-mcp`, and every repository runs the
version its lock file pins.

## Read more

- [**The workflow in full**](docs/workflow.md): locks, the landing line,
  trains, impact classes, verification, and agent sessions.
- [`JjCi.qnt`](JjCi.qnt): the protocol in about 500 lines.
- [`.agents/skills/ci`](.agents/skills/ci/SKILL.md): how an agent decides
  which command to run.
