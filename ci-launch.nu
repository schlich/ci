# `ci` chooses which ci.nu to run each time it starts. The installed package,
# the dev shell, and the MCP server all start here; only this launcher is
# frozen at build time.
#
# Other repositories run the copy bundled with the package, the version their
# flake.lock pins, and move to a newer one deliberately. Inside the ci
# repository itself, a topic that edits ci.nu runs its own copy, so a change
# to the workflow is exercised before it lands, and any other workspace runs
# main@tangled's copy, which an older workspace may not have checked out yet.
# CI_SCRIPT names a ci.nu to run instead, from any repository, while
# developing the workflow.

const TRUNK = "main@tangled"
const SCRIPT = "ci.nu"
# Beside ci.nu, it marks the ci repository rather than any project that
# happens to keep a ci.nu at its root.
const LAUNCHER = "ci-launch.nu"

# Which copy to run, from what the workspace shows: `override`, `bundled`,
# `topic`, or `trunk`. A workspace whose trunk copy cannot be read (no fetch
# yet, or a stale working copy that `ci` itself reports) runs its own.
def launch-choice [facts: record] {
    if $facts.override { return "override" }
    if not $facts.has_script { return "bundled" }
    if $facts.topic_edits { return "topic" }
    if not $facts.trunk_readable { return "topic" }
    "trunk"
}

# The trunk copy, stored under its hash so concurrent launches agree on a path
# and never read a half-written file.
def cached-trunk-script [source: string] {
    let cache = ($env.XDG_CACHE_HOME? | default ($env.HOME | path join ".cache") | path join "ci")
    mkdir $cache
    let script = ($cache | path join $"ci-($source | hash sha256).nu")
    if not ($script | path exists) {
        let partial = $"($script).(random uuid)"
        $source | save $partial
        mv --force $partial $script
    }
    $script
}

# Whether JJ refused to run because this workspace is stale: another
# workspace rewrote the change checked out here.
def stale-working-copy [stderr: string] {
    $stderr | str contains "working copy is stale"
}

def --wrapped main [...args] {
    let bundled = $env.CI_BUNDLED_SCRIPT
    let override = ($env.CI_SCRIPT? | default "")
    let root = (^jj root | complete)
    let checkout = if $root.exit_code == 0 { $root.stdout | str trim } else { "" }
    let local = if ($checkout | is-empty) { "" } else { $checkout | path join $SCRIPT }
    let has_script = ($local | is-not-empty) and ($local | path exists) and ($checkout | path join $LAUNCHER | path exists)
    let changes = {|| ^jj log --no-graph -r $"($TRUNK)..@ & files\(root:\"($SCRIPT)\")" -T 'change_id ++ "\n"' | complete }
    let first = if $has_script { do $changes } else { { exit_code: 1 stdout: "" stderr: "" } }
    # Update a stale workspace before anything else runs here; update-stale
    # never overwrites a file edited since JJ last snapshotted it.
    let edits = if $first.exit_code != 0 and (stale-working-copy $first.stderr) {
        let updated = (^jj workspace update-stale | complete)
        if $updated.exit_code == 0 {
            print --stderr "ci: another workspace had rewritten this one's change; updated its files first."
            do $changes
        } else { $first }
    } else { $first }
    let trunk = if $has_script and $edits.exit_code == 0 {
        ^jj file show -r $TRUNK $"root:\"($SCRIPT)\"" | complete
    } else { { exit_code: 1 stdout: "" } }
    let choice = (launch-choice {
        override: ($override | is-not-empty)
        has_script: $has_script
        topic_edits: ($edits.exit_code == 0 and ($edits.stdout | str trim | is-not-empty))
        trunk_readable: ($trunk.exit_code == 0)
    })
    let script = match $choice {
        "override" => ($override | path expand)
        "bundled" => $bundled
        "topic" => $local
        "trunk" => (cached-trunk-script $trunk.stdout)
    }
    match $choice {
        "override" => { print --stderr $"ci: running ($script) from CI_SCRIPT." }
        "topic" if $trunk.exit_code == 0 => { print --stderr $"ci: running this topic's ($SCRIPT), not ($TRUNK)'s." }
        _ => {}
    }
    # This nu has already parsed NU_LIB_DIRS into a list, which `exec` does
    # not pass on as the script's module path, so hand it over explicitly.
    let lib_dirs = ($env.NU_LIB_DIRS? | default [] | each {|dirs| $dirs | split row (char esep) } | flatten | where {|dir| $dir | is-not-empty })
    let include = if ($lib_dirs | is-empty) { [] } else { ["--include-path" ($lib_dirs | str join (char record_sep))] }
    exec $nu.current-exe --no-config-file ...$include $script ...$args
}
