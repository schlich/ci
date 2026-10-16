"""MCP server that exposes the repository's `ci` workflow as agent tools.

Every tool starts `ci` as a background job in a JJ workspace, waits up to
`wait_seconds` for it, and returns its output. A job that outlives the wait
keeps running; poll it with `job`. Jobs record their log and exit code
under $XDG_STATE_HOME/ci-mcp/jobs, so a result survives the server.

The server starts the `ci` launcher (ci-launch.nu), which runs the ci.nu the
package bundles, or, inside the ci repository, a topic's own ci.nu when the
topic edits it and main@tangled's otherwise.

Each job also announces its start and end on the local cross.stream store,
under the topic its meta.json names, so `watch-job` wakes the moment it ends.
"""

import asyncio
import json
import os
import re
import secrets
import signal
import subprocess
import threading
import time
from pathlib import Path
from typing import Annotated, Literal

from mcp.server.fastmcp import FastMCP
from mcp.types import ToolAnnotations
from pydantic import Field

CI = os.environ.get("CI_MCP_CI", "ci")
STATE = (
    Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local" / "state")
    / "ci-mcp"
    / "jobs"
)
XS_STORE = os.environ.get("XS_ADDR") or str(
    Path.home() / ".local" / "share" / "cross.stream" / "store"
)
ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07]*\x07")
# The wait a mutating tool gets when the caller names none: long enough for
# quick commands to answer inline, short enough not to hold a client's call.
DEFAULT_WAIT = 60
TAIL = 12_000

READ_ONLY = ToolAnnotations(readOnlyHint=True, openWorldHint=True)
LOCAL = ToolAnnotations(readOnlyHint=False, destructiveHint=False)
REMOTE = ToolAnnotations(readOnlyHint=False, destructiveHint=False, openWorldHint=True)
DESTRUCTIVE = ToolAnnotations(
    readOnlyHint=False, destructiveHint=True, openWorldHint=True
)

mcp = FastMCP(
    "ci",
    instructions=(
        "Tools for this repository's `ci` trunk workflow over Jujutsu and "
        "Tangled; the `ci` skill describes when to use each command. Every "
        "tool runs in `workspace` (default: the server's working directory) "
        "and returns a job record. When `state` is `running`, poll it with "
        "`job`. Run `land`, `dispatch` with `land`, and `cancel_topic` only when "
        "the user explicitly asks to deliver or drop the topic."
    ),
)

Workspace = Annotated[
    str | None,
    Field(description="Directory inside the JJ workspace to run in."),
]
Wait = Annotated[
    float | None,
    Field(
        description="Seconds to wait for the result before returning a "
        "running job (0-600).",
        ge=0,
        le=600,
    ),
]

_procs: dict[str, subprocess.Popen] = {}


def workspace_root(workspace: str | None) -> Path:
    start = Path(workspace or os.getcwd()).expanduser()
    result = subprocess.run(
        ["jj", "root"], cwd=start, capture_output=True, text=True, check=False
    )
    if result.returncode != 0:
        raise ValueError(f"{start} is not in a JJ workspace: {result.stderr.strip()}")
    return Path(result.stdout.strip())


def job_dir(job_id: str) -> Path:
    if not re.fullmatch(r"[0-9]{8}T[0-9]{6}-[a-z0-9-]+", job_id):
        raise ValueError(f"Unknown job id {job_id!r}.")
    return STATE / job_id


def read_meta(path: Path) -> dict:
    return json.loads((path / "meta.json").read_text())


def alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def job_event(topic: str, meta: dict) -> None:
    # The job directory stays the record, so a store that is down costs a
    # watcher only its prompt wake-up.
    try:
        subprocess.run(
            ["xs", "append", XS_STORE, topic, "--meta", json.dumps(meta)],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            timeout=5,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        pass


def job_state(path: Path, meta: dict) -> tuple[str, int | None]:
    exit_file = path / "exit"
    if exit_file.exists():
        code = int(exit_file.read_text().strip() or "1")
        return ("succeeded" if code == 0 else "failed"), code
    if alive(meta["pid"]):
        return "running", None
    return "lost", None


def render(job_id: str, tail: int = TAIL) -> dict:
    path = job_dir(job_id)
    meta = read_meta(path)
    current, code = job_state(path, meta)
    log = ANSI.sub("", (path / "log").read_text(errors="replace"))
    truncated = len(log) > tail
    return {
        "job_id": job_id,
        "command": "ci " + " ".join(meta["args"]),
        "workspace": meta["workspace"],
        "state": current,
        "exit_code": code,
        "started": meta["started"],
        "log_path": str(path / "log"),
        "output_truncated": truncated,
        "output": log[-tail:] if truncated else log,
    }


def running_mutation(root: Path) -> str | None:
    if not STATE.exists():
        return None
    for path in STATE.iterdir():
        try:
            meta = read_meta(path)
        except (OSError, ValueError):
            continue
        if (
            meta["mutating"]
            and meta["workspace"] == str(root)
            and job_state(path, meta)[0] == "running"
        ):
            return path.name
    return None


def start_job(args: list[str], workspace: str | None, mutating: bool) -> str:
    root = workspace_root(workspace)
    # Run where the caller asked, not at the JJ root: from a Claude Code
    # worktree, which has no .jj, the root is the shared checkout above it,
    # so `ci start` could not see the worktree to nest the new workspace in,
    # and topic commands could not refuse to act on the shared checkout.
    cwd = Path(workspace or os.getcwd()).expanduser()
    if mutating and (busy := running_mutation(root)):
        raise ValueError(
            f"Job {busy} is still changing {root}; wait for it with `job` "
            "or stop it with `cancel` first."
        )
    stamp = time.strftime("%Y%m%dT%H%M%S")
    slug = re.sub(r"[^a-z0-9]+", "-", args[0].lower()).strip("-")
    job_id = f"{stamp}-{slug}-{secrets.token_hex(3)}"
    path = STATE / job_id
    path.mkdir(parents=True)
    env = dict(os.environ, NO_COLOR="1", TERM="dumb", COLUMNS="100")
    topic = f"job.{job_id}"
    env["CI_MCP_XS"] = XS_STORE
    env["CI_MCP_DONE"] = f"{topic}.done"
    env["CI_MCP_LOG"] = str(path / "log")
    env["CI_MCP_EXIT"] = str(path / "exit")
    # ci reports its phases there as OSC 7501 records, which
    # `watch-job <log_path>` follows beside the log.
    env["PST_FILE"] = str(path / "log.status.jsonl")
    # The shell records the exit code even if this server exits first; the
    # job runs in its own session so a client disconnect does not kill it.
    proc = subprocess.Popen(
        [
            "sh",
            "-c",
            # It then announces the exit code on cross.stream, so watch-job
            # wakes the moment the job ends.
            (
                '"$@" >"$CI_MCP_LOG" 2>&1; code=$?; echo $code >"$CI_MCP_EXIT"; '
                'xs append "$CI_MCP_XS" "$CI_MCP_DONE" '
                '--meta "{\\"outcome\\": {\\"exit_code\\": $code}}" >/dev/null 2>&1'
            ),
            "ci-mcp-job",
            CI,
            *args,
        ],
        cwd=cwd,
        env=env,
        stdin=subprocess.DEVNULL,
        start_new_session=True,
    )
    _procs[job_id] = proc
    threading.Thread(target=proc.wait, daemon=True).start()
    (path / "meta.json").write_text(
        json.dumps(
            {
                "args": args,
                "workspace": str(root),
                "mutating": mutating,
                "pid": proc.pid,
                "started": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
                "topic": topic,
            }
        )
    )
    (path / "log").touch()
    job_event(
        f"{topic}.start",
        {"log": str(path / "log"), "cwd": str(cwd), "pid": proc.pid},
    )
    return job_id


async def wait_for(job_id: str, wait: float) -> dict:
    deadline = time.monotonic() + wait
    path = job_dir(job_id)
    meta = read_meta(path)
    while job_state(path, meta)[0] == "running" and time.monotonic() < deadline:
        await asyncio.sleep(0.5)
    return render(job_id)


async def run(
    args: list[str],
    workspace: str | None,
    wait: float | None,
    *,
    mutating: bool = True,
    default_wait: float = DEFAULT_WAIT,
) -> dict:
    job_id = start_job(args, workspace, mutating)
    return await wait_for(job_id, default_wait if wait is None else wait)


def parse_json_output(result: dict) -> dict:
    if result["state"] == "succeeded":
        text = result["output"].strip()
        start = min(
            (i for i in (text.find("{"), text.find("[")) if i >= 0),
            default=-1,
        )
        if start >= 0:
            try:
                result["data"] = json.loads(text[start:])
            except ValueError:
                pass
    return result


# Read-only inspection


@mcp.tool(annotations=READ_ONLY)
async def status(workspace: Workspace = None, wait_seconds: Wait = None) -> dict:
    """`ci status`: JJ status plus each published topic with its stack
    parent, spindle pipeline state, and open Tangled pull request."""
    return await run(["status"], workspace, wait_seconds, mutating=False)


@mcp.tool(annotations=READ_ONLY)
async def state(workspace: Workspace = None, wait_seconds: Wait = None) -> dict:
    """`ci ci-state`: the current topic's publication and pipeline facts as
    JSON in `data`. Never fetches, pushes, or rewrites anything."""
    result = await run(["ci-state"], workspace, wait_seconds, mutating=False)
    return parse_json_output(result)


@mcp.tool(annotations=READ_ONLY)
async def sequence(workspace: Workspace = None, wait_seconds: Wait = None) -> dict:
    """`ci sequence --json`: trial-merge in-flight topics against main@tangled
    and each other, and propose independent topics or stacks (in `data`).
    Fetches, but moves no working copy."""
    result = await run(["sequence", "--json"], workspace, wait_seconds, mutating=False)
    return parse_json_output(result)


@mcp.tool(annotations=READ_ONLY)
async def conflicts(workspace: Workspace = None, wait_seconds: Wait = None) -> dict:
    """`ci conflicts`: list conflicted revisions and files after a rebase."""
    return await run(["conflicts"], workspace, wait_seconds, mutating=False)


@mcp.tool(annotations=READ_ONLY)
async def worktree_status(
    workspace: Workspace = None, wait_seconds: Wait = None
) -> dict:
    """`ci worktree-status`: each Git worktree's state against tangled/main."""
    return await run(["worktree-status"], workspace, wait_seconds, mutating=False)


@mcp.tool(annotations=READ_ONLY)
async def version(workspace: Workspace = None, wait_seconds: Wait = None) -> dict:
    """`ci version`: the CalVer release in the current revision."""
    return await run(["version"], workspace, wait_seconds, mutating=False)


@mcp.tool(annotations=READ_ONLY)
async def verify_list(
    count: Annotated[int, Field(ge=1, le=100)] = 10,
    workspace: Workspace = None,
    wait_seconds: Wait = None,
) -> dict:
    """`ci verify list`: recent releases and their recorded verifications."""
    return await run(
        ["verify", "list", "--count", str(count)],
        workspace,
        wait_seconds,
        mutating=False,
    )


@mcp.tool(annotations=READ_ONLY)
async def interdiff(
    old: str, new: str, workspace: Workspace = None, wait_seconds: Wait = None
) -> dict:
    """`ci interdiff OLD NEW`: commit-by-commit range-diff between two review
    snapshots taken with `review_snapshot`."""
    return await run(["interdiff", old, new], workspace, wait_seconds, mutating=False)


@mcp.tool(annotations=READ_ONLY)
async def impact_check(
    base: str, head: str, workspace: Workspace = None, wait_seconds: Wait = None
) -> dict:
    """`ci impact check BASE HEAD`: check the impact declared for each
    revision in a range; for a refactor, prove every host closure matches the
    merge base. Builds closures, so it can take minutes."""
    return await run(
        ["impact", "check", base, head],
        workspace,
        wait_seconds,
        mutating=False,
        default_wait=20,
    )


@mcp.tool(annotations=READ_ONLY)
async def impact_show(
    revset: Annotated[
        str | None,
        Field(description="Revisions to show (default: the current topic)."),
    ] = None,
    workspace: Workspace = None,
    wait_seconds: Wait = None,
) -> dict:
    """`ci impact show`: each revision's declared impact class and manual
    steps, from the ci log."""
    args = ["impact", "show"] + ([] if revset is None else [revset])
    return await run(args, workspace, wait_seconds, mutating=False)


@mcp.tool(annotations=READ_ONLY)
async def release_dry_run(
    workspace: Workspace = None, wait_seconds: Wait = None
) -> dict:
    """`ci release --dry-run`: show which release tags `ci release` would
    push to catch up after a failed tag push."""
    return await run(["release", "--dry-run"], workspace, wait_seconds, mutating=False)


@mcp.tool(annotations=READ_ONLY)
async def prune_dry_run(
    keep_days: Annotated[int, Field(ge=0)] = 14,
    workspace: Workspace = None,
    wait_seconds: Wait = None,
) -> dict:
    """`ci prune`: list leaked workspaces, landed topic branches, and old
    checkpoints that `ci prune --apply` would delete. Deletes nothing."""
    return await run(
        ["prune", "--keep-days", str(keep_days)],
        workspace,
        wait_seconds,
        mutating=False,
    )


# Topics and workspaces


@mcp.tool(annotations=LOCAL)
async def new(
    message: Annotated[
        str | None, Field(description="Description for the new topic.")
    ] = None,
    workspace: Workspace = None,
    wait_seconds: Wait = None,
) -> dict:
    """`ci new`: start a topic as a new change on main@tangled in this
    workspace; the current topic stays as a sibling."""
    args = ["new"] + ([] if message is None else ["--message", message])
    return await run(args, workspace, wait_seconds)


@mcp.tool(annotations=LOCAL)
async def impact_set(
    impact: Literal["refactor", "behavior", "breaking"],
    steps: Annotated[
        list[str] | None,
        Field(
            description="The manual steps activating a breaking change needs, "
            "in order. Required for breaking; omit otherwise."
        ),
    ] = None,
    revision: Annotated[
        str, Field(description="Revision or revset to declare (default: @).")
    ] = "@",
    workspace: Workspace = None,
    wait_seconds: Wait = None,
) -> dict:
    """`ci impact set IMPACT [STEP...] -r REVISION`: declare a revision's
    impact in the ci log. Dispatch and landing require one per revision; the
    latest declaration for a change wins."""
    args = ["impact", "set", impact, *(steps or []), "--revision", revision]
    return await run(args, workspace, wait_seconds)


@mcp.tool(annotations=LOCAL)
async def start(
    name: Annotated[
        str,
        Field(
            description="Lowercase workspace and topic name.",
            pattern=r"^[a-z0-9][a-z0-9-]*$",
        ),
    ],
    workspace: Workspace = None,
    wait_seconds: Wait = None,
) -> dict:
    """`ci start NAME`: create .jj-workspaces/NAME on main@tangled for an
    actor that runs alongside the current working copy, inside the Git
    worktree `workspace` names if it is one (a Claude Code worktree). Run
    later tools with `workspace` set to the new directory."""
    return await run(["start", name], workspace, wait_seconds)


@mcp.tool(annotations=LOCAL)
async def sync(workspace: Workspace = None, wait_seconds: Wait = None) -> dict:
    """`ci sync`: fetch Tangled, advance main, and rebase an empty working
    copy onto main@tangled. Refuses a nonempty change."""
    return await run(["sync"], workspace, wait_seconds)


@mcp.tool(annotations=LOCAL)
async def rebase(workspace: Workspace = None, wait_seconds: Wait = None) -> dict:
    """`ci rebase`: checkpoint, fetch, and rebase the current topic onto
    main@tangled in place. Check `conflicts` afterwards."""
    return await run(["rebase"], workspace, wait_seconds)


@mcp.tool(annotations=LOCAL)
async def recover(
    checkpoint: Annotated[
        str | None,
        Field(description='The ID printed with "Recovery point"; omit for the latest'),
    ] = None,
    workspace: Workspace = None,
    wait_seconds: Wait = None,
) -> dict:
    """`ci recover [CHECKPOINT]`: undo a checkpoint's rebase, restack, sync,
    or cancel by reverting only the operations it tagged. Other workspaces'
    operations since then stay; never `jj op restore` a recovery point."""
    args = ["recover"] if checkpoint is None else ["recover", checkpoint]
    return await run(args, workspace, wait_seconds)


@mcp.tool(annotations=LOCAL)
async def review_snapshot(
    label: str, workspace: Workspace = None, wait_seconds: Wait = None
) -> dict:
    """`ci review snapshot LABEL`: record the series' base and tip for a
    later `interdiff`."""
    return await run(["review", "snapshot", label], workspace, wait_seconds)


@mcp.tool(annotations=LOCAL)
async def unclaim(workspace: Workspace = None, wait_seconds: Wait = None) -> dict:
    """`ci unclaim`: release a Codex task's claim on this workspace. The
    topic's revisions, branch, and pull request stay untouched."""
    return await run(["unclaim"], workspace, wait_seconds)


# Validation and delivery


@mcp.tool(annotations=LOCAL)
async def preflight(workspace: Workspace = None, wait_seconds: Wait = None) -> dict:
    """`ci preflight`: run formatting and Prek gates on the current change.
    Usually outlasts the default wait; poll the job."""
    return await run(["preflight"], workspace, wait_seconds, default_wait=20)


@mcp.tool(annotations=REMOTE)
async def dispatch(
    land: Annotated[
        bool,
        Field(
            description="Also land once the topic has clearance. Only on an "
            "explicit user request to deliver."
        ),
    ] = False,
    clearance: Literal["local", "spindle", "github"] = "local",
    timeout: Annotated[
        str, Field(description="Nushell duration --land waits, e.g. 2hr.")
    ] = "2hr",
    attempts: Annotated[int, Field(ge=1, le=20)] = 5,
    workspace: Workspace = None,
    wait_seconds: Wait = None,
) -> dict:
    """`ci dispatch`: rebase, validate, and push the topic's stable jj-*
    branch to Tangled, keeping the same change."""
    args = ["dispatch"]
    if land:
        args += ["--land", "--clearance", clearance, "--timeout", timeout]
        args += ["--attempts", str(attempts)]
    return await run(args, workspace, wait_seconds, default_wait=20)


@mcp.tool(annotations=DESTRUCTIVE)
async def land(
    clearance: Literal["local", "spindle", "github"] = "local",
    timeout: Annotated[
        str, Field(description="Nushell duration to wait, e.g. 2hr.")
    ] = "2hr",
    attempts: Annotated[int, Field(ge=1, le=20)] = 5,
    train: Annotated[
        bool,
        Field(
            description="Land every dispatched, conflict-free topic in one "
            "fast-forward (`--train`), clearing the chain once and bisecting "
            "on failure. Only when the user asks to land them all."
        ),
    ] = False,
    workspace: Workspace = None,
    wait_seconds: Wait = None,
) -> dict:
    """`ci land`: dispatch, wait in the machine's landing queue, clear the
    exact head (every flake check by default), fast-forward main on Tangled
    and GitHub, and tag releases. Concurrent landings take turns instead of
    restarting one another. Only on an explicit user request to deliver the
    topic. Takes minutes to hours; poll the job."""
    args = ["land", "--clearance", clearance, "--timeout", timeout]
    if train:
        args += ["--train"]
    else:
        args += ["--attempts", str(attempts)]
    return await run(args, workspace, wait_seconds, default_wait=20)


@mcp.tool(annotations=REMOTE)
async def sequence_apply(
    no_push: bool = False,
    all_topics: Annotated[
        bool,
        Field(description="Also rebase topics merely behind main (--all)."),
    ] = False,
    workspace: Workspace = None,
    wait_seconds: Wait = None,
) -> dict:
    """`ci sequence --apply`: restack stacked or conflicting dispatched
    topics and push only conflict-free ones. Run only when the user asks."""
    args = ["sequence", "--apply"]
    args += ["--no-push"] if no_push else []
    args += ["--all"] if all_topics else []
    return await run(args, workspace, wait_seconds, default_wait=20)


@mcp.tool(annotations=REMOTE)
async def dispatch_stack(
    workspace: Workspace = None, wait_seconds: Wait = None
) -> dict:
    """`ci dispatch --stack`: push each revision of the series as its own
    branch for stacked Tangled review. Review only; `land` delivers."""
    return await run(["dispatch", "--stack"], workspace, wait_seconds)


@mcp.tool(annotations=REMOTE)
async def park(
    keep: Annotated[
        bool,
        Field(description="Keep a `ci start` workspace for the next task."),
    ] = False,
    workspace: Workspace = None,
    wait_seconds: Wait = None,
) -> dict:
    """`ci park`: verify the topic landed, delete its branch, and free
    the workspace (removing one `ci start` created unless `keep`)."""
    args = ["park"] + (["--keep"] if keep else [])
    return await run(args, workspace, wait_seconds)


@mcp.tool(annotations=DESTRUCTIVE)
async def cancel_topic(
    keep: Annotated[
        bool,
        Field(description="Keep a `ci start` workspace for the next task."),
    ] = False,
    workspace: Workspace = None,
    wait_seconds: Wait = None,
) -> dict:
    """`ci cancel`: delete the topic branch, abandon its revisions, and
    release the workspace. Only on an explicit user request."""
    args = ["cancel"] + (["--keep"] if keep else [])
    return await run(args, workspace, wait_seconds)


@mcp.tool(annotations=REMOTE)
async def verify(
    message: Annotated[str, Field(description="How you tested it.")],
    release: Annotated[
        str | None,
        Field(description="CalVer release; defaults to the newest."),
    ] = None,
    workspace: Workspace = None,
    wait_seconds: Wait = None,
) -> dict:
    """`ci verify`: record that a release was verified on this host."""
    args = ["verify"] + ([] if release is None else [release])
    return await run(args + ["--message", message], workspace, wait_seconds)


# Jobs


@mcp.tool(annotations=ToolAnnotations(readOnlyHint=True))
async def job(
    job_id: str,
    wait_seconds: Wait = None,
    tail_chars: Annotated[int, Field(ge=1000, le=100_000)] = TAIL,
) -> dict:
    """Wait up to `wait_seconds` (default 30) for a job, then return its
    state, exit code, and the end of its output. The full log is at
    `log_path`."""
    await wait_for(job_id, 30 if wait_seconds is None else wait_seconds)
    return render(job_id, tail_chars)


@mcp.tool(annotations=ToolAnnotations(readOnlyHint=True))
def jobs(
    limit: Annotated[int, Field(ge=1, le=100)] = 20,
) -> list[dict]:
    """List the most recent jobs, newest first, without their output."""
    if not STATE.exists():
        return []
    found = []
    for path in sorted(STATE.iterdir(), reverse=True)[:limit]:
        try:
            meta = read_meta(path)
        except (OSError, ValueError):
            continue
        current, code = job_state(path, meta)
        found.append(
            {
                "job_id": path.name,
                "command": "ci " + " ".join(meta["args"]),
                "workspace": meta["workspace"],
                "state": current,
                "exit_code": code,
                "started": meta["started"],
            }
        )
    return found


@mcp.tool(annotations=ToolAnnotations(readOnlyHint=False, destructiveHint=True))
def cancel(job_id: str) -> dict:
    """Stop a running job by sending SIGTERM to its process group. `ci`
    checkpoints before history surgery; inspect the workspace afterwards."""
    path = job_dir(job_id)
    meta = read_meta(path)
    if job_state(path, meta)[0] == "running":
        os.killpg(meta["pid"], signal.SIGTERM)
        time.sleep(1)
    return render(job_id)


def main() -> None:
    mcp.run()


if __name__ == "__main__":
    main()
