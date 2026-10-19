# Property-based tests for `ci shape`: how a topic's diffs become the units
# Jev judges, and how its answers become advice. A stub stands in for Jev, so
# nothing leaves the machine. Run with:
#
#   nu --no-config-file -c "source tests/shape-properties.nu"
#
# tests/pbt.nu holds the generators and the runner.

use std/assert
source pbt.nu
source ../ci.nu

$env.CI_LOG = (mktemp --tmpdir shape-properties-log-XXXXXX)

const DIRECTORIES = ["" "src" "src/lib" "docs" "docs/guide/deep" "tests" "dir with space"]
const NAMES = ["main.nu" "README.md" "flake.lock" "notes.txt" "x"]

# A probability in steps of 0.01, or null for an answer Jev did not give.
def gen-p [key: string] {
    if (pick $"($key)/missing" 8) == 0 { null } else { (pick $key 101) / 100 }
}

# Changed files with unique paths, as git-diff-files returns them, and the
# kind of change each one is.
def gen-files [key: string, max: int] {
    0..<(pick $"($key)/count" ($max + 1)) | each {|i|
        let directory = (pick-from $"($key)/dir/($i)" $DIRECTORIES)
        let name = $"($i)-(pick-from $'($key)/name/($i)' $NAMES)"
        let kind = (pick-from $"($key)/kind/($i)" ["modified" "added" "deleted"])
        # Content lines that look like diff headers must still count.
        let line = {|j| pick-from $"($key)/line/($i)/($j)" ["text" "++ b/fake" "-- a/fake" "@@ not a hunk" ""] }
        {
            path: (if ($directory | is-empty) { $name } else { $"($directory)/($name)" })
            kind: $kind
            added: (if $kind == "deleted" { [] } else { 0..<(pick $"($key)/added/($i)" 4) | each {|j| do $line $j } })
            removed: (if $kind == "added" { [] } else { 0..<(pick $"($key)/removed/($i)" 4) | each {|j| do $line ($j + 10) } })
        }
    }
}

# The Git-format diff `jj diff --git` prints for `files`.
def render-diff [files: list] {
    $files | each {|file|
        let old = if $file.kind == "added" { "/dev/null" } else { $"a/($file.path)" }
        let new = if $file.kind == "deleted" { "/dev/null" } else { $"b/($file.path)" }
        let mode = match $file.kind { "added" => ["new file mode 100644"] "deleted" => ["deleted file mode 100644"] _ => [] }
        let hunk = if ($file.added | is-empty) and ($file.removed | is-empty) { [] } else {
            let header = $"@@ -1,($file.removed | length) +1,($file.added | length) @@"
            [$header] ++ ($file.removed | each {|line| $"-($line)" }) ++ ($file.added | each {|line| $"+($line)" })
        }
        [$"diff --git a/($file.path) b/($file.path)"] ++ $mode ++ ["index 0000000..1111111"] ++ (if ($hunk | is-empty) { [] } else { [$"--- ($old)" $"+++ ($new)"] }) ++ $hunk
    } | flatten | str join "\n"
}

for-all "git-diff-files reads back every file of a diff" {|key|
    let files = (gen-files $key 6)
    let parsed = (git-diff-files (render-diff $files))
    assert equal ($parsed | get --optional path | default []) ($files | get --optional path | default [])
    for pair in ($files | zip $parsed) {
        assert equal $pair.1.added ($pair.0.added | length) $"added lines of ($pair.0.path)"
        assert equal $pair.1.removed ($pair.0.removed | length) $"removed lines of ($pair.0.path)"
    }
}

for-all "shape-units puts every file in exactly one unit within the budget" {|key|
    let files = (gen-files $key 40 | each {|file| { path: $file.path added: ($file.added | length) removed: ($file.removed | length) diff: ($file.added | str join "\n") } })
    let shape = ($SHAPE | merge {
        max_units: (1 + (pick $"($key)/max" 12))
        max_state_chars: (50 + (pick $"($key)/budget" 400))
        max_excerpt_chars: (20 + (pick $"($key)/excerpt" 200))
    })
    let units = (shape-units $files $shape)
    if ($units | is-empty) {
        assert (($files | is-empty) or ($files | length) > $shape.max_units) "a small revision got no units"
        return
    }
    assert (($units | length) <= $shape.max_units) $"($units | length) units for at most ($shape.max_units)"
    assert equal ($units | each {|unit| $unit.paths } | flatten | sort) ($files | get path | sort) "a file was lost or doubled"
    let room = ([$shape.max_excerpt_chars ($shape.max_state_chars // ($units | length))] | math min)
    for unit in $units {
        assert (($unit.diff | str length --grapheme-clusters) <= ($room + 8)) $"($unit.name)'s diff exceeds its room of ($room)"
        assert equal $unit.added ($files | where path in $unit.paths | get added | math sum)
    }
}

# Units a revision's split request names, with answers Jev may have given.
def gen-split-case [key: string] {
    let count = (pick $"($key)/units" 6)
    let units = (0..<$count | each {|i| { name: $"u($i)" kind: "file" paths: [$"u($i)"] added: 1 removed: 0 diff: "+x" } })
    let answers = if (pick $"($key)/failed" 10) == 0 { null } else {
        0..<$count | reduce --fold { mixed: { noul: (gen-p $"($key)/mixed") } } {|i, answers|
            $answers | insert $"unit_($i)" { noul: (gen-p $"($key)/unit/($i)") }
        }
    }
    { units: $units answers: $answers }
}

for-all "shape-split-verdict splits only a confident mix with units on both sides" {|key|
    let case = (gen-split-case $key)
    let result = (shape-split-verdict $case.units $case.answers $SHAPE)
    let mixed = (shape-noul $case.answers "mixed")
    assert equal ($result.verdict == "unjudged") ($mixed == null) "unjudged must mean no mixed answer"
    if $result.verdict == "unjudged" { return }
    if ($case.units | length) >= 2 {
        assert equal ($result.moved ++ $result.kept | get name | sort) ($case.units | get name | sort) "moved and kept must partition the units"
    }
    for unit in $result.moved {
        assert ($unit.on_topic != null and $unit.on_topic <= $SHAPE.max_on_topic) $"($unit.name) moved at ($unit.on_topic)"
    }
    match $result.verdict {
        "split" => {
            assert ($mixed >= $SHAPE.min_mixed) $"split at mixed ($mixed)"
            assert (($result.moved | is-not-empty) and ($result.kept | is-not-empty)) "a split must leave units on both sides"
        }
        "by-hunk" => { assert (($mixed >= $SHAPE.min_mixed) and ($case.units | length) == 1) "by-hunk needs one confidently mixed unit" }
        "keep" => { assert (($mixed < 0.5) and ($result.moved | is-empty)) $"kept at mixed ($mixed)" }
        "unsure" => {}
        _ => { error make { msg: $"unknown verdict ($result.verdict)" } }
    }
}

for-all "shape-placement places a split only when the parts' needs are clear" {|key|
    let moved_needs = (gen-p $"($key)/moved")
    let kept_needs = (gen-p $"($key)/kept")
    let placement = (shape-placement { moved_needs_kept: { noul: $moved_needs } kept_needs_moved: { noul: $kept_needs } } $SHAPE)
    let alone = 1 - $SHAPE.min_needs
    let expected = if $moved_needs == null or $kept_needs == null {
        null
    } else if $moved_needs >= $SHAPE.min_needs and $kept_needs < $alone {
        "after"
    } else if $kept_needs >= $SHAPE.min_needs and $moved_needs < $alone {
        "before"
    } else if $moved_needs < $alone and $kept_needs < $alone {
        "trunk"
    } else {
        null
    }
    assert equal $placement $expected $"moved needs ($moved_needs), kept needs ($kept_needs)"
}

# A topic of `count` revisions, the pairs compared, and Jev's relations for
# some of them.
def gen-pair-case [key: string] {
    let count = (1 + (pick $"($key)/count" 7))
    let pairs = (shape-pairs $count (2 + (pick $"($key)/max" 8)))
    let relations = ($pairs | enumerate | where {|entry| (pick $"($key)/answered/($entry.index)" 6) != 0 } | each {|entry|
        $entry.item
        | insert relation (pick-from $"($key)/relation/($entry.index)" ["fixup" "builds_on" "independent"])
        | insert confidence ((pick $"($key)/confidence/($entry.index)" 101) / 100)
    })
    { count: $count pairs: $pairs relations: $relations }
}

for-all "shape-pair-verdicts squashes only confident fixups, each into one revision" {|key|
    let case = (gen-pair-case $key)
    let verdicts = (shape-pair-verdicts $case.count $case.pairs $case.relations $SHAPE)
    let laters = ($verdicts.squashes | each {|squash| $squash.later })
    assert equal ($laters | uniq | length) ($laters | length) "a revision squashed twice"
    for squash in $verdicts.squashes {
        assert ($squash.relation == "fixup" and $squash.confidence >= $SHAPE.min_relation_confidence and $squash.earlier < $squash.later) $"bad squash ($squash)"
        let best = ($case.relations | where {|relation| $relation.later == $squash.later and $relation.relation == "fixup" } | get confidence | math max)
        assert equal $squash.confidence $best $"($squash.later) squashed into a weaker fixup"
    }
    assert equal $laters ($laters | sort --reverse) "squashes must run newest first"
}

for-all "shape-pair-verdicts separates only revisions nothing ties to the rest" {|key|
    let case = (gen-pair-case $key)
    let verdicts = (shape-pair-verdicts $case.count $case.pairs $case.relations $SHAPE)
    let complete = ($case.pairs | length) == ($case.count * ($case.count - 1) // 2)
    if not $complete {
        assert equal $verdicts.groups [] "a topic compared only by neighbours separated revisions"
        return
    }
    let independent = ($case.relations | where {|relation| $relation.relation == "independent" and $relation.confidence >= $SHAPE.min_relation_confidence })
    let separated = ($verdicts.groups | flatten)
    assert equal ($separated | uniq | length) ($separated | length) "a revision is in two groups"
    assert (0 not-in $separated) "the first revision was separated"
    for group in $verdicts.groups {
        for inside in $group {
            for outside in (0..<$case.count | where {|index| $index not-in $group }) {
                let earlier = ([$inside $outside] | math min)
                let later = ([$inside $outside] | math max)
                let free = ($independent | any {|relation| $relation.earlier == $earlier and $relation.later == $later })
                assert $free $"($inside) moves away from ($outside) without a confident independent relation"
            }
        }
    }
}

for-all "shape-advice commands name only the topic's revisions and moved files" {|key|
    let case = (gen-pair-case $key)
    let revisions = (0..<$case.count | each {|i| { short: $"r($i)" description: $"revision ($i)" units: [] } })
    let splits = (0..<$case.count | each {|i|
        let split = (gen-split-case $"($key)/split/($i)")
        shape-split-verdict $split.units $split.answers $SHAPE
        | insert placement (pick-from $"($key)/placement/($i)" ["trunk" "before" "after" null])
    })
    let advice = (shape-advice $revisions $splits $case.pairs $case.relations $SHAPE)
    let shorts = ($revisions | get short)
    let squashed = ($advice.advice | where action == "squash" | each {|item| $item.revisions } | flatten)
    for item in $advice.advice {
        assert (($item.revisions | all {|short| $short in $shorts })) $"($item.action) names unknown revisions"
        if $item.action == "split" {
            assert ($item.revisions.0 not-in $squashed) "a squashed revision was also split"
            let split = ($splits | get ($shorts | enumerate | where item == $item.revisions.0 | get 0.index))
            let filesets = ($item.argv | where {|arg| $arg | str starts-with "root-file:" })
            assert equal $filesets ($split.moved | each {|unit| $unit.paths } | flatten | each {|path| shape-fileset $path }) "the split moves other files"
            assert ("MESSAGE" in $item.argv) "a split must ask for a message"
        }
        if $item.argv != null {
            assert equal ($item.argv | first) "jj"
            assert ((shape-command $item.argv) | str starts-with "jj ") "the rendered command lost its program"
        }
    }
}

# End to end in a scratch repository, with a stub in place of `jev ask`: a
# revision that adds an unrelated file and a later revision that fixes the
# first one's typo. The advice must squash the fix and move the unrelated
# file to a topic of its own, and its commands must do exactly that.
let shape_repo = (mktemp --directory --tmpdir ci-shape-XXXXXX)
let shape_bin = (mktemp --directory --tmpdir ci-shape-jev-XXXXXX)
let shape_config = (mktemp --tmpdir ci-shape-jj-XXXXXX.toml)
'user.name = "ci"
user.email = "ci@example.invalid"
revset-aliases."trunk()" = "latest(present(main) | root())"
' | save --force $shape_config
let stub = ($shape_bin | path join "jev")
$"#!($nu.current-exe) --stdin
" + '
# Answers like Jev would for the scratch topic: notes.txt is unrelated to the
# greeting, and every later revision fixes up the earlier one.
def "main ask" [--model: string] {
    let request = ($in | from json)
    if ($env.STUB_JEV_FAIL? | default "") == "all" {
        print --stderr "jev is down"
        exit 1
    }
    let ids = ($request.questions | columns)
    if ($env.STUB_JEV_FAIL? | default "") == "pairs" and ($ids | any {|id| $id | str starts-with "pair_" }) {
        print --stderr "pairs are down"
        exit 1
    }
    let state = $request.state
    let answers = ($ids | reduce --fold {} {|id, answers|
        let answer = if $id == "mixed" {
            { noul: (if ($state.revision.units | any {|unit| $unit.name == "notes.txt" }) { 0.9 } else { 0.1 }) }
        } else if ($id | str starts-with "unit_") {
            let index = ($id | str replace "unit_" "" | into int)
            { noul: (if ($state.revision.units | get $index | get name) == "notes.txt" { 0.05 } else { 0.95 }) }
        } else if ($id | str starts-with "pair_") {
            { choice: "fixup" confidence: 0.9 }
        } else {
            { noul: 0.1 }
        }
        $answers | insert $id $answer
    })
    { answers: $answers model: $model usage: { input_tokens: 10 } } | to json --raw
}

def main [] {}
' | save --force $stub
chmod +x $stub

with-env { XDG_STATE_HOME: $shape_bin JJ_CONFIG: $shape_config CI_JEV: $stub } {
    cd $shape_repo
    ^jj git init --quiet
    "hello wrold\n" | save --force greeting.txt
    ^jj commit --quiet -m "base"
    ^jj bookmark create --quiet main -r @-
    "hello wrold, and welcome\n" | save --force greeting.txt
    "unrelated notes\n" | save --force notes.txt
    ^jj commit --quiet -m "Welcome visitors"
    let first = (^jj log --no-graph -r @- -T 'change_id.short()' | str trim)
    "hello world, and welcome\n" | save --force greeting.txt
    ^jj commit --quiet -m "Fix the greeting's typo"
    let second = (^jj log --no-graph -r @- -T 'change_id.short()' | str trim)

    let report = (shape-report "trunk()..@" $SHAPE)
    assert equal ($report.revisions | get change) [$first $second]
    assert equal ($report.advice | get action) ["squash" "split"] $"advice: ($report.advice | to nuon)"
    assert equal ($report.unjudged) []
    assert equal $report.input_tokens 40 "two split requests, one pair request, and one placement request"
    let squash = ($report.advice | first)
    assert equal $squash.argv ["jj" "squash" "--from" $second "--into" $first "--use-destination-message"]
    let split = ($report.advice | last)
    assert equal (shape-command $split.argv) $"jj split -r ($first) -o 'trunk\()' -m MESSAGE 'root-file:\"notes.txt\"'"

    run-external ...$squash.argv
    run-external ...($split.argv | each {|arg| if $arg == "MESSAGE" { "Keep notes" } else { $arg } })
    let kept = (^jj diff --name-only -r $first | lines)
    assert equal $kept ["greeting.txt"] "the split left the wrong files behind"
    assert equal (^jj file show -r $first greeting.txt | str trim) "hello world, and welcome" "the fixup was not squashed in"
    let notes = (^jj log --no-graph -r 'description(substring:"Keep notes")' -T 'change_id.short() ++ " " ++ parents.map(|p| p.change_id().short()).join(",")' | str trim | split row " ")
    assert equal (^jj diff --name-only -r ($notes | first) | lines) ["notes.txt"]
    assert equal ($notes | last) (^jj log --no-graph -r main -T 'change_id.short()' | str trim) "the unrelated file did not move to trunk"
    print "ok shape advice carries out end to end"

    # A failed pair request leaves the split advice and says what went unjudged.
    ^jj new --quiet main
    "a\n" | save --force greeting.txt
    "b\n" | save --force notes.txt
    ^jj commit --quiet -m "Greet and take notes"
    "c\n" | save --force greeting.txt
    ^jj commit --quiet -m "Greet again"
    let partial = (with-env { STUB_JEV_FAIL: "pairs" } { shape-report "trunk()..@" $SHAPE })
    assert equal ($partial.advice | get action) ["split"]
    assert equal ($partial.unjudged | get request) ["how the revisions relate"]
    assert ($partial.unjudged.0.error | str contains "pairs are down")
    print "ok shape reports what Jev could not judge"

    let down = (with-env { STUB_JEV_FAIL: "all" } { try { shape-report "trunk()..@" $SHAPE; null } catch {|err| $err.msg } })
    assert ($down != null and ($down | str contains "Jev could not judge the topic")) $"an unreachable Jev produced advice: ($down)"
    let missing = (with-env { CI_JEV: ($shape_bin | path join "no-such-jev") } { try { shape-report "trunk()..@" $SHAPE; null } catch {|err| $err.msg } })
    assert ($missing != null and ($missing | str contains "is not installed")) $"a missing jev produced advice: ($missing)"
    print "ok shape fails when Jev answers nothing"
}
rm --recursive --force $shape_repo $shape_bin $shape_config
