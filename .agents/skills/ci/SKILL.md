---
name: ci
description: Use the repository's `ci` workflow to sequence, preflight, dispatch, land, park, and verify JJ changes. Apply when the `ci` command is available; do not use it as a generic Jujutsu tutorial.
---

# `ci` workflow

Use this skill when the repository provides the `ci` command. It is the
repository's policy layer around Jujutsu, Prek, its forges, and the trunk
workflow. The remote `trunk()` names (`main@tangled` or `main@origin`) hosts
`main` and every topic branch, and the other forge mirrors `main`; `ci land`
is the only path to `main`.

## Before acting

- Start with `jj status`, `jj diff`, and a focused `jj log` for the current
  change and its ancestors.
- Preserve unrelated working-copy changes. Jujutsu has no staging area, so
  every file in the working copy belongs to the current change unless the
  user says otherwise.
- Treat change IDs as the stable identity of a change and commit IDs as
  content hashes that can change when the change is rewritten.
- Inspect conflicts and emptiness before choosing a workflow.
- Before a synchronization that rebases history, create a checkpoint with
  `.agents/skills/jj/scripts/jj-checkpoint`.
- Before validation or dispatch, inspect the diff for mixed deliverables.
  Split independent deliverables into separate changes. Choose parent/child
  only when the later change depends on the earlier one to build, test, or
  make sense; choose siblings when both can be reviewed and landed
  independently. `jj split` creates parent/child changes by default, while
  `jj split --parallel` creates siblings. Checkpoint before splitting, assign
  explicit descriptions, and verify the resulting graph with `jj log`.
- Declare every revision's impact with `ci impact set`, not in its
  description: `refactor` when no NixOS closure changes (refactors, docs, CI,
  tooling), `behavior` for a user-facing change, or `breaking STEP...` for a
  user-facing change, listing each manual activation step as an argument.
  Declare each revision of a stack (`-r REV`), and declare again to change
  one. Never combine a refactor with a user-facing change in one topic; split
  the refactor into its own topic, or its own parent layer when the change
  depends on it.

## JJ MCP integration

When the `jj` MCP server is available, use its read-only status, log, diff,
show, file, bookmark, and operation-log tools for repository inspection. Read
the server's workflow guidance before a non-trivial JJ operation.

Use `ci` for repository policy workflows even when the MCP server exposes
equivalent low-level commands:

- `ci preflight` for formatting and Prek checks;
- `ci dispatch` for the stable topic bookmark and its push to the trunk remote while
  retaining the same working-copy change;
- `ci land` for delivery to `main`;
- `ci rebase` for updating that topic in place;
- `ci new` to start a topic as a revision in the current workspace, `ci start`
  to create a workspace when no free one exists, and `ci park` or
  `ci cancel` to release a topic.

When the `ci` MCP server is available, call its tools (`status`, `plan`,
`validate`, `publish`, `land`, `finish`, and so on) instead of running `ci`
in a shell. Each takes the same flags as the command below, runs in its
`workspace` argument, and returns a job; poll a `running` job with `job`.
The same safety rules apply.

Do not use low-level MCP mutation tools such as restore, abandon, direct push,
or rebase unless the user explicitly requests that specific operation and the
repository workflow does not provide the appropriate policy command. Never
push `main` directly.

## Command routing

Use the narrowest workflow that matches the request:

| User intent | Command | Notes |
| --- | --- | --- |
| Inspect local and dispatched state | `ci status` | Read-only. Lists each dispatched topic with its stack parent and open Tangled pull request. |
| Align an empty working copy with trunk | `ci sync` | Fetches the trunk remote, advances `main`, and rebases onto `trunk()`. |
| Check readiness and run preflight checks | `ci preflight` | Describes an undescribed change, runs `jj fix -s @`, then Prek on the JJ file list; a repository with no Prek configuration skips Prek. |
| Dispatch the current change | `ci dispatch` | Refuses unclassified or mixed-impact topics, then rebases, validates, and pushes a stable `jj-*` bookmark to the trunk remote. Keeps editing the same change. A topic built on another dispatched topic, or reported by `ci sequence` as conflicting with one, is restacked onto that topic's branch; conflicts must be resolved locally first. Open a pull request from the branch on the trunk's forge for review; never merge it there. |
| Land a topic on `main` | `ci land` | Requires an explicit user request. Dispatches, refuses a stacked topic until its parent lands, and proves a refactor is closure-neutral before it waits. It then waits in this machine's landing queue (a `blocked` `landing-queue` record names the landing ahead). From the front, it rebases only if `main` moved, builds every flake check at the exact head on this machine (skipping cached outputs), fast-forwards `main` to it on the trunk remote (setting a `ci land` commit status first where that is GitHub) and on the mirror, and tags releases. No other landing moves `main` meanwhile, so concurrent landings never restart one another; start them at once rather than one after another. `--clearance github` or `--clearance nixbot` waits for that CI on the exact head instead (`--timeout`, default 2hr); in a repository with `nixbot.toml` every dispatch already mirrors the topic for nixbot to build. Only if something outside the queue moves `main` during clearance does it rebase, redispatch, and clear the new head again (`--attempts`, default 5). `ci dispatch --land` does the same. Never merge a GitHub pull request; squash and rebase merges rewrite the tested commit. |
| Land every dispatched topic at once | `ci land --train` | Requires an explicit user request to land them all. Waits in the landing queue, rebases the dispatched, conflict-free topics into one chain in `ci sequence` order, proves each refactor against the chain below it, clears the tip once, fast-forwards `main`, and tags a release per user-facing revision. On a failed clearance it bisects, lands the passing prefix, names the culprit, and returns the rest to `main`. Skips topics with undispatched edits, conflicts, mixed or missing impact, or a held topic lock, and lists why. |
| Decide whether a topic ships alone or stacked | `ci sequence` | Read-only apart from a fetch. Trial-merges in-flight topics (dispatched `jj-*` bookmarks and workspace changes) against `trunk()` and each other, then proposes independent topics or stacks. `--json` for structured output. |
| Update a topic from trunk | `ci rebase` | Checkpoints, fetches, and rebases the same change. |
| Undo a failed rebase, restack, sync, or cancel | `ci recover [<id>]` | Reverts only the operations of the checkpoint printed as `Recovery point: ci recover ID` (default: this workspace's latest), keeping every other workspace's operations since. Refuses once a commit the rewrite made was edited or resolved. Never `jj op restore` a recovery point: it rewinds every workspace. |
| Restack dispatched topics after trunk moves | `ci sequence --apply` | Run it by hand only on request. Restacks stacked topics onto their parent's bookmark and conflicting topics onto `trunk()`, parents first. Checked-out topics are rebased from their own workspace only when a trial merge is clean. Pushes only conflict-free stacks. `--all` also rebases topics that are merely behind; `--no-push` stops before any remote change. |
| Start a topic | `ci new [-m <message>]` | Fetches and starts a topic on `trunk()` in the current workspace. An empty working copy that is unnamed, or that this session claimed, becomes the topic in place, keeping its change ID; otherwise a new change starts and the previous topic stays as a sibling (`jj edit` returns to it). Refuses while an active agent session owns another change here or an unfinished `ci start` topic is checked out. |
| Start concurrent work | `ci start <name>` | Only when no workspace is free. Creates `.jj-workspaces/<name>` at `trunk()` for an actor that runs alongside the current working copy (another agent task, a build, a dev server), inside the Git worktree it runs from if any (such as a Claude Code worktree); refuses a name already in use. |
| Hand a topic to an agent | `ci adopt` | Only on the user's request. Lets the next agent session that edits the workspace claim the topic checked out there, which agents are otherwise refused. |
| Finish a landed topic | `ci park` | Verifies the current revision is on `trunk()`, deletes the topic bookmark locally and on the remotes, and removes a workspace that `ci start` created before archiving. `--keep` returns it to the pool instead: it stays on an empty change on main and drops its `ci start` marker, so the next task starts a fresh topic there. Any other workspace also stays. An empty working copy passes when its dispatched branch, if any, landed. |
| Drop a topic that will not land | `ci cancel` | Refuses while a Tangled pull request from its branch is open. Checkpoints, deletes the topic bookmark, abandons the revisions above `trunk()`, and releases the workspace like `park`. Requires an explicit user request. |
| Reclaim leaked workspaces | `ci prune` | Dry run by default. Lists missing workspaces and unowned ones whose work is delivered (only an empty undescribed working copy remains above `trunk()`), plus checkpoints older than `--keep-days`. Reports stale workspaces untouched. `--apply` updates stale ones, decides again, then forgets and deletes the listed ones, which requires an explicit user request. |
| Capture a review version | `ci review snapshot <label>` | Records the exact base and series tip for a later interdiff. |
| Compare review versions | `ci interdiff <old> <new>` | Runs a commit-by-commit `git range-diff` between named snapshots. |
| Review a series as stacked Tangled pull requests | `ci dispatch --stack` | Pushes each revision as `stack/<series>/<change-id>`; then choose `Submit as stacked PRs` in Tangled. Review only; `ci land` still delivers. |
| Declare a revision's impact | `ci impact set <class> [<step>...] [-r <rev>]` | Records a `ci.impact.set` event in the machine's ci log, keyed by change ID, so it survives rebases. `breaking` requires at least one step; the others take none. `ci impact show [<revset>]` lists declarations; `ci impact import` reads former `Impact:` trailers of undeclared revisions. |
| Check a commit range's impact | `ci impact check <base> <head>` | Reads the declarations from this machine's ci log; for a refactor it proves every host closure matches the merge base. `ci land` runs the same proof. |
| Show the release in the current revision | `ci version` | Read-only. Releases are CalVer tags (`YYYY.MM.DD.N`) that `ci land` cuts for behavior and breaking revisions; `ci release` only catches up after a failed tag push. |

## Safety rules

- `ci sync` rejects nonempty changes and active agent session ownership.
  Use `ci rebase` to update an active topic without creating another change.
- Do not dispatch an empty or conflicted change. `ci dispatch` enforces this,
  but inspect the state first so the user understands the blocker.
- Do not run `ci land` or `ci dispatch --land` unless the user explicitly
  asks to deliver the topic.
- Do not activate NixOS or Home Manager configuration as part of validation.
  If configuration changes are ready, report the appropriate activation command
  and request approval separately.
- Prefer `ci` over manually reproducing its fetch, bookmark, push, landing,
  and validation sequence. Use raw JJ commands only for focused inspection or
  when the user explicitly asks for a different history operation.

## Publication expectations

Keep one coherent topic per revision; give it its own workspace only when
another actor uses the current working copy concurrently. Use one stable JJ change ID
for a single deliverable, or a small stack of stable change IDs when mixed
deliverables were intentionally split. `ci dispatch` uses a persisted
`jj-<title-slug>-<short-change-id>` bookmark for new topics, preserving the
selected branch through title changes and repeated edits. Only `jj-*`
bookmarks count as dispatched topics. Do not wait for a pipeline after
dispatching; `ci land` takes clearance locally. It does not start
an unrelated follow-up change. Report the branch and existing change IDs.

Land only at requested topic closeout. Once `ci land` has fast-forwarded
`main`, `ci park` verifies the landing and prepares a clean workspace.
Then archive through the app tool. Leave the task open if clearance failed,
landing is pending, or there are later local edits. SessionEnd also fires on
exit and idle timeout, so it must never trigger dispatch or landing. A
direct archive button click does not run this workflow.

For stacked work, inspect the stack before acting. Land parents first; do not
bypass the workflow with direct branch pushes or merges.

## Continuous integration and conflict handling

In a repository with topic workspaces, an agent session works only in a
workspace whose change it owns. Any workspace idle on trunk (nothing above
`trunk()` but an empty change) is free, the default checkout included:
the session's first edit there claims it, and `ci new -m MESSAGE` names the
claimed change in place. A workspace another live session owns, or one holding
a topic no session owns, refuses the session's edits; the session-start note
and the refusal name the free workspaces to move to, and only when none is
free does the session create one with `ci start NAME`. Never take over a topic
the user started unless they ask; they hand it over with `ci adopt`. In a
workspace it owns, a session starts its next topic with `ci new` and continues
in place after `ci park --keep` or `ci park` returns the workspace to trunk.
From a Claude Code worktree under `.claude/worktrees/`, which is a Git
worktree rather than a JJ workspace, `ci start` creates the workspace inside
it so the app lets the session edit there.
Rebase before each review update and when the topic conflicts with `main`; a
topic that merely fell behind needs nothing until it lands. `ci dispatch` and
`ci land` perform a final rebase and validation before pushing, and `ci land`
lands only the exact commit the landing clearance passed, so a stale head cannot
reach `main`.

Use `ci conflicts` after a rebase to list conflicted revisions and files.
A conflicted rebase has already rewritten the topic: resolve revisions from
oldest to newest, then verify with `ci conflicts` before validating. To drop
the attempt instead, run `ci recover` before resolving anything; never
`jj op restore` its recovery point, which also undoes every other workspace's
operations since, such as a concurrent dispatch.
Never run an automatic conflict resolver. `ci sequence --apply` is the only
unattended rebase.

`ci sequence --apply` rewrites only topics that need it: a stacked topic whose parent
moved, and a topic that conflicts with `main`. `--all` also rebases topics that
are merely behind. A topic checked out in a workspace is snapshotted and then
rebased from that workspace, so its files move with it. If a trial merge
predicts a conflict, the topic is left untouched for its owner. A topic that is
not checked out uses JJ's recorded conflicts as the push condition: it stays rebased
locally, its branch is untouched, and the command lists each conflicted
revision and file. Resolve oldest first with `jj new CHANGE_ID`, edit the files
or run `jj resolve`, `jj squash`, and then run `ci sequence --apply` again to push.
Never resolve those conflicts automatically.

Run `ci sequence` before dispatching when other topics are in flight. It builds
headless trial merges (`jj new --no-edit`) and abandons them, so no working
copy moves. Topics that conflict with nothing dispatch as independent topics.
Topics that conflict with each other are ordered with dispatched topics first,
then refactors before user-facing changes, then by age: the later topic is
rebased onto the earlier one, its conflicts are resolved locally, and it is
dispatched stacked on the earlier topic's branch. Age is the topic's oldest
author time, then its change ID, so rewrites never reorder topics. If the
earlier topic is not dispatched yet, the later one dispatches independently
instead of waiting, and whichever lands second resolves the conflict. Chains
longer than three hold the remainder locally until a layer lands. Topics that
conflict with `main` must be resolved with `ci rebase` first. Never rebase a
dispatched topic onto undispatched work, and never rewrite another session's
topic to build a stack; stack new work on top of it. Landing fast-forwards
`main` to the parent's exact commits, so a stacked child is already on `main`
once its parent lands. The plan detects textual conflicts only; the landing
clearance check on each rebased head is the backstop for semantic breakage between topics.

Herdr and Paseo may supervise one existing JJ workspace per topic, monitor
trunk, topic freshness, and pipelines, and notify the owner when integration
is needed. They must not take ownership of the workspace or silently rebase,
resolve conflicts, dispatch, land, or advance a stack.

Prefer one ordinary branch per coherent topic. Use stacks only for
independently reviewable changes with real dependency order; keep each child
based on its immediate parent. Keep unrelated work in separate sibling
changes.
