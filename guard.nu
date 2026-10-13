# Interactive guard for workspaces that `ci start` created. A bare
# `jj new main` there moves the working copy off an unfinished topic, which
# then sits beside main while `ci` works on an empty change. This refuses a
# `jj new` whose parents do not descend from the unlanded working copy. `^jj`
# runs JJ directly and skips the guard.

# The parents a `jj new` invocation would give the new working-copy change, or
# null when it does not move this workspace's working copy off `@`: another
# subcommand, `--no-edit`, an insertion before a commit, or options that act on
# another repository or operation.
def jj-new-parents [args: list<string>] {
    if ($args | first | default "") != "new" { return null }
    const VALUE_FLAGS = ["-m" "--message" "-A" "--insert-after" "--after" "-o" "-r" "--color" "--config" "--config-file"]
    const TARGET_FLAGS = ["-A" "--insert-after" "--after" "-o" "-r"]
    const SKIP_FLAGS = ["--no-edit" "-B" "--insert-before" "--before" "-R" "--repository" "--at-operation" "--at-op" "--ignore-working-copy" "-h" "--help"]
    mut parents: list<string> = []
    mut expecting: any = null
    for arg in ($args | skip 1) {
        if $expecting != null {
            if $expecting in $TARGET_FLAGS { $parents = ($parents | append $arg) }
            $expecting = null
            continue
        }
        let flag = ($arg | split row "=" | first)
        if $flag in $SKIP_FLAGS { return null }
        if ($arg | str starts-with "-") {
            if $arg =~ "=" {
                if $flag in $TARGET_FLAGS { $parents = ($parents | append ($arg | str replace $"($flag)=" "")) }
            } else if $flag in $VALUE_FLAGS {
                $expecting = $flag
            }
            continue
        }
        $parents = ($parents | append $arg)
    }
    if ($parents | is-empty) { null } else { $parents }
}

# Why this `jj new` would strand the topic, or null when it may run.
def jj-new-refusal [parents: list<string>] {
    let root = (^jj root | complete)
    if $root.exit_code != 0 { return null }
    let marker = ($root.stdout | str trim | path join ".jj" "jj-ci-workspace.json")
    if not ($marker | path exists) { return null }
    let revset = ($parents | each {|parent| $"\(($parent)\)" } | str join " | ")
    # Unfinished work: a working copy above trunk that holds changes or a
    # description. An empty undescribed one is simply replaced.
    let stranded = (^jj log --no-graph -r $"@ ~ ::main@tangled ~ \(empty\() & description\(exact:\"\"\)\) ~ ::\(($revset)\)" -T 'change_id.short() ++ "\t" ++ description.first_line()' | complete)
    # A revset JJ cannot resolve is left for `jj new` itself to report.
    if $stranded.exit_code != 0 { return null }
    let found = ($stranded.stdout | str trim)
    if ($found | is-empty) { return null }
    let fields = ($found | split row "\t")
    let title = ($fields | get -o 1 | default "")
    $"the new change would not descend from this workspace's unfinished topic ($fields | first) \"($title)\""
}

@complete external
def --wrapped jj [...args: string] {
    let parents = (jj-new-parents $args)
    if $parents != null {
        let refusal = (jj-new-refusal $parents)
        if $refusal != null {
            error make {
                msg: $"Refusing `jj ($args | str join ' ')`: ($refusal)."
                help: "Keep working here with `jj new` or `jj new --no-edit`, start other work with `ci start NAME`, end the topic with `ci park` or `ci cancel`, or run `^jj` to leave the topic on purpose."
            }
        }
    }
    ^jj ...$args
}
