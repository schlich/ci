# ci

`ci` carries Jujutsu topics to trunk: a topic is started, sequenced against
the others in flight, preflighted, dispatched to Tangled, cleared by checks
built on the exact head, fast-forwarded onto `main`, and parked, with every
user-facing landing cut as a CalVer release. It grew inside the
[dotfiles](https://tangled.org/schlich.tngl.sh/dotfiles) repository and was
split out of it at commit `91bf664f17ae`, whose history keeps every earlier
change to these files (`jj log -- jj/ci.nu` there).

| Path | What it is |
| --- | --- |
| `ci.nu`, `ci-launch.nu`, `ci-package.nix` | the workflow, the launcher that picks which `ci.nu` runs, and its package |
| `JjCi.tla`, `JjCi.cfg`, `lifecycle/` | the protocol as a TLA+ model and as the statig machine checked against it |
| `context-status.nu` | the topic readout for the prompt, the shell, and agent hooks |
| `codex-session.nu`, `guard.nu` | Codex task ownership, and the interactive `jj new` guard (Claude Code sessions claim through `context-status guard`) |
| `mcp.py`, `mcp-package.nix` | the workflow as MCP tools, run as jobs agents can follow |
| `tower/` | `ci tower`, the live terminal view of every topic and run |
| `completions.nu`, `workspace.nu`, `describe.nu` | Nushell completions, `jw`, and `jj-describe` |
| `.agents/skills/ci` | the agent skill describing when to use each command |
| `tests/` | property tests for the helpers, against the model's invariants |

## Using it from a repository

A repository takes `ci` as a flake input and installs its packages:
`packages.<system>.ci` (with `ci tower`), `context-status`, `ci-mcp`,
`codex-jj-session`, and `jj-describe`. `lib.nushell` names the files to
source for completions, the guard, and `jw`, and `lib.skills.ci` the skill.
Every repository runs the `ci.nu` its lock file pins; `nix flake update ci`
moves to a newer one.

## Stately dispatch and landing

Single-topic `ci dispatch`, `ci dispatch --land`, and `ci land` use the
Stately agent in `agent/machine.mjs`. It names the work that used to live in
the landing retry loop: publishing, checking landability, queueing,
refreshing trunk, republishing, proving, clearing, and advancing. Progress
reports expose the current state through the existing OSC 7501 and ci log
channels. Dispatch ends in `dispatched`; only an explicitly requested landing
enters the landing states. Stacked review and train landing keep their
separate orchestration.

The agent is deterministic and needs no model, provider SDK, or credentials.
Nushell executes the existing policy operations under the same topic lock
and landing queue. Clearance must name the published head before advancing;
only a lost landing race retries, up to `--attempts`. Conflicts, failed
checks, and other command errors stop. Rewritten heads are redispatched and
cleared again. No activation is part of this flow.

The npm lockfile pins the alpha agent and its exact XState peer. The Nix
package fetches those tarballs by their lockfile integrity hashes, without
an install script or network access at runtime. This published agent version
predates the guide's step helpers, so the host uses XState's pure transition
API with a `setupAgent` machine. JSON snapshots move between host steps
inside one locked run. They are not durable checkpoints: after interruption,
rerun the command to observe repository and remote state afresh rather than
replay a remote effect whose outcome may be unknown.

For development, install the pinned dependencies in `agent/`, then point both
overrides at this checkout when exercising the workflow from another repo:

```nu
$env.CI_SCRIPT = '/path/to/ci/ci.nu'
$env.CI_AGENT_SCRIPT = '/path/to/ci/agent/cli.mjs'
```

`checks.x86_64-linux.ci-agent` covers dispatch-only termination, queue and
clearance ordering, stale-head rejection, rewriting and reproving, bounded
races, and terminal failures. It uses no repository or remote mutations.
The existing TLA+ and Rust lifecycle model continue to define protocol
safety; this command machine refines their Publish, Queue, GatePasses, and
Land operations.

## Protocol

`JjCi.tla` is a bounded TLA+ state-machine model of topic rebase, conflict
resolution, validation, dispatch, the landing clearance, fast-forward landing,
and workspace finish. `JjCi.cfg` supplies a small TLC state space for checking
its safety invariants. Validation records the exact topic head it checked, and
dispatch must capture that same head from the current trunk. Landing moves
`main` only to the exact head a gate passed, and only from the trunk that head
was based on, so `main` never holds a commit no gate ran on. The model
intentionally abstracts command failures and detailed multi-revision stack
topology; the operational rules below remain authoritative.

`lifecycle/` implements the same protocol as an executable hierarchical state
machine with [statig](https://crates.io/crates/statig): the control facts
(editing, validated, conflicted, delivered, released) are states, and the data
facts (heads, trunk, publication, gate verdict) are shared storage. Its tests
walk every state of the bounded model in `JjCi.cfg`, require the machine to
accept exactly the events whose TLA+ action is enabled and to reach the same
variables, and check every invariant, so `checks.x86_64-linux.ci-lifecycle`
keeps the Rust machine and the specification in step. Change both together.

Codex shell commands and OpenCode server shell execution receive a no-op
`JJ_EDITOR` and an unpaginated `PAGER`. This keeps agent-run JJ commands from
blocking on an editor or pager while leaving the normal interactive shell
unchanged. Explicitly supply messages, filesets, revsets, and any available
non-interactive flags for commands that prompt for other input.

One task owns one topic and one stable change ID. A topic is a revision; a
workspace is a working copy for one actor. Topics worked one at a time are
sibling changes in the same workspace, and `jj edit` switches between them. A
separate workspace is only for an actor that runs concurrently with the
current working copy: another agent task, or a build, dev server, or editor
whose files must not change underneath it. A topic may contain a series of
logically separate JJ changes. Review fixes should be absorbed into the
appropriate change instead of appended as "address review" commits.

```nu
ci new -m "Topic title"     # Start a topic on main@tangled in this workspace.
ci start topic-name         # Or, when no workspace is free: create one for concurrent work.
ci status
ci sequence                 # See whether the topic stacks on another in flight.
ci rebase                   # Fetch trunk and rebase the whole topic stack.
ci conflicts                # Show conflicted revisions and files after a rebase.
ci preflight                # Run every pre-activation check when requested.
ci review snapshot v1       # Capture the current series for interdiff review.
ci dispatch                 # Push the same topic branch to Tangled.
# After editing or absorbing review fixes:
ci review snapshot v2
ci interdiff v1 v2
# At topic closeout:
ci land                     # Build the flake checks locally, then fast-forward main.
ci land --clearance spindle # Take clearance from the spindle (or github) instead.
ci park                     # Confirm the landing and free the workspace.
# To drop an undispatched or closed topic instead:
ci cancel
# After activating the release:
ci verify -m "how you tested it"
# Occasionally, from any workspace:
ci prune                    # List leaked workspaces and landed branches; --apply removes them.
ci sim --shell              # Try trunk plus dispatched user-facing topics, unactivated.
```

### Naming

A topic travels to `main` in flight words: `new`, `sequence`, `preflight`
and `sim`, `dispatch`, `land --clearance`, then `park` (or `cancel`), and
`verify` once its release runs. The phases follow Wing's split: _preflight_
is everything before activation (evaluation, builds, closure proofs, landing
clearance), and _inflight_ is everything on a running machine (activation, the
activation log, `ci verify`). A refactor is a change with no inflight effect.
Tools keep plain VCS words (`status`, `sync`, `rebase`, `conflicts`), and
"release" means only a CalVer tag. The old names (`validate`, `plan`,
`refresh`, `preview`, `publish`, `finish`, `abandon`, `tangled stack-publish`,
and `land --gate`) still work and print their replacement.

`ci new` fetches trunk and runs `jj new main@tangled`, leaving the previous
topic untouched as a sibling. An empty working copy that is unnamed, or that
an agent session claimed before naming it, becomes the topic in place instead:
`ci new` moves it onto `main@tangled` and describes it, so its change ID, and
the session's claim on it, stay. It refuses while an active agent session owns
another change in the workspace, or while the unfinished topic of a `ci start`
workspace is checked out; start concurrent work in a free workspace or with
`ci start` instead.

A workspace from `ci start` stays on its topic until `park` or `cancel`
frees it. `ci start` records the topic's change ID in `.jj/jj-ci-workspace.json`, and
every command that checks ownership refuses to run when the working copy is an
empty change beside that unlanded topic, as after a manual `jj new main`; the
error names the `jj edit` that returns to it. In an interactive Nushell, the
`jj` wrapper from `guard.nu` refuses such a `jj new` before it runs when the
working copy holds unfinished work, or when it would move the working copy off
a change an agent session claimed. Plain `jj new` and `jj new --no-edit` still
work, and `^jj new …` leaves the topic on purpose.

## Patch-series review

The intended review model is an evolving patch series:

```
v1: A1 -> B1 -> C1
v2: A2 -> B2 -> C2
```

Each commit should have one logical purpose and should be readable as part of
the series. Use `jj edit` to select an earlier change, or use `jj absorb` to
move an unambiguous fix into the change that introduced the affected lines.
Descendants are rewritten as needed while retaining their change identities.

Before each review update, run `ci review snapshot <label>`. Snapshots are
stored in the workspace's `.jj/jj-ci-review-versions.json`; this is local
review metadata and is not committed. `ci interdiff old new` runs
`git range-diff` over the exact base and tip recorded for both snapshots.
That preserves the pairwise, commit-by-commit review signal described by the
interdiff model.

The topic bookmark identifies the topic, not an individual patch. Dispatching
moves the same bookmark to the current series tip, and a Tangled pull request
opened from that branch records each push as a new review round. The local
range-diff command supplies the true interdiff between review rounds.

## Topic lifecycle

`ci sync` is for an empty workspace with no active topic. It refuses to move
an owned workspace. Use `ci rebase` during an active topic; it fetches trunk
and rebases the whole series in place.

JJ's `trunk()` is the trunk: the base of every topic and the one remote
bookmark `ci land` advances, `main@tangled` here. Its remote also hosts the
topic branches. `ci` reads the bookmark and remote from a `trunk()` that your
config or the repository's defines, which must name exactly one, such as
`main@origin` or `remote_bookmarks(exact:"master", exact:"origin")`. Where
only JJ's default defines it, `ci` defines it in the repository's config as
`main` on `tangled`, else `origin`, else the only remote, written as
`latest(present(main@REMOTE) | root())` so that topics start from the root
until main is first pushed there. Change it with
`jj config set --repo 'revset-aliases."trunk()"' main@REMOTE`.
GitHub (`origin`) is a mirror of the trunk bookmark that `ci land`
fast-forwards after each landing when it is not the trunk itself, and an
optional landing clearance; `ci dispatch` never pushes there.
`ci dispatch` rebases,
validates, and pushes the stable `jj-<slug>-<change-id>` bookmark to the trunk
remote. It does not create a follow-up change, so further edits to the series
update the same branch. Open a Tangled pull request from that branch when the
topic needs review; `ci` finds it by branch through Tangled's public index and
needs no credentials beyond the SSH key used to push. A remote URL may name
the repository by owner and name or by its repository DID; a trunk remote
that is not on Tangled skips the pull request link.

`ci land` is the only way a change reaches `main`. It dispatches the topic,
which rebases it onto `main@tangled`. Then it runs the checks that fail fast:
a stacked topic must wait for its parent to land, and a declared refactor
must leave every NixOS closure as it was at that base. The proof compares the head with the
commit it forks from, found once the proof holds the local checks lock, so a
topic that lands while it waits is never counted as this one's change. Next
the topic joins the landing queue, described below. Once at its front, `ci
land` passes the exact commit through the landing clearance, fast-forwards
`main` to it, mirrors it, and tags any release.
`main` therefore holds only commits that were tested as they are, and history
stays linear without squashing. A stacked topic lands after its parent.
`ci dispatch --land` dispatches and lands in one step.

Every `ci land` on this machine waits its turn in one landing queue,
`$XDG_STATE_HOME/jj-ci/landing-queue/`, shared by every workspace and
session. Each waiting landing holds a ticket there, numbered in arrival
order, and only the lowest live ticket may move `main`. From the front, a
landing rebases onto `main@tangled` only if `main` moved while it waited,
runs the fast checks again on the new head, and takes clearance. No other
landing here moves `main` until it is done, so it never restarts and N
landings at once cost about N clearances. Before the queue, they restarted
one another: on 2026-10-16, landings that took 4 minutes alone took 30 to 77
minutes each when five ran at once, and two never landed. While landings are
ahead of it, `ci land` prints and reports, as a `blocked` record under
`landing-queue`, `Waiting to land behind <topic> (pid N) and K more.`, so
`watch-job` and `ci tower` show the wait. A landing that exits, however it
ends, leaves the queue, and one that was killed is dropped by the next
landing to look.

Something outside the queue can still move `main`: another machine, or a push
by hand. The push of `main` therefore still carries JJ's lease on it, and
when clearance passes `ci land` fetches `main@tangled` again. If `main`
moved, it leaves `main` alone, rebases and redispatches the topic, and takes
clearance again on the new head, up to `--attempts` times (default 5). A
rebase conflict or failed clearance still stops it.

`ci land --train` lands every dispatched topic it can in one fast-forward,
for one clearance instead of one per topic. It runs from any workspace and
waits in the same landing queue. From the front, it takes the topics `ci
sequence` lists, in that order, and rebases each onto the one before it,
forming one linear chain on `main`. A topic joins only as it was dispatched:
its local bookmark is the one on the trunk remote, with no edits above it,
it is not stacked on another topic, does not conflict with `main`, and has
one declared impact. A topic whose rebase onto the chain would conflict, or
that another `ci` is moving (its topic lock is held), is left untouched.
Each declared refactor proves its closures unchanged against the chain
below it, on a trial merge, before it joins, and stays out if they changed.
Clearance then runs once on the chain's tip. When it passes, the topic
branches are pushed, `main` fast-forwards to the tip, and a release is
tagged for each behavior or breaking revision, exactly as separate landings
would. When it fails, `ci land --train` bisects: it takes clearance on
prefixes of the chain to find the first topic that fails, about log2(N) more
runs, lands the prefix before that topic, and reports the culprit with its
failure. The culprit stays on the new `main`, the topics after it move back
onto `main` without it, and each is pushed unless it conflicts there; their
owners land them again. The run ends with a table of what happened to each
topic, and fails when a culprit was found. Workspaces with a train topic
checked out are snapshotted before planning and updated afterwards, and the
whole rewrite has one `ci recover` checkpoint. A train does not retry: if
something outside the queue moves `main` while it clears, nothing lands and
every topic returns to `main`.

The installed `ci`, the dev shell's, and the ci MCP server's are one launcher
(`ci-launch.nu`) that picks the `ci.nu` to run each time it starts. Other
repositories run the copy bundled with the package, the version their lock
file pins. Inside this repository, a topic that edits `ci.nu` runs its own
copy, so a workflow change is tried before it lands, and any other workspace
runs `main@tangled`'s, so an older workspace or a long-lived session never
runs an older workflow. `CI_SCRIPT=/path/to/ci.nu` runs that copy from any
repository while developing it.

To dispatch a multi-change topic to Tangled as stacked PRs, run:

```nu
ci dispatch --stack
```

This rebases the complete topic onto `main@tangled`, runs the repository
preflight, and pushes each revision as a stable
`stack/<series>/<change-id>` branch to Tangled, oldest layer first. In Tangled,
choose `Submit as stacked PRs` for the pushed branches. Later edits retain
their JJ change IDs, so Tangled can associate rewritten commits with the
corresponding stack layer and review round.

The default clearance, `--clearance local`, exports the exact commit's tree with
`git archive` and builds its `checks.x86_64-linux` on this machine with the
same `nix-fast-build --skip-cached` command the spindle workflow runs,
streaming the build log. It evaluates with one worker and a 4 GiB budget:
past the budget, nix-eval-jobs kills the worker and retries the check alone,
so the largest single check, not the whole set, has to fit. Anything already
in the local store or a binary
cache is skipped, so once `main`'s systems have been built, a topic that
leaves them unchanged (every refactor, for instance) builds only the cheap
checks. The first landing after a large input update pays for the full
system builds. Nix's configured remote builders apply as usual.

Local clearance reports each check as it goes, as OSC 7501 records that
`watch-job` and `ci tower` follow. The `clearance` record names the newest
build and its place among the checks, such as `building desktop-primary
(3/14)`. Each check that needs building gets its own `clearance/<check>`
record: working when it starts, then done with its build time, or error when
it does not build or evaluate. A check that does not build is explained from
the log Nix kept for its derivation: the record, and the clearance failure,
quote the log's last line naming an error, assertion, or failure, and the
whole log is saved as `$XDG_STATE_HOME/ci/check-failures/<commit>/<check>.log`,
such as `workbench did not build: AssertionError: unexpected changes: …
(log: ~/.local/state/ci/check-failures/a94c0c7a1b2c/workbench.log)`. A
`watch-job` monitor therefore delivers the cause, and an agent or person
reads the rest from that file. An evaluation that outgrows its worker's
memory budget reports as an error under its own name, such as
`den-host-evaluation exceeded 4 GiB`. A run killed outright reports the
builds and the evaluation it cut short as errors, and names them in the
clearance failure. Checks substituted from a cache report nothing.

Local clearance and a refactor's closure proof hold one lock for the whole
machine, `$XDG_STATE_HOME/jj-ci/local-checks.lock` (under `~/.local/state` by
default), shared by every workspace and session, since two of them at once
can exhaust memory. A landing that finds it held prints
`Waiting for local checks of <topic> (pid N) to finish.` and waits. A holder
that has exited, unless its checks unit is still running, gives the lock up to
the next waiter. When a check run dies from a signal, or fails without any
check failing, clearance reports it as `killed (likely out of memory)` with
its exit status rather than as a failed check. systemd counts a stopped unit
as a success, so the checks record their own exit status, and a run stopped
before it finished fails clearance too. Never stop another landing's checks
to make room; wait for the lock instead.

Each topic also has its own lock while `ci dispatch` or `ci land` moves it,
`$XDG_STATE_HOME/jj-ci/topics/<change-id>.lock`. Two sessions that landed the
same topic at once rebased it separately and split it into divergent copies,
so a second `ci` that finds a live holder fails at once, naming its pid and
workspace, rather than waiting to move the topic again. Let that run finish.

These locks are always taken in one order: the topic lock, which nothing
waits for, then the landing queue, then the local checks lock. Nothing that
holds the local checks lock waits for the queue, so no two `ci` processes can
deadlock. `ci tower` shows the landing at the front of the queue as LANDING
and those behind it as QUEUED.

Other sessions' work cannot stop a landing either. The plan that places a
topic names every other topic's tip by commit, so a divergent change in some
other workspace no longer makes JJ refuse the plan; the copies show up as
separate topics. A trial merge abandons its probe however it ends. A JJ
command that loses the race to read the operation heads while another
process replaces them ("Failed to read operation heads") fails before it
changes anything, and `ci` retries it twice.

`ci land --clearance spindle` takes clearance from the repository's spindle instead. Pushes
do not trigger it, so start `flake-checks.yml` on the topic branch by hand. It
polls every 30 seconds (default timeout `--timeout 2hr`) and stops at the
first failed, timed-out, or cancelled workflow without landing anything.

`ci land --clearance github` takes clearance from GitHub Actions. It pushes the topic branch to `origin`, where
`nix-ci.yml` runs on every `jj-*` push, waits for the `nix flake checks` run
on the exact head, and then fast-forwards `main`
on Tangled and GitHub exactly as a spindle-cleared landing does. Never merge a
GitHub pull request instead: GitHub's squash and rebase merges rewrite
commits, so `main` would hold a commit no check ran on, change IDs and the
impact declarations keyed by them would be lost, and `park` and `prune` could no longer
tell that the topic landed. The GitHub repository therefore allows only
merge commits, which its linear-history rule rejects, so its merge button
cannot land anything; its `main` rule accepts only fast-forward pushes.

`ci park` checks that the current revision is on `main@tangled`. It then
deletes the topic bookmark locally and on Tangled, advances local main, and
releases the workspace. A workspace that `ci start` created is forgotten
and its directory deleted; continue from the default checkout. `--keep`, or
any other workspace, is left on an empty change on main with its session's
ownership finished. `--keep` also deletes the `ci start` marker, so the
workspace joins a reusable pool: it is free again, and the next session there
starts a fresh topic instead of being refused for the landed one. Archive the
task only after it succeeds.

`ci adopt` hands the topic checked out in a workspace to the next agent
session that edits it. Agents claim only free workspaces on their own, so a
topic you started by hand, or one whose session ended, stays yours until you
run it. It refuses while a live session owns the workspace.

`ci cancel` drops a topic that will not land. It refuses while a Tangled
pull request from the topic's branch is open, records a checkpoint, deletes
the topic bookmark, abandons the revisions above `main@tangled`, and releases
the workspace like `park`. `ci recover` with the printed checkpoint, run from
any workspace, brings back the revisions and the local bookmark; the deleted
remote branch returns with the next dispatch.

Workspace lifetime follows ownership rather than garbage collection:
`ci start` creates a workspace for one concurrent actor's topic, and `park`
or `cancel` frees it, or returns it to the pool with `--keep`. `ci prune` is the backstop for owners that never
released theirs, such as a crashed task or a workspace created by hand. It
lists workspaces that are missing, or that no active task owns and whose
revisions above `main@tangled` are all delivered: nothing but an empty,
undescribed working copy remains. Landed work is on `main` itself, so it never
counts as pending. It also lists JJ checkpoints older than
`--keep-days` (14). A stale working copy is reported without being touched;
`--apply` first runs `jj workspace update-stale` there and decides again. `--apply` then forgets the listed
workspaces, deletes their directories, and deletes the old checkpoints. Prune
always keeps the default and current workspaces, Git and Codex worktrees, and
anything with undelivered changes; a kept workspace untouched for more than
a day says for how long, since such work needs someone to land or cancel it.

A Codex task archived without `park` leaves its ownership record active.
Prune treats that claim as ended once the task's rollout under
`$CODEX_HOME/sessions` has been archived or quiet for two days, releases the
record, and removes the workspace if nothing in it is pending. Prune also
deletes topic branches whose every copy, local, on Tangled, and on GitHub,
is already on `main`, unless a remaining workspace still records the branch
for its topic, whose `park` needs it.

`--idle DURATION` keeps every workspace used more recently than that, judged
from its `ci start` marker and JJ's tree state on disk, before any JJ command
runs there, so a live session's working copy is never snapshotted under it.
The `ci-prune` user timer runs `ci prune --apply --idle 1day` in the default
checkout once a day.

### Rebasing with conflicts

`ci rebase` creates a JJ operation checkpoint, fetches `tangled`, and rebases
the complete topic stack onto `main@tangled`. If the rebase conflicts, it does
not attempt another rebase: it prints every conflicted revision and its files,
then exits non-zero so dispatch cannot accidentally proceed.

Resolve the revisions from oldest to newest. For a conflicted revision that is
not the working copy, select it with `jj edit CHANGE_ID`; resolve its files by
editing the conflict markers or using `jj resolve`; then return to the original
topic tip with `jj edit TOPIC_TIP` (record the tip before selecting a revision).
Run `ci conflicts` between revisions. Once it reports no conflicts, run
`ci preflight` before dispatching.

The rebase itself has already completed when the conflict report appears. Do
not run `ci rebase` again while conflicts remain; doing so would attempt to
move an already-rebased topic a second time. To start over from the
pre-rebase state instead, run `ci recover` with the printed checkpoint before
resolving anything.

### Recovering a checkpoint

Every command that rewrites history (`rebase`, a restack in `dispatch` or
`land`, `sequence --apply`, `sync`, `park`, and `cancel`) first prints
`Recovery point: ci recover ID`, and passes that ID to each JJ command of the
rewrite as `--config ci.checkpoint="ID"`. JJ records a command's arguments on
every operation it makes, so `ci recover ID` (or plain `ci recover` for the
workspace's latest checkpoint) reverts exactly the rewrite's operations,
newest first, with `jj op revert`. Fetches and pushes are not part of it.
Every other operation since the checkpoint stays, including other
workspaces' dispatches and landings. `ci recover` refuses once someone has
resolved, edited, or abandoned a commit the rewrite made, since reverting
then would fork that work, and refuses a checkpoint it already recovered.

Never `jj op restore` a recovery point: it rewinds the whole repository,
every workspace included. On 2026-10-16 a session restored a failed
landing's recovery point 14 seconds after it was recorded and undid another
workspace's dispatch in between, which left that topic's pushed bookmark
untracked and its commit immutable.

### Stale workspaces

Rewriting a change rebases its descendants, and another workspace that has
one of them checked out goes stale: its files still show the old commit, and
JJ refuses to run there until `jj workspace update-stale`. Sessions found
their workspaces stale after another session rebased or abandoned a topic
below theirs, and a switch once built a stale checkout (2026-10-07). Now:

- `ci rebase` (and so `dispatch` and `land`), the stacked restack, and
  `ci cancel` name the other workspaces whose working copies the rewrite
  will move, and update them afterwards, printing each one they update.
- `ci` itself, started in a stale workspace, updates it before anything else
  and says so.
- The context-status SessionStart handoff updates a stale workspace, the
  session's own or one inside its worktree, and says so; the shell prompt
  shows `⚠ stale` instead of changing files.

`jj workspace update-stale` never overwrites a file edited there since JJ
last snapshotted it; that file keeps its local content, which the next
snapshot records.

## Continuous integration and conflict avoidance

The canonical checkout tracks `main`; active work happens in dedicated JJ
workspaces. The local webhook may advance the canonical checkout after a
successful `main` workflow, but it never rewrites an owned topic workspace.
Each topic therefore has an isolated working copy and must integrate trunk
changes into itself.

The integration points are deliberately automatic:

- `ci rebase` fetches `tangled` and rebases the complete topic stack onto
  `main@tangled`.
- `ci dispatch` rebases before validation and pushing.
- `ci land` performs the same final rebase, so the commit the landing clearance
  tests is the commit `main` receives.

The spindle runs `.tangled/workflows` only when started by hand on `main` or a
`jj-*` branch; pushes do not trigger it. Landing requires clearance to pass the
rebased head, so two topics that
break only in combination cannot both land: the second is rebased onto the
first and tested again. A topic that merely fell behind `main` needs no
attention until it lands.

What still needs rewriting after `main` moves is handled by `ci sequence --apply`:

- a stacked topic whose parent branch moved is restacked onto it;
- a topic that conflicts with `main` is rebased so the conflict is recorded
  locally for resolution.

A stacked topic whose parent landed is already on `main`, because landing
fast-forwards `main` to the parent's exact commits; it needs no restack.

A topic checked out in a workspace is snapshotted and rebased from that
workspace, so its files move with it; a trial merge must predict no conflict
first, or the topic is left untouched for its owner. Only conflict-free results
are pushed. `ci sequence --apply --all` also rebases topics that are merely behind.
Keep topics short-lived and changes small enough to rebase without large
manual resolutions.

### Validation and pipeline state

`ci preflight` and `ci dispatch` record the commit Prek passed in
`.jj/jj-ci-validation.json`. JJ snapshots every edit as a new commit, so the
record stops matching the working copy as soon as the topic changes; comparing
the two answers whether lint is fresh without running Prek again. A
repository with no Prek configuration (`prek.toml` or
`.pre-commit-config.yaml` in the work tree or a directory above it) has no
hooks to run: preflight says so and records the commit as passed, and the
flake checks remain the landing gate.

`ci ci-state` prints the current topic's dispatch branch, the head
Tangled holds for it, whether it landed, its open pull request, and the
spindle's verdict on that head (and GitHub's, when a GitHub-cleared landing
pushed it there) as JSON. A run that only timed out reports `timeout` rather
than `failed`, since it says nothing about the topic. It reads the last-fetched remote state and the forge
APIs only; it never fetches, pushes, or rewrites anything.

### The ci log

Every status report `ci` makes, the same ones it sends as OSC 7501 records,
is also an OpenTelemetry log record in `$XDG_STATE_HOME/ci/log.otlp.jsonl`
(`CI_LOG` moves it). Each line is one OTLP/JSON `ExportLogsServiceRequest`,
which the OpenTelemetry Collector's `otlpjsonfile` receiver reads as is. The
records carry the event name (`ci.status` for a status report), the state,
phase id, and message, the process id that groups one run, and the working
directory. One log serves every repository and workspace on the machine.
It is also where `ci impact set` records impact declarations
(`ci.impact.set`) and `ci land` records releases (`ci.release`), so it is
state as well as telemetry: keep it when cleaning up `$XDG_STATE_HOME`.

When `OTEL_EXPORTER_OTLP_LOGS_ENDPOINT` or `OTEL_EXPORTER_OTLP_ENDPOINT` is
set, `ci` also posts each record to that OTLP/HTTP endpoint (`/v1/logs` under
the general one). A record that cannot be written or exported never fails the
run.

### Traces

Every `ci dispatch` and `ci land` is also an OpenTelemetry trace, built from
the status records it wrote to the ci log, so you can see where a landing's
time went:

```text
ci land                          the run: command, workspace, MCP job, outcome
├── attempt 1                    one per start over when main moved
│   ├── rebase / preflight / push
│   ├── closures                 the refactor closure proof
│   │   └── wait for local checks    another topic held the checks lock
│   └── clearance
│       └── clearance/<check>    one per check that had to build
└── attempt 2 …                  releases and mirroring are events on it
```

When `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` or `OTEL_EXPORTER_OTLP_ENDPOINT` is
set, a run exports its trace as it ends (`/v1/traces` under the general one).
`ci trace export` sends the runs recorded before, or while the collector was
down: every run in the ci log, and every job in the ci MCP server's job
store, which reaches further back. `--dry-run` lists them instead, and
`--since` limits them.

```nu
ci trace export --endpoint http://127.0.0.1:4318/v1/traces
```

Trace and span ids are digests of the run's process and first record, so a
run exported live and again by `ci trace export` keeps them. `ci` lists each
trace it sends in `traces.exported` beside the ci log and never sends one
twice, because a store keyed by span id, as otel-desktop-viewer's is, drops a
duplicate together with whatever arrived with it. A trace that cannot be sent
never fails the run.

### Context status

`context-status` summarizes the current workspace's topic: its stage in the
lifecycle modelled by `JjCi.tla` (stage names editing, validated, published, passed,
failed, landed, finished, or off topic when the working copy left it), the next `ci` step, the changes above trunk and
trunk commits the topic lacks, conflicts, lint freshness, the task owner, and
the pipeline verdict and pull request for the dispatched head.

- `context-status` prints the full readout, refreshing a stale verdict first.
- `context-status prompt` is the Starship segment next to the JJ one.
- `context-status brief` prints when an interactive Nushell enters a different
  workspace; set `CONTEXT_STATUS_ON_CD=false` to silence it.
- `context-status handoff` prints Markdown for the next agent. Claude Code and
  Codex run it with `--hook` at session start, so every session opens with the
  workspace's state.
- `context-status json` prints the collected record.
- `context-status audit` checks every workspace of the repository against the
  ownership rules below and reports each violation with the
  command that repairs it: a working copy that left its recorded topic (the
  state the topic guard refuses, which the prompt shows as off topic),
  orphaned or leftover claims, legacy records that cannot prove delivery, conflicts,
  undispatched work `ci status` does not list, stale dispatch entries,
  and Codex session records for workspaces that no longer exist. It only
  reads; `--json` prints the findings.

The stage and next step come from `jj-ci-lifecycle classify`, which restores
the state machine from the observed facts; `context-status json` also lists
the protocol steps the machine `allowed` from there. A conflicted topic is
never validated, as in the model.

Local facts are read on each call. Pipeline and pull request state is cached in
`.jj/context-status.json` and refreshed in a detached process, so the prompt
never waits on the network. An owner record in `.jj/codex-session.json` counts
only while it names the current change.

### Control tower

`ci tower` (the `ci-tower` binary from `tower/`, bundled with `ci`) is the
whole repository's context status, live, in one terminal:

- **Board** lists every workspace's topic, and each dispatched `jj-*` branch
  no workspace holds, grouped as in flight, needing attention, dispatched, on
  the ground, and landed. It classifies each with the same lifecycle crate as
  `context-status`, so stages, glyphs, and next steps agree with the prompt.
  The selected topic shows its trip as a flight path (new, preflight,
  dispatch, clearance, land, park), its stack, preflight freshness, branch,
  cached pipeline state, owner, and locks.
- **Runs** follows every `ci` job: those the ci MCP server keeps under
  `$XDG_STATE_HOME/ci-mcp/jobs`, and `job-log` jobs announced on cross.stream
  whose status records come from `ci`. It folds their OSC 7501 records into a
  phase timeline and tails the log.
- **Trunk** lists `main@tangled` with its release tags, which of them this
  host verified, its last activation, and who holds the local checks lock.

Space opens ACTION mode for the selection: preflight, dispatch, land, park,
rebase, conflicts, sequence, a pipeline refresh (`context-status refresh`),
jjui, cancel, and stopping a run. Each `ci` step starts as a detached job in
the ci MCP server's layout, so agents see it with the `jobs` and `job` tools
and `watch-job` follows it, and it outlives the tower. Dispatch, land, park,
cancel, and stopping a run ask first, as does any change to a workspace an
active Codex task owns; a workspace with a mutating job still running refuses
another, as the MCP server does. The hint bar always lists the keys of the
current mode, and Esc returns to NORMAL.

The tower reads JJ with `--ignore-working-copy`, so it never snapshots
another session's working copy, and it reads the graph again only when the
shared operation heads or a workspace's `ci` records change: three `jj`
processes per change, and a few `stat` calls per tick otherwise. It never
contacts a forge itself. `ci tower --json` prints what it collected, and
`ci tower --snapshot 120x36 [--view runs] [--html]` renders one frame.

### Previewing in-flight work

`ci sim` answers what the machine would look like once the dispatched
user-facing topics land. It merges `main@tangled` with the head of every
dispatched topic whose revisions are declared `behavior` or `breaking`
(or the topic branches given; `--all` adds refactors) in a temporary
workspace, then builds that merge's Home
Manager generation to `$XDG_STATE_HOME/ci/preview-home`. The merge is
abandoned afterwards and nothing is pushed, rewritten, or activated.

It reports package changes and changed configuration files against trunk's
generation, so only what the topics change is listed; `--active` compares against
the active generation instead. `--shell` opens Nushell with the preview's programs first
on `PATH`; `--config` also points `XDG_CONFIG_HOME` at the preview's
read-only configuration, so applications that write their own configuration
may refuse to start. System-level (NixOS) changes are not previewed. If the
selected topics conflict with each other, the preview stops and lists the files;
preview a subset or use `ci sequence` to decide how to stack them.

### Herdr and Paseo coordination

Herdr or Paseo may supervise the terminals and agents used for this workflow,
but they do not replace JJ workspace ownership. Create the JJ workspace from
`main@tangled` first, then attach one Herdr or Paseo coordination lane to that
directory. Keep the mapping one coordinator : one JJ workspace : one active
topic.

A supervisor may monitor `main@tangled`, topic freshness, and pipelines, and
notify the owner when integration is needed. Conflict resolution, dispatch,
landing, and stack advancement remain explicit operations in the owning
workspace. The conflict-free restack by `ci sequence --apply` is the only
unattended rebase; a supervisor does not rebase on its own.

## Impact classes and releases

Every JJ change declares what it does to the built machines with
`ci impact set`, which records a typed `ci.impact.set` event in
[the ci log](#the-ci-log) rather than text in the description:

- `refactor`: every NixOS closure is unchanged, as for refactors, docs, CI,
  and repository tooling. `ci land` proves that each host's toplevel
  derivation matches the base; a flake without `nixosConfigurations` has no
  hosts, so the proof holds trivially. No release.
- `behavior`: a user-facing change to a host. Landing it cuts a CalVer release.
- `breaking`: a user-facing change that needs manual steps when activating.
  Each step is its own argument, and at least one is required.

```nushell
ci impact set refactor
ci impact set breaking "Run `ssh-keygen -R homelab` once" -r lqwrwwuy
ci impact show
```

The event is keyed by the full change ID, which survives every rebase and
restack, so a declaration follows its change to `main`; declaring again
replaces it. `-r` takes a revset and declares each revision in it. The
description stays prose: nothing parses it. A change that predates this
carried an `Impact:` trailer instead, and `ci impact import` declares the
undeclared revisions of a topic from theirs.

The declarations live only on the machine that made them, which is the one
that dispatches and lands the topic. GitHub cannot read them, so it no longer
runs an impact check; a GitHub-cleared landing still classifies the topic and
proves a refactor closure-neutral locally first.

`ci dispatch` refuses a topic with an undeclared revision, a breaking
revision without steps, or one that mixes a refactor with a user-facing
change: the topic lands as a unit, so it would ship the refactor inside a
release and lose its closure-neutral guarantee. Split the refactor into its
own topic, or make it the parent layer of a stack when the change depends on
it. Breaking and behavior revisions may share a topic; the topic takes the
stronger class.

After fast-forwarding `main`, `ci land` tags every behavior or breaking
revision it landed as `YYYY.MM.DD.N` (UTC commit date, numbered within the
day) with `jj tag set` and pushes the tag to Tangled. The tagged commit's
description and its declared manual steps are the release note: `ci land`
prints them and records a `ci.release` event in the ci log. `ci release`
catches up on anything since the newest release if a tag push failed.
Refactors never cut a version, so the list of releases is the list of changes
that alter a machine. `ci version` prints the newest release in the current
revision.

A NixOS generation cannot carry the tag: the tag is created after merge, and
local `path:` builds have no Git revision. Compare a generation with a release
by the checkout it was built from.

## Verifying releases

The landing clearance proves that every closure builds, not that the machine
behaves as the release describes. After activating a release and trying it,
record that on the host:

```nu
ci verify -m "Codex runs in ~ without the JJ guard"
ci verify 2026.09.30.11 -m "..."   # name the release explicitly
ci verify list                     # recent releases and this host's verifications
ci verify flush                    # resend any queued verifications
```

`ci verify` refuses unless the release evaluates to exactly the running
`/run/current-system` for this host; without a release it checks the five
newest and takes the first that matches. It appends the record to
`~/.local/state/config-verifications/verified.jsonl` and sends that one line
to homelab, where the `config-verifications` account can only append it to
`/var/lib/config-verifications/<host>.jsonl`. It connects on port 2222
because Tailscale SSH owns port 22 on the tailnet address and ignores the
account's forced command. When homelab is unreachable the record stays in
`outbox.jsonl` until the next `ci verify` or `ci verify flush`.

Every host also appends one line per activation to
`/var/log/nixos-activations.jsonl` (time, toplevel, and system profile), which
`ci verify` uses to record when the verified toplevel was switched to. That
log stays on the host; only verifications go to homelab. Nothing is kept on
Tangled, which holds code.

## Merge strategy

The permanent default is one branch per ordinary JJ topic. The dispatch
bookmark is a stable `jj-<slug>-<change-id>` branch, and `ci land`
fast-forwards `main` to it after the landing clearance passes it. `main` stays linear
without squashing, and every revision keeps its change ID and so its impact
declaration. Branches
from older sessions may retain their descriptive names, but new topics must use
the `jj-` prefix: the spindle accepts manual runs only on `jj-*` branches and
`main`, and `ci` treats only `jj-*` bookmarks as dispatched topics.

Use a stack only when every layer is independently reviewable and the layers
must land in dependency order. Ordinary one-branch topics are preferred because
they minimize the number of moving bases. A topic built on another dispatched
topic is stacked on it; the stack lives in the commit graph, with no labels or
base branches to keep in step. Land the parent first; the child is then
already on `main` and lands next. Never land a child based on an outdated
parent.

To review a multi-change topic on Tangled as stacked pull requests, run:

```nu
ci dispatch --stack
```

It dispatches the topological series as `stack/<series>/<change-id>` branches,
after which Tangled's `Submit as stacked PRs` action creates the linked pull
request stack. Pull requests are for review only; `ci land` still delivers
the topic.

Impact shapes ordering. When topics conflict, `ci sequence` still places
dispatched topics before undispatched work, but within each group it bases the
stack on the refactor, so the user-facing layer above it stays a small behavior
diff and its release notes describe only that behavior. A refactor that must
stack on an already-dispatched user-facing topic is reported with a note. The
order uses only keys that rewrites leave alone (dispatch, impact, the
topic's oldest author time, and change ID), so concurrent tasks agree on the
base. `ci dispatch` stacks only on a topic that is already dispatched; when
the planned parent is undispatched it dispatches independently instead of
waiting, and whichever topic lands second resolves the conflict when it
rebases. Refactors can land at any time without activation; land each
user-facing topic on its own so every release maps to exactly one reviewed
change.

Merge commits are not part of the repository policy: `ci land` only ever
fast-forwards `main`. Squash only while authoring, with `jj squash` or
`jj absorb` before dispatching, so each dispatched change is already one logical
unit; never squash at delivery.

## Concurrent tasks

A workspace is a working copy for one actor at a time. An agent session works
only in a workspace whose change it owns, and takes a new one only when it is
**free**: idle on trunk, with nothing above `main@tangled` but an empty change,
and no live session owning it. The default checkout is not special: when it is
idle on trunk, the next session claims it like any other. A workspace that
holds a topic no session owns (work someone started by hand, or a session's
that ended) stays with that topic; agents are refused there until the user
hands the topic over with `ci adopt`.

So a session opened in a busy checkout moves to a free workspace, and only
when none is free does it create one:

```nu
ci start agent-1
```

It creates `.jj-workspaces/agent-1` at `main@tangled` and refuses a name
that is already in use. `ci park` or `ci cancel` removes it; with `--keep`
it stays for the next task. Workspaces that sessions claimed rather than
created, the default checkout among them, stay after `ci park`, back on
trunk and free. A small pool of workspaces, one per agent that runs at the
same time, avoids creating and deleting one per topic.

A stale claim never holds a workspace forever. The owning session's
transcript (Claude Code) or rollout (Codex) shows when it last ran: once it
has been quiet for 10 minutes another session may take over a claimed change
that is still empty, and after 2 days one with work in it.

Use that directory as a **Local** Codex project. Do not start the chat in
Codex's **Worktree** mode or hand it off to a worktree: [Codex worktrees](https://developers.openai.com/codex/app/worktrees)
are Git checkouts, and the handoff flow performs Git operations between them.
That would add a second workspace and lifecycle beside `ci`'s JJ topic. Codex's
worktree documentation does not describe a project setting that redirects its
worktree operations through JJ or `ci`.

The session hook starts an independent topic at `main@tangled`, records ownership in
`.jj/codex-session.json`, and guards prompts and tool calls against change-ID
drift. It never automatically switches another task's working copy.

In a repository that has topic workspaces, the hook claims a workspace only
when it is free or `ci start` dedicated it to its topic, the default checkout
included. A session opened on a topic no task owns is told to move, and its
edits are blocked. A repository with a single workspace, such as one Codex
initialized in a Git worktree, is claimed as before.

An ownership record's `state` says how its task ended: `delivered` by
`ci park` after landing, `discarded` by `ci cancel` or finishing an
empty topic, or `released` by `ci unclaim`. Records written before `state`
carry only `finished`, which reads as released, never as delivered.

If a task leaves its change behind (the workspace moved to another change
without `park` or `cancel`), its claim blocks every later session. Run
`ci unclaim` in that workspace to release it. It refuses while the owner's
change is still checked out, leaves the topic's revisions, branch, and pull
request alone, and also clears a claim directory that no active task holds.
An ended record from before `state` is rewritten as `released`.
Never edit `.jj/codex-session.json` by hand.

`tests/codex-session-properties.nu` checks these rules against the helpers
that decide them.

### Claude Code sessions

Claude Code's desktop app opens each session either in the default checkout
or in a linked Git worktree under `.claude/worktrees/NAME`, and refuses
edits outside that worktree. The worktree has no `.jj`, so `jj` and `ci`
run there resolve to the default checkout, and JJ never records files edited
in the worktree itself. Sessions that shared the default checkout moved each
other's working copies, snapshotted each other's edits into divergent
changes, and built systems from half-finished topics (2026-10-07).

- `ci start NAME` run inside such a worktree creates
  `<worktree>/.jj-workspaces/NAME`, where the app allows edits; elsewhere it
  creates `.jj-workspaces/NAME` beside the default checkout as before. The
  ci MCP server runs each job in the directory its `workspace` names, not at
  that directory's JJ root, so its `start` nests the same way.
- The app stops a session's whole cgroup scope when the session restarts,
  which twice killed one `ci land` waiting for the local checks lock
  (2026-10-16). The ci MCP server therefore starts each job in its own
  transient systemd user unit, `ci-mcp-JOB`, passing its environment
  explicitly, so a job keeps running and `job` reports its real outcome after
  a restart. `meta.json` names the unit; `cancel` stops the unit's processes.
  Without a user manager, or with `CI_MCP_DETACH=0`, a job runs as a
  detached process as before.
- Every other topic command (`new`, `sync`, `rebase`, `preflight`,
  `dispatch`, `land`, `park`, `cancel`) refuses to run from such a worktree,
  since it would act on the shared default checkout's working copy.
- The context-status plugin's PreToolUse hook (`context-status guard`)
  claims workspaces for Claude Code sessions in a repository with topic
  workspaces. A session's first Edit, Write, or NotebookEdit of a tracked file
  in a free workspace records the session as its owner in
  `.jj/codex-session.json`, with the session's transcript path for the
  takeover rule above, so `ci park`, `ci cancel`, `ci unclaim`, the audit, and
  Codex's hook all see it. A claim lock serializes two sessions' first
  edits. The hook refuses an edit to a workspace another live session owns,
  to a topic nobody handed over, or to a Git worktree without its own `.jj`,
  and names the free workspaces to use instead. It snapshots a workspace only
  when no live session owns it.
- Its SessionStart handoff says what the session may do in its directory:
  that it owns the workspace, that its first edit will claim it, or why it is
  refused and which workspaces are free. In a worktree, it lists the JJ
  workspaces the session already made there.

`tests/context-status-properties.nu` checks the guard's verdicts.

## Git worktrees and the devshell

A repository's dev shell provides the Nushell, JJ, GitHub CLI, Prek, and
`ci` for the workflow. From any checkout, enter it with:

```nu
nix develop path:.
```

Codex may create ordinary Git worktrees rather than JJ workspaces. Inspect
every checkout against the latest fetched trunk with:

```nu
ci worktree-status
```

`worktree-status` reports every Git worktree as `current`, `ahead`, `behind`,
or `diverged`, along with its branch, cleanliness, and whether it is a JJ or
ordinary Git worktree. The merge webhook updates only the dedicated JJ trunk
workspace. When Codex creates an ordinary linked Git worktree, the session hook
initializes a non-colocated JJ workspace there, using the shared Git repository
as its backend, and starts the task's topic from `main@tangled`. Active or dirty
worktrees remain owned by their tasks; ordinary Git worktrees created outside
Codex remain visible as ordinary Git worktrees.

## Nix and Tangled

Git-backed flakes can omit untracked files, so use `path:` references for
local commands, which include new files without Git staging:

```nu
nix develop path:.
nix build path:.#ci
```

Use JJ for change, bookmark, rebase, and push operations, and `ci land` for
delivery to `main`; nothing else pushes `main`. The landing clearance owns required
checks. Keep plaintext secrets and bulky generated output outside the selected
flake source root.
