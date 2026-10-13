def state-path [session_id: string] {
    if $session_id !~ '^[a-zA-Z0-9_-]+$' {
        error make { msg: "Invalid Codex session ID." }
    }
    let state_dir = ($env.XDG_STATE_HOME? | default ($env.HOME | path join ".local" "state"))
    $state_dir | path join "codex-jj-sessions" $"($session_id).json"
}

const MUTATING_TOOLS = "(^Bash$|exec_command$|apply_patch$|^Edit$|^Write$)"

# Hook output must be printed: a value computed before a `return` is
# discarded, so a returned verdict would never reach Codex.
def block [reason: string] {
    { decision: "block", reason: $reason } | to json | print
}

def add-context [event_name: string, text: string] {
    { hookSpecificOutput: { hookEventName: $event_name additionalContext: $text } } | to json | print
}

def git-worktree-warning [cwd: path] {
    let main_result = (^git -C $cwd rev-parse --verify refs/remotes/tangled/main | complete)
    if $main_result.exit_code != 0 { return null }
    let stale = (^git -C $cwd merge-base --is-ancestor refs/remotes/tangled/main HEAD | complete).exit_code != 0
    if not $stale { return null }
    let branch_result = (^git -C $cwd symbolic-ref --short -q HEAD | complete)
    let branch = if $branch_result.exit_code == 0 {
        $branch_result.stdout | str trim
    } else {
        "detached"
    }
    let jj_workspace = (($cwd | path join ".jj") | path exists)
    if $jj_workspace {
        $"This worktree ($branch) is behind or diverged from tangled/main. Run `ci rebase` before continuing. Use `ci worktree-status` to inspect the other worktrees."
    } else {
        $"This checkout ($branch) is a Git worktree, not a JJ workspace, and is behind or diverged from tangled/main. Enter the devshell with `nix develop path:.` and inspect it with `ci worktree-status`; do not assume `ci rebase` can safely operate here until this checkout is converted to a JJ workspace."
    }
}

def checked [repository: string, ...args: string] {
    let result = (^jj --repository $repository ...$args | complete)
    if $result.exit_code != 0 {
        error make { msg: ($result.stderr | str trim) }
    }
    $result.stdout | str trim
}

# This hook runs in every Codex project, so trunk may live on any remote.
def trunk-revset [root: string] {
    let candidates = ["main@tangled" "main@origin" "trunk()"]
    $candidates | where {|revset|
        (^jj --repository $root log -r $revset --no-graph -T commit_id | complete).exit_code == 0
    } | first
}

def git-backend-root [cwd: string] {
    let result = (^git -C $cwd rev-parse --path-format=absolute --git-common-dir | complete)
    if $result.exit_code != 0 { return null }
    let common_dir = ($result.stdout | str trim)
    if ($common_dir | path type) == "dir" {
        $common_dir
    } else {
        null
    }
}

def initialize-git-worktree [cwd: string] {
    let backend = (git-backend-root $cwd)
    if $backend == null { return false }

    # Codex creates linked Git worktrees, where `jj git init --colocate` is not
    # allowed. Point the new JJ workspace at the shared Git backend instead.
    let result = (do {
        cd $cwd
        ^jj git init --git-repo $backend $cwd
    } | complete)
    if $result.exit_code != 0 {
        # Another session may have initialized this worktree concurrently.
        let jj_root = (^jj --repository $cwd root | complete)
        if $jj_root.exit_code != 0 {
            error make { msg: $"Could not initialize JJ workspace in ($cwd): ($result.stderr | str trim)" }
        }
    }
    true
}

# The state an ownership record declares: none, active, delivered, discarded,
# or released. A record from before `state` has only `finished`, which proves
# release but never delivery. Keep in step with owner-status in ci.nu.
def owner-status [owner: any] {
    if $owner == null { return "none" }
    let state = ($owner.state? | default "")
    if $state in ["active" "delivered" "discarded" "released"] { return $state }
    if ($owner.finished? | default false) { "released" } else { "active" }
}

# Whether this session may take the workspace, from facts the caller reads:
#   workspace     this workspace's name
#   dedicated     whether the repository has other workspaces
#   owner         owner-status of the workspace's ownership record
#   same_session  whether that record belongs to this session
#   claim         whether a startup claim directory exists
#   has_state     whether this session already recorded a workspace
# `resume` continues this session's task, `claim` starts a new topic, `skip`
# leaves the workspace unclaimed with `reason`, and `refuse` stops the session.
def claim-verdict [facts: record] {
    if $facts.owner == "active" and not $facts.same_session {
        return { action: "refuse" reason: "This workspace belongs to another active Codex task. Use a separate JJ workspace for a different topic." }
    }
    if $facts.has_state { return { action: "resume" reason: null } }
    # A repository with topic workspaces keeps its default one as the
    # canonical checkout on main; claiming it strands the checkout on a topic.
    if $facts.workspace == "default" and $facts.dedicated {
        return { action: "skip" reason: "This is the repository's canonical checkout. Start the topic in its own workspace with `ci start NAME` and open that directory as the project." }
    }
    if $facts.claim {
        return { action: "refuse" reason: "This workspace has a session claim that no active task holds. Inspect .jj/codex-session.json, then clear it with `ci unclaim`." }
    }
    { action: "claim" reason: null }
}

def workspace-facts [root: string] {
    let listing = (checked $root -- workspace list -T 'name ++ "\t" ++ target.current_working_copy() ++ "\n"')
    let workspaces = ($listing | lines | where {|line| $line | is-not-empty } | parse "{name}\t{current}")
    {
        workspace: ($workspaces | where current == "true" | get --optional 0.name | default "default")
        dedicated: (($workspaces | length) > 1)
    }
}

# Claim the workspace for this session or resume its claim, and return the
# claim verdict so the caller can explain a skipped workspace.
def prepare [cwd: string, session_id: string, path: path] {
    let root_result = (^jj --repository $cwd root | complete)
    if $root_result.exit_code != 0 { return null }
    let root = ($root_result.stdout | str trim)
    let owner_path = ($root | path join ".jj" "codex-session.json")
    let owner = if ($owner_path | path exists) { open $owner_path } else { null }
    let has_state = ($path | path exists)
    let base_facts = {
        owner: (owner-status $owner)
        same_session: ($owner != null and ($owner.session_id? | default "") == $session_id)
        claim: ($root | path join ".jj" "codex-session-claim" | path exists)
        has_state: $has_state
    }
    # Listing workspaces costs a JJ call, and the guard runs on every tool
    # call; a resuming session never needs it.
    let facts = if $has_state { $base_facts | merge { workspace: "" dedicated: false } } else { $base_facts | merge (workspace-facts $root) }
    let verdict = (claim-verdict $facts)
    if $verdict.action == "refuse" {
        let detail = if $owner != null and $facts.owner == "active" { $" Owner: task ($owner.session_id? | default 'unknown'), change ($owner.change_id? | default 'unknown')." } else { "" }
        error make { msg: $"($verdict.reason)($detail)" }
    }
    if $verdict.action == "skip" { return $verdict }
    if $has_state {
        let previous = (open $path)
        if $previous.cwd != $root {
            error make { msg: "This task moved to another workspace. Resolve the recorded session mapping before editing." }
        }
        if not ($owner_path | path exists) {
            if (checked $root -- log -r @ --no-graph -T change_id) != $previous.change_id {
                error make { msg: "The existing task's change is not checked out. Restore its workspace before migrating session ownership." }
            }
            let claim = ($root | path join ".jj" "codex-session-claim")
            let claimed = (^mkdir $claim | complete)
            if $claimed.exit_code != 0 {
                error make { msg: "Workspace already claimed; inspect its session ownership before continuing." }
            }
            $previous | upsert session_id $session_id | upsert state "active" | upsert finished false | to json | save --force $owner_path
        }
        return $verdict
    }

    # A permanent claim prevents simultaneous startups from both changing @.
    # Finish removes it only after verified delivery. A failed creation removes it.
    let claim = ($root | path join ".jj" "codex-session-claim")
    let claimed = (^mkdir $claim | complete)
    if $claimed.exit_code != 0 {
        error make { msg: "This workspace already has a session claim. Inspect .jj/codex-session.json before recovering it; never steal another task's working copy." }
    }
    try {
        let marker = ($root | path join ".jj" "jj-ci-workspace.json")
        let change_id = if ($marker | path exists) {
            # ci start created the topic change; claim that exact change.
            let expected = (open $marker).change_id
            let actual = (checked $root -- log -r @ --no-graph -T change_id)
            if $actual != $expected {
                error make { msg: $"ci start recorded change ($expected), but this workspace is on ($actual). Restore its topic before starting Codex." }
            }
            $actual
        } else {
            # Other JJ workspaces still start a fresh task from trunk.
            checked $root -- new (trunk-revset $root) -m "Codex session" | ignore
            checked $root -- log -r @ --no-graph -T change_id
        }
        let state = { cwd: $root, session_id: $session_id, change_id: $change_id, described: false, state: "active", finished: false }
        mkdir ($path | path dirname)
        $state | to json | save --force $owner_path
        $state | to json | save --force $path
    } catch {|err|
        rm --recursive $claim
        error make { msg: $err.msg }
    }
    $verdict
}

def main [event: string] {
    if ($env.CODEX_JJ_SESSION_HOOK? | default "") == "1" { return }
    let hook = (open --raw /dev/stdin | from json)
    let cwd = $hook.cwd? | default ""
    let session_id = $hook.session_id? | default ""
    if ($cwd | is-empty) or ($session_id | is-empty) { return }
    let path = (state-path $session_id)

    let root_result = (^jj --repository $cwd root | complete)
    if $root_result.exit_code != 0 {
        # Outside any repository (for example the home directory) there is no
        # topic to own, so leave the session unguarded.
        if (git-backend-root $cwd) == null { return }
        if $event != "session-start" {
            if $event == "guard" or $event == "first-prompt" {
                block "This checkout is not a JJ workspace. Restart the Codex session so its startup hook can initialize the Git worktree, or start work in a JJ workspace."
            }
            return
        }
    }

    try {
        if $root_result.exit_code != 0 and not (initialize-git-worktree $cwd) {
            let warning = (git-worktree-warning $cwd)
            if $warning != null {
                add-context "SessionStart" $warning
            }
            return
        }
        let verdict = (prepare $cwd $session_id $path)
        let mutating = (($hook.tool_name? | default "") =~ $MUTATING_TOOLS)
        if $verdict != null and $verdict.action == "skip" {
            # An unclaimed canonical checkout may be read, never edited.
            if $event == "guard" and $mutating {
                block $verdict.reason
            } else if $event == "session-start" {
                add-context "SessionStart" $verdict.reason
            }
            return
        }
        if not ($path | path exists) { return }
        let state = (open $path)
        let owner_path = ($state.cwd | path join ".jj" "codex-session.json")
        let status = (owner-status (if ($owner_path | path exists) { open $owner_path } else { null }))
        if $status in ["delivered" "discarded" "released"] {
            let ending = match $status {
                "delivered" => "This JJ topic was delivered."
                "discarded" => "This JJ topic was finished or abandoned without delivery."
                _ => "This task's claim on the workspace was released; its topic may continue in another workspace."
            }
            # An ended task may still archive itself, but makes no new edits here.
            if $event == "guard" and $mutating {
                block $"($ending) Archive this task and start a new task for further work."
            } else {
                add-context ($hook.hook_event_name? | default "UserPromptSubmit") $"($ending) Archive this task; use a new task for further code edits."
            }
            return
        }
        let actual = (checked $state.cwd -- log -r @ --no-graph -T change_id)
        if $actual != $state.change_id {
            block $"Task owns change ($state.change_id), but this workspace is on ($actual). Restore the correct dedicated workspace before continuing; do not edit another task's change."
            return
        }
        if $event == "first-prompt" and not ($state.described? | default false) {
            let described = (with-env { CODEX_JJ_SESSION_HOOK: "1" } {
                cd $state.cwd
                ^jj-describe $state.change_id --prompt ($hook.prompt? | default "") | complete
            })
            if $described.exit_code != 0 {
                block $"Could not name this JJ change: ($described.stderr | str trim)"
                return
            }
            $state | upsert described true | to json | save --force $path
        }
        if $event == "session-start" {
            add-context "SessionStart" $"This task owns JJ change ($state.change_id) in ($state.cwd). Keep one topic and rewrite this change throughout the task. Publish in place. Finish and verify delivery before archiving."
        }
    } catch {|err|
        block $err.msg
    }
}
