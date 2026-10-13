# Property-based tests for which ci.nu the `ci` launcher runs. Run with:
#
#   nu --no-config-file -c "source tests/ci-launch-properties.nu"

source pbt.nu
source ../ci-launch.nu

def gen-launch-facts [key: string] {
    {
        override: (flag $"($key)/override")
        has_script: (flag $"($key)/script")
        topic_edits: (flag $"($key)/edits")
        trunk_readable: (flag $"($key)/trunk")
    }
}

for-all "CI_SCRIPT always wins" {|key|
    let facts = (gen-launch-facts $key | upsert override true)
    assert equal (launch-choice $facts) "override"
}

for-all "the bundled copy runs exactly outside the ci repository" {|key|
    let facts = (gen-launch-facts $key | upsert override false)
    assert equal ((launch-choice $facts) == "bundled") (not $facts.has_script)
}

for-all "a topic that edits ci.nu always runs its own copy" {|key|
    let facts = (gen-launch-facts $key | upsert override false | upsert has_script true | upsert topic_edits true)
    assert equal (launch-choice $facts) "topic"
}

for-all "only JJ's stale working copy error makes the launcher update the workspace" {|key|
    let stale = "Error: The working copy is stale (not updated since operation 9791d5336f18).\nHint: Run `jj workspace update-stale` to update it."
    let stderr = (pick-from $"($key)/stderr" [
        $stale
        "Error: Revision `main@tangled` doesn't exist"
        "Attempted recovery, but the working copy is not stale."
        ""
    ])
    assert equal (stale-working-copy $stderr) ($stderr == $stale)
}

for-all "every other ci workspace runs the trunk copy when it can read it" {|key|
    let facts = (gen-launch-facts $key | upsert override false)
    let trunk = $facts.has_script and (not $facts.topic_edits) and $facts.trunk_readable
    assert equal ((launch-choice $facts) == "trunk") $trunk
}
