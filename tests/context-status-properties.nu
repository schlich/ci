# Property-based tests for context-status: its reading of ownership records
# and the audit's findings, which check the ownership rules in
# README.md against real workspaces. Run with:
#
#   nu --no-config-file -c "source tests/context-status-properties.nu"
#
# Sourcing through `-c` defines the helpers without running its `main`.

source pbt.nu
source ../context-status.nu

const ERROR_CODES = ["missing-workspace" "unreadable" "stranded-topic" "orphaned-claim" "leftover-claim"]

def gen-audit-facts [key: string] {
    let owner = (pick-from $"($key)/owner" ["none" "active" "delivered" "discarded" "released"])
    {
        name: (pick-from $"($key)/name" ["default" "topic"])
        root: "/w"
        exists: ((pick $"($key)/exists" 8) != 0)
        error: (if (pick $"($key)/error" 8) == 0 { "stale" } else { null })
        owner: $owner
        owner_change: (if $owner == "none" { null } else { gen-change-id $"($key)/change" })
        legacy: ($owner == "released" and (flag $"($key)/legacy"))
        owner_checked_out: ($owner != "none" and (flag $"($key)/checked"))
        claim: (flag $"($key)/claim")
        stack: (pick $"($key)/stack" 3)
        published: (flag $"($key)/published")
        behind: (pick $"($key)/behind" 4)
        conflicts: (if (flag $"($key)/conflicts") { [] } else { ["abcdefgh"] })
        stale_entries: (if (flag $"($key)/stale") { [] } else { ["jj-x-abcdefgh"] })
        stranded: ((pick $"($key)/stranded" 4) == 0)
    }
}

# The state the ownership rules allow: a claim exactly while a session is
# active, with that session's change checked out, in any workspace.
def consistent [facts: record] {
    $facts | merge {
        exists: true error: null
        claim: ($facts.owner == "active")
        owner_checked_out: ($facts.owner == "active" or $facts.owner_checked_out)
        legacy: false
        stranded: false
    }
}

owner-status-properties {|record| owner-status $record }

for-all "every finding has a known severity and a fix" {|key|
    for finding in (audit-findings (gen-audit-facts $key)) {
        assert ($finding.severity in $SEVERITIES) $"unknown severity ($finding.severity)"
        assert ($finding.fix | is-not-empty) $"($finding.code) names no fix"
        assert ($finding.workspace | is-not-empty)
    }
}

for-all "a workspace the invariants allow has no errors" {|key|
    let findings = (audit-findings (consistent (gen-audit-facts $key)))
    assert equal ($findings | where severity == "error") []
}

# Each ownership invariant, broken on its own, is reported as an error.

for-all "an active claim on a change not checked out is an orphaned claim" {|key|
    let facts = (consistent (gen-audit-facts $key) | merge { owner: "active" owner_checked_out: false })
    assert ("orphaned-claim" in (audit-findings $facts | get code))
}

for-all "a claim without an active task is a leftover claim" {|key|
    let facts = (consistent (gen-audit-facts $key) | merge {
        owner: (pick-from $"($key)/ended" ["none" "delivered" "discarded" "released"])
        claim: true
    })
    assert ("leftover-claim" in (audit-findings $facts | get code))
}

for-all "a legacy record is never trusted as delivered" {|key|
    let facts = (consistent (gen-audit-facts $key) | merge { owner: "released" legacy: true })
    assert ("legacy-record" in (audit-findings $facts | get code))
}

for-all "errors appear only when an invariant is broken" {|key|
    let facts = (gen-audit-facts $key)
    let errors = (audit-findings $facts | where severity == "error" | get code)
    let broken = (
        not $facts.exists
        or $facts.error != null
        or $facts.stranded
        or ($facts.owner == "active" and not $facts.owner_checked_out)
        or ($facts.claim and $facts.owner != "active")
    )
    assert equal ($errors | is-not-empty) $broken
    assert ($errors | all {|code| $code in $ERROR_CODES })
}

for-all "a working copy off its recorded topic is reported" {|key|
    let facts = (consistent (gen-audit-facts $key) | merge { stranded: true })
    assert ("stranded-topic" in (audit-findings $facts | get code))
}

# context-status and the `ci` guard must agree on when a topic is stranded.
for-all "topic-stranded matches the guard in ci.nu" {|key|
    let flag = {|name| (pick $"($key)/($name)" 2) == 0 }
    let facts = { recorded: (do $flag recorded) visible: (do $flag visible) landed: (do $flag landed) ancestor: (do $flag ancestor) working_copy_empty: (do $flag wc) topic_empty: (do $flag empty) }
    let expected = ($facts.recorded and $facts.visible and not $facts.landed and not $facts.ancestor and $facts.working_copy_empty and not $facts.topic_empty)
    assert equal (topic-stranded $facts) $expected
}

def gen-edit-facts [key: string] {
    {
        workspace: (flag $"($key)/workspace")
        worktree: (flag $"($key)/worktree")
        dedicated: (flag $"($key)/dedicated")
        ignored: (flag $"($key)/ignored")
        owner: (pick-from $"($key)/owner" ["none" "active" "delivered" "discarded" "released"])
        same_session: (flag $"($key)/same")
        idle: (pick-from $"($key)/idle" [null 1min 30min 3day])
        free: (flag $"($key)/free")
        adoptable: (flag $"($key)/adoptable")
    }
}

# A tracked file in a workspace of a repository with topic workspaces: the
# edits the claim rules decide.
def gen-guarded-facts [key: string] {
    gen-edit-facts $key | merge { workspace: true worktree: false dedicated: true ignored: false }
}

for-all "edit-verdict returns a known action, with a reason when it denies" {|key|
    let verdict = (edit-verdict (gen-edit-facts $key))
    assert ($verdict.action in ["allow" "claim" "deny"]) $"unknown action ($verdict.action)"
    assert equal ($verdict.reason != null) ($verdict.action == "deny")
}

for-all "edits are never refused where no topic workspaces exist" {|key|
    let facts = (gen-edit-facts $key)
    if not $facts.workspace or not $facts.dedicated {
        assert equal (edit-verdict $facts).action "allow"
    }
}

for-all "a Git worktree's edits are refused wherever topic workspaces exist" {|key|
    let facts = (gen-edit-facts $key | merge { workspace: true worktree: true dedicated: true })
    assert equal (edit-verdict $facts) { action: "deny" reason: "worktree" }
}

for-all "an ignored file is editable in any workspace" {|key|
    let facts = (gen-guarded-facts $key | merge { ignored: true })
    assert equal (edit-verdict $facts).action "allow"
}

for-all "a session edits freely where it owns the change" {|key|
    let facts = (gen-guarded-facts $key | merge { owner: "active" same_session: true })
    assert equal (edit-verdict $facts).action "allow"
}

# The default checkout is not special: any workspace idle on trunk is free.
for-all "the first session to edit a free workspace claims it" {|key|
    let facts = (gen-guarded-facts $key | merge {
        owner: (pick-from $"($key)/ended" ["none" "delivered" "discarded" "released"])
        free: true
    })
    assert equal (edit-verdict $facts).action "claim"
}

for-all "a session never edits another live session's workspace" {|key|
    let facts = (gen-guarded-facts $key | merge { owner: "active" same_session: false })
    let limit = if $facts.free { 10min } else { 2day }
    if $facts.idle == null or $facts.idle < $limit {
        assert equal (edit-verdict $facts) { action: "deny" reason: "owned" }
    }
}

# A stale record never holds a workspace forever.
for-all "a quiet session's workspace can be taken over" {|key|
    let facts = (gen-guarded-facts $key | merge { owner: "active" same_session: false idle: 3day })
    assert equal (edit-verdict $facts).action "claim"
}

for-all "a session paused briefly keeps work it started" {|key|
    let facts = (gen-guarded-facts $key | merge { owner: "active" same_session: false free: false idle: 30min })
    assert equal (edit-verdict $facts).action "deny"
}

for-all "a topic nobody owns or handed over is never claimed" {|key|
    let facts = (gen-guarded-facts $key | merge {
        owner: (pick-from $"($key)/ended" ["none" "delivered" "discarded" "released"])
        free: false
        adoptable: false
    })
    assert equal (edit-verdict $facts) { action: "deny" reason: "occupied" }
}

for-all "a handed-over topic is claimed by the next session" {|key|
    let facts = (gen-guarded-facts $key | merge {
        owner: (pick-from $"($key)/ended" ["none" "delivered" "discarded" "released"])
        adoptable: true
    })
    assert equal (edit-verdict $facts).action "claim"
}

for-all "a claim never takes a workspace from a live owner" {|key|
    let facts = (gen-guarded-facts $key)
    if (edit-verdict $facts).action == "claim" and $facts.owner == "active" {
        assert (not $facts.same_session)
        assert ($facts.idle != null and $facts.idle >= 10min) "took over a session that was just active"
    }
}

for-all "a session's Git worktree is found inside the workspace, never above it" {|key|
    let base = (mktemp --directory --tmpdir "context-status-worktree.XXXXXX" | path expand)
    let root = ($base | path join "repo")
    let worktree = ($root | path join ".claude" "worktrees" "session")
    let inner = (0..<(pick $"($key)/depth" 3) | reduce --fold $worktree {|level, dir| $dir | path join $"d($level)" })
    mkdir ($root | path join ".jj") $inner ($root | path join "src")
    # A linked worktree's .git is a file; one above the workspace never counts.
    "gitdir: elsewhere" | save ($worktree | path join ".git")
    "gitdir: outside" | save ($base | path join ".git")
    let found = (enclosing-git-worktree $inner $root)
    let outside = (enclosing-git-worktree ($root | path join "src") $root)
    let at_root = (enclosing-git-worktree $root $root)
    rm --recursive $base
    assert equal $found $worktree
    assert equal $outside null
    assert equal $at_root null
}

for-all "only JJ's stale working copy error counts as stale" {|key|
    let stale = "Error: The working copy is stale (not updated since operation 2206fd5bc752).\nHint: Run `jj workspace update-stale` to update it."
    let message = (pick-from $"($key)/message" [
        $stale
        "Attempted recovery, but the working copy is not stale."
        "Error: There is no jj repo in \".\""
        ""
    ])
    assert equal (stale-working-copy $message) ($message == $stale)
}

for-all "unpublished work above trunk is always surfaced" {|key|
    let facts = (consistent (gen-audit-facts $key) | merge { stack: (1 + (pick $"($key)/n" 3)) published: false })
    assert ("unpublished-work" in (audit-findings $facts | get code))
}
