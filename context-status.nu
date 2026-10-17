# One view of a JJ workspace's topic for the prompt, the shell, and agents.
#
#   context-status            full readout
#   context-status prompt     one line for the Starship prompt
#   context-status brief      a few lines, printed when a shell enters a workspace
#   context-status handoff    Markdown for the next agent; --hook wraps it as
#                             Claude Code or Codex SessionStart hook output
#   context-status guard      Claude Code PreToolUse hook: claim a free workspace
#                             on a session's first edit, and refuse edits to
#                             a workspace another session or topic holds
#   context-status json       the collected record
#   context-status refresh    update the cached pipeline state now
#
# Local facts are read on every call: the change graph against trunk, the task
# owner, and `ci`'s publication and validation records. Pipeline and pull
# request state comes from `ci ci-state`, cached in .jj/context-status.json
# and refreshed in the background, so the prompt never waits on the network.

const TRUNK = 'coalesce(remote_bookmarks(exact:"main", exact:"tangled"), trunk())'
const TRUNK_REMOTE = "tangled"
const CACHE_FILE = "context-status.json"
const LOCK_FILE = "context-status.lock"
# A pipeline still running is rechecked often; a settled verdict rarely.
const PENDING_TTL = 1min
const SETTLED_TTL = 15min
const LOCK_TTL = 2min
# The ownership record and the claim directory that marks it active. Codex
# sessions wrote them first, hence the name; Claude Code sessions use them too.
const OWNER_FILE = "codex-session.json"
const CLAIM_DIR = "codex-session-claim"
# A topic `ci adopt` hands to the next session that edits the workspace.
const ADOPT_FILE = "jj-ci-adopt.json"
# Serializes claims, so two sessions' first edits cannot both take a workspace.
const CLAIM_LOCK = "agent-claim.lock"
const CLAIM_LOCK_TTL = 1min
# How long an owning session may stay quiet before another may take over. An
# owned change that is still empty holds no work, so a short pause frees it;
# one with work waits as long as `ci prune` does for an ended task.
const IDLE_TAKEOVER = 10min
const BUSY_TAKEOVER = 2day

# Each revision as one JSON line. Trunk commits the topic lacks only count.
const REVISION_TEMPLATE = '
if(self.contained_in("::@"),
  "{\"above\":true"
    ++ ",\"wc\":" ++ json(self.current_working_copy())
    ++ ",\"change_id\":" ++ "\"" ++ change_id ++ "\""
    ++ ",\"short\":" ++ json(change_id.short(8))
    ++ ",\"commit_id\":" ++ "\"" ++ commit_id ++ "\""
    ++ ",\"empty\":" ++ json(empty)
    ++ ",\"conflict\":" ++ json(conflict)
    ++ ",\"described\":" ++ json(description != "")
    ++ ",\"title\":" ++ json(description.first_line())
    ++ ",\"files\":[" ++ self.diff().files().map(|f| "[" ++ json(f.status()) ++ "," ++ json(f.path().display()) ++ "]").join(",") ++ "]"
    ++ "}\n",
  "{\"above\":false}\n")
'

# Each change's declared impact class, from the latest `ci.impact.set` record
# in the ci log, as { CHANGE_ID: class }. Only lines naming the event are
# decoded, since this runs at every prompt. Keep in step with read-ci-log and
# impact-declarations in ci.nu.
def impact-declarations [] {
    let path = if ($env.CI_LOG? | is-not-empty) { $env.CI_LOG } else {
        $env.XDG_STATE_HOME? | default ($env.HOME | path join ".local" "state") | path join "ci" "log.otlp.jsonl"
    }
    if not ($path | path exists) { return {} }
    open --raw $path
    | lines
    | where {|line| $line | str contains '"eventName":"ci.impact.set"' }
    | each {|line| try { $line | from json } catch { null } }
    | each {|request| $request.resourceLogs | get scopeLogs | flatten | get logRecords | flatten }
    | flatten
    | reduce --fold {} {|record, declarations|
        let attributes = ($record.attributes? | default [] | reduce --fold {} {|attribute, all| $all | upsert $attribute.key ($attribute.value | values | first) })
        let change = ($attributes."ci.change_id"? | default "")
        if ($change | is-empty) { $declarations } else { $declarations | upsert $change ($attributes."ci.impact"? | default "") }
    }
}

# The state a Codex ownership record declares: none, active, delivered,
# discarded, or released. A record from before `state` has only `finished`,
# which proves release but never delivery. Keep in step with owner-status in
# ci.nu.
def owner-status [owner: any] {
    if $owner == null { return "none" }
    let state = ($owner.state? | default "")
    if $state in ["active" "delivered" "discarded" "released"] { return $state }
    if ($owner.finished? | default false) { "released" } else { "active" }
}

# The nearest directory at or above `dir` that holds a JJ workspace.
def workspace-root [dir: path] {
    mut current = ($dir | path expand)
    loop {
        if ($current | path join ".jj" | path type) == "dir" { return $current }
        let parent = ($current | path dirname)
        if $parent == $current { return null }
        $current = $parent
    }
}

def require-root [dir?: path] {
    let root = (workspace-root ($dir | default $env.PWD))
    if $root == null { error make { msg: "Not inside a JJ workspace." } }
    $root
}

# The linked Git worktree that holds `dir` inside the JJ workspace `root`, or
# null. Claude Code's desktop app gives each session such a worktree under
# .claude/worktrees. It has no .jj of its own, so JJ resolves it to `root`
# and never records the files edited there. Keep in step with
# enclosing-git-worktree in ci.nu.
def enclosing-git-worktree [dir: path, root: path] {
    mut current = ($dir | path expand)
    while ($current | str starts-with $"($root)/") {
        if ($current | path join ".git" | path type) == "file" { return $current }
        $current = ($current | path dirname)
    }
    null
}

# Whether `root` is the canonical default checkout, and whether the repository
# also has topic workspaces. Reads the workspace list without snapshotting:
# the guard and the handoff must never record another session's edits.
def workspace-layout [root: path] {
    let listing = (^jj --ignore-working-copy --repository $root workspace list -T 'name ++ "\t" ++ root ++ "\n"' | complete)
    if $listing.exit_code != 0 { return { default: false dedicated: false } }
    let workspaces = ($listing.stdout | lines | where {|line| $line | is-not-empty } | parse "{name}\t{root}")
    {
        default: ($workspaces | any {|workspace| $workspace.name == "default" and $workspace.root == $root })
        dedicated: (($workspaces | length) > 1)
    }
}

# The JJ workspaces a session made inside its Git worktree, as `ci start`
# places them there.
def worktree-workspaces [worktree: path] {
    let parent = ($worktree | path join ".jj-workspaces")
    if ($parent | path type) != "dir" { return [] }
    ls $parent | where type == dir | get name | where {|dir| ($dir | path join ".jj" | path type) == "dir" }
}

# Whether an agent may edit a file, from facts the guard reads:
#   workspace     whether the file is inside a JJ workspace at all
#   worktree      whether it sits in a Git worktree with no JJ workspace of its own
#   dedicated     whether the repository has topic workspaces besides it
#   ignored       whether Git ignores the file there
#   owner         owner-status of the workspace's ownership record
#   same_session  whether that record belongs to this session
#   idle          how long the owning session has been quiet, or null if unknown
#   free          whether the workspace is idle on trunk: nothing above trunk
#                 but an empty change, so no one's work is checked out
#   adoptable     whether its topic was handed to the next session, by
#                 `ci start` dedicating the workspace to it or by `ci adopt`
# Only a repository that uses topic workspaces is guarded. In it, a session
# works only where it owns the change: its first edit claims a free workspace,
# the default checkout included, and never another session's or a topic
# nobody handed over. `allow` lets the edit through; `claim` records this
# session as the owner first; `deny` names why not.
def edit-verdict [facts: record] {
    if not $facts.workspace or not $facts.dedicated { return { action: "allow" reason: null } }
    if $facts.worktree { return { action: "deny" reason: "worktree" } }
    # An ignored file reaches no change, so whoever holds the workspace loses nothing.
    if $facts.ignored { return { action: "allow" reason: null } }
    if $facts.owner == "active" {
        if $facts.same_session { return { action: "allow" reason: null } }
        # A stale record must not hold a workspace forever.
        let limit = if $facts.free { $IDLE_TAKEOVER } else { $BUSY_TAKEOVER }
        if $facts.idle == null or $facts.idle < $limit { return { action: "deny" reason: "owned" } }
        return { action: "claim" reason: null }
    }
    if $facts.free or $facts.adoptable { return { action: "claim" reason: null } }
    { action: "deny" reason: "occupied" }
}

# How long the session behind an ownership record has been quiet, from the
# transcript it writes as it runs: a Claude Code session records its
# transcript's path, and a Codex task is found by its rollout file. Null when
# neither can be found. Keep in step with owner-liveness in ci.nu.
def owner-idle [record: any] {
    if $record == null { return null }
    let transcript = ($record.transcript_path? | default "")
    let session = ($record.session_id? | default "")
    let codex = ($env.CODEX_HOME? | default ($env.HOME | path join ".codex"))
    let files = if ($transcript | is-not-empty) and ($transcript | path exists) {
        [$transcript]
    } else if $session =~ '^[a-zA-Z0-9_-]+$' {
        # An archived Codex task has ended, however recently it wrote.
        if (glob $"($codex)/archived_sessions/**/*($session).jsonl" | is-not-empty) { return 1000wk }
        glob $"($codex)/sessions/**/*($session).jsonl"
    } else { [] }
    if ($files | is-empty) { return null }
    (date now) - ($files | each {|file| ls --long $file | first | get modified } | math max)
}

# Whether a workspace's collected facts show it idle on trunk, and whether its
# checked-out topic was handed to the next session.
def occupancy [root: path, facts: record] {
    let jj_dir = ($root | path join ".jj")
    let held = ($facts.checked_out | append ($facts.stack | get change_id))
    let handed = ([(read-json ($jj_dir | path join "jj-ci-workspace.json")) (read-json ($jj_dir | path join $ADOPT_FILE))]
        | compact | any {|record| $record.change_id? in $held })
    {
        free: ($facts.stranded == null and ($facts.conflicts | is-empty) and ($facts.stack | length) <= 1 and ($facts.stack | all {|rev| $rev.empty }))
        adoptable: $handed
    }
}

# The workspaces besides `root` that a session could claim now: idle on
# trunk, or parked on landed work, with no active owner. Reads without
# snapshotting, so edits not yet recorded can hide from it.
def list-workspace-roots [root: path] {
    let listing = (^jj --ignore-working-copy --repository $root workspace list -T 'name ++ "\t" ++ root ++ "\n"' | complete)
    if $listing.exit_code != 0 { return [] }
    $listing.stdout | lines | where {|line| $line | is-not-empty } | parse "{name}\t{root}"
}

def free-workspaces [root: path] {
    let revset = $"working_copies\() & \(\(empty\() & ~conflicts\() & children\(::($TRUNK))) | ::($TRUNK))"
    let idle = (^jj --ignore-working-copy --repository $root log --no-graph -r $revset -T 'working_copies ++ "\n"' | complete)
    if $idle.exit_code != 0 { return [] }
    let names = ($idle.stdout | split row --regex '\s+' | where {|name| $name | is-not-empty } | str replace --regex '@$' '')
    list-workspace-roots $root
    | where {|workspace| $workspace.name in $names and $workspace.root != $root }
    | where {|workspace| (owner-status (read-json ($workspace.root | path join ".jj" $OWNER_FILE))) != "active" }
}

def free-workspace-hint [root: path, relative?: string] {
    let free = (free-workspaces $root)
    # `ci start` puts new workspaces beside the default checkout.
    let parent = (list-workspace-roots $root | where name == "default" | get --optional 0.root | default $root)
    let start = if $relative == null { "`ci start NAME`" } else { $"`ci start NAME` and edit ($parent)/.jj-workspaces/NAME/($relative)" }
    if ($free | is-empty) {
        $"No other workspace is free; create one with ($start)."
    } else {
        $"Free workspaces: ($free | each {|workspace| $'($workspace.name) at ($workspace.root)' } | str join ', '). Use one of them, or create another with ($start)."
    }
}

# Record `session` as the owner of `change` in `root`, if the ownership record
# still reads as `seen` when the claim lock is held: a session that claimed
# in between keeps the workspace. Returns whether this session now owns it.
def claim-workspace [root: path, seen: any, claim: record] {
    let jj_dir = ($root | path join ".jj")
    let lock = ($jj_dir | path join $CLAIM_LOCK)
    # A lock this old belongs to a claim that crashed.
    if ($lock | path exists) and ((date now) - (ls --long $lock | first | get modified)) > $CLAIM_LOCK_TTL {
        rm --recursive --force $lock
    }
    if (^mkdir $lock | complete).exit_code != 0 { return false }
    let claimed = try {
        let owner_path = ($jj_dir | path join $OWNER_FILE)
        if (read-json $owner_path) != $seen { false } else {
            {
                cwd: $root
                session_id: $claim.session_id
                change_id: $claim.change_id
                agent: "claude-code"
                transcript_path: $claim.transcript_path
                claimed_at: (date now | format date "%+")
                described: true
                state: "active"
                finished: false
            } | to json | save --force $owner_path
            mkdir ($jj_dir | path join $CLAIM_DIR)
            rm --force ($jj_dir | path join $ADOPT_FILE)
            true
        }
    } catch { false }
    rm --recursive --force $lock
    $claimed
}

def read-json [path: path] {
    if not ($path | path exists) { return null }
    try { open --raw $path | from json } catch { null }
}

# Run from the root: JJ prints paths relative to the working directory.
def jj-lines [root: path, args: list<string>] {
    let result = (do { cd $root; ^jj ...$args | complete })
    if $result.exit_code != 0 { error make { msg: ($result.stderr | str trim) } }
    $result.stdout | lines | where {|line| $line | is-not-empty }
}

def remote-head [root: path, branch: string] {
    let revset = $"remote_bookmarks\(exact:'($branch)', exact:'($TRUNK_REMOTE)')"
    let result = (^jj --repository $root log --no-graph -r $revset -T 'commit_id' | complete)
    let commit = ($result.stdout | str trim)
    if $result.exit_code != 0 or ($commit | is-empty) { null } else { $commit }
}

def ago [when: any] {
    if $when == null { return "never" }
    let elapsed = ((date now) - ($when | into datetime))
    if $elapsed < 1min { "just now" } else if $elapsed < 1hr {
        $"($elapsed // 1min)min ago"
    } else if $elapsed < 1day {
        $"($elapsed // 1hr)h ago"
    } else {
        $"($elapsed // 1day)d ago"
    }
}

def ttl [ci: record] {
    # The spindle runs only when started by hand, so a head with no pipeline
    # is not waiting for one.
    if ($ci.spindle?.state? | default "") in ["success" "failed" "timeout" "missing"] { $SETTLED_TTL } else { $PENDING_TTL }
}

# Where the topic stands in the `ci` lifecycle, its next step, and the
# protocol steps allowed from there, from the statig state machine in
# lifecycle/ that implements JjCi.qnt.
def classify [facts: record] {
    {
        owner: $facts.owner
        stranded: $facts.stranded
        landed: ($facts.ci?.landed? == true)
        idle: ($facts.stack | is-empty)
        head: $facts.head.commit_id
        described: $facts.head.described
        behind: $facts.behind
        published_head: $facts.published_head
        spindle: ($facts.ci?.spindle?.state? | default null)
        lint_passed: ($facts.lint == "passed")
        conflicts: $facts.conflicts
    } | to json | ^jj-ci-lifecycle classify | from json
}

# Whether the working copy has wandered off the topic that `ci start`
# recorded. Keep in step with topic-stranded in ci.nu, which refuses `ci`
# commands in this state.
def topic-stranded [facts: record] {
    $facts.recorded and $facts.visible and not $facts.landed and not $facts.ancestor and $facts.working_copy_empty and not $facts.topic_empty
}

# The recorded topic this workspace has left, as { short title stray } with
# stray the working copy that left it, or null. A topic in the stack below the
# working copy needs no JJ call to rule out.
def stranded-topic [root: path, stack_ids: list, wc: record] {
    let marker = (read-json ($root | path join ".jj" "jj-ci-workspace.json"))
    let topic = ($marker.change_id? | default null)
    if $topic == null or $topic in $stack_ids or not $wc.empty { return null }
    # The trunk revset sits inside a template string, so its quotes are escaped.
    let trunk = ($TRUNK | str replace --all '"' '\"')
    let template = ('"{\"landed\":" ++ json(self.contained_in("::' + $trunk + '")) ++ ",\"ancestor\":" ++ json(self.contained_in("::@")) ++ ",\"empty\":" ++ json(empty && description == "") ++ ",\"short\":" ++ json(change_id.short(8)) ++ ",\"title\":" ++ json(description.first_line()) ++ "}\n"')
    let found = (try { jj-lines $root [log --no-graph -r $"change_id\(($topic))" -T $template] } catch { [] })
    let topic_facts = ($found | get --optional 0 | if $in == null { null } else { $in | from json })
    let stranded = (topic-stranded {
        recorded: true
        visible: ($topic_facts != null)
        landed: ($topic_facts.landed? | default false)
        ancestor: ($topic_facts.ancestor? | default false)
        working_copy_empty: $wc.empty
        topic_empty: ($topic_facts.empty? | default false)
    })
    if $stranded { $topic_facts | select short title | insert stray $wc.short } else { null }
}

# Every local fact, plus the cached pipeline state for the published head.
def collect [root: path] {
    let revset = ('@ | (' + $TRUNK + '..@) | (@..' + $TRUNK + ')')
    let declarations = (impact-declarations)
    let revisions = (jj-lines $root [log --no-graph -r $revset -T $REVISION_TEMPLATE] | each {|line| $line | from json }
        | each {|rev| if $rev.above and ($rev.title | is-empty) { $rev | update title "(no description)" } else { $rev } }
        | each {|rev|
            if not $rev.above { return $rev }
            let impact = ($declarations | get --optional $rev.change_id)
            $rev | insert impact (if ($impact | is-empty) { [] } else { [$impact] })
        })
    let above = ($revisions | where above)
    let wc = ($above | where wc | first)
    # An empty, undescribed working copy is scratch space; the topic is below.
    let scratch = ($wc.empty and not $wc.described)
    let stack = ($above | where {|rev| not ($rev.wc and $scratch) } | reverse)
    let head = if ($stack | is-empty) { $wc } else { $stack | last }

    let jj_dir = ($root | path join ".jj")
    # A task owns the change it recorded; a record naming another change is
    # left over from an earlier task in this workspace.
    let owner_record = (read-json ($jj_dir | path join "codex-session.json"))
    let owned = $owner_record != null and ($owner_record.change_id? in [$wc.change_id $head.change_id])
    let owner = if $owned { owner-status $owner_record } else { "none" }
    let topics = ((read-json ($jj_dir | path join "jj-ci-publication.json")) | default {} | get --optional topics | default {})
    let branch = ($topics | get --optional $head.change_id)
    let published_head = if $branch == null { null } else { remote-head $root $branch }
    let validation = (read-json ($jj_dir | path join "jj-ci-validation.json"))
    let lint = if $validation == null { "never" } else if $validation.commit_id == $head.commit_id { "passed" } else { "stale" }
    let cache = (read-json ($jj_dir | path join $CACHE_FILE))
    let ci = if $cache != null and $published_head != null and $cache.state?.published_head? == $published_head { $cache.state } else { null }
    let stranded = (stranded-topic $root ($stack | get change_id) $wc)

    let facts = {
        root: $root
        workspace: ($root | path basename)
        owner: $owner
        owner_change: (if $owned { $owner_record.change_id } else { null })
        checked_out: ([$wc.change_id $head.change_id] | uniq)
        head: $head
        stack: $stack
        behind: ($revisions | where not above | length)
        conflicts: ($stack | where conflict | get short)
        working_copy: (if $scratch { [] } else { $wc.files })
        branch: $branch
        published_head: $published_head
        lint: $lint
        validated_at: ($validation.validated_at? | default null)
        ci: $ci
        ci_checked_at: (if $ci == null { null } else { $cache.checked_at })
        refresh_due: ($published_head != null and ($ci == null or ((date now) - ($cache.checked_at | into datetime)) > (ttl $ci)))
        stranded: $stranded
    }
    $facts | merge (classify $facts)
}

# Whether JJ refused to read a workspace because another one rewrote the
# change checked out there. Keep in step with stale-working-copy in
# jj/ci-launch.nu.
def stale-working-copy [message: string] {
    $message | str contains "working copy is stale"
}

# Collect a workspace's facts, first updating it if another workspace left it
# stale: as { facts healed }, or null when it cannot be read. Only a session
# starting there does this; update-stale never overwrites a file edited since
# JJ last snapshotted it.
def collect-healing [root: path] {
    let first = (try { { facts: (collect $root) error: null } } catch {|err| { facts: null error: $err.msg } })
    if $first.error == null { return { facts: $first.facts healed: false } }
    if not (stale-working-copy $first.error) { return null }
    let updated = (^jj --repository $root workspace update-stale | complete)
    if $updated.exit_code != 0 { return null }
    try { { facts: (collect $root) healed: true } } catch { null }
}

def locked [root: path] {
    let lock = ($root | path join ".jj" $LOCK_FILE)
    ($lock | path exists) and ((date now) - (ls --long $lock | first | get modified)) < $LOCK_TTL
}

def refresh-now [root: path] {
    let lock = ($root | path join ".jj" $LOCK_FILE)
    touch $lock
    let result = (do { cd $root; ^ci ci-state } | complete)
    if $result.exit_code == 0 {
        let state = (try { $result.stdout | from json } catch { null })
        if $state != null {
            { checked_at: (date now | format date "%+") state: $state } | to json | save --force ($root | path join ".jj" $CACHE_FILE)
        }
    }
    rm --force $lock
}

# Refresh the pipeline cache in a detached process so the caller returns now.
def refresh-in-background [facts: record] {
    if not $facts.refresh_due or (locked $facts.root) { return }
    touch ($facts.root | path join ".jj" $LOCK_FILE)
    try {
        ^setsid --fork $nu.current-exe --no-config-file $env.CURRENT_FILE refresh $facts.root o+e> /dev/null
    } catch { }
}

def ci-glyph [state: any] {
    match $state {
        "success" => $"(ansi green)✔(ansi reset)"
        "failed" => $"(ansi red)✗(ansi reset)"
        "timeout" => $"(ansi dark_gray)⌛(ansi reset)"
        "running" | "in_progress" | "queued" => $"(ansi yellow)⧗(ansi reset)"
        "missing" => $"(ansi yellow)…(ansi reset)"
        _ => $"(ansi dark_gray)?(ansi reset)"
    }
}

def stage-label [stage: string] {
    match $stage {
        "editing" => $"(ansi blue)✎ editing(ansi reset)"
        "validated" => $"(ansi cyan)✓ validated(ansi reset)"
        "republish" => $"(ansi yellow)↻ edited since publish(ansi reset)"
        "stranded" => $"(ansi red)⚠ off topic(ansi reset)"
        "published" => $"(ansi purple)↑ published(ansi reset)"
        "passed" => $"(ansi green)✔ passed(ansi reset)"
        "failed" => $"(ansi red)✗ pipeline failed(ansi reset)"
        "landed" => $"(ansi green)⚑ landed(ansi reset)"
        "finished" => $"(ansi dark_gray)⚑ finished(ansi reset)"
        _ => $"(ansi dark_gray)· idle(ansi reset)"
    }
}

def ci-summary [facts: record] {
    if $facts.published_head == null { return "not published" }
    if $facts.ci == null { return $"published ($facts.published_head | str substring 0..7), pipeline not checked yet" }
    let parts = [
        (match ($facts.ci.spindle?.state? | default "unknown") {
            "missing" => null
            "timeout" => "spindle timed out (not the landing gate)"
            $state => $"spindle ($state)"
        })
        (if $facts.ci.github? != null { $"GitHub ($facts.ci.github.state)" })
        (if $facts.ci.pull? != null { $"PR \"($facts.ci.pull)\"" })
    ] | compact
    let summary = if ($parts | is-empty) { "published" } else { $parts | str join ", " }
    $"($summary) on ($facts.published_head | str substring 0..7) \(checked (ago $facts.ci_checked_at))"
}

def lint-summary [facts: record] {
    match $facts.lint {
        "passed" => $"Prek passed on this head \((ago $facts.validated_at))"
        "stale" => "not validated since the last edit"
        _ => "never validated in this workspace"
    }
}

def topic-title [facts: record] {
    let title = if $facts.head.described { $"\"($facts.head.title)\"" } else { "(no description)" }
    let impact = ($facts.stack | each {|rev| $rev.impact } | flatten | uniq)
    let impact_label = if ($impact | is-empty) { "no impact declared" } else { $impact | str join "+" }
    $"($facts.head.short) ($title) · ($impact_label)"
}

def "main prompt" [] {
    let root = (workspace-root $env.PWD)
    if $root == null { return }
    # A stale checkout's files are not its change's: say so before anyone
    # builds from them. The prompt never rewrites files itself.
    let collected = (try { { facts: (collect $root) error: null } } catch {|err| { facts: null error: $err.msg } })
    if $collected.error != null {
        if (stale-working-copy $collected.error) { print --no-newline $"(ansi red)⚠ stale(ansi reset)" }
        return
    }
    let facts = $collected.facts
    refresh-in-background $facts
    let parts = [
        (if ($facts.conflicts | is-not-empty) { $"(ansi red)⚠ conflict(ansi reset)" })
        (if $facts.stage != "idle" { stage-label $facts.stage })
        (if $facts.stage in ["published" "passed" "failed" "republish"] and $facts.ci != null { ci-glyph $facts.ci.spindle?.state? })
        (if $facts.behind > 0 and $facts.stage != "idle" { $"(ansi dark_gray)↓($facts.behind)(ansi reset)" })
        (if $facts.owner == "active" { $"(ansi dark_gray)◆(ansi reset)" })
    ] | compact
    print --no-newline ($parts | str join " ")
}

def "main brief" [dir?: path] {
    let facts = (collect (require-root $dir))
    refresh-in-background $facts
    print-brief $facts
}

def print-brief [facts: record] {
    let conflicts = if ($facts.conflicts | is-empty) { "no conflicts" } else { $"(ansi red)conflicts in ($facts.conflicts | str join ', ')(ansi reset)" }
    print $"(ansi attr_bold)($facts.workspace)(ansi reset)  (topic-title $facts)"
    print $"  (stage-label $facts.stage) · next: ($facts.next)"
    print $"  ($facts.stack | length) above trunk, ($facts.behind) behind · ($conflicts) · lint: (lint-summary $facts)"
    if $facts.published_head != null { print $"  ci: (ci-summary $facts)" }
}

def "main json" [dir?: path] {
    collect (require-root $dir) | to json
}

def "main refresh" [dir?: path] {
    refresh-now (require-root $dir)
}

# edit-verdict for a tracked file in `root`, for `session`, from facts already
# collected there, with the free workspaces to suggest when it would deny.
def session-access [root: path, facts: record, session: string] {
    let record = (read-json ($root | path join ".jj" $OWNER_FILE))
    let access = ({
        workspace: true worktree: false dedicated: true ignored: false
        owner: (owner-status $record)
        same_session: ($session != "" and ($record.session_id? | default "") == $session)
        idle: (owner-idle $record)
    } | merge (occupancy $root $facts))
    let verdict = (edit-verdict $access)
    { facts: $access verdict: $verdict hint: (if $verdict.action == "deny" { free-workspace-hint $root } else { "" }) }
}

# What a session starting in the workspace may do there, as edit-verdict
# decides it for the session's first edit.
def access-text [access: record] {
    let verdict = $access.verdict
    match [$verdict.action $verdict.reason] {
        ["allow" _] => (if $access.facts.same_session { "- Access: this session owns this workspace's change." })
        ["claim" _] => (if $access.facts.owner == "active" {
            $"- Access: the session that owns this workspace has been quiet for ($access.facts.idle | format duration hr | str replace --regex '\.\d+' ''); your first edit takes it over for this session."
        } else if $access.facts.free {
            "- Access: this workspace is idle on trunk, so it is free. Your first edit claims it for this session. Name the topic with `ci new -m MESSAGE`, which describes the empty change in place."
        } else {
            "- Access: this workspace's topic was handed to the next session; your first edit claims it and continues the topic."
        })
        ["deny" "owned"] => $"- Access: another agent session owns this workspace, so edits here are refused. ($access.hint)"
        ["deny" _] => $"- Access: this workspace holds a topic no session owns, so edits here are refused. Continue it only if the user asks, after `ci adopt` there hands it over. ($access.hint)"
    }
}

def handoff-text [facts: record] {
    let owner = match $facts.owner {
        "active" => $"owned by an active agent session on change ($facts.owner_change)"
        "delivered" => "its last session delivered the topic"
        "discarded" => "its last session ended without delivering"
        "released" => "its last session released the workspace; the topic may continue elsewhere"
        _ => "no session owner recorded"
    }
    let stack = ($facts.stack | each {|rev|
        let flags = ([(if $rev.conflict { "conflicted" }) (if not $rev.described { "undescribed" })] | compact)
        let suffix = if ($flags | is-empty) { "" } else { $" [($flags | str join ', ')]" }
        $"  - ($rev.short) ($rev.title)($suffix)"
    })
    let files = ($facts.working_copy | each {|file| $"($file.0) ($file.1)" })
    [
        $"JJ workspace context \(context-status, (date now | format date '%Y-%m-%d %H:%M %Z')):"
        $"- Workspace: ($facts.root), ($owner)."
        (if ($facts.healed? | default false) {
            "- Updated this workspace's files first: another workspace had rewritten its checked-out change, which left it stale."
        })
        (if ($facts.access? | default null) != null { access-text $facts.access })
        $"- Topic: (topic-title $facts | ansi strip)."
        $"- Stage: ($facts.stage). Next: ($facts.next)."
        (if ($stack | is-not-empty) { (["- Changes above trunk, oldest first:"] | append $stack | str join "\n") })
        $"- Trunk: ($facts.behind) trunk commits are not in this topic. Conflicts: (if ($facts.conflicts | is-empty) { 'none' } else { $facts.conflicts | str join ', ' })."
        (if ($files | is-not-empty) { $"- Working copy: ($files | length) files changed: ($files | str join ', ')." })
        $"- Lint: (lint-summary $facts)."
        $"- CI: (ci-summary $facts)."
    ] | compact | str join "\n"
}

# The handoff for a session whose directory is a Git worktree inside `root`:
# what JJ sees there, and the workspaces the session already made in it.
def worktree-handoff-text [worktree: path, root: path] {
    let workspaces = (worktree-workspaces $worktree | each {|dir|
        let collected = (collect-healing $dir)
        if $collected == null {
            $"  - ($dir): unreadable; run `jj status` there to see why"
        } else {
            let facts = $collected.facts
            let healed = if $collected.healed { " (its files were stale and have been updated)" } else { "" }
            $"  - ($dir): (topic-title $facts | ansi strip), ($facts.stage); next: ($facts.next)($healed)"
        }
    })
    [
        $"JJ workspace context \(context-status, (date now | format date '%Y-%m-%d %H:%M %Z')):"
        $"- This session's directory, ($worktree), is a Git worktree, not a JJ workspace. `jj` and `ci` run here act on the shared checkout at ($root), and JJ never records files edited in the worktree itself, so agent edits there are refused."
        $"- Start a topic with `ci start NAME` from this directory: it creates ($worktree)/.jj-workspaces/NAME on main@tangled. Edit only inside that workspace, and run `jj` and `ci` there."
        (if ($workspaces | is-not-empty) { ["- JJ workspaces already in this worktree:"] | append $workspaces | str join "\n" })
    ] | compact | str join "\n"
}

def deny-edit [reason: string] {
    { hookSpecificOutput: {
        hookEventName: "PreToolUse"
        permissionDecision: "deny"
        permissionDecisionReason: $reason
    } } | to json --raw | print
}

# PreToolUse guard for agent edits. In a repository with topic workspaces, a
# session's first Edit, Write, or NotebookEdit in a free workspace claims it,
# and edits to a workspace another session owns, to a topic nobody handed
# over, or to a Git worktree with no JJ workspace of its own are refused. It
# reads the Claude Code hook event on stdin; silence lets the edit through.
# A workspace is snapshotted only when no live session owns it.
def "main guard" [] {
    let event = (try { open --raw /dev/stdin | from json } catch { return })
    let file = ($event.tool_input?.file_path? | default ($event.tool_input?.notebook_path? | default ""))
    if ($file | is-empty) { return }
    let file = ($file | path expand)
    let dir = ($file | path dirname)
    let root = (workspace-root $dir)
    if $root == null { return }
    let worktree = (enclosing-git-worktree $dir $root)
    let layout = (workspace-layout $root)
    let relative = ($file | path relative-to ($worktree | default $root))
    let session = ($event.session_id? | default "")
    let record = (read-json ($root | path join ".jj" $OWNER_FILE))
    let facts = {
        workspace: true
        worktree: ($worktree != null)
        dedicated: $layout.dedicated
        ignored: false
        owner: (owner-status $record)
        same_session: ($session != "" and ($record.session_id? | default "") == $session)
        idle: null
        free: false
        adoptable: false
    }
    # Decide from the cheapest facts first: most edits come from the owner.
    if (edit-verdict $facts).action == "allow" { return }
    let facts = ($facts | merge {
        ignored: ($worktree == null and (^git -C $root check-ignore --quiet -- $relative | complete).exit_code == 0)
        idle: (owner-idle $record)
    })
    let verdict = (edit-verdict $facts)
    if $verdict.action == "allow" { return }
    if $verdict.reason == "worktree" {
        let existing = (worktree-workspaces $worktree | path basename)
        let target = if ($existing | length) == 1 { $existing | first } else { "NAME" }
        let known = if ($existing | length) > 1 { $" Workspaces here: ($existing | str join ', ')." } else { "" }
        deny-edit $"($file) is in the Git worktree ($worktree), which is not a JJ workspace: JJ resolves it to the shared checkout at ($root) and would never record this edit. (if ($existing | is-empty) { $'Run `ci start NAME` in ($worktree) first, then edit' } else { 'Edit' }) ($worktree)/.jj-workspaces/($target)/($relative) instead.($known)"
        return
    }
    let owned_text = {||
        let quiet = if $facts.idle == null { "" } else { $", quiet for ($facts.idle | format duration min | str replace --regex '\.\d+' '')" }
        $"($root) belongs to another agent session \(($record.session_id? | default 'unknown'), change ($record.change_id? | default 'unknown' | str substring 0..7)($quiet)). (free-workspace-hint $root $relative)"
    }
    # Whether a quiet owner's change is still empty decides a takeover, and
    # that needs the workspace read; an owner active within the shorter limit
    # keeps it either way.
    if $verdict.reason == "owned" and ($facts.idle == null or $facts.idle < $IDLE_TAKEOVER) { deny-edit (do $owned_text); return }
    # Only a workspace no live session holds gets here, so reading it may
    # snapshot its files; that is what tells an idle checkout from one with
    # edits nobody has recorded yet.
    let collected = (collect-healing $root)
    if $collected == null {
        deny-edit $"($root) could not be read; run `jj status` there to see why. (free-workspace-hint $root $relative)"
        return
    }
    let facts = ($facts | merge (occupancy $root $collected.facts))
    let verdict = (edit-verdict $facts)
    match $verdict.action {
        "allow" => { return }
        "deny" if $verdict.reason == "owned" => { deny-edit (do $owned_text); return }
        "deny" => {
            let topic = (topic-title $collected.facts | ansi strip)
            deny-edit $"($root) holds the topic ($topic), and no session owns it, so this session may not add to it. Continue that topic only if the user asks: running `ci adopt` there hands it to the next session that edits it. (free-workspace-hint $root $relative)"
            return
        }
    }
    # Without a session ID no later edit could match the record.
    if ($session | is-empty) { return }
    let change = ($collected.facts.checked_out | first)
    if not (claim-workspace $root $record { session_id: $session change_id: $change transcript_path: ($event.transcript_path? | default null) }) {
        deny-edit $"Another session claimed ($root) a moment ago. (free-workspace-hint $root $relative)"
    }
}

# Markdown for the next agent. As a SessionStart hook it reads the hook event
# from stdin and never waits on the network; run directly it refreshes a stale
# pipeline verdict first.
def "main handoff" [
    dir?: path
    --hook # Read a Claude Code or Codex hook event on stdin and answer with additionalContext
] {
    if $hook {
        let event = (try { open --raw /dev/stdin | from json } catch { {} })
        let cwd = ($event.cwd? | default $env.PWD)
        let root = (workspace-root $cwd)
        if $root == null { return }
        let worktree = (enclosing-git-worktree $cwd $root)
        # A worktree resolves to the shared checkout; describing (and so
        # snapshotting) that checkout would hand this session another's topic.
        let text = if $worktree != null {
            try { worktree-handoff-text $worktree $root } catch { return }
        } else {
            let collected = (collect-healing $root)
            if $collected == null { return }
            let layout = (workspace-layout $root)
            let facts = ($collected.facts | insert healed $collected.healed)
            let facts = if $layout.dedicated { $facts | insert access (session-access $root $facts ($event.session_id? | default "")) } else { $facts }
            refresh-in-background $facts
            handoff-text $facts
        }
        { hookSpecificOutput: {
            hookEventName: ($event.hook_event_name? | default "SessionStart")
            additionalContext: $text
        } } | to json --raw | print
        return
    }
    let root = (require-root $dir)
    let facts = (collect $root)
    let facts = if $facts.refresh_due and not (locked $root) { refresh-now $root; collect $root } else { $facts }
    print (handoff-text $facts)
}

# Audit: every workspace of the repository checked against the ownership and
# publication invariants in JjCi.qnt. It reads state and reports; each
# finding names the command that repairs it.

const SEVERITIES = ["error" "warning" "info"]

# Findings for one workspace, from facts `audit-facts` gathers:
#   name, root, exists, error      the workspace and whether it could be read
#   owner, owner_change, legacy    the ownership record's status, change, and
#                                  whether it predates `state`
#   owner_checked_out              whether that change is checked out here
#   claim                          whether a claim directory exists
#   stack, published, behind       work above trunk, whether it has a branch
#   conflicts                      conflicted revisions in the stack
#   stale_entries                  publication entries for changes not here
#   stranded                       the working copy left its `ci start` topic
def audit-findings [facts: record] {
    let finding = {|severity, code, detail, fix| { workspace: $facts.name severity: $severity code: $code detail: $detail fix: $fix } }
    if not $facts.exists {
        return [(do $finding "error" "missing-workspace" $"($facts.root) no longer exists." "`ci prune --apply` forgets it")]
    }
    if $facts.error != null {
        return [(do $finding "error" "unreadable" $facts.error "`jj workspace update-stale` in the workspace, then audit again")]
    }
    let change = ($facts.owner_change | default "" | str substring 0..7)
    [
        # TLA: OwnerRecordMatchesSession, UnclaimOnlyOrphans.
        (if $facts.owner == "active" and not $facts.owner_checked_out {
            do $finding "error" "orphaned-claim" $"An active task owns change ($change), which is no longer checked out here; every new session is refused." "`ci unclaim` in the workspace"
        })
        # The topic guard in ci.nu: `ci` refuses to run until the working
        # copy returns (TLA: topic commands require `checkedOut`).
        (if $facts.stranded {
            do $finding "error" "stranded-topic" "The working copy left the topic `ci start` recorded; `ci` refuses to run here." "`jj edit` the topic, as `context-status` in the workspace names it"
        })
        # TLA: ClaimOnlyWhileActive.
        (if $facts.claim and $facts.owner != "active" {
            do $finding "error" "leftover-claim" "A session claim remains without an active task; new Codex sessions are refused." "`ci unclaim` in the workspace"
        })
        # TLA: DeliveredRecordIsTrue.
        (if $facts.legacy {
            do $finding "warning" "legacy-record" $"The ownership record for change ($change) predates `state`; it cannot say whether the topic was delivered." "check the topic's branch; `ci park` or `ci unclaim` rewrites the record"
        })
        (if ($facts.conflicts | is-not-empty) {
            do $finding "warning" "conflicts" $"Conflicted revisions: ($facts.conflicts | str join ', ')." "resolve oldest first; `ci conflicts` lists them"
        })
        (if $facts.stack > 0 and not $facts.published {
            let behind = if $facts.behind > 0 { $", based ($facts.behind) trunk commits back" } else { "" }
            do $finding "warning" "unpublished-work" $"The head of ($facts.stack) change\(s) above trunk is unpublished($behind); `ci status` does not list it." "`ci dispatch` it, or `ci cancel` it"
        })
        (if ($facts.stale_entries | is-not-empty) {
            do $finding "info" "stale-publication-entries" $"($facts.stale_entries | length) publication entries name changes not checked out here: ($facts.stale_entries | str join ', ')." "harmless; they are reused only if those changes return here"
        })
    ] | compact
}

def list-workspaces [root: path] {
    jj-lines $root [workspace list -T 'name ++ "\t" ++ root ++ "\n"'] | parse "{name}\t{root}"
}

def audit-facts [workspace: record] {
    let blank = {
        name: $workspace.name root: $workspace.root exists: false error: null
        owner: "none" owner_change: null legacy: false owner_checked_out: false claim: false
        stack: 0 published: false behind: 0 conflicts: [] stale_entries: [] stranded: false
    }
    if not ($workspace.root | path exists) { return $blank }
    let jj_dir = ($workspace.root | path join ".jj")
    let record = (read-json ($jj_dir | path join "codex-session.json"))
    let facts = (try { collect $workspace.root } catch {|err| return ($blank | merge { exists: true error: ($err.msg | lines | first) }) })
    let topics = ((read-json ($jj_dir | path join "jj-ci-publication.json")) | default {} | get --optional topics | default {})
    $blank | merge {
        exists: true
        owner: (owner-status $record)
        owner_change: ($record.change_id? | default null)
        legacy: ($record != null and ($record.state? | default "") == "" and ($record.finished? | default false))
        owner_checked_out: ($record != null and ($record.change_id? in $facts.checked_out))
        claim: ($jj_dir | path join "codex-session-claim" | path exists)
        stack: ($facts.stack | length)
        published: ($facts.branch != null)
        behind: $facts.behind
        conflicts: $facts.conflicts
        stale_entries: ($topics | transpose change branch | where {|entry| $entry.change not-in $facts.checked_out } | get branch)
        stranded: ($facts.stranded != null)
    }
}

# Codex session records whose workspace no longer exists.
def orphaned-session-records [] {
    let dir = ($env.XDG_STATE_HOME? | default ($env.HOME | path join ".local" "state") | path join "codex-jj-sessions")
    if not ($dir | path exists) { return [] }
    ls $dir | get name | each {|path| read-json $path } | compact | where {|state| not ($state.cwd? | default "" | path exists) }
}

def "main audit" [
    dir?: path
    --json # Print the findings as JSON
] {
    let root = (require-root $dir)
    let workspaces = (list-workspaces $root)
    let findings = ($workspaces | each {|workspace| audit-findings (audit-facts $workspace) } | flatten)
    let orphans = (orphaned-session-records)
    let findings = if ($orphans | is-empty) { $findings } else {
        $findings | append { workspace: "(codex)" severity: "info" code: "orphaned-session-records" detail: $"($orphans | length) Codex session records name workspaces that no longer exist." fix: "harmless; delete them from $XDG_STATE_HOME/codex-jj-sessions" }
    }
    if $json { return ($findings | to json) }
    if ($findings | is-empty) {
        print $"(ansi green)✔(ansi reset) ($workspaces | length) workspaces, no findings."
        return
    }
    for group in ($findings | group-by workspace | transpose workspace items) {
        print $"(ansi attr_bold)($group.workspace)(ansi reset)"
        for item in $group.items {
            let color = match $item.severity { "error" => (ansi red) "warning" => (ansi yellow) _ => (ansi dark_gray) }
            print $"  ($color)($item.severity)(ansi reset) ($item.code): ($item.detail)"
            print $"    fix: ($item.fix)"
        }
    }
    let counts = ($SEVERITIES | each {|severity| $"($findings | where severity == $severity | length) ($severity)" } | str join ", ")
    print $"\n($workspaces | length) workspaces: ($counts)."
}

def main [dir?: path] {
    let root = (require-root $dir)
    let facts = (collect $root)
    let facts = if $facts.refresh_due and not (locked $root) { refresh-now $root; collect $root } else { $facts }
    print-brief $facts
    if ($facts.stack | is-not-empty) {
        print ""
        for rev in $facts.stack {
            let conflict = if $rev.conflict { $" (ansi red)conflict(ansi reset)" } else { "" }
            let impact = if ($rev.impact | is-empty) { "" } else { $" (ansi dark_gray)($rev.impact | str join '+')(ansi reset)" }
            print $"  ($rev.short) ($rev.title)($impact)($conflict)"
        }
    }
    if ($facts.working_copy | is-not-empty) {
        print ""
        for file in $facts.working_copy { print $"  ($file.0) ($file.1)" }
    }
    if $facts.published_head != null and $facts.ci == null { print "\n  (pipeline state unavailable; is `ci` current?)" }
}
