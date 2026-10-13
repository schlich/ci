# Property-based tests for the Codex session hook's claim decisions, derived
# from the ownership rules in README.md. Run with:
#
#   nu --no-config-file -c "source tests/codex-session-properties.nu"
#
# Sourcing through `-c` defines the hook's helpers without running its `main`.

source pbt.nu
source ../codex-session.nu

def gen-claim-facts [key: string] {
    {
        workspace: (pick-from $"($key)/workspace" ["default" "topic" "other"])
        dedicated: (flag $"($key)/dedicated")
        owner: (pick-from $"($key)/owner" ["none" "active" "delivered" "discarded" "released"])
        same_session: (flag $"($key)/same")
        claim: (flag $"($key)/claim")
        has_state: (flag $"($key)/state")
    }
}

owner-status-properties {|record| owner-status $record }

for-all "claim-verdict returns a known action with a reason when it declines" {|key|
    let verdict = (claim-verdict (gen-claim-facts $key))
    assert ($verdict.action in ["claim" "resume" "skip" "refuse"]) $"unknown action ($verdict.action)"
    if $verdict.action in ["skip" "refuse"] { assert ($verdict.reason | is-not-empty) }
}

# TLA: OwnerRecordMatchesSession. One active task per workspace.
for-all "no session takes over another session's active workspace" {|key|
    let facts = (gen-claim-facts $key | upsert owner "active" | upsert same_session false)
    assert equal (claim-verdict $facts).action "refuse"
}

# TLA: NoClaimOnSharedDefault.
for-all "no new task claims the canonical checkout of a repository with topic workspaces" {|key|
    let facts = (gen-claim-facts $key | upsert workspace "default" | upsert dedicated true)
    assert ((claim-verdict $facts).action != "claim")
}

# TLA: ClaimOnlyWhileActive. A leftover claim stops a new task instead of
# being silently reused or removed during a racing startup.
for-all "a new task never claims over a leftover claim" {|key|
    let facts = (gen-claim-facts $key | upsert claim true)
    assert ((claim-verdict $facts).action != "claim")
}

for-all "a session with a recorded workspace resumes unless another task owns it" {|key|
    let facts = (gen-claim-facts $key | upsert has_state true)
    let expected = if $facts.owner == "active" and not $facts.same_session { "refuse" } else { "resume" }
    assert equal (claim-verdict $facts).action $expected
}

# Liveness in the small: a free workspace is always claimable.
for-all "every free workspace can be claimed" {|key|
    let facts = (gen-claim-facts $key | merge {
        owner: (pick-from $"($key)/free" ["none" "delivered" "discarded" "released"])
        claim: false
        has_state: false
    })
    let shared_default = ($facts.workspace == "default" and $facts.dedicated)
    assert equal (claim-verdict $facts).action (if $shared_default { "skip" } else { "claim" })
}
