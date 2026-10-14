# Property-based tests for the pure planning helpers in ci.nu, derived from
# the invariants in JjCi.tla. Run with:
#
#   nu --no-config-file -c "source tests/ci-properties.nu"
#
# Sourcing through `-c` defines ci.nu's helpers without running its `main`.
# tests/pbt.nu holds the generators and the runner.

source pbt.nu
source ../ci.nu
source ../guard.nu

const BLOCKING = ["conflicted" "waiting on parent"]
const REFRESH_STATES = [
    "current" "pushed" "ready to push" "conflicted"
    "parent not local" "no local bookmark" "checked out"
]

# Published topics with unique names. Parents may be another topic, absent, or
# null for a root. Cycles and missing parents exercise unrooted topic handling.
def gen-topics [key: string] {
    let count = (pick $"($key)/count" 8)
    let names = (0..<$count | each {|i| $"b($i)" })
    let parents = ([null "gone"] ++ $names)
    shuffle $"($key)/order" (0..<$count | each {|i|
        {
            name: ($names | get $i)
            parent: (pick-from $"($key)/parent/($i)" $parents)
        }
    })
}

def gen-graph [key: string] {
    let count = (pick $"($key)/count" 9)
    let nodes = (0..<$count | each {|i| $"t($i)" })
    let pairs = ($nodes | enumerate | each {|a|
        $nodes | skip ($a.index + 1) | each {|b| { a: $a.item b: $b } }
    } | flatten)
    let edges = ($pairs | enumerate | where {|pair| (pick $"($key)/edge/($pair.index)" 4) == 0 } | get item)
    { nodes: $nodes edges: $edges }
}

# Topic names whose parent chain reaches a root, by fixpoint.
def rooted-names [topics: list] {
    mut rooted = []
    loop {
        let known = $rooted
        let next = ($topics
            | where {|topic| $topic.parent == null or $topic.parent in $known }
            | get name
            | where {|name| $name not-in $known })
        if ($next | is-empty) { break }
        $rooted = ($rooted ++ $next)
    }
    $rooted
}

def reachable [start: string, edges: list] {
    mut seen = [$start]
    loop {
        let known = $seen
        let next = ($edges
            | each {|edge| if $edge.a in $known { $edge.b } else if $edge.b in $known { $edge.a } else { null } }
            | compact
            | where {|node| $node not-in $known }
            | uniq)
        if ($next | is-empty) { break }
        $seen = ($seen ++ $next)
    }
    $seen | sort
}

def canonical-partition [components: list] {
    $components | each {|component| $component | sort } | sort-by {|component| $component | str join "," }
}

# Publication bookmarks: stable, branch-safe names for a topic.

for-all "slugify is branch-safe and bounded" {|key|
    let slug = (slugify (gen-title $key))
    assert ($slug =~ '^([a-z0-9]+(-[a-z0-9]+)*)?$') $"not branch-safe: '($slug)'"
    assert (($slug | str length) <= 48) $"too long: '($slug)'"
}

for-all "slugify is idempotent" {|key|
    let once = (slugify (gen-title $key))
    assert equal (slugify $once) $once
}

for-all "new bookmarks end with the topic's short change id" {|key|
    let id = (gen-change-id $"($key)/id")
    let bookmark = (new-publication-bookmark $id (slugify (gen-title $"($key)/title")))
    assert ($bookmark =~ '^jj-[a-z0-9]+(-[a-z0-9]+)*-[k-z]{8}$') $"malformed: ($bookmark)"
    assert ($bookmark | str ends-with $"-($id | str substring 0..7)")
}

for-all "distinct topics never share a new bookmark" {|key|
    let a = (gen-change-id $"($key)/a")
    let b = (gen-change-id $"($key)/b")
    if ($a | str substring 0..7) != ($b | str substring 0..7) {
        let left = (new-publication-bookmark $a (slugify (gen-title $"($key)/ta")))
        let right = (new-publication-bookmark $b (slugify (gen-title $"($key)/tb")))
        assert not equal $left $right
    }
}

# Stack ordering: parents are always refreshed before their children.

for-all "stack-order returns each rooted topic exactly once" {|key|
    let topics = (gen-topics $key)
    let names = (stack-order $topics | get name? | default [])
    assert equal ($names | sort) (rooted-names $topics | sort)
    assert equal ($names | uniq | length) ($names | length)
}

for-all "stack-order is topological" {|key|
    let order = (stack-order (gen-topics $key))
    $order | enumerate | each {|entry|
        let earlier = ($order | first $entry.index | get name? | default [])
        assert ($entry.item.parent == null or $entry.item.parent in $earlier) $"($entry.item.name) precedes its parent ($entry.item.parent)"
    } | ignore
}

for-all "stack-order excludes cycles and topics with missing parents" {|key|
    let topics = (gen-topics $key)
    let order = (stack-order $topics | get name? | default [])
    assert equal ($order | sort) (rooted-names $topics | sort)
}

for-all "stack-order ignores input order" {|key|
    let topics = (gen-topics $key)
    let left = (stack-order $topics | get name? | default [] | sort)
    let right = (stack-order (shuffle $"($key)/again" $topics) | get name? | default [] | sort)
    assert equal $left $right
}

# Refresh: a blocked parent blocks everything stacked above it (TLA: a
# conflicted topic is never published, delivered, or finished).

for-all "refresh never touches topics above a blocked parent" {|key|
    let topics = (gen-topics $key)
    let ordered = (stack-order $topics)
    let outcome = {|topic| pick-from $"($key)/state/($topic.name)" $REFRESH_STATES }
    let results = (refresh-outcomes $ordered {|topic|
        { branch: $topic.name state: (do $outcome $topic) }
    })
    assert equal ($results | get branch? | default [] | sort) ($ordered | get name? | default [] | sort)
    for result in $results {
        let topic = ($topics | where name == $result.branch | first)
        let parent = ($results | where branch == $topic.parent | get 0?)
        if $parent != null and $parent.state in $BLOCKING {
            assert equal $result.state "waiting on parent"
        } else {
            assert equal $result.state (do $outcome $topic)
        }
    }
}

# Planning: conflict components and their stacking proposals.

for-all "plan-components is the connectivity partition" {|key|
    let graph = (gen-graph $key)
    let components = (plan-components $graph.nodes $graph.edges)
    assert equal ($components | flatten | sort) ($graph.nodes | sort)
    for component in $components {
        for node in $component {
            assert equal ($component | sort) (reachable $node $graph.edges)
        }
    }
}

for-all "plan-components ignores edge order and direction" {|key|
    let graph = (gen-graph $key)
    let flipped = (shuffle $"($key)/edges" $graph.edges | each {|edge| { a: $edge.b b: $edge.a } })
    assert equal (canonical-partition (plan-components $graph.nodes $graph.edges)) (canonical-partition (plan-components (shuffle $"($key)/nodes" $graph.nodes) $flipped))
}

for-all "plan proposals respect the stack limit and publication order" {|key|
    let graph = (gen-graph $key)
    # build-plan orders candidates published-first before proposing.
    let candidates = ($graph.nodes | enumerate | each {|entry|
        let published = (pick $"($key)/published/($entry.index)" 2) == 0
        { tip: $entry.item label: $entry.item pr: (if $published { 200 + $entry.index } else { null }) }
    } | sort-by {|candidate| $candidate.pr == null })
    let proposals = (plan-proposals $candidates $graph.edges)
    assert equal ($proposals | get tip? | default [] | sort) ($graph.nodes | sort)
    for component in (plan-components ($candidates | get tip? | default []) $graph.edges) {
        let placed = ($proposals | where tip in $component)
        if ($component | length) == 1 {
            assert equal ($placed | get action) ["independent"]
        } else {
            assert equal ($placed | where action == "base" | length) 1
            assert (($placed | where action != "hold" | length) <= $PLAN_MAX_STACK)
            assert equal ($placed | where action == "hold" | length) ([0 (($component | length) - $PLAN_MAX_STACK)] | math max)
        }
        for proposal in ($placed | where action == "stack") {
            assert ($proposal.parent.tip in $component) "a stack parent must conflict with its child"
            let child = ($candidates | where tip == $proposal.tip | first)
            if $child.pr != null {
                assert ($proposal.parent.pr != null) $"published ($child.tip) stacks on unpublished ($proposal.parent.tip)"
            }
        }
    }
}

# Impact classes: trailers, PR classification, release numbering, and plan order.

# "" stands for a missing trailer; `each` would drop a null.
const IMPACT_VALUES = ["refactor" "behavior" "breaking" "Refactor" "BEHAVIOR" "chore" ""]

def gen-impacts [key: string] {
    0..<(1 + (pick $"($key)/count" 5)) | each {|i| pick-from $"($key)/($i)" $IMPACT_VALUES }
}

def with-trailer [key: string, impact: any] {
    let title = (gen-title $"($key)/title")
    let body = if (pick $"($key)/body" 2) == 0 { "" } else { $"\n\n(gen-title $'($key)/body-text')" }
    if ($impact | is-empty) { $"($title)($body)\n" } else { $"($title)($body)\n\nImpact: ($impact)\n" }
}

for-all "parse-impact reads the trailer case-insensitively" {|key|
    let impact = (pick-from $"($key)/impact" $IMPACT_VALUES)
    assert equal (parse-impact (with-trailer $key $impact)) ($impact | str lowercase)
}

for-all "description-body drops the subject and the trailer" {|key|
    let impact = (pick-from $"($key)/impact" ["refactor" "behavior" "breaking"])
    let description = (with-trailer $key $impact)
    let body = (description-body $description)
    assert equal (parse-impact $body) ""
    assert equal $body ($description | lines | skip 1 | drop 1 | str join "\n" | str trim)
}

for-all "combine-impacts never mixes refactors with user-facing changes" {|key|
    let impacts = (gen-impacts $key | each {|impact| $impact | str lowercase })
    let result = (combine-impacts $impacts)
    assert (($result.impact == null) != ($result.problem == null)) "exactly one of impact and problem"
    if ($impacts | any {|impact| $impact not-in $IMPACTS }) {
        assert equal $result.impact null
    } else if ($impacts | all {|impact| $impact == "refactor" }) {
        assert equal $result.impact "refactor"
    } else if "refactor" in $impacts {
        assert equal $result.impact null
    } else {
        assert equal $result.impact (if "breaking" in $impacts { "breaking" } else { "behavior" })
    }
}

for-all "next-version is unique and increments per day" {|key|
    let dates = ["2026.09.26" "2026.09.27" "2026.10.01"]
    mut tags = []
    for i in 0..<(pick $"($key)/count" 12) {
        let date = (pick-from $"($key)/($i)" $dates)
        let version = (next-version $date $tags)
        assert ($version not-in $tags) $"($version) was already released"
        assert ($version | str starts-with $"($date).")
        $tags = ($tags | append $version)
    }
    for date in $dates {
        let serials = ($tags | where {|tag| $tag | str starts-with $"($date)." } | each {|tag| $tag | split row "." | last | into int })
        if ($serials | is-not-empty) {
            assert equal $serials (1..($serials | length) | each {|n| $n })
        }
    }
}

for-all "plan-order keeps published topics first and refactors early" {|key|
    let topics = (0..<(pick $"($key)/count" 8) | each {|i|
        let published = (pick $"($key)/pr/($i)" 2) == 0
        {
            tip: $"t($i)"
            bookmark: (if $published { $"b($i)" } else { null })
            impact: (pick-from $"($key)/impact/($i)" ["refactor" "behavior" "breaking" null])
            created: (pick $"($key)/time/($i)" 1000)
        }
    })
    let ordered = (plan-order $topics)
    assert equal ($ordered | length) ($topics | length)
    # Two workspaces see the topics in different orders; both must pick the
    # same base, or each tells the other to publish first.
    assert equal ($ordered | get tip) (plan-order ($topics | reverse) | get tip)
    $ordered | window 2 | each {|pair|
        let a = ($pair | first)
        let b = ($pair | last)
        assert (($a.bookmark != null) or ($b.bookmark == null)) "an unpublished topic precedes a published one"
        if (($a.bookmark == null) == ($b.bookmark == null)) {
            assert ((impact-order $a.impact) <= (impact-order $b.impact)) "a user-facing topic precedes a refactor"
        }
    } | ignore
}

def gen-workspace-facts [key: string] {
    let flag = {|name| (pick $"($key)/($name)" 2) == 0 }
    {
        name: (pick-from $"($key)/name" ["default" "topic" "other"])
        current: (do $flag current)
        exists: (do $flag exists)
        git_worktree: (do $flag git)
        codex_worktree: (do $flag codex)
        owner: (pick-from $"($key)/owner" ["none" "active" "delivered" "discarded" "released"])
        owner_ended: (do $flag ended)
        recent: (do $flag recent)
        stale: (do $flag stale)
        error: (if (do $flag error) { "unreadable" } else { null })
        pending: (do $flag pending)
    }
}

for-all "prune never removes a workspace that is live or unknown" {|key|
    let facts = (gen-workspace-facts $key)
    if (prune-verdict $facts) == null {
        assert ($facts.name != "default") "prune removed the default workspace"
        assert (not $facts.current) "prune removed the current workspace"
        if $facts.exists {
            assert (not $facts.git_worktree) "prune removed a Git worktree"
            assert (not $facts.codex_worktree) "prune removed a Codex worktree"
            assert (not $facts.recent) "prune removed a workspace used within --idle"
            assert ($facts.owner != "active" or $facts.owner_ended) "prune removed a live task's workspace"
            assert (not $facts.stale) "prune removed an unrefreshed workspace"
            assert ($facts.error == null) "prune removed an unreadable workspace"
            assert (not $facts.pending) "prune removed undelivered work"
        }
    }
}

for-all "prune reclaims an ended task's workspace unless it holds work" {|key|
    let facts = (gen-workspace-facts $key | merge {
        name: "topic" current: false exists: true git_worktree: false codex_worktree: false
        recent: false stale: false error: null owner: "active" owner_ended: true
    })
    assert equal ((prune-verdict $facts) == null) (not $facts.pending)
}

for-all "a Codex task ends when archived or quiet past OWNER_QUIET" {|key|
    let now = (2026-10-07T12:00:00Z | into datetime)
    let quiet = (pick-from $"($key)/quiet" [null 1min 1day ($OWNER_QUIET + 1min) 5day])
    let facts = {
        archived: (flag $"($key)/archived")
        last_write: (if $quiet == null { null } else { $now - $quiet })
        now: $now
    }
    let expected = if $facts.archived { "ended" } else if $quiet == null { "unknown" } else if $quiet > $OWNER_QUIET { "ended" } else { "live" }
    assert equal (owner-liveness $facts) $expected
}

for-all "only branches landed in every copy and recorded by no workspace are deleted" {|key|
    let names = (0..<(1 + (pick $"($key)/branches" 5)) | each {|i| $"jj-topic-($i)" })
    let copies = ($names | each {|name|
        0..<(1 + (pick $"($key)/($name)/copies" 3)) | each {|i| { name: $name landed: (flag $"($key)/($name)/landed/($i)") } }
    } | flatten)
    let in_use = ($names | where {|name| flag $"($key)/($name)/used" })
    let deleted = (landed-branches $copies $in_use)
    for name in $names {
        let landed = ($copies | where name == $name | all {|copy| $copy.landed })
        assert equal ($name in $deleted) ($landed and $name not-in $in_use) $name
    }
}

for-all "prune reclaims every released, delivered workspace" {|key|
    let facts = (gen-workspace-facts $key | merge {
        name: "topic" current: false exists: true git_worktree: false codex_worktree: false
        recent: false owner_ended: false stale: false error: null
    })
    let owner = (pick-from $"($key)/released" ["none" "delivered" "discarded" "released"])
    let delivered = not $facts.pending
    assert equal ((prune-verdict ($facts | upsert owner $owner)) == null) $delivered
}

# Topic guard: the working copy must not wander off the topic that
# `ci start` recorded, and the interactive `jj new` guard only inspects
# invocations that would move the working copy.

def gen-topic-facts [key: string] {
    let flag = {|name| (pick $"($key)/($name)" 2) == 0 }
    {
        recorded: (do $flag recorded)
        visible: (do $flag visible)
        landed: (do $flag landed)
        ancestor: (do $flag ancestor)
        working_copy_empty: (do $flag working_copy_empty)
        topic_empty: (do $flag topic_empty)
        topic: "t"
    }
}

for-all "a topic below the working copy, landed, or gone is never stranded" {|key|
    let facts = (gen-topic-facts $key)
    for safe in [{ ancestor: true } { landed: true } { visible: false } { recorded: false } { topic_empty: true }] {
        assert (not (topic-stranded ($facts | merge $safe))) $"stranded despite ($safe | to nuon)"
    }
}

for-all "an empty working copy beside unlanded topic work is stranded" {|key|
    let facts = (gen-topic-facts $key | merge {
        recorded: true visible: true landed: false ancestor: false working_copy_empty: true topic_empty: false
    })
    assert (topic-stranded $facts) "`jj new main` beside the topic went unnoticed"
}

# `ci new`: a workspace holds sibling topics unless an active task or an
# unfinished `ci start` topic owns it.

def gen-new-topic-facts [key: string] {
    {
        owner: (pick-from $"($key)/owner" ["none" "active" "delivered" "discarded" "released"])
        dedicated: (flag $"($key)/dedicated")
        topic_done: (flag $"($key)/done")
        in_place: (flag $"($key)/in-place")
    }
}

for-all "ci new never moves an owned or dedicated working copy" {|key|
    let facts = (gen-new-topic-facts $key)
    if (new-topic-refusal $facts) == null {
        assert ($facts.owner != "active" or $facts.in_place) "started a topic over an active task's change"
        assert ((not $facts.dedicated) or $facts.topic_done) "stranded a `ci start` topic"
    }
}

# A session that claimed an empty change names it with `ci new`; the change,
# and so the session's claim on it, stays.
for-all "ci new names an owned empty change in place" {|key|
    let facts = (gen-new-topic-facts $key | merge { owner: "active" in_place: true dedicated: false })
    assert equal (new-topic-refusal $facts) null
}

for-all "ci new starts a sibling in every unowned shared workspace" {|key|
    let facts = (gen-new-topic-facts $key | merge { dedicated: false })
    let owner = (pick-from $"($key)/ended" ["none" "delivered" "discarded" "released"])
    assert equal (new-topic-refusal ($facts | upsert owner $owner)) null
}

const JJ_NEW_CASES = [
    [args expected];
    [["log"] null]
    [["new"] null]
    [["new" "-m" "later"] null]
    [["new" "-m" "main"] null]
    [["new" "main"] ["main"]]
    [["new" "main@tangled" "other"] ["main@tangled" "other"]]
    [["new" "-m" "fresh" "main"] ["main"]]
    [["new" "--message=fresh" "main"] ["main"]]
    [["new" "-A" "main"] ["main"]]
    [["new" "--insert-after=main"] ["main"]]
    [["new" "-o" "main"] ["main"]]
    [["new" "--no-edit" "main"] null]
    [["new" "main" "--no-edit"] null]
    [["new" "-B" "main"] null]
    [["new" "-R" "/elsewhere" "main"] null]
    [["new" "--at-op=abc" "main"] null]
    [["new" "--color" "never" "main"] ["main"]]
]

for case in $JJ_NEW_CASES {
    assert equal (jj-new-parents $case.args) $case.expected $"jj ($case.args | str join ' ')"
}
print $"ok jj new parents \(($JJ_NEW_CASES | length) cases)"

# Ownership records (TLA: DeliveredRecordIsTrue). A hand-edited `finished`
# must never read as a delivered topic.

owner-status-properties {|record| owner-status $record }

# `ci unclaim` (TLA: Unclaim, UnclaimOnlyOrphans, ClaimOnlyWhileActive).

def gen-unclaim-facts [key: string] {
    {
        status: (pick-from $"($key)/status" ["none" "active" "delivered" "discarded" "released"])
        at_owner_change: (flag $"($key)/at")
        claim: (flag $"($key)/claim")
        legacy: (flag $"($key)/legacy")
    }
}

for-all "unclaim rewrites every ended legacy record and no active one" {|key|
    let facts = (gen-unclaim-facts $key)
    let verdict = (unclaim-verdict $facts)
    let ended = $facts.status in ["delivered" "discarded" "released"]
    assert equal $verdict.normalize ($facts.legacy and $facts.status != "active")
    if $verdict.normalize { assert (not $verdict.release) "normalized and released at once" }
    if $ended and $facts.legacy { assert $verdict.normalize }
}

for-all "unclaim never frees a change that is checked out" {|key|
    let facts = (gen-unclaim-facts $key)
    let verdict = (unclaim-verdict $facts)
    if $facts.status == "active" and $facts.at_owner_change {
        assert (not $verdict.release) "released a checked-out change"
        assert (not $verdict.clear_claim) "cleared the claim of a checked-out change"
        assert ($verdict.refuse != null) "gave no reason to use finish or abandon"
    }
}

for-all "unclaim frees every orphaned active claim" {|key|
    let facts = (gen-unclaim-facts $key | upsert status "active" | upsert at_owner_change false)
    let verdict = (unclaim-verdict $facts)
    assert $verdict.release "left an orphaned claim active"
    assert $verdict.clear_claim "released the record but kept its claim"
    assert equal $verdict.refuse null
}

for-all "unclaim only ever changes an active record" {|key|
    let facts = (gen-unclaim-facts $key)
    let verdict = (unclaim-verdict $facts)
    if $verdict.release { assert equal $facts.status "active" }
}

# `ci preflight` reruns Prek once when its formatters rewrote files.

def gen-prek-run [key: string] {
    let hooks = (0..<(pick $"($key)/count" 4) | each {|i|
        let failed = (flag $"($key)/failed/($i)")
        {
            name: (pick-from $"($key)/name/($i)" ["format repository" "check whitespace" "nix fmt" "evaluate Home Manager"])
            failed: $failed
            modified: ($failed and (flag $"($key)/modified/($i)"))
        }
    })
    let output = ($hooks | each {|hook|
        let status = if $hook.failed { "Failed" } else { "Passed" }
        let rewrite = if $hook.modified { "\n  - files were modified by this hook" } else { "" }
        let dots = ("" | fill --character "." --width (3 + (pick $"($key)/pad/($hook.name)" 40)))
        $"(ansi red)  ($hook.name)($dots)($status)(ansi reset)\n  - hook id: x($rewrite)\n    formatted 2 files \(1 changed\)"
    } | str join "\n")
    let exit_code = if ($hooks | any {|hook| $hook.failed }) { 1 } else { 0 }
    { hooks: $hooks outcome: (prek-outcome $exit_code $output) }
}

for-all "prek-outcome reads every failed hook and any rewrite" {|key|
    let run = (gen-prek-run $key)
    assert equal $run.outcome.failed ($run.hooks | where failed | get name)
    assert equal $run.outcome.modified ($run.hooks | any {|hook| $hook.modified })
}

for-all "preflight passes exactly when its last Prek run passes" {|key|
    let runs = [(gen-prek-run $"($key)/1").outcome (gen-prek-run $"($key)/2").outcome]
    let verdict = (prek-verdict $runs)
    assert (not $verdict.rerun) "ran Prek a third time"
    assert equal ($verdict.error == null) (($runs | last).exit_code == 0)
}

for-all "preflight reruns Prek only after a failed run rewrote files" {|key|
    let first = (gen-prek-run $key).outcome
    let verdict = (prek-verdict [$first])
    assert equal $verdict.rerun ($first.exit_code != 0 and $first.modified)
    if $verdict.rerun { assert equal $verdict.error null }
}

for-all "a Prek failure names every failed hook" {|key|
    let run = (gen-prek-run $key).outcome
    let verdict = (prek-verdict [$run $run])
    for hook in $run.failed { assert ($verdict.error | default "" | str contains $hook) $"did not name ($hook)" }
}

# Preflight skips Prek only where Prek would find no configuration: none in
# the work tree or any directory above it.
for-all "prek-config finds the nearest configuration at or above the work tree" {|key|
    let base = (mktemp --directory --tmpdir "ci-prek-config.XXXXXX" | path expand)
    let dirs = [$base ($base | path join "repo") ($base | path join "repo" "sub")]
    for dir in $dirs { mkdir $dir }
    let placed = ($dirs | enumerate | each {|dir|
        let name = (pick-from $"($key)/name/($dir.index)" ([null] ++ $PREK_CONFIGS))
        if $name != null { "" | save ($dir.item | path join $name) }
        if $name == null { null } else { $dir.item | path join $name }
    })
    let expected = ($placed | reverse | compact | get --optional 0)
    let found = (prek-config ($base | path join "repo" "sub"))
    rm --recursive $base
    # A configuration above the temporary directory would also count.
    if $expected != null { assert equal $found $expected }
}

for-all "unclaim leaves no claim without an active owner" {|key|
    let facts = (gen-unclaim-facts $key)
    let verdict = (unclaim-verdict $facts)
    let owner_active_after = ($facts.status == "active" and not $verdict.release)
    let claim_after = ($facts.claim and not $verdict.clear_claim)
    if $verdict.refuse == null {
        assert ((not $claim_after) or $owner_active_after) "a claim outlived its owner"
    }
}

# Local clearance outcomes (2026-10-07). nix-fast-build writes its result file
# only when it finishes, so a run that a signal ended, or that failed without
# a failed check on record, was killed. An evaluation over the memory budget
# counts as killed too. Only a check that failed by itself reads as failed.

const MEMORY_BUDGET_ERROR = "evaluation exceeded the memory budget of 6144 MiB (workers * max-memory-size) even when run alone"
const CHECK_OUTCOME_CASES = [
    { exit: 0 results: null expected: { status: "success" } }
    # The 2026-10-07 landing: the checks unit's main process died from a
    # signal before nix-fast-build wrote any results.
    { exit: 255 results: null expected: { status: "killed" error: "likely out of memory, exit status 255" } }
    { exit: -9 results: null expected: { status: "killed" error: "likely out of memory, signal 9" } }
    # nix-eval-jobs died, so nix-fast-build failed with every result passing.
    { exit: 1 results: [{ type: "BUILD" attr: "fine" success: true error: null }] expected: { status: "killed" error: "likely out of memory, exit status 1" } }
    { exit: 1 results: [{ type: "EVAL" attr: "desktop-primary" success: false error: $MEMORY_BUDGET_ERROR }] expected: { status: "killed" error: "likely out of memory, exit status 1" } }
    { exit: 1 results: [{ type: "BUILD" attr: "den-inventory-tests" success: false error: "builder failed" }] expected: { status: "failed" error: "den-inventory-tests did not build" } }
    { exit: 1 results: [{ type: "EVAL" attr: "broken" success: false error: "error: attribute 'x' missing" } { type: "BUILD" attr: "other" success: false error: "builder failed" }] expected: { status: "failed" error: "broken did not evaluate, other did not build" } }
]

let outcome_dir = (mktemp --directory --tmpdir "ci-outcome.XXXXXX")
let outcome_file = ($outcome_dir | path join "checks.json")

for case in $CHECK_OUTCOME_CASES {
    rm --force $outcome_file
    if $case.results != null { { results: $case.results } | to json | save $outcome_file }
    assert equal (checks-outcome $case.exit $outcome_file) $case.expected $"exit ($case.exit) with results ($case.results | to nuon)"
}
print $"ok local check outcomes \(($CHECK_OUTCOME_CASES | length) cases)"

# What a transient checks unit leaves behind, as observed on 2026-10-07: the
# shell's recorded status and systemd-run's exit status for each way a run ends.
const UNIT_EXIT_CASES = [
    { recorded: "0" systemd_run: 0 expected: 0 }
    { recorded: "1" systemd_run: 0 expected: 1 }
    # The shell reports a check run killed by SIGKILL as 137.
    { recorded: "137" systemd_run: 0 expected: -9 }
    # A stop's SIGTERM counts as a clean exit: nothing recorded, and systemd-run
    # exits 0, which once let unfinished checks pass.
    { recorded: "" systemd_run: 0 expected: null }
    # A unit killed whole records nothing, and systemd-run exits 255.
    { recorded: "" systemd_run: 255 expected: 255 }
]

for case in $UNIT_EXIT_CASES {
    assert equal (unit-exit-code $case.recorded $case.systemd_run) $case.expected $"recorded ($case.recorded | to nuon) with systemd-run exit ($case.systemd_run)"
}
print $"ok unit exit codes \(($UNIT_EXIT_CASES | length) cases)"

# Local clearance progress, folded from the JSON lines nix-fast-build streams.
# A landing where one check was substituted, one built, one evaluation ran
# over the memory budget, and one check shared the built check's derivation.
def fold-progress [names: any, results: list] {
    $results | reduce --fold { progress: (checks-progress-start $names) reports: [] } {|result, acc|
        let step = (checks-progress-step $acc.progress $result)
        { progress: $step.progress reports: ($acc.reports ++ $step.reports) }
    }
}

let landing = (fold-progress ["cached" "desktop-primary" "den-host-evaluation" "alias"] [
    { type: "EVAL" attr: "cached" success: true error: null drvPath: "/d/0" cacheStatus: "cached" }
    { type: "EVAL" attr: "desktop-primary" success: true error: null drvPath: "/d/1" cacheStatus: "notBuilt" }
    { type: "EVAL" attr: "den-host-evaluation" success: false error: $MEMORY_BUDGET_ERROR }
    { type: "BUILD" attr: "desktop-primary" success: true error: null duration: 62.4 }
    { type: "EVAL" attr: "alias" success: true error: null drvPath: "/d/1" cacheStatus: "notBuilt" }
])
assert equal $landing.reports [
    { state: "working" id: "clearance/desktop-primary" msg: "building desktop-primary" }
    { state: "working" id: "clearance" msg: "building desktop-primary (2/4)" }
    { state: "error" id: "clearance/den-host-evaluation" msg: "den-host-evaluation exceeded 6 GiB" }
    { state: "done" id: "clearance/desktop-primary" msg: "desktop-primary built in 1min 2sec" }
    { state: "working" id: "clearance" msg: "evaluated 3/4 checks" }
]
assert equal $landing.progress.building []

let failing = (fold-progress null [
    { type: "EVAL" attr: "broken" success: false error: "error:\n       … while evaluating the attribute 'checks'\n\n       error: attribute 'x' missing\n" }
    { type: "EVAL" attr: "tests" success: true error: null drvPath: "/d/2" }
    { type: "BUILD" attr: "tests" success: false error: "build exited with 1" duration: 3.0 }
])
assert equal ($failing.reports | where state == "error" | get msg) ["broken did not evaluate: error: attribute 'x' missing" "tests did not build"]
assert equal ($failing.reports | where id == "clearance" | get msg) ["building tests (2)" "evaluated 2 checks"]

# Killed while one check built and the next in name order was evaluating.
let cut = (fold-progress ["a" "b" "c"] [
    { type: "EVAL" attr: "a" success: true error: null drvPath: "/d/a" cacheStatus: "notBuilt" }
])
assert equal (checks-killed "likely out of memory, signal 9" $cut.progress) {
    outcome: { status: "killed" error: "likely out of memory, signal 9, while building a and evaluating b" }
    reports: [
        { state: "error" id: "clearance/a" msg: "a was killed while building" }
        { state: "error" id: "clearance/b" msg: "b was killed while evaluating" }
    ]
}
assert equal (checks-killed "likely out of memory, exit status 1" $landing.progress).outcome.error "likely out of memory, exit status 1 (den-host-evaluation exceeded 6 GiB)"
assert equal (check-status-id "nixos/a very long check name that keeps going") "clearance/nixos-a-very-long-check-name-tha"
print "ok local clearance progress"

def gen-check-results [key: string] {
    let names = (0..<(pick $"($key)/count" 6) | each {|i| $"check-($i)" })
    let evals = ($names | enumerate | each {|name|
        let kind = (pick-from $"($key)/eval/($name.index)" ["cached" "build" "alias" "eval-error" "memory"])
        match $kind {
            "cached" => { type: "EVAL" attr: $name.item success: true error: null drvPath: $"/d/($name.index)" cacheStatus: "cached" }
            "build" => { type: "EVAL" attr: $name.item success: true error: null drvPath: $"/d/($name.index)" cacheStatus: "notBuilt" }
            "alias" => { type: "EVAL" attr: $name.item success: true error: null drvPath: "/d/0" cacheStatus: "notBuilt" }
            "eval-error" => { type: "EVAL" attr: $name.item success: false error: "error: boom" }
            _ => { type: "EVAL" attr: $name.item success: false error: $MEMORY_BUDGET_ERROR }
        }
    })
    # nix-fast-build builds each derivation once, after its check evaluates.
    mut stream = []
    mut queued = []
    for eval in $evals {
        $stream = ($stream ++ [$eval])
        if $eval.success and $eval.cacheStatus == "notBuilt" and $eval.drvPath not-in $queued {
            $queued = ($queued ++ [$eval.drvPath])
            if (flag $"($key)/finish/($eval.attr)") {
                $stream = ($stream ++ [{ type: "BUILD" attr: $eval.attr success: (flag $"($key)/ok/($eval.attr)") error: null duration: 1.0 }])
            }
        }
    }
    { names: $names results: $stream }
}

for-all "every check reported started ends done or error, once the run ends" {|key|
    let run = (gen-check-results $key)
    let folded = (fold-progress $run.names $run.results)
    let reports = ($folded.reports ++ (if ($folded.progress.building | is-empty) { [] } else {
        (checks-killed "likely out of memory, signal 9" $folded.progress).reports
    }))
    let total = ($run.names | length)
    for started in ($reports | where state == "working" and id != "clearance" | get id | uniq) {
        let last = ($reports | where id == $started | last)
        assert ($last.state in ["done" "error"]) $"($started) was left ($last.state)"
    }
    for summary in ($reports | where id == "clearance" | get msg) {
        let counted = ($summary | parse --regex '(?<n>\d+)/(?<total>\d+)' | get --optional 0)
        assert ($counted != null and ($counted.n | into int) <= $total and ($counted.total | into int) == $total) $"bad count in ($summary)"
    }
    assert ($reports | all {|report| $report.id =~ '^clearance(/[A-Za-z0-9_.+-]{1,32})?$' }) "an id is not an OSC 7501 path"
}

def gen-check-result [key: string] {
    let kind = (pick-from $"($key)/kind" ["passed" "build" "eval" "memory"])
    {
        type: (match $kind { "build" => "BUILD", "passed" => (pick-from $"($key)/type" ["BUILD" "EVAL"]), _ => "EVAL" })
        attr: $"check-(pick $'($key)/attr' 100)"
        success: ($kind == "passed")
        error: (match $kind { "passed" => null, "memory" => $MEMORY_BUDGET_ERROR, _ => "error: builder failed" })
    }
}

for-all "local checks read as killed exactly when no check failed by itself" {|key|
    let exit_code = (pick-from $"($key)/exit" [1 2 255 -9 -15])
    let finished = (flag $"($key)/finished")
    let results = (0..<(pick $"($key)/count" 5) | each {|i| gen-check-result $"($key)/($i)" })
    rm --force $outcome_file
    if $finished { { results: $results } | to json | save $outcome_file }
    let outcome = (checks-outcome $exit_code $outcome_file)
    let own_failures = if $finished { $results | where {|result| not $result.success and $result.error != $MEMORY_BUDGET_ERROR } } else { [] }
    if $exit_code < 0 or $exit_code == 255 or ($own_failures | is-empty) {
        assert equal $outcome.status "killed"
        assert ($outcome.error | str starts-with "likely out of memory") $outcome.error
    } else {
        assert equal $outcome.status "failed"
        for failure in $own_failures {
            assert ($outcome.error | str contains $failure.attr) $"($failure.attr) is missing from ($outcome.error)"
        }
    }
}

# The local checks lock (2026-10-07): a live holder keeps it, a holder that
# exited or whose pid was reused gives way, and the locked work releases it
# however it ends.

with-env { XDG_STATE_HOME: $outcome_dir } {
    let lock = (local-checks-lock-path)
    let start = (process-start $nu.pid)
    assert ($start != null) "no start time for this process"
    assert equal (with-local-checks-lock deadbeef { 42 }) 42
    assert (not ($lock | path exists)) "the lock outlived the work it guarded"
    { topic: "live" pid: $nu.pid start: $start unit: null } | to json --raw | save --force $lock
    assert equal (claim-local-checks-lock $lock "next" | get topic) "live"
    for holder in [
        { topic: "reused pid" pid: $nu.pid start: "1" unit: null }
        { topic: "exited" pid: 99999999 start: $start unit: null }
    ] {
        $holder | to json --raw | save --force $lock
        assert equal (claim-local-checks-lock $lock "next") null $holder.topic
        assert equal (open --raw $lock | into binary | decode utf-8) "next"
    }
    rm $lock
    let raised = (try { with-local-checks-lock deadbeef { error make { msg: "boom" } }; null } catch {|err| $err.msg })
    assert equal $raised "boom"
    assert (not ($lock | path exists)) "a failed body kept the lock"
}
print "ok local checks lock"

# The topic lock (2026-10-07): a second `ci` moving a topic that a live one is
# already moving fails at once instead of waiting, and the lock goes with the
# work however it ends.

with-env { XDG_STATE_HOME: $outcome_dir } {
    let lock = (topic-lock-path "kxtopic")
    assert equal (with-topic-lock "kxtopic" { 7 }) 7
    assert (not ($lock | path exists)) "the topic lock outlived the work it guarded"
    { topic: "live" pid: $nu.pid start: (process-start $nu.pid) workspace: "/w/other" } | to json --raw | save --force $lock
    let refused = (try { with-topic-lock "kxtopic" { "ran" } } catch {|err| $err.msg })
    assert ($refused | str contains "already dispatching or landing") $"a live holder let a second run through: ($refused)"
    assert ($refused | str contains "/w/other") "the refusal does not name the holder's workspace"
    { topic: "exited" pid: 99999999 start: "1" workspace: "/w/other" } | to json --raw | save --force $lock
    assert equal (with-topic-lock "kxtopic" { "ran" }) "ran"
    assert (not ($lock | path exists)) "a dead holder's lock was not taken over and released"
    let other = (topic-lock-path "kyother")
    { topic: "live" pid: $nu.pid start: (process-start $nu.pid) workspace: "/w/other" } | to json --raw | save --force $other
    assert equal (with-topic-lock "kxtopic" { "ran" }) "ran" "another topic's lock blocked this one"
}
print "ok topic lock"

rm --recursive $outcome_dir

# Plan tips: every tip has its own name, and only a divergent change's copies
# are told apart by commit, so the plan never hands JJ a bare divergent ID.

for-all "every plan tip is named apart, by change unless the change is divergent" {|key|
    let changes = (0..<(1 + (pick $"($key)/changes" 4)) | each {|i| gen-change-id $"($key)/change/($i)" })
    let rows = (0..<(1 + (pick $"($key)/rows" 6)) | each {|i|
        { commit: ($"($key)/commit/($i)" | hash sha256 | str substring 0..39) change: (pick-from $"($key)/of/($i)" $changes) }
    } | uniq-by commit)
    let tips = (tip-identities $rows)
    assert equal ($tips | get commit) ($rows | get commit)
    assert equal ($tips | get tip | uniq | length) ($tips | length)
    for pair in ($rows | zip $tips) {
        let copies = ($rows | where change == $pair.0.change | length)
        assert equal ($pair.1.tip == $pair.0.change) ($copies == 1)
        assert ($pair.1.tip | str starts-with $pair.0.change)
    }
}

# Local commands retry only JJ's operation-heads race.

for-all "local commands retry only the operation-heads race, while attempts remain" {|key|
    let attempt = (1 + (pick $"($key)/attempt" ($LOCAL_ATTEMPTS + 2)))
    let stderr = (pick-from $"($key)/stderr" [
        "Internal error: Unexpected error from operation heads store\nCaused by: Failed to read operation heads"
        "Error: Change ID `qlxvsrukuvws` is divergent"
        "Error: Unable to create '.git/index.lock': File exists."
        ""
    ])
    let delay = (local-retry-delay $attempt $stderr)
    assert equal ($delay != null) (($stderr | str contains $OPERATION_HEADS_RACE) and $attempt < $LOCAL_ATTEMPTS)
}

# Remote commands retry only Tangled's rate-limit refusal.

def gen-remote-failure [key: string] {
    {
        attempt: (1 + (pick $"($key)/attempt" ($REMOTE_ATTEMPTS + 2)))
        stderr: (pick-from $"($key)/stderr" [
            $"git: knot: ($RATE_LIMITED) from your address, try again shortly"
            "Error: Refusing to move bookmark backwards or sideways: main"
            "git: Bad owner or permissions on /home/schlich/.ssh/config"
            ""
        ])
    }
}

for-all "remote commands retry only a rate limit, and only while attempts remain" {|key|
    let failure = (gen-remote-failure $key)
    let delay = (remote-retry-delay $failure.attempt $failure.stderr)
    let retries = ($failure.stderr | str contains $RATE_LIMITED) and $failure.attempt < $REMOTE_ATTEMPTS
    assert equal ($delay != null) $retries
}

for-all "a moved workspace is reported updated only when update-stale changed it" {|key|
    let stderr = (pick-from $"($key)/stderr" [
        "Attempted recovery, but the working copy is not stale."
        "Working copy  (@) now at: mqrkszpm 1c2d3e4f rewritten from a"
        ""
    ])
    assert equal (update-stale-noop $stderr) ($stderr | str starts-with "Attempted recovery")
}

for-all "ci start nests a workspace in the Git worktree it runs from" {|key|
    let worktree = if (flag $"($key)/worktree") { "/repo/.claude/worktrees/session" } else { null }
    let expected = if $worktree == null { "/repo/.jj-workspaces" } else { "/repo/.claude/worktrees/session/.jj-workspaces" }
    assert equal (start-parent "/repo" $worktree) $expected
}

for-all "remote retries back off by doubling from two seconds" {|key|
    let attempt = (1 + (pick $"($key)/attempt" ($REMOTE_ATTEMPTS - 2)))
    let first = (remote-retry-delay $attempt $RATE_LIMITED)
    assert equal (remote-retry-delay ($attempt + 1) $RATE_LIMITED) ($first * 2)
    assert equal (remote-retry-delay 1 $RATE_LIMITED) 2sec
}

# Where only JJ's default defines trunk(), ci defines it on a preferred remote,
# else the only remote. Several remotes with no preferred one among them are
# refused rather than guessed.
for-all "an undefined trunk goes on a preferred remote or the only one" {|key|
    let names = (["tangled" "origin" "upstream" "knot"] | where {|name| flag $"($key)/has/($name)" })
    let preferred = ($TRUNK_REMOTES | where {|name| $name in $names } | get --optional 0)
    let expected = if $preferred != null {
        $preferred
    } else if ($names | length) == 1 {
        $names | first
    } else { null }
    assert equal (choose-trunk-remote $names) $expected
}

# A trunk() definition must name exactly one remote bookmark for ci to land on.
const TRUNK_SYMBOL_CASES = [
    [definition expected];
    ["main@tangled" { bookmark: "main" remote: "tangled" }]
    ["latest(present(main@tangled) | root())" { bookmark: "main" remote: "tangled" }]
    ["release/1.x@origin" { bookmark: "release/1.x" remote: "origin" }]
    ['remote_bookmarks(exact:"master", exact:"origin")' { bookmark: "master" remote: "origin" }]
    ["remote_bookmarks(exact:'main', exact:'knot')" { bookmark: "main" remote: "knot" }]
    ["main@origin | main@origin" { bookmark: "main" remote: "origin" }]
    ["main@origin | main@upstream" null]
    ["root()" null]
    ["latest(::@ & ~mutable())" null]
    ["trunk()..@-" null]
]

for case in $TRUNK_SYMBOL_CASES {
    assert equal (trunk-symbol $case.definition) $case.expected $"trunk-symbol ($case.definition)"
}
print $"ok trunk\() definitions \(($TRUNK_SYMBOL_CASES | length) cases)"

const TANGLED_LOCATION_CASES = [
    [url expected];
    ["git@tangled.org:schlich.tngl.sh/xr-ui" { owner: "schlich.tngl.sh" name: "xr-ui" }]
    ["git@tangled.org:@schlich.tngl.sh/ci.git" { owner: "schlich.tngl.sh" name: "ci" }]
    ["https://tangled.org/did:plc:abc/ci/" { owner: "did:plc:abc" name: "ci" }]
    ["ssh://git@knot.example/schlich.tngl.sh/ci" { owner: "schlich.tngl.sh" name: "ci" }]
    ["git@tangled.org:did:plc:cbfi43hmtk77onjajvmonkjl" { did: "did:plc:cbfi43hmtk77onjajvmonkjl" }]
    ["https://tangled.org/did:plc:abc" { did: "did:plc:abc" }]
    ["git@tangled.org:a/b/c" null]
    ["git@tangled.org:xr-ui" null]
    ["/srv/git/ci" null]
]

for case in $TANGLED_LOCATION_CASES {
    assert equal (tangled-location $case.url) $case.expected $"tangled-location ($case.url)"
}
print $"ok tangled remote locations \(($TANGLED_LOCATION_CASES | length) cases)"
