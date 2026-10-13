# Property-based tests for context-status: its reading of ownership records
# and the audit's findings, which check the ownership rules in
# README.md against real workspaces. Run with:
#
#   nu --no-config-file -c "source tests/context-status-properties.nu"
#
# Sourcing through `-c` defines the helpers without running its `main`.

source pbt.nu
source ../context-status.nu

const ERROR_CODES = ["missing-workspace" "unreadable" "stranded-topic" "orphaned-claim" "leftover-claim" "shared-default-claim"]

def gen-audit-facts [key: string] {
    let owner = (pick-from $"($key)/owner" ["none" "active" "delivered" "discarded" "released"])
    {
        name: (pick-from $"($key)/name" ["default" "topic"])
        root: "/w"
        exists: ((pick $"($key)/exists" 8) != 0)
        error: (if (pick $"($key)/error" 8) == 0 { "stale" } else { null })
        default: (flag $"($key)/default")
        dedicated: (flag $"($key)/dedicated")
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

# The state the TLA+ invariants allow: a claim exactly while a task is
# active, that task's change checked out, and never on a shared default.
def consistent [facts: record] {
    $facts | merge {
        exists: true error: null
        claim: ($facts.owner == "active")
        owner_checked_out: ($facts.owner == "active" or $facts.owner_checked_out)
        default: ($facts.default and not ($facts.owner == "active" and $facts.dedicated))
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

for-all "a task on a shared canonical checkout is reported" {|key|
    let facts = (consistent (gen-audit-facts $key) | merge { owner: "active" default: true dedicated: true claim: true })
    assert ("shared-default-claim" in (audit-findings $facts | get code))
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
        or ($facts.claim != ($facts.owner == "active"))
        or ($facts.owner == "active" and $facts.default and $facts.dedicated)
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
        default: (flag $"($key)/default")
        dedicated: (flag $"($key)/dedicated")
        ignored: (flag $"($key)/ignored")
    }
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

for-all "only tracked edits to the shared default checkout are refused" {|key|
    let facts = (gen-edit-facts $key | merge { workspace: true worktree: false dedicated: true })
    let expected = if $facts.default and not $facts.ignored { "deny" } else { "allow" }
    assert equal (edit-verdict $facts).action $expected
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
