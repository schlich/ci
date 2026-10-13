# Shared generators and the runner for the property-based tests. Randomness
# is keyed by PBT_SEED, property name, and case number, so a failure report is
# enough to replay it exactly.

use std/assert

const CASES = 100
const TITLE_CHARS = ["a" "b" "z" "Q" "0" "7" " " "  " "-" "--" "_" "." "/" ":" "!" "é" "日"]
const CHANGE_CHARS = ["k" "l" "m" "n" "o" "p" "q" "r" "s" "t" "u" "v" "w" "x" "y" "z"]

def seed [] { $env.PBT_SEED? | default "0" }

# A deterministic integer in 0..<n for the given key.
def pick [key: string, n: int] {
    if $n <= 0 { return 0 }
    # The leading 1 keeps `into int` from reading a 0b or 0x prefix.
    let hex = ($key | hash sha256 | str substring 0..11)
    ($"1($hex)" | into int --radix 16) mod $n
}

def pick-from [key: string, items: list] {
    $items | get (pick $key ($items | length))
}

def flag [key: string] { (pick $key 2) == 0 }

def shuffle [key: string, items: list] {
    $items | enumerate | sort-by {|entry| pick $"($key)/($entry.index)" 1000000007 } | get item
}

# Half of the titles are long enough to exercise the 48-character cut.
def gen-title [key: string] {
    let length = if (pick $"($key)/long" 2) == 0 { 60 + (pick $"($key)/len" 60) } else { pick $"($key)/len" 40 }
    0..<$length
    | each {|i| pick-from $"($key)/($i)" $TITLE_CHARS }
    | str join
}

def gen-change-id [key: string] {
    0..<32 | each {|i| pick-from $"($key)/($i)" $CHANGE_CHARS } | str join
}

# An ownership record as any hook version wrote it: missing, legacy (only
# `finished`), current (`state` and `finished`), or hand-edited, with a state
# the reader may not know.
def gen-owner-record [key: string] {
    let shape = (pick-from $"($key)/shape" ["missing" "legacy" "current" "unknown"])
    let base = { session_id: $"s(pick $'($key)/session' 4)" change_id: (gen-change-id $"($key)/change") }
    match $shape {
        "missing" => null
        "legacy" => ($base | insert finished (flag $"($key)/finished"))
        "current" => {
            let state = (pick-from $"($key)/state" ["active" "delivered" "discarded" "released"])
            $base | insert state $state | insert finished ($state != "active")
        }
        _ => ($base | insert state (pick-from $"($key)/state" ["finished" "done" ""]) | insert finished (flag $"($key)/finished"))
    }
}

def for-all [name: string, property: closure] {
    for case in 0..<$CASES {
        let key = $"(seed)/($name)/($case)"
        try {
            do $property $key
        } catch {|error|
            error make { msg: $"property `($name)` failed at PBT_SEED=(seed) case ($case): ($error.msg)" }
        }
    }
    print $"ok ($name) \(($CASES) cases)"
}

# Every copy of owner-status must read records the same way, so each test file
# runs these properties against its own copy.
def owner-status-properties [status: closure] {
    for-all "owner-status only reports delivery that a record states" {|key|
        let record = (gen-owner-record $key)
        let result = (do $status $record)
        assert ($result in ["none" "active" "delivered" "discarded" "released"]) $"unknown status ($result)"
        if $result == "delivered" { assert equal $record.state? "delivered" }
        if $record == null { assert equal $result "none" }
    }
    for-all "owner-status reads a legacy finished record as released" {|key|
        let record = { session_id: "s" change_id: (gen-change-id $key) finished: (flag $"($key)/finished") }
        assert equal (do $status $record) (if $record.finished { "released" } else { "active" })
    }
    for-all "owner-status trusts a known state over finished" {|key|
        let state = (pick-from $"($key)/state" ["active" "delivered" "discarded" "released"])
        let record = { session_id: "s" change_id: (gen-change-id $key) state: $state finished: (flag $"($key)/finished") }
        assert equal (do $status $record) $state
    }
}
