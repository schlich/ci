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

for-all "a topic that edits ci.nu or its agent always runs its own copy" {|key|
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

# The agent beside the chosen copy (2026-10-16): main's ci.nu called a
# ci-agent the installed package did not have yet.
def gen-agent-facts [key: string] {
    {
        script: (pick-from $"($key)/script" ["override" "bundled" "topic" "trunk"])
        has_agent: (flag $"($key)/agent")
        matches_package: (flag $"($key)/matches")
        cached: (flag $"($key)/cached")
    }
}

for-all "the package's agent runs beside every copy not taken from the repository" {|key|
    let facts = (gen-agent-facts $key)
    if $facts.script in ["override" "bundled"] { assert equal (agent-choice $facts) "package" }
}

for-all "an agent whose sources match the package's is never built" {|key|
    let facts = (gen-agent-facts $key | upsert matches_package true)
    assert equal (agent-choice $facts) "package"
}

for-all "a repository copy with a different agent gets that agent, built at most once" {|key|
    let facts = (gen-agent-facts $key)
    let differs = ($facts.script in ["topic" "trunk"]) and $facts.has_agent and (not $facts.matches_package)
    let choice = (agent-choice $facts)
    assert equal ($choice != "package") $differs
    if $differs { assert equal $choice (if $facts.cached { "cached" } else { "build" }) }
}

for-all "bookmarks are exported from the workspace ci ran in, else from the repository's home" {|key|
    let facts = {
        checkout: "/repo/.jj-workspaces/topic"
        checkout_exists: (flag $"($key)/checkout")
        home: "/repo"
        home_exists: (flag $"($key)/home")
    }
    let expected = if $facts.checkout_exists { $facts.checkout } else if $facts.home_exists { $facts.home } else { null }
    assert equal (export-root $facts) $expected
}

# A secondary workspace's `.jj/repo` names the home's `.jj/repo` relative to
# its own `.jj`, the way `ci start` and `jj workspace add` write it.
let home = (mktemp --directory)
mkdir ($home | path join ".jj" "repo")
let secondary = ($home | path join ".jj-workspaces" "topic")
mkdir ($secondary | path join ".jj")
"../../../.jj/repo" | save ($secondary | path join ".jj" "repo")
assert equal (repo-home $home) $home
assert equal (repo-home $secondary) ($home | path expand)
assert equal (repo-home "") ""
assert equal (repo-home ($home | path join "elsewhere")) ""
rm --recursive $home
print "ok repo home"

# `ci park` removing the workspace it ran in exited 1 (2026-10-19): the
# launcher still stood in the deleted directory when ci.nu returned. The
# child's own status comes back, and the launcher can still run commands.
let start = $env.PWD
let home = (mktemp --directory)
for code in [0 3] {
    let doomed = ($home | path join ".jj-workspaces" "topic")
    mkdir $doomed
    cd $doomed
    let status = (run-in $doomed $home $nu.current-exe [--no-config-file -c $"cd /; rm --recursive '($doomed)'; exit ($code)"])
    assert equal $status $code
    assert equal $env.PWD $home
    assert not ($doomed | path exists)
    assert equal (^$nu.current-exe --no-config-file -c "print ok" | str trim) "ok"
}
cd $start
rm --recursive $home
print "ok run from a removed workspace"

# ci-package.nix hashes the agent's files in this order, which must be the
# order `jj file show` prints them in, so a revision whose agent matches the
# package's is recognised without a build.
assert equal $AGENT_FILES ($AGENT_FILES | sort)
assert ($AGENT_FILES | all {|file| $file | str starts-with $"($AGENT)/" })
print "ok agent files"
