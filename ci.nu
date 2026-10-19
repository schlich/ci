use pst

# Report this run's progress as OSC 7501 program status: to the terminal when
# stdout is one, and as a JSON line to $env.PST_FILE when it is set, which
# `watch-job` follows. A plain run writes nothing, and a report that cannot be
# written never fails the run.
def report-status [state: string, msg?: string, --id: string, --kind: string] {
    let text = if $msg == null { null } else {
        $msg | str replace --all --regex '[\x00-\x1f\x7f-\x9f]+' ' ' | str trim | str substring 0..<500
    }
    try {
        pst report $state --app ci --id=$id --msg=$text --kind=$kind
    } catch {|err|
        print --stderr $"ci: could not report status: ($err.msg)"
    }
    # A run's final clear only drops its records; a clear under an id ends a
    # wait, which its trace times.
    if $state != "clear" or $id != null {
        let severity = match $state { "error" => "ERROR" "blocked" => "WARN" _ => "INFO" }
        log-event "ci.status" ($text | default $state) { "ci.status.state": $state "ci.status.id": $id "ci.status.kind": $kind } --severity $severity
    }
}

# Every ci action is also an OpenTelemetry log record: each line of the ci log
# is one OTLP/JSON ExportLogsServiceRequest, the format the Collector's
# otlpjsonfile receiver reads. When OTEL_EXPORTER_OTLP_LOGS_ENDPOINT or
# OTEL_EXPORTER_OTLP_ENDPOINT is set, each record is also posted there. The
# log is this machine's record of what ci did, shared by every repository and
# workspace; CI_LOG moves it. context-status.nu and tower/src/log.rs read it
# too, so change a record's shape in every reader at once.
const SEVERITY_NUMBERS = { DEBUG: 5 INFO: 9 WARN: 13 ERROR: 17 }

def ci-log-path [] {
    if ($env.CI_LOG? | is-not-empty) { return $env.CI_LOG }
    let state_dir = ($env.XDG_STATE_HOME? | default ($env.HOME | path join ".local" "state"))
    $state_dir | path join "ci" "log.otlp.jsonl"
}

# The OTLP AnyValue for a Nushell value.
def otlp-value [value: any] {
    match ($value | describe | str replace --regex '<.*' '') {
        "string" => { stringValue: $value }
        "int" => { intValue: ($value | into string) }
        "float" => { doubleValue: $value }
        "bool" => { boolValue: $value }
        "list" | "table" => { arrayValue: { values: ($value | each {|item| otlp-value $item }) } }
        "record" => { kvlistValue: { values: (otlp-attributes $value) } }
        _ => { stringValue: ($value | to nuon) }
    }
}

# OTLP key-value attributes for a record, without its null fields.
def otlp-attributes [attributes: record] {
    $attributes
    | transpose key value
    | where value != null
    | each {|attribute| { key: $attribute.key value: (otlp-value $attribute.value) } }
}

def from-otlp-value [value: record] {
    let kind = ($value | columns | first)
    let inner = ($value | get $kind)
    match $kind {
        "intValue" => ($inner | into int)
        "arrayValue" => ($inner.values? | default [] | each {|item| from-otlp-value $item })
        "kvlistValue" => (from-otlp-attributes ($inner.values? | default []))
        _ => $inner
    }
}

def from-otlp-attributes [attributes: list] {
    $attributes | reduce --fold {} {|attribute, record| $record | upsert $attribute.key (from-otlp-value $attribute.value) }
}

# The OTLP/JSON request that carries one log record.
def otlp-log-request [event: string, body: string, attributes: record, severity: string, time: int] {
    {
        resourceLogs: [{
            resource: { attributes: (otlp-attributes { "service.name": "ci" "host.name": (sys host | get hostname) }) }
            scopeLogs: [{
                scope: { name: "ci" }
                logRecords: [{
                    timeUnixNano: ($time | into string)
                    observedTimeUnixNano: ($time | into string)
                    severityNumber: ($SEVERITY_NUMBERS | get $severity)
                    severityText: $severity
                    eventName: $event
                    body: { stringValue: $body }
                    attributes: (otlp-attributes ({ "process.pid": $nu.pid "process.working_directory": $env.PWD } | merge $attributes))
                }]
            }]
        }]
    }
}

# Append the log record `event` to the ci log and export it. A record that
# cannot be written fails the run only when it is `--required`, as a record
# other commands read back is.
def log-event [event: string, body: string, attributes: record, --severity: string = "INFO", --required] {
    let request = (otlp-log-request $event $body $attributes $severity (date now | into int))
    try {
        let path = (ci-log-path)
        mkdir ($path | path dirname)
        $"($request | to json --raw)\n" | save --append $path
    } catch {|err|
        if $required { error make { msg: $"could not write the ci log: ($err.msg)" } }
        print --stderr $"ci: could not write the ci log: ($err.msg)"
    }
    let base = ($env.OTEL_EXPORTER_OTLP_ENDPOINT? | default "" | str trim --right --char "/")
    let endpoint = ($env.OTEL_EXPORTER_OTLP_LOGS_ENDPOINT? | default (if ($base | is-empty) { "" } else { $"($base)/v1/logs" }))
    if ($endpoint | is-not-empty) {
        try {
            http post --content-type application/json --max-time 2sec $endpoint $request | ignore
        } catch {|err|
            print --stderr $"ci: could not export a log record to ($endpoint): ($err.msg)"
        }
    }
}

# The ci log's records, oldest first, as { time, event, severity, body,
# attributes }. A line another writer is still appending is skipped. With
# `--event`, only lines naming that event are decoded at all, which keeps a
# reader of one kind of record fast however long the log grows. `--pid` keeps
# only the records that process wrote, the same way.
def read-ci-log [--event: string, --pid: int] {
    let path = (ci-log-path)
    if not ($path | path exists) { return [] }
    let needles = ([
        (if $event == null { null } else { $"\"eventName\":\"($event)\"" })
        (if $pid == null { null } else { $"\"key\":\"process.pid\",\"value\":{\"intValue\":\"($pid)\"}" })
    ] | compact)
    open --raw $path
    | lines
    | where {|line| $needles | all {|needle| $line | str contains $needle } }
    | each {|line| try { $line | from json } catch { null } }
    | each {|request| $request.resourceLogs? | default [] | each {|resource| $resource.scopeLogs? | default [] | each {|scope| $scope.logRecords? | default [] } } }
    | flatten | flatten | flatten
    | each {|record|
        {
            time: ($record.timeUnixNano | into int)
            event: ($record.eventName? | default "")
            severity: ($record.severityText? | default "")
            body: (from-otlp-value ($record.body? | default { stringValue: "" }))
            attributes: (from-otlp-attributes ($record.attributes? | default []))
        }
    }
}

# Every dispatch and landing is also an OpenTelemetry trace, derived from the
# status records it wrote to the ci log: a span for the run, one for each
# landing attempt, one for each phase and check inside it, and one for each
# wait on another topic's local checks. A phase that reports done without
# having reported working, such as a release, becomes an event on its attempt.
# When OTEL_EXPORTER_OTLP_TRACES_ENDPOINT or OTEL_EXPORTER_OTLP_ENDPOINT is
# set, a run exports its trace as it ends, and `ci trace export` sends the
# runs recorded before, from the ci log and the ci MCP job store. Ids derive
# from the run's process and first record, so both give a run the same ids.
# The trace ledger beside the ci log keeps either from sending a trace twice:
# a store keyed by span id, as otel-desktop-viewer's is, drops a duplicate
# together with whatever it was appending beside it.

# A process's records further apart than this come from a later process that
# reused its pid; no phase stays silent this long.
const TRACE_RUN_GAP = 3hr

def trace-ledger-path [] {
    ci-log-path | path dirname | path join "traces.exported"
}

def otlp-traces-endpoint [] {
    let base = ($env.OTEL_EXPORTER_OTLP_ENDPOINT? | default "" | str trim --right --char "/")
    $env.OTEL_EXPORTER_OTLP_TRACES_ENDPOINT? | default (if ($base | is-empty) { "" } else { $"($base)/v1/traces" })
}

# This run's command line as `ci SUBCOMMAND ARGS...`, from the arguments the
# launcher passed the ci.nu it runs, or null when they cannot be read.
def this-command [] {
    let argv = (try { ps --long | where pid == $nu.pid | get 0.command | split row " " } catch { [] })
    let script = ($argv | enumerate | where {|arg| $arg.item | str ends-with "ci.nu" } | get --optional 0.index)
    if $script == null { return null }
    ["ci"] ++ ($argv | skip ($script + 1)) | str join " "
}

# The ci MCP job running this process, which its PST_FILE names.
def this-mcp-job [] {
    let file = ($env.PST_FILE? | default "")
    let dir = ($file | path dirname)
    if ($file | path basename) == "log.status.jsonl" and ($dir | path dirname | path basename) == "jobs" {
        $dir | path basename
    } else { null }
}

# The root span's name: `ci` and its subcommand, guessed from the phases when
# a run recorded no command line.
def run-name [run: record] {
    if ($run.command? | is-not-empty) {
        return ($run.command | split row " " | where {|word| $word | is-not-empty } | first 2 | str join " ")
    }
    let ids = ($run.records | get id)
    if ("clearance" in $ids) or ("land" in $ids) { "ci land" } else if "push" in $ids { "ci dispatch" } else if "preflight" in $ids { "ci preflight" } else { "ci" }
}

# Close every phase still open in `open`, and `wait` if it is open, at `time`.
def close-open-spans [open: record, wait: any, time: int, status: string, message: string] {
    let phases = ($open | values | each {|span| $span | insert end $time | insert status $status | insert message $message })
    let waits = if $wait == null { [] } else { [($wait | insert end $time | insert status $status | insert message $message)] }
    $phases ++ $waits | each {|span| finish-span $span }
}

# A span in the shape `status-spans` returns, from an open one.
def finish-span [span: record] {
    {
        path: $span.path
        parent: $span.parent
        name: $span.name
        start: $span.start
        end: $span.end
        status: $span.status
        message: $span.message
        attributes: ($span.attributes? | default {} | merge (if ($span.waited? | is-empty) { {} } else { { "ci.wait.for": ($span.waited | uniq) } }))
        events: ($span.events? | default [])
    }
}

# The spans of one run from its status records, { time state id msg } with
# time in Unix nanoseconds, as { path parent name start end status message
# attributes events }. `path` names a span uniquely within the run, `parent`
# is its parent's path (null for the run itself), and `status` is ok, error,
# or unset.
def status-spans [records: list, --name: string = "ci", --attributes: record = {}] {
    let records = ($records
        | each {|r| { time: $r.time state: ($r.state? | default "") id: ($r.id? | default "") msg: ($r.msg? | default "") } }
        | sort-by time)
    if ($records | is-empty) { return [] }
    let start = ($records | first | get time)
    let end = ($records | last | get time)
    mut spans = []
    mut open = {}
    mut opened = 0
    mut waits = 0
    mut wait: any = null
    mut attempt = { number: 1 start: $start events: [] }
    mut outcome: any = null
    for r in $records {
        let attempt_path = $"attempt-($attempt.number)"
        if $r.id == "land" and $r.state == "working" and ($r.msg | str contains "trying again") {
            # Landing starts over: close this attempt and everything open in it.
            $spans = ($spans ++ (close-open-spans $open $wait $r.time "unset" "still open when the landing started over"))
            $spans = ($spans | append (finish-span {
                path: $attempt_path parent: "run" name: $"attempt ($attempt.number)" start: $attempt.start end: $r.time
                status: "unset" message: $r.msg events: $attempt.events
                attributes: { "ci.attempt": $attempt.number "ci.attempt.retried": true }
            }))
            $open = {}
            $wait = null
            $attempt = { number: ($attempt.number + 1) start: $r.time events: [] }
        } else if $r.id == "local-checks" {
            if $r.state == "blocked" {
                if $wait == null {
                    # The wait belongs to the phase that opened last.
                    let within = ($open | values | sort-by start | get --optional path | default [] | last 1 | get --optional 0 | default $attempt_path)
                    $waits += 1
                    $wait = { path: $"($attempt_path)/wait#($waits)" parent: $within name: "wait for local checks" start: $r.time waited: [$r.msg] attributes: { "ci.attempt": $attempt.number } }
                } else {
                    $wait = ($wait | update waited { append $r.msg })
                }
            } else if $r.state == "clear" and $wait != null {
                $spans = ($spans | append (finish-span ($wait | insert end $r.time | insert status "ok" | insert message "")))
                $wait = null
            }
        } else if $r.id == "" {
            if $r.state in ["done" "error"] { $outcome = $r }
        } else if $r.state == "working" {
            if $r.id in $open {
                $open = ($open | update $r.id { update attributes { upsert "ci.status.last_msg" $r.msg } })
            } else {
                let prefix = ($r.id | split row "/" | first)
                let parent = if $prefix != $r.id and $prefix in $open { $open | get $prefix | get path } else { $attempt_path }
                $opened += 1
                $open = ($open | insert $r.id {
                    path: $"($attempt_path)/($r.id)#($opened)" parent: $parent name: $r.id start: $r.time
                    attributes: { "ci.status.id": $r.id "ci.status.msg": $r.msg "ci.attempt": $attempt.number }
                })
            }
        } else if $r.state in ["done" "error" "failed"] and $r.id in $open {
            let failed = $r.state != "done"
            $spans = ($spans | append (finish-span ($open | get $r.id | insert end $r.time | insert status (if $failed { "error" } else { "ok" }) | insert message (if $failed { $r.msg } else { "" }))))
            $open = ($open | reject $r.id)
        } else if $r.state != "clear" {
            $attempt = ($attempt | update events { append { time: $r.time name: $r.id attributes: { "ci.status.state": $r.state "ci.status.msg": $r.msg } } })
        }
    }
    let status = if $outcome == null { "unset" } else if $outcome.state == "error" { "error" } else { "ok" }
    let message = if $outcome == null { "the run recorded no outcome" } else if $status == "error" { $outcome.msg } else { "" }
    $spans = ($spans ++ (close-open-spans $open $wait $end "error" "never reported done"))
    $spans = ($spans | append (finish-span {
        path: $"attempt-($attempt.number)" parent: "run" name: $"attempt ($attempt.number)" start: $attempt.start end: $end
        status: $status message: $message events: $attempt.events attributes: { "ci.attempt": $attempt.number }
    }))
    [(finish-span {
        path: "run" parent: null name: $name start: $start end: $end status: $status message: $message
        attributes: ($attributes | merge { "ci.attempts": $attempt.number })
    })] ++ $spans
}

# The OTLP/JSON ExportTraceServiceRequest for the spans of the run `key`
# names. Ids are hex digests of the key and each span's path.
def trace-request [key: string, spans: list] {
    let trace = ($key | hash md5)
    let span_id = {|path| $"($key)#($path)" | hash md5 | str substring 0..<16 }
    {
        resourceSpans: [{
            resource: { attributes: (otlp-attributes { "service.name": "ci" "host.name": (sys host | get hostname) }) }
            scopeSpans: [{
                scope: { name: "ci" }
                spans: ($spans | each {|span|
                    let parent = if $span.parent == null { {} } else { { parentSpanId: (do $span_id $span.parent) } }
                    {
                        traceId: $trace
                        spanId: (do $span_id $span.path)
                        name: $span.name
                        kind: 1
                        startTimeUnixNano: ($span.start | into string)
                        endTimeUnixNano: ($span.end | into string)
                        attributes: (otlp-attributes $span.attributes)
                        events: ($span.events | each {|event|
                            { timeUnixNano: ($event.time | into string) name: $event.name attributes: (otlp-attributes $event.attributes) }
                        })
                        status: { code: (match $span.status { "ok" => 1 "error" => 2 _ => 0 }) message: $span.message }
                    } | merge $parent
                })
            }]
        }]
    }
}

# The trace of a recorded run, { key name command workspace job records }.
def run-trace [run: record] {
    let attributes = {
        "ci.command": ($run.command? | default null)
        "ci.workspace": ($run.workspace? | default null)
        "ci.job.id": ($run.job? | default null)
        "process.pid": ($run.pid? | default null)
        "ci.command.inferred": (if ($run.command? | is-empty) { true } else { null })
    }
    trace-request $run.key (status-spans $run.records --name (run-name $run) --attributes $attributes)
}

# The runs the ci log records, oldest first: each process's status records,
# from the `ci.run` record that starts a dispatch or landing, and split where
# the process falls silent for TRACE_RUN_GAP. With `--pid`, only that
# process's runs.
def logged-runs [--pid: int] {
    let host = (sys host | get hostname)
    (read-ci-log --event ci.status --pid $pid) ++ (read-ci-log --event ci.run --pid $pid)
    | sort-by time
    | group-by {|record| $record.attributes."process.pid"? | default 0 | into string }
    | values
    | each {|records|
        mut runs = []
        mut current = []
        for record in $records {
            let gap = if ($current | is-empty) { false } else { ($record.time - ($current | last | get time)) > ($TRACE_RUN_GAP | into int) }
            if ($current | is-not-empty) and ($gap or $record.event == "ci.run") {
                $runs = ($runs | append [$current])
                $current = []
            }
            $current = ($current | append $record)
        }
        $runs | append [$current]
    }
    | flatten
    | where {|records| $records | is-not-empty }
    | each {|records|
        let first = ($records | first)
        let started = ($records | where event == "ci.run" | get --optional 0)
        {
            key: $"($host)/($first.attributes.'process.pid'?)/($first.time)"
            pid: $first.attributes."process.pid"?
            command: ($started.attributes?."ci.command"? | default null)
            job: ($started.attributes?."ci.job.id"? | default null)
            workspace: $first.attributes."process.working_directory"?
            records: ($records | each {|record|
                if $record.event == "ci.run" {
                    { time: $record.time state: "start" id: "" msg: $record.body }
                } else {
                    { time: $record.time state: $record.attributes."ci.status.state"? id: ($record.attributes."ci.status.id"? | default "") msg: $record.body }
                }
            })
        }
    }
    | sort-by {|run| $run.records | first | get time }
}

# The runs the ci MCP job store records: each job's OSC 7501 status file and
# the command its meta.json names.
def job-runs [] {
    let state_dir = ($env.XDG_STATE_HOME? | default ($env.HOME | path join ".local" "state"))
    let jobs = ($state_dir | path join "ci-mcp" "jobs")
    if not ($jobs | path exists) { return [] }
    ls $jobs | where type == dir | get name | each {|dir|
        let status_file = ($dir | path join "log.status.jsonl")
        let meta_file = ($dir | path join "meta.json")
        if not ($status_file | path exists) or not ($meta_file | path exists) { return null }
        let meta = (try { open --raw $meta_file | from json } catch { null })
        if $meta == null { return null }
        let records = (open --raw $status_file
            | lines
            | each {|line| try { $line | from json } catch { null } }
            | compact
            | where {|r| ($r.time? | is-not-empty) }
            | each {|r| { time: ($r.time | into datetime | into int) state: ($r.state? | default "") id: ($r.id? | default "") msg: ($r.msg? | default "") } }
            | sort-by time)
        if ($records | is-empty) { return null }
        let args = ($meta.args? | default ($meta.command? | default "" | split row " " | skip 1))
        {
            key: $"ci-mcp/($dir | path basename)"
            command: (["ci"] ++ $args | str join " ")
            job: ($dir | path basename)
            workspace: ($meta.workspace? | default null)
            records: $records
        }
    } | compact
}

# Every recorded run once, oldest first. The ci log's runs take the command,
# job id, and status records of the MCP job that ran them, matched by the time
# of their first status report, which both stores record in the same call;
# the job's records also hold the clears that ended each wait, which the ci
# log kept only from 2026-10-16. MCP jobs the ci log does not cover keep
# their own.
def recorded-runs [] {
    let second = {|time| $time // 1_000_000_000 }
    let first_status = {|run| $run.records | where id != "" | get --optional 0.time }
    let jobs = (job-runs | where {|job| (do $first_status $job) != null })
    let by_second = ($jobs | reduce --fold {} {|job, index|
        let bucket = (do $second (do $first_status $job) | into string)
        $index | upsert $bucket ($index | get --optional $bucket | default [] | append $job)
    })
    let match = {|run|
        let time = (do $first_status $run)
        if $time == null { return null }
        let bucket = (do $second $time)
        [($bucket - 1) $bucket ($bucket + 1)]
        | each {|b| $by_second | get --optional ($b | into string) | default [] }
        | flatten
        | where {|job| ((do $first_status $job) - $time | math abs) < 2_000_000_000 }
        | get --optional 0
    }
    let logged = (logged-runs | each {|run|
        let job = (do $match $run)
        if $job == null { $run } else {
            # The ci.run record, when there is one, still starts the run.
            let start = ($run.records | where state == "start")
            $run
            | upsert command ($run.command | default $job.command)
            | upsert job ($run.job | default $job.job)
            | upsert records ($start ++ $job.records | sort-by time)
            | insert matched $job.key
        }
    })
    let matched = ($logged | get --optional matched | compact)
    $logged | reject --optional matched | append ($jobs | where {|job| $job.key not-in $matched })
    | sort-by {|run| $run.records | first | get time }
}

# Send each run's trace to `endpoint`, one request per trace, skipping the
# traces the ledger lists and adding the ones sent. Returns a row per run.
def export-traces [runs: list, endpoint: string] {
    let ledger = (trace-ledger-path)
    let sent = if ($ledger | path exists) { open --raw $ledger | lines | reduce --fold {} {|id, set| $set | upsert $id true } } else { {} }
    mkdir ($ledger | path dirname)
    $runs | each {|run|
        let request = (run-trace $run)
        let spans = $request.resourceSpans.0.scopeSpans.0.spans
        let trace = $spans.0.traceId
        let row = {
            started: ($spans.0.startTimeUnixNano | into int | into datetime)
            name: $spans.0.name
            took: ((($spans.0.endTimeUnixNano | into int) - ($spans.0.startTimeUnixNano | into int)) | into duration | format duration sec)
            spans: ($spans | length)
            trace: $trace
        }
        if $trace in $sent { return ($row | insert sent "already") }
        try {
            http post --content-type application/json --max-time 5sec $endpoint $request | ignore
        } catch {|err|
            error make { msg: $"could not export trace ($trace) to ($endpoint): ($err.msg)" }
        }
        $"($trace)\n" | save --append $ledger
        $row | insert sent "now"
    }
}

# Export this process's run as a trace when an OTLP traces endpoint is set. A
# trace that cannot be sent never fails the run; `ci trace export` sends it
# later.
def export-this-run [] {
    let endpoint = (otlp-traces-endpoint)
    if ($endpoint | is-empty) { return }
    try {
        let since = (ps --long | where pid == $nu.pid | get 0.start_time | into int)
        let runs = (logged-runs --pid $nu.pid | where {|run| ($run.records | first | get time) >= $since })
        export-traces ($runs | last 1) $endpoint | ignore
    } catch {|err|
        print --stderr $"ci: could not export this run's trace: ($err.msg)"
    }
}

# Run one phase under `id`, reporting it working, then done or error. The
# phase's own error propagates unchanged.
def phase [id: string, msg: string, body: closure] {
    report-status working $msg --id $id
    let result = try { do $body } catch {|err|
        report-status error $"($msg) failed" --id $id
        $err.raw
    }
    report-status done $msg --id $id
    $result
}

# One line naming what failed. A bare "External command failed" names no
# command (2026-10-16); its first label does, such as "Command `ci-agent` not
# found".
def error-summary [err: record] {
    let first = ($err.msg | lines | get --optional 0 | default "")
    let label = ($err.details?.labels? | default [] | get --optional 0.text | default "")
    if ($label | is-empty) or ($first | str contains $label) { $first } else { $"($first): ($label)" }
}

# Run a whole dispatch or landing: record its command line, report done or
# error for the run, clear its records so terminals and watchers drop them,
# and export its trace.
def report-run [msg: string, body: closure] {
    let command = (this-command)
    log-event "ci.run" ($command | default $msg) { "ci.command": $command "ci.job.id": (this-mcp-job) }
    try { do $body } catch {|err|
        report-status error (error-summary $err | default --empty $"($msg) failed")
        report-status clear
        export-this-run
        $err.raw
    }
    report-status done $msg
    report-status clear
    export-this-run
}

# JJ lists its operation heads as files that another JJ process may be
# replacing at that moment. When one vanishes mid-read, JJ fails with
# "Failed to read operation heads" before it changes anything, which happened
# whenever several sessions ran JJ in the same repository (2026-10-07). Such a
# failure is retried; every other one is final.
const LOCAL_ATTEMPTS = 3
const OPERATION_HEADS_RACE = 'operation heads'

# How long to wait before retrying a local command whose `attempt` failed with
# `stderr`, or null when it fails for good.
def local-retry-delay [attempt: int, stderr: string] {
    if $attempt >= $LOCAL_ATTEMPTS or not ($stderr | str contains $OPERATION_HEADS_RACE) { return null }
    500ms * $attempt
}

# `complete` for a local command, retried while it loses JJ's operation-heads
# race to another process.
def local-complete [command: closure] {
    mut attempt = 1
    loop {
        let result = (do $command | complete)
        let delay = (local-retry-delay $attempt $result.stderr)
        if $result.exit_code == 0 or $delay == null { return $result }
        sleep $delay
        $attempt += 1
    }
}

def run-command [label: string, command: closure] {
    report-command $label (local-complete $command)
}

# Print a finished command's output, and fail with `label` if it failed.
def report-command [label: string, result: record] {
    if ($result.stdout | is-not-empty) { print --no-newline $result.stdout }
    if ($result.stderr | is-not-empty) {
        # JJ reports a no-op fetch, bookmark move, or push only as "Nothing
        # changed.", which says nothing about which step it was.
        let stderr = ($result.stderr | str replace --all --regex '(?m)^Nothing changed\.$' $"($label): nothing changed.")
        print --stderr --no-newline $stderr
    }
    if $result.exit_code != 0 {
        error make { msg: $"($label) failed with exit code ($result.exit_code)" }
    }
    $result.stdout | str trim
}

def git-command [label: string, command: closure] {
    let result = (local-complete $command)
    if $result.exit_code != 0 {
        error make { msg: $"($label) failed with exit code ($result.exit_code): ($result.stderr | str trim)" }
    }
    $result.stdout | str trim
}

def git-worktree [path: string, main: string] {
    let head = (git-command "reading worktree HEAD" { ^git -C $path rev-parse HEAD })
    let short_head = ($head | str substring 0..6)
    let branch_result = (^git -C $path symbolic-ref --short -q HEAD | complete)
    let branch = if $branch_result.exit_code == 0 and ($branch_result.stdout | str trim | is-not-empty) {
        $branch_result.stdout | str trim
    } else {
        "detached"
    }
    let dirty_result = (^git -C $path status --porcelain | complete)
    if $dirty_result.exit_code != 0 {
        error make { msg: $"Could not inspect worktree ($path): ($dirty_result.stderr | str trim)" }
    }
    let dirty = if ($dirty_result.stdout | str trim | is-empty) { "clean" } else { "dirty" }
    let main_in_head = (^git -C $path merge-base --is-ancestor $main HEAD | complete).exit_code == 0
    let head_in_main = (^git -C $path merge-base --is-ancestor HEAD $main | complete).exit_code == 0
    let state = if $head == $main {
        "current"
    } else if $main_in_head {
        "ahead"
    } else if $head_in_main {
        "behind"
    } else {
        "diverged"
    }
    let jj_result = (^jj --repository $path root | complete)
    let vcs = if $jj_result.exit_code == 0 { "jj" } else { "git" }
    {
        path: $path
        branch: $branch
        head: $short_head
        dirty: $dirty
        state: $state
        vcs: $vcs
    }
}

def current-change [template: string] {
    let result = (local-complete { ^jj log -r @ --no-graph -T $template })
    if $result.exit_code != 0 { error make { msg: ($result.stderr | str trim) } }
    $result.stdout | str trim
}

def revision-id [revision: string] {
    let result = (local-complete { ^jj log -r $revision --no-graph -T 'commit_id' })
    if $result.exit_code != 0 { error make { msg: ($result.stderr | str trim) } }
    $result.stdout | str trim
}

def git-context [] {
    let root = (^jj root | complete)
    let backend = (^jj git root | complete)
    if $root.exit_code != 0 or $backend.exit_code != 0 {
        error make { msg: "Could not locate this JJ workspace and its Git backend." }
    }
    { GIT_DIR: ($backend.stdout | str trim) GIT_WORK_TREE: ($root.stdout | str trim) }
}

# JJ's `trunk()` alias names the trunk: one remote bookmark, BOOKMARK@REMOTE,
# whose remote also hosts every topic branch. `ci land` is the only path to it:
# it fast-forwards the bookmark to a head the landing gate has already passed.
# Where only JJ's default defines `trunk()`, ci defines it in the repository's
# config as `main` on the first of these remotes that the repository has, or
# on its only remote.
const TRUNK_REMOTES = ["tangled" "origin"]
const TRUNK_KEY = 'revset-aliases."trunk()"'
# Whichever of the trunk remotes is not trunk mirrors it: `ci land` pushes
# main and each release there after landing. GitHub's Actions can gate a
# landing with `ci land --clearance github`. Its rules accept only
# fast-forwards.
const GITHUB_REMOTE = "origin"
# Where GitHub is trunk, `ci land` sets this commit status on the head it
# cleared just before fast-forwarding main, so a ruleset that requires it
# admits only commits that `ci land` cleared, and needs no pull request.
const LANDING_STATUS = "ci land"
# Impact declarations live in this machine's ci log, which GitHub cannot read,
# so `ci land` classifies the topic itself and GitHub only builds it.
const GITHUB_REQUIRED_CHECKS = ["nix flake checks"]
# nixbot (github.com/Mic92/nixbot) reports its evaluation and the build of
# every check as two combined check runs on the mirror's commits. A repository
# whose root holds nixbot.toml has each topic mirrored on dispatch, so nixbot
# builds it before `ci land --clearance nixbot` waits for these.
const NIXBOT_REQUIRED_CHECKS = ["nixbot/nix-eval" "nixbot/nix-build"]
const NIXBOT_CONFIG = "nixbot.toml"
# Clearances that read check runs on the mirror and so need the head there.
const GITHUB_CLEARANCES = ["github" "nixbot"]
const TANGLED_INDEX = "https://api.tangled.org"
const TANGLED_WEB = "https://tangled.org"
const IDENTITY_RESOLVER = "https://slingshot.microcosm.blue"

# Tangled's knot refuses an address that holds too many git operations at
# once, which happens whenever several sessions fetch or push together. The
# refusal is transient, so a remote command waits and tries again.
const REMOTE_ATTEMPTS = 5
const RATE_LIMITED = 'too many concurrent operations'

# How long to wait before retrying a remote command whose `attempt` failed
# with `stderr`, or null when it fails for good: any other error, or the last
# attempt. The wait doubles from 2 seconds.
def remote-retry-delay [attempt: int, stderr: string] {
    if $attempt >= $REMOTE_ATTEMPTS or not ($stderr | str contains $RATE_LIMITED) { return null }
    2sec * (2 ** ($attempt - 1))
}

# `complete` for a fetch or push, retried while the remote rate-limits it.
# Jitter keeps sessions refused together from retrying together. Each retry
# is reported under `remote`, and so is a retried command that then succeeds.
def remote-complete [label: string, command: closure] {
    mut attempt = 1
    loop {
        let result = (do $command | complete)
        let delay = (remote-retry-delay $attempt $result.stderr)
        if $result.exit_code == 0 or $delay == null {
            if $attempt > 1 and $result.exit_code == 0 {
                report-status done $"($label) went through on attempt ($attempt)" --id remote
            }
            return $result
        }
        let retry = $"($label): the remote is rate-limiting this address; trying again in ($delay) \(attempt ($attempt + 1) of ($REMOTE_ATTEMPTS))."
        print --stderr $retry
        report-status working $retry --id remote
        sleep ($delay + (random int 0..1000 | into duration --unit ms))
        $attempt += 1
    }
}

def run-remote [label: string, command: closure] {
    report-command $label (remote-complete $label $command)
}

def xrpc [service: string, method: string, params: record] {
    let response = (http get --full --allow-errors $"($service)/xrpc/($method)?($params | url build-query)")
    let body = if ($response.body | describe) == "string" {
        try { $response.body | from json } catch { $response.body }
    } else { $response.body }
    if $response.status != 200 {
        error make { msg: $"($method) on ($service) failed with HTTP ($response.status): ($body | to json --raw)" }
    }
    $body
}

def remotes [] {
    git-command "listing remotes" { ^jj git remote list } | lines | parse "{name} {url}"
}

# The remote to define the trunk on among `names`: the first preferred one
# present, else the only remote. Null when none qualifies.
def choose-trunk-remote [names: list<string>] {
    let preferred = ($TRUNK_REMOTES | where {|name| $name in $names } | get --optional 0)
    if $preferred != null { return $preferred }
    if ($names | length) == 1 { $names | first } else { null }
}

# The one remote bookmark a `trunk()` definition names, as `{bookmark remote}`,
# or null when it names none or several. `main@origin` and
# `remote_bookmarks(exact:"main", exact:"origin")` both name one.
def trunk-symbol [definition: string] {
    let symbols = ($definition | parse --regex '(?:^|[^\w./@-])(?P<bookmark>\w[\w./-]*)@(?P<remote>\w[\w.-]*)')
    let calls = ($definition | parse --regex r#'remote_bookmarks\(\s*(?:exact:)?["'](?P<bookmark>[^"']+)["']\s*,\s*(?:exact:)?["'](?P<remote>[^"']+)["']\s*\)'#)
    let found = ($symbols | append $calls | uniq)
    if ($found | length) == 1 { $found | first } else { null }
}

# The definition of `trunk()` that JJ uses here, and where it comes from:
# `default` for JJ's own, or the config layer that sets it.
def trunk-definition [] {
    let listing = (git-command "reading trunk()" {
        ^jj config list --include-defaults -T 'source ++ "\t" ++ value ++ "\n"' $TRUNK_KEY
    })
    let entry = ($listing | parse --regex '(?s)^(?P<source>[^\t]*)\t(?P<value>.*)$' | first)
    { source: $entry.source value: ($"value = ($entry.value)" | from toml | get value) }
}

# The trunk as `{bookmark remote}`. A `trunk()` that the user or repository
# defines must name one remote bookmark. Otherwise ci defines it here, as main
# on the chosen remote, or the root until main is first pushed there: a bare
# `main@REMOTE` would fail every revset naming `trunk()` before then, JJ's
# immutable heads included.
def trunk [] {
    let definition = (trunk-definition)
    if $definition.source != "default" {
        let symbol = (trunk-symbol $definition.value)
        if $symbol == null {
            error make { msg: $"trunk\() is `($definition.value | str trim)` in the ($definition.source) config, which names no single BOOKMARK@REMOTE to land on. Define it as one, as in `jj config set --repo '($TRUNK_KEY)' main@origin`." }
        }
        return $symbol
    }
    let names = (remotes | get name)
    let remote = (choose-trunk-remote $names)
    if $remote == null {
        let found = if ($names | is-empty) { "This repository has no remote" } else { $"Cannot tell which of ($names | str join ', ') is trunk" }
        error make { msg: $"($found). Define trunk\() as the remote bookmark to land on, as in `jj config set --repo '($TRUNK_KEY)' main@origin`." }
    }
    run-command $"defining trunk\() as main@($remote)" {
        ^jj config set --repo $TRUNK_KEY $"latest\(present\(main@($remote)) | root\())"
    } | ignore
    { bookmark: "main" remote: $remote }
}

def trunk-remote [] {
    (trunk).remote
}

# The remotes among `names` that mirror a trunk on `trunk_remote`: every
# other trunk remote the repository has, in preference order.
def mirror-remotes [trunk_remote: string, names: list<string>] {
    $TRUNK_REMOTES | where {|name| $name != $trunk_remote and $name in $names }
}

# The trunk's revset, once `trunk()` is known to name it.
def trunk-revset [] {
    trunk | ignore
    "trunk()"
}

# Where a Tangled remote URL points: `{owner name}` for an owner's handle or
# DID and a repository name, `{did}` for a repository addressed by its own
# DID, or null for any other URL.
def tangled-location [url: string] {
    let path = ($url | parse --regex '^(?:[^@/]+@[^:/]+:|(?:https?|ssh)://[^/]+/)(?P<path>.+?)(?:\.git)?/?$' | get --optional 0.path)
    if $path == null { return null }
    let named = ($path | parse --regex '^(?P<owner>[^/]+)/(?P<name>[^/]+)$' | get --optional 0)
    if $named != null { return { owner: ($named.owner | str trim --left --char "@") name: $named.name } }
    if ($path =~ '^did:[a-z]+:[^/]+$') { { did: $path } } else { null }
}

# The Tangled repository behind the trunk remote. Its URL names the owner's
# handle and the repository, or the repository's own DID; the repository record
# carries the repo DID that the index APIs key on.
def tangled-repo [] {
    let remote = (trunk-remote)
    let url = (remotes | where name == $remote | get 0.url)
    let location = (tangled-location $url)
    if $location == null { error make { msg: $"Cannot read a Tangled repository from ($url)." } }
    if $location.did? != null {
        return { did: $location.did web: $"($TANGLED_WEB)/($location.did)" }
    }
    let owner = $location.owner
    let did = if ($owner | str starts-with "did:") {
        $owner
    } else {
        (xrpc $IDENTITY_RESOLVER "com.atproto.identity.resolveHandle" { handle: $owner }).did
    }
    let record = (xrpc $TANGLED_INDEX "sh.tangled.repo.getRepo" { repo: $"at://($did)/sh.tangled.repo/($location.name)" })
    {
        did: $record.value.repoDid
        web: $"($TANGLED_WEB)/($owner)/($location.name)"
    }
}

# Open pull requests with the branch each one proposes.
def open-pulls [repo: record] {
    (xrpc $TANGLED_INDEX "sh.tangled.repo.listPulls" { subject: $repo.did status: "open" limit: 100 }).items
    | each {|item| { title: $item.value.title branch: ($item.value.source?.branch? | default "") uri: $item.uri } }
}

# The GitHub repository a remote URL names, as `owner/name`, or null for a
# URL elsewhere.
def github-location [url: string] {
    let location = ($url | parse --regex 'github\.com[:/](?P<owner>[^/]+)/(?P<name>[^/]+?)(?:\.git)?/?$' | get --optional 0)
    if $location == null { null } else { $"($location.owner)/($location.name)" }
}

# The GitHub repository behind the `origin` remote, as `owner/name`.
def github-repo [] {
    let url = (remotes | where name == $GITHUB_REMOTE | get --optional 0.url)
    if $url == null { error make { msg: $"This repository has no ($GITHUB_REMOTE) remote." } }
    let location = (github-location $url)
    if $location == null { error make { msg: $"($url) is not a GitHub repository." } }
    $location
}

# Mark `head` as cleared on a GitHub trunk, naming the clearance that passed
# it, before main moves there. A trunk elsewhere has nothing to mark. The
# commit is already on GitHub: dispatch pushed its branch.
def post-landing-status [remote: string, head: string, clearance: string] {
    let url = (remotes | where name == $remote | get --optional 0.url)
    let repo = if $url == null { null } else { github-location $url }
    if $repo == null { return }
    git-command $"marking ($head | str substring 0..11) cleared on ($repo)" {
        ^gh api --method POST $"repos/($repo)/statuses/($head)" -f state=success -f $"context=($LANDING_STATUS)" -f $"description=Cleared by ci land --clearance ($clearance)"
    } | ignore
}

# GitHub's verdict on one commit, as `{state workflows}`: the newest run of
# each required check decides, and a check that has not reported is missing.
# A skipped run proves nothing, so it counts as not having reported.
def github-checks-state [repo: string, commit: string, required: list<string> = $GITHUB_REQUIRED_CHECKS] {
    let runs = (git-command "reading GitHub check runs" {
        ^gh api --paginate $"repos/($repo)/commits/($commit)/check-runs?per_page=100" --jq '.check_runs[] | {name, status, conclusion, id}'
    } | lines | where {|line| $line | is-not-empty } | each {|line| $line | from json }
    | where {|run| $run.conclusion not-in ["skipped" "neutral"] })
    let workflows = ($required | each {|name|
        let matching = ($runs | where name == $name)
        let run = if ($matching | is-empty) { null } else { $matching | sort-by id | last }
        let status = if $run == null {
            "missing"
        } else if $run.status != "completed" {
            $run.status
        } else if $run.conclusion == "success" {
            "success"
        } else {
            "failed"
        }
        { name: $name status: $status }
    })
    let state = if ($workflows | any {|workflow| $workflow.status == "failed" }) {
        "failed"
    } else if ($workflows | all {|workflow| $workflow.status == "success" }) {
        "success"
    } else if ($workflows | all {|workflow| $workflow.status == "missing" }) {
        "missing"
    } else {
        "running"
    }
    { state: $state workflows: $workflows }
}

# Local clearance and the refactor proof are the heaviest things `ci` runs:
# the flake checks may take 9 GiB, and the proof evaluates every host twice.
# Two sessions that landed at once exhausted this 16 GiB machine, and the
# kernel killed one landing's checks (2026-10-07). Both therefore run under
# one lock shared by every workspace and session: a file under the state
# directory that names its holder.
def local-checks-lock-path [] {
    $env.XDG_STATE_HOME? | default ($env.HOME | path join ".local" "state") | path join "jj-ci" "local-checks.lock"
}

# A process's start time in clock ticks since boot, or null once it has
# exited. With the pid, it names one process even after the pid is reused.
def process-start [pid: int] {
    try {
        open --raw $"/proc/($pid)/stat" | split row ")" | last | str trim | split row " " | get 19
    } catch { null }
}

# Whether a lock holder still runs: its `ci` process, or the transient unit
# running its checks, which outlives a `ci` that was cancelled or killed.
def lock-holder-alive [holder: record] {
    let start = (process-start $holder.pid)
    if $start != null and $start == $holder.start { return true }
    if ($holder.unit? | is-empty) { return false }
    try { (^systemctl --user is-active --quiet $holder.unit | complete).exit_code == 0 } catch { false }
}

# The topic `commit` belongs to, as its change id and title, for the wait
# message other sessions print. Outside a JJ workspace, the commit itself.
def lock-topic [commit: string] {
    let named = (try {
        ^jj log -r $commit --no-graph -T 'change_id.short(8) ++ " " ++ description.first_line().escape_json()' | complete
    } catch { { exit_code: 1 stdout: "" } })
    if $named.exit_code == 0 and ($named.stdout | str trim | is-not-empty) {
        $named.stdout | str trim
    } else {
        $commit | str substring 0..11
    }
}

# Replace the lock file whose contents hash to `expected` ("absent" for no
# file) with `next`, or remove it when `next` is empty, unless another session
# changed it first. flock(1) on a guard file serializes the comparison and the
# write, so two sessions that both find the lock free, or its holder dead,
# cannot both take it.
def swap-local-checks-lock [lock: string, expected: string, next: string] {
    let swap = 'let current = (try { open --raw $env.LOCK | into binary | hash sha256 } catch { "absent" }); if $current != $env.EXPECTED { exit 3 }; if ($env.NEXT | is-empty) { rm --force $env.LOCK } else { $env.NEXT | save --force $env.LOCK }'
    let result = (with-env { LOCK: $lock EXPECTED: $expected NEXT: $next } {
        ^flock $"($lock).guard" $nu.current-exe --no-config-file --commands $swap | complete
    })
    if $result.exit_code not-in [0 3] {
        error make { msg: $"updating ($lock) failed with exit code ($result.exit_code): ($result.stderr | str trim)" }
    }
    $result.exit_code == 0
}

# Take the lock for `claim` if it is free or its holder has died. Returns null
# once it is taken, or else the record of the live session holding it.
def claim-local-checks-lock [lock: string, claim: string] {
    loop {
        let raw = (try { open --raw $lock | into binary } catch { null })
        let holder = (try { $raw | decode utf-8 | from json } catch { null })
        if $holder != null and (try { lock-holder-alive $holder } catch { false }) { return $holder }
        let current = if $raw == null { "absent" } else { $raw | hash sha256 }
        if (swap-local-checks-lock $lock $current $claim) { return null }
    }
}

# Run `body` under the local checks lock, waiting while another live session
# holds it and printing that session once per holder. `unit` names the
# transient unit that will run the checks: the lock stays held while it runs,
# even if this process dies. The lock is released however `body` ends; if
# this process is killed instead, the next session finds it dead and takes
# the lock over.
def with-local-checks-lock [commit: string, body: closure, --unit: string] {
    let lock = (local-checks-lock-path)
    mkdir ($lock | path dirname)
    let claim = ({
        topic: (lock-topic $commit)
        pid: $nu.pid
        start: (process-start $nu.pid)
        unit: $unit
        workspace: $env.PWD
    } | to json --raw)
    mut announced = {}
    loop {
        let holder = (claim-local-checks-lock $lock $claim)
        if $holder == null { break }
        if $holder != $announced {
            let waiting = $"Waiting for local checks of ($holder.topic? | default 'another topic') \(pid ($holder.pid? | default '?')) to finish."
            print $waiting
            # Blocked on another session, not a person, so no --kind.
            report-status blocked $waiting --id local-checks
            $announced = $holder
        }
        sleep 5sec
    }
    if $announced != {} { report-status clear --id local-checks }
    let outcome = try { { value: (do $body) error: null } } catch {|err| { value: null error: $err } }
    swap-local-checks-lock $lock ($claim | hash sha256) "" | ignore
    if $outcome.error != null { error make $outcome.error.raw }
    $outcome.value
}

# Two sessions that dispatched or landed the same topic at once rebased it
# separately, splitting it into divergent copies that then stopped every
# landing (2026-10-07). So one process at a time may move a topic: a lock per
# change ID under the state directory, claimed the way the local checks lock
# is, names its holder.
def topic-lock-path [change: string] {
    $env.XDG_STATE_HOME? | default ($env.HOME | path join ".local" "state") | path join "jj-ci" "topics" $"($change).lock"
}

# Run `body` holding the lock for topic `change`, or fail at once naming the
# live process that holds it: waiting would only move the topic twice. An
# error inside `body` is raised again whole, with the command and labels that
# say what failed, not just its message.
def with-topic-lock [change: string, body: closure] {
    let lock = (topic-lock-path $change)
    mkdir ($lock | path dirname)
    let claim = ({
        topic: (lock-topic $change)
        pid: $nu.pid
        start: (process-start $nu.pid)
        workspace: $env.PWD
    } | to json --raw)
    let holder = (claim-local-checks-lock $lock $claim)
    if $holder != null {
        error make { msg: $"Another `ci` \(pid ($holder.pid? | default '?') in ($holder.workspace? | default 'another workspace')) is already dispatching or landing ($holder.topic? | default 'this topic'). Let it finish, or stop it, rather than moving the topic twice." }
    }
    let outcome = try { { value: (do $body) error: null } } catch {|err| { value: null error: $err } }
    swap-local-checks-lock $lock ($claim | hash sha256) "" | ignore
    if $outcome.error != null { error make $outcome.error.raw }
    $outcome.value
}

# Concurrent landings restarted one another (2026-10-16): each rebased, took
# clearance, and fast-forwarded main outside any lock, so a topic that landed
# while another's clearance ran threw that clearance away. Landings that ran
# alone took about 4 minutes; five at once took 30 to 77 minutes each, and two
# never landed. So landings share one runway on this machine: each landing
# holds a ticket, numbered in arrival order, and only the lowest live ticket
# may rebase onto main, take clearance, fast-forward main, and tag releases. A
# landing rebases once it reaches the runway, onto a main that no other
# landing here moves until it is done, so N landings cost about N clearances.
#
# One topic is in flight at a time, and only one lands from a session: `ci
# land` takes the runway only when it is clear, with no live ticket ahead of
# its own and no topic held for the drainer. Otherwise it gives its ticket
# back and refuses, naming what is in flight, rather than keep a session
# waiting for a turn it may not live to see. `ci queue` holds the topic
# instead, and the drainer, which lands held topics a flight at a time, waits
# its turn on the runway like any landing. The tickets stay in
# `landing-queue`, where earlier copies of ci keep them, so every copy on
# this machine shares one runway.
#
# Locks are taken in one order, so no two processes ever wait on each other:
# a topic lock (never waited for), then the runway, then the local checks
# lock. Nothing that holds the local checks lock waits for the runway.
def runway-path [] {
    $env.XDG_STATE_HOME? | default ($env.HOME | path join ".local" "state") | path join "jj-ci" "landing-queue"
}

# The number of the ticket at `path`, or null for any other file.
def landing-ticket-number [path: string] {
    let parsed = ($path | path parse)
    if $parsed.extension != "json" { return null }
    try { $parsed.stem | into int } catch { null }
}

# Draw a ticket behind every one already in `dir`, a runway or the holds:
# one more than the highest ticket there, drawn under flock(1) on a guard
# file, so two that arrive together never draw the same number and a later
# arrival never draws a lower one. The ticket is renamed into place whole, so
# no reader sees half of one. Returns its path.
def draw-ticket [dir: string, claim: string] {
    let take = 'let numbers = (ls $env.QUEUE | get name | each {|path| let parsed = ($path | path parse); if $parsed.extension == "json" { try { $parsed.stem | into int } catch { null } } } | compact); let next = ($numbers | append 0 | math max) + 1; let path = ($env.QUEUE | path join $"($next | fill --alignment right --character "0" --width 12).json"); $env.CLAIM | save --force $"($path).tmp"; mv --force $"($path).tmp" $path; print --no-newline $path'
    let result = (with-env { QUEUE: $dir CLAIM: $claim } {
        ^flock ($dir | path join ".guard") $nu.current-exe --no-config-file --commands $take | complete
    })
    if $result.exit_code != 0 {
        error make { msg: $"drawing a ticket in ($dir) failed with exit code ($result.exit_code): ($result.stderr | str trim)" }
    }
    $result.stdout | str trim
}

# The live tickets on the runway `queue`, oldest first, as { number, path,
# holder }. A ticket whose landing has exited, or that cannot be read, is
# removed, so a landing that was killed never holds up the ones behind it.
def runway-tickets [queue: string] {
    ls $queue | get name | each {|path|
        let number = (landing-ticket-number $path)
        if $number == null { return null }
        let holder = (try { open --raw $path | from json } catch { null })
        if $holder != null and (try { lock-holder-alive $holder } catch { false }) {
            { number: $number path: $path holder: $holder }
        } else {
            rm --force $path
            null
        }
    } | compact | sort-by number
}

# What a landing waiting behind the live tickets `ahead` reports: the landing
# on the runway, and how many more wait between it and this one.
def runway-wait [ahead: list] {
    let front = ($ahead | first | get holder)
    let more = ($ahead | length) - 1
    let others = if $more > 0 { $" and ($more) more" } else { "" }
    $"Waiting for the runway behind ($front.topic? | default 'another topic') \(pid ($front.pid? | default '?'))($others)."
}

# Why the runway is not clear for `ci land`: the live tickets `ahead` and the
# topics `held` for the drainer, as one sentence.
def runway-busy [ahead: list, held: list] {
    let landing = if ($ahead | is-empty) { null } else {
        let front = ($ahead | first | get holder)
        let more = ($ahead | length) - 1
        let others = if $more > 0 { $", with ($more) more behind it" } else { "" }
        $"($front.topic? | default 'another topic') \(pid ($front.pid? | default '?')) is landing($others)"
    }
    let holding = if ($held | is-empty) { null } else {
        let count = ($held | length)
        let topics = if $count == 1 { "1 topic is" } else { $"($count) topics are" }
        let idle = if (drainer-alive) { "" } else { ", but no drainer is running: `ci queue drain` lands them, or `ci queue drop` in their workspace takes one out" }
        $"($topics) held for the drainer, first ($held | first | get hold.topic)($idle)"
    }
    [$landing $holding] | compact | str join "; "
}

# Whether a drainer is running. A drainer that was stopped leaves its holds
# behind, and they keep `ci land` off the runway until one lands them.
def drainer-alive [] {
    let holder = (try { open --raw (drainer-lock-path) | from json } catch { null })
    $holder != null and (try { lock-holder-alive $holder } catch { false })
}

# Run `body` once this landing, named `topic`, holds the runway. While
# landings are ahead of it, it reports working under `runway` whenever the
# front or the count changes, so `watch-job` shows the wait: waiting one's
# turn is progress, not something for a person to unblock. The ticket leaves
# the runway however `body` ends; if this process is killed instead, the next
# landing finds it dead and drops it.
#
# `--alone` is `ci land`: unless the runway is clear, the ticket goes back at
# once and `busy` runs instead of `body`, given why. `--hold` names the hold
# files of the topics this landing flies for the drainer (several, joined by
# ":", for a train). They go once the ticket is drawn, which keeps their
# place: no `ci land` finds the runway clear between the two.
def with-runway [topic: string, body: closure, --alone, --busy: closure, --hold: string] {
    let queue = (runway-path)
    mkdir $queue
    let claim = ({
        topic: $topic
        pid: $nu.pid
        start: (process-start $nu.pid)
        workspace: $env.PWD
    } | to json --raw)
    let ticket = (draw-ticket $queue $claim)
    let number = (landing-ticket-number $ticket)
    if $hold != null {
        for path in ($hold | split row ":" | where {|path| $path | is-not-empty }) { rm --force $path }
    }
    if $alone {
        let ahead = (runway-tickets $queue | where number < $number)
        let held = (held-topics)
        if ($ahead | is-not-empty) or ($held | is-not-empty) {
            rm --force $ticket
            return (do $busy (runway-busy $ahead $held))
        }
    }
    let outcome = try {
        mut announced = ""
        loop {
            let ahead = (runway-tickets $queue | where number < $number)
            if ($ahead | is-empty) { break }
            let waiting = (runway-wait $ahead)
            if $waiting != $announced {
                print $waiting
                report-status working $waiting --id runway
                $announced = $waiting
            }
            sleep 5sec
        }
        if $announced != "" { report-status done "On the runway" --id runway }
        { value: (do $body) error: null }
    } catch {|err| { value: null error: $err } }
    rm --force $ticket
    if $outcome.error != null { error make $outcome.error.raw }
    $outcome.value
}

# `ci queue` holds a dispatched topic for the drainer instead of taking the
# runway. A hold is a ticket in `landing-holds`, drawn like a runway ticket,
# that names the exact head it holds, where its topic lives, how to land it,
# and the log its owner can follow with `watch-job`. Holds outlive the
# session that made them, which may end at once: the drainer, a transient
# systemd unit, lands them in turn and leaves each one's outcome in its log's
# `.done.nuon`, as job-log does, and in `outcomes.jsonl`.
def holds-path [] {
    $env.XDG_STATE_HOME? | default ($env.HOME | path join ".local" "state") | path join "jj-ci" "landing-holds"
}

# Who drains the holds, claimed like the local checks lock: one drainer runs
# at a time, and a second one exits as soon as it finds the first alive.
def drainer-lock-path [] {
    $env.XDG_STATE_HOME? | default ($env.HOME | path join ".local" "state") | path join "jj-ci" "landing-drainer.lock"
}

# The topics held for the drainer, oldest first, as { number, path, hold }. A
# hold that cannot be read is dropped. Holds have no process behind them, so
# unlike runway tickets they never lapse.
def held-topics [] {
    let dir = (holds-path)
    if not ($dir | path exists) { return [] }
    ls $dir | get name | each {|path|
        let number = (landing-ticket-number $path)
        if $number == null { return null }
        let hold = (try { open --raw $path | from json } catch { null })
        if $hold == null { rm --force $path; return null }
        { number: $number path: $path hold: $hold }
    } | compact | sort-by number
}

# The settings a child `ci` started for the drainer must keep: systemd starts
# a user unit with almost none of the caller's environment.
def drainer-environment [] {
    const KEEP = [PATH HOME USER LOGNAME SHELL LANG XDG_STATE_HOME XDG_CACHE_HOME XDG_CONFIG_HOME XDG_DATA_HOME XDG_RUNTIME_DIR NU_LIB_DIRS SSH_AUTH_SOCK NIX_PATH NIX_SSL_CERT_FILE SSL_CERT_FILE GIT_SSH_COMMAND JJ_CONFIG XS_ADDR]
    $env | transpose name value | where {|var|
        $var.name in $KEEP or ($var.name | str starts-with "CI_") or ($var.name | str starts-with "OTEL_")
    } | each {|var|
        let kind = ($var.value | describe)
        let value = if ($kind | str starts-with "list") { $var.value | str join (char esep) } else if $kind == "string" { $var.value } else { null }
        if $value == null { null } else { { name: $var.name value: $value } }
    } | compact
}

# Start the drainer as a transient user unit unless a live one runs, and
# return its pid. It runs through the `ci` launcher from this workspace, so it
# is the same ci.nu this command runs.
def ensure-drainer [launcher: string] {
    let lock = (drainer-lock-path)
    let holder = (try { open --raw $lock | from json } catch { null })
    if $holder != null and (try { lock-holder-alive $holder } catch { false }) { return $holder.pid }
    let unit = $"ci-landing-drain-(date now | format date '%Y%m%d%H%M%S')-(random chars --length 4)"
    let setenv = (drainer-environment | each {|var| $"--setenv=($var.name)=($var.value)" })
    let started = (^systemd-run --user --collect --quiet $"--unit=($unit)" $"--working-directory=($env.PWD)" ...$setenv -- $launcher queue drain --unit $unit | complete)
    if $started.exit_code != 0 {
        error make { msg: $"starting the drainer failed with exit code ($started.exit_code): ($started.stderr | str trim)" }
    }
    let pid = (^systemctl --user show --property MainPID --value $unit | complete | get stdout | str trim)
    try { $pid | into int } catch { null }
}

# Hold the dispatched topic `published` for the drainer, to land with
# `clearance`, `timeout`, and `attempts`, and start the drainer. Returns the
# hold, its path, and how many holds wait ahead of it.
def hold-topic [published: record, clearance: string, timeout: duration, attempts: int] {
    let launcher = (which ci | get --optional 0.path)
    if $launcher == null {
        error make { msg: "`ci queue` needs the `ci` launcher on PATH: the drainer runs it to land the topic." }
    }
    let dir = (holds-path)
    let logs = ($dir | path join "logs")
    mkdir $logs
    let change = (current-topic-id)
    let log = ($logs | path join $"(date now | format date '%Y%m%dT%H%M%S')-($change | str substring 0..<8).log")
    let hold = {
        topic: (lock-topic $published.head)
        change: $change
        head: $published.head
        branch: $published.branch
        repo: (git-command "locating the repository" { ^jj git root })
        workspace: (git-command "locating the workspace" { ^jj root })
        clearance: $clearance
        timeout_sec: ($timeout / 1sec | into int)
        attempts: $attempts
        launcher: $launcher
        ci_script: ($env.CI_SCRIPT? | default null)
        held_at: (date now | format date '%+')
        log: $log
    }
    $"Held ($hold.topic) at ($hold.head | str substring 0..11) for the drainer.\n" | save --force $log
    let path = (draw-ticket $dir ($hold | to json --raw))
    let number = (landing-ticket-number $path)
    let pid = (ensure-drainer $launcher)
    hold-job-record $hold ($pid | default $nu.pid)
    { hold: $hold path: $path ahead: (held-topics | where number < $number | length) }
}

# Write the `.job.nuon` that `watch-job` reads for a hold's log, naming the
# drainer `pid` as its owner: once that process exits without a result, the
# watcher reports the landing lost.
def hold-job-record [hold: record, pid: int] {
    {
        pid: $pid
        task: $"ci land ($hold.topic)"
        cwd: $hold.workspace
        started: ($hold.held_at | into datetime)
    } | save --force $"($hold.log).job.nuon"
}

# End `held`, a { path, hold } record, with `outcome`, as job-log ends a job:
# its `.done.nuon` and a line in `outcomes.jsonl`. The hold file goes too,
# if a landing has not taken it already.
def finish-hold [held: record, outcome: record] {
    rm --force $held.path
    let reason = if ($outcome.error? | is-empty) { "landed" } else { $outcome.error }
    try { $"($reason)\n" | save --append $held.hold.log }
    try { $outcome | save --force $"($held.hold.log).done.nuon" }
    let record = ({ at: (date now | format date '%+') topic: $held.hold.topic head: $held.hold.head log: $held.hold.log } | merge $outcome)
    try { $"($record | to json --raw)\n" | save --append ((holds-path) | path join "outcomes.jsonl") }
}

# Why `hold` cannot land as held, or null when it can: its workspace must
# still have the held change checked out at the held head, and that change
# must not be on trunk already.
def hold-problem [hold: record] {
    if not ($hold.workspace | path join ".jj" | path exists) { return $"its workspace ($hold.workspace) is gone" }
    let at = (do { cd $hold.workspace; ^jj log -r @ --no-graph -T 'change_id ++ " " ++ commit_id' } | complete)
    if $at.exit_code != 0 { return $"reading its workspace failed: ($at.stderr | str trim)" }
    let fields = ($at.stdout | str trim | split row " ")
    if ($fields | first) != $hold.change { return "its workspace no longer has the held change checked out" }
    if ($fields | last) != $hold.head { return "it changed since it was queued; `ci queue` it again to land the new head" }
    null
}

# The holds the drainer lands next, as one flight: the oldest, and with it
# every later hold of the same repository and clearance, which fly together
# as one train. Arrival is the only order for now; ordering the holds by
# their dependencies would change this function alone.
def next-flight [held: list] {
    let lead = ($held | first | get hold)
    $held | where {|entry| $entry.hold.repo == $lead.repo and $entry.hold.clearance == $lead.clearance }
}

# Land `flight`, holds that `next-flight` chose and that can land as held,
# with the `ci` launcher in the lead's workspace: `ci land` for one, a train
# for more. Its log, status reports, and outcome go to the lead's hold; the
# others' logs point there.
def fly [flight: list] {
    let lead = ($flight | first | get hold)
    let held = ($flight | get path | str join ":")
    let common = [--clearance $lead.clearance --timeout $"($lead.timeout_sec)sec" --held $held]
    let args = if ($flight | length) == 1 {
        [land ...$common --attempts $lead.attempts]
    } else {
        [land --train ...$common]
    }
    for entry in ($flight | skip 1) {
        try { $"Landing in a train led by ($lead.topic); its log is ($lead.log).\n" | save --append $entry.hold.log }
    }
    let script = if $lead.ci_script == null { {} } else { { CI_SCRIPT: $lead.ci_script } }
    let code = (with-env ({ PST_FILE: $"($lead.log).status.jsonl" } | merge $script) {
        try {
            cd $lead.workspace
            ^$lead.launcher ...$args o+e>> $lead.log
            0
        } catch {
            let code = ($env.LAST_EXIT_CODE? | default 1)
            if $code == 0 { 1 } else { $code }
        }
    })
    let last = (try { open --raw $lead.log | lines | where {|line| $line | str trim | is-not-empty } | last } catch { "" })
    for entry in $flight {
        let landed = if ($flight | length) == 1 { $code == 0 } else {
            let found = (do { cd $lead.workspace; ^jj log -r $"trunk\() & change_id\(($entry.hold.change))" --no-graph -T 'change_id' } | complete)
            $found.exit_code == 0 and ($found.stdout | str trim | is-not-empty)
        }
        let outcome = if $landed { { exit_code: 0 } } else if ($flight | length) == 1 {
            { exit_code: $code error: $"did not land: ($last)" }
        } else {
            { exit_code: 1 error: $"did not land with the train; see ($lead.log)" }
        }
        finish-hold $entry $outcome
    }
}

# Release the drainer lock `lock`, held with `claim`, but only if no hold
# waits: the check and the release share the holds' guard with draw-ticket,
# so a hold drawn at that moment is either seen here or finds the drainer
# gone and starts another. Returns whether it released.
def release-idle-drainer [lock: string, claim: string] {
    let dir = (holds-path)
    mkdir $dir
    let release = 'let waiting = (ls $env.HOLDS | get name | where {|path| ($path | path parse | get extension) == "json" }); if ($waiting | is-not-empty) { exit 4 }; let current = (try { open --raw $env.LOCK | into binary | hash sha256 } catch { "absent" }); if $current == $env.EXPECTED { rm --force $env.LOCK }'
    let result = (with-env { HOLDS: $dir LOCK: $lock EXPECTED: ($claim | hash sha256) } {
        ^flock ($dir | path join ".guard") $nu.current-exe --no-config-file --commands $release | complete
    })
    if $result.exit_code not-in [0 4] {
        error make { msg: $"releasing the drainer failed with exit code ($result.exit_code): ($result.stderr | str trim)" }
    }
    $result.exit_code == 0
}

# Land every held topic in turn, then exit. Each flight is a child `ci` run,
# so a failure ends that flight's holds and the drainer goes on to the next.
def drain-holds [unit?: string] {
    let lock = (drainer-lock-path)
    mkdir ($lock | path dirname)
    let claim = ({
        topic: 'drainer "ci queue drain"'
        pid: $nu.pid
        start: (process-start $nu.pid)
        unit: $unit
        workspace: $env.PWD
    } | to json --raw)
    let holder = (claim-local-checks-lock $lock $claim)
    if $holder != null {
        print $"The drainer is already running \(pid ($holder.pid? | default '?'))."
        return
    }
    let outcome = try {
        loop {
            let held = (held-topics)
            if ($held | is-empty) {
                if (release-idle-drainer $lock $claim) { break }
                continue
            }
            for entry in $held { try { hold-job-record $entry.hold $nu.pid } }
            let flight = (next-flight $held | each {|entry|
                let problem = (try { hold-problem $entry.hold } catch {|err| $err.msg })
                if $problem == null { $entry } else {
                    print $"Dropping ($entry.hold.topic): ($problem)."
                    finish-hold $entry { exit_code: 1 error: $"dropped: ($problem)" }
                    null
                }
            } | compact)
            if ($flight | is-not-empty) {
                print $"Landing ($flight | each {|entry| $entry.hold.topic } | str join ', ')."
                fly $flight
            }
        }
        { error: null }
    } catch {|err| { error: $err } }
    swap-local-checks-lock $lock ($claim | hash sha256) "" | ignore
    if $outcome.error != null { error make $outcome.error.raw }
}

# How a nix-fast-build run that exited with `exit_code` went, judged by the
# result file it writes once it finishes. A signal, or a failure that left no
# failed build or evaluation there, means something killed the run rather
# than a check failing: on this machine, almost always memory. An evaluation
# that outgrew the memory budget counts as killed too; nix-eval-jobs reports
# it as failed once a retry on its own runs out as well.
#
# `explained` maps a check that did not build to why, as
# explain-build-failure returns it, and its error then says so.
def checks-outcome [exit_code: int, results: string, explained: record = {}] {
    if $exit_code == 0 { return { status: "success" } }
    let failed = ((try { open $results | get results } catch { [] }) | where {|result|
        not $result.success and ($result.error? | default "") !~ "exceeded the memory budget"
    })
    # Nu reports death by a signal as the negated signal number; systemd-run
    # exits 255 when the unit's main process died from one.
    if $exit_code < 0 or $exit_code == 255 or ($failed | is-empty) {
        let ended = if $exit_code < 0 { $"signal (-1 * $exit_code)" } else { $"exit status ($exit_code)" }
        return { status: "killed" error: $"likely out of memory, ($ended)" }
    }
    let checks = ($failed | each {|result|
        match $result.type {
            "BUILD" => $"($result.attr) did not build(build-failure-detail ($explained | get --optional $result.attr))"
            "EVAL" => $"($result.attr) did not evaluate"
            _ => $"($result.attr) failed to ($result.type | str lowercase)"
        }
    })
    { status: "failed" error: ($checks | str join ", ") }
}

# The line of a failed build's log that says why: the last one naming an
# error, assertion, failure, panic, or exception, else the last line printed.
# A test runner's traceback ends in its assertion, and a compiler's output in
# its error, so this is usually the line a reviewer looks for first.
def build-failure-reason [log: string] {
    let printed = ($log | ansi strip | lines | each {|line| $line | str trim } | where {|line| $line | is-not-empty })
    let named = ($printed | where {|line| $line =~ '(?i)\b(error|assert\w*|fail(ed|ure)?|panic\w*|exception)\b' })
    $named | last | default ($printed | last) | default "" | str substring 0..<300
}

# What follows "<check> did not build" for a failure explain-build-failure
# explained, or nothing for one it could not.
def build-failure-detail [failure: any] {
    if $failure == null { return "" }
    let reason = if ($failure.reason | is-empty) { "" } else { $": ($failure.reason)" }
    let log = if $failure.log == null { "" } else { $" \(log: ($failure.log))" }
    $"($reason)($log)"
}

# Why the check `attr` did not build at `commit`, from the log Nix kept for
# its derivation `drv`. The whole log is saved, without colour codes, as
# $XDG_STATE_HOME/ci/check-failures/<commit>/<check>.log, which outlives the
# exported tree, so a person or an agent can read it after the landing fails.
# Returns { reason log }, or null when Nix has no log for `drv`, as for a
# check built on a remote builder that kept it.
def explain-build-failure [commit: string, attr: string, drv: string] {
    if not ($drv | str starts-with "/nix/store/") { return null }
    let fetched = (try { ^nix log $drv | complete } catch { { exit_code: 1 } })
    if $fetched.exit_code != 0 or ($fetched.stdout | is-empty) { return null }
    let log = ($fetched.stdout | ansi strip)
    let dir = ($env.XDG_STATE_HOME? | default ($env.HOME | path join ".local" "state") | path join "ci" "check-failures" ($commit | str substring 0..<12))
    let path = ($dir | path join $"($attr | str replace --all --regex '[^A-Za-z0-9_.+-]+' '-').log")
    let saved = (try { mkdir $dir; $log | save --force $path; $path } catch { null })
    { reason: (build-failure-reason $log) log: $saved }
}

# The exit code of checks that ran in a transient unit, in Nu's convention (a
# signal N as -N), from the status their shell `recorded` and systemd-run's own
# exit status; null when the run was stopped. systemd counts a stop's SIGTERM
# as a clean exit, so a stopped run records nothing and systemd-run exits 0,
# while a unit killed whole records nothing and keeps systemd-run's status.
def unit-exit-code [recorded: string, systemd_run: int] {
    if ($recorded | is-empty) { return (if $systemd_run == 0 { null } else { $systemd_run }) }
    let code = ($recorded | into int)
    if $code > 128 { -1 * ($code - 128) } else { $code }
}

# nix-eval-jobs' memory budget per worker, in MiB. The budget is workers times
# this; past it, nix-eval-jobs kills the largest worker mid-check and retries
# that check alone, failing it if it exceeds the budget even then. Size it
# from nix-eval-jobs' own peak, not `nix eval`'s, which reports about 1.7 GiB
# less for the same check: a 4 GiB budget measured with `nix eval` (largest
# check 3.1 GiB) failed every dotfiles landing that evaluated homelab. Under
# nix-eval-jobs alone (2026-10-16) the largest dotfiles checks peak at 4.8 GiB
# (clan-machine-homelab) and 3.8 GiB (clan-machine-asus); 6 GiB leaves a
# quarter of headroom and evaluated them faster than 4 GiB, 178 s against
# 224 s. Keep it a whole number of GiB: failures name it in GiB.
const EVAL_MEMORY_MIB = 6144

# The status record for one check: a child of `clearance`, its name cut to
# the characters and length an OSC 7501 id segment allows.
def check-status-id [attr: string] {
    $"clearance/($attr | str replace --all --regex '[^A-Za-z0-9_.+-]+' '-' | str substring 0..<32)"
}

# Local clearance progress, before nix-fast-build reports anything. `names`
# lists the checks, or is null when listing them failed.
def checks-progress-start [names: any] {
    { names: $names seen: [] building: [] built: [] failed: [] explained: {} }
}

# The `clearance` record for `progress`: the newest build and its place
# among the checks, or how many have been evaluated while none builds.
def checks-progress-summary [progress: record] {
    let of = if $progress.names == null { "" } else { $"/($progress.names | length)" }
    let msg = if ($progress.building | is-empty) {
        $"evaluated ($progress.seen | length)($of) checks"
    } else {
        let newest = ($progress.building | last)
        let more = ($progress.building | length) - 1
        let others = if $more > 0 { $" and ($more) more" } else { "" }
        $"building ($newest.attr)($others) \(($newest.ordinal)($of))"
    }
    { state: "working" id: "clearance" msg: $msg }
}

# Fold one result nix-fast-build streamed into `progress`. Returns the next
# progress and the status reports it calls for, as { state id msg } records.
# A check that needs building starts once evaluated, since a free build job
# takes it at once; a cached one needs no report. nix-fast-build builds a
# derivation once, so a second check with the same derivation never starts.
def checks-progress-step [progress: record, result: record] {
    let attr = ($result.attr? | default "unknown-attribute")
    let id = (check-status-id $attr)
    match ($result.type? | default "") {
        "EVAL" => {
            let ordinal = ($progress.seen | length) + 1
            let progress = ($progress | update seen ($progress.seen ++ [$attr]))
            if not ($result.success? | default false) {
                let error = ($result.error? | default "")
                let msg = if $error =~ "exceeded the memory budget" {
                    $"($attr) exceeded ($EVAL_MEMORY_MIB // 1024) GiB"
                } else {
                    let reason = ($error | lines | where {|line| $line | str trim | is-not-empty } | last | default "" | str trim)
                    if ($reason | is-empty) { $"($attr) did not evaluate" } else { $"($attr) did not evaluate: ($reason)" }
                }
                return {
                    progress: ($progress | update failed ($progress.failed ++ [$msg]))
                    reports: [{ state: "error" id: $id msg: $msg }]
                }
            }
            let drv = ($result.drvPath? | default $attr)
            let cached = (($result.cacheStatus? | default "notBuilt") in ["cached" "local"]) or ($result.skipped? | default false)
            if $cached or $drv in $progress.built or ($progress.building | any {|build| $build.drv == $drv }) {
                return { progress: $progress reports: [] }
            }
            let progress = ($progress | update building ($progress.building ++ [{ attr: $attr drv: $drv ordinal: $ordinal }]))
            {
                progress: $progress
                reports: [
                    { state: "working" id: $id msg: $"building ($attr)" }
                    (checks-progress-summary $progress)
                ]
            }
        }
        "BUILD" => {
            let drv = ($progress.building | where attr == $attr | get --optional 0.drv | default $attr)
            let progress = ($progress
                | update building ($progress.building | where attr != $attr)
                | update built ($progress.built ++ [$drv]))
            if ($result.success? | default false) {
                let took = (($result.duration? | default 0 | math round) * 1sec)
                {
                    progress: $progress
                    reports: [
                        { state: "done" id: $id msg: $"($attr) built in ($took)" }
                        (checks-progress-summary $progress)
                    ]
                }
            } else {
                # The report carries the derivation, so the caller can say why
                # from its build log.
                let msg = $"($attr) did not build"
                {
                    progress: ($progress | update failed ($progress.failed ++ [$msg]))
                    reports: [
                        { state: "error" id: $id msg: $msg drv: $drv }
                        (checks-progress-summary $progress)
                    ]
                }
            }
        }
        _ => { { progress: $progress reports: [] } }
    }
}

# A killed run's outcome, naming what it cut short: the builds under way and
# the check being evaluated, which with one worker is the first in name order
# not yet reported, and any check already over the memory budget. Each check
# cut short reports error under its own record.
def checks-killed [error: string, progress: record] {
    let next = if $progress.names == null { null } else {
        $progress.names | where {|name| $name not-in $progress.seen } | get --optional 0
    }
    let building = ($progress.building | get attr)
    let cut = ([
        (if ($building | is-empty) { null } else { $"building ($building | str join ', ')" })
        (if $next == null { null } else { $"evaluating ($next)" })
    ] | compact)
    let during = if ($cut | is-empty) { "" } else { $", while ($cut | str join ' and ')" }
    let over = ($progress.failed | where {|msg| $msg =~ ' exceeded \d+ GiB$' })
    let budget = if ($over | is-empty) { "" } else { $" \(($over | str join ', '))" }
    {
        outcome: { status: "killed" error: $"($error)($during)($budget)" }
        reports: (($building | each {|attr| { state: "error" id: (check-status-id $attr) msg: $"($attr) was killed while building" } })
            ++ (if $next == null { [] } else { [{ state: "error" id: (check-status-id $next) msg: $"($next) was killed while evaluating" }] }))
    }
}

# Build every flake check at `commit` on this machine with nix-fast-build,
# streaming the build log. Outputs already in the local
# store or a binary cache are skipped, so a topic that leaves the system
# closures alone builds only the cheap checks. Evaluation uses one worker:
# two workers beside open agent sessions exhausted this 16 GiB machine and
# froze it (2026-10-07), and two workers sharing the same budget were slower
# than one (2026-10-16), since one worker reuses the evaluation the checks
# share, such as nixpkgs and each host's configuration.
#
# The checks run in their own transient user service with a memory cap, so
# when memory runs out the kernel or systemd-oomd stops that unit rather than
# the terminal or agent app that started `ci land`. They hold the local checks
# lock, so another session's landing waits rather than running beside them.
# systemd-run exits 0 for a service that a stop ended, which once let two
# topics land without their checks finishing (2026-10-07), so a shell in the
# unit records the checks' own exit status, and a run that recorded none fails.
#
# nix-fast-build streams each check's result to stdout as a JSON line, which
# this reads as it arrives and reports under `clearance`, while its build log
# goes to stderr as before. Nu drops the exit status of a command that feeds
# a pipeline, so another shell records it, systemd-run's own when there is a
# unit. The checks are listed first, by name only, to number them.
def local-checks-state [commit: string] {
    let unit = if ($env.XDG_RUNTIME_DIR? | is-empty) { null } else { $"ci-local-checks-($commit | str substring 0..7)" }
    let outcome = (with-local-checks-lock $commit --unit $unit {
        with-commit-trees { head: $commit } {|trees|
            let flake = $"path:($trees.head)"
            let attrs = $"($flake)#checks.x86_64-linux"
            let results = ($trees.head | path dirname | path join "checks.json")
            let status = ($trees.head | path dirname | path join "checks.status")
            let ran = ($trees.head | path dirname | path join "checks.ran")
            let nix = (which nix | get 0.path)
            let listed = (try { ^$nix --accept-flake-config eval --json $attrs --apply builtins.attrNames | complete } catch { { exit_code: 1 } })
            let names = if $listed.exit_code == 0 { try { $listed.stdout | from json } catch { null } } else { null }
            let checks = [$nix --accept-flake-config run --inputs-from $flake nixpkgs#nix-fast-build -- --no-nom --skip-cached --stream-json-lines --eval-workers 1 --eval-max-memory-size $EVAL_MEMORY_MIB --result-file $results --flake $attrs]
            let command = if $unit == null { $checks } else {
                [systemd-run --user --wait --pipe --collect --quiet --same-dir $"--unit=($unit)" -p MemoryHigh=7G -p MemoryMax=9G -p MemorySwapMax=2G -- /bin/sh -c '"$@"; echo $? > "$0"' $status ...$checks]
            }
            let streamed = try {
                let progress = (^/bin/sh -c '"$@"; echo $? > "$0"' $ran ...$command
                    | lines
                    | reduce --fold (checks-progress-start $names) {|line, progress|
                        let result = (try { $line | from json } catch { null })
                        if ($result | describe) !~ '^record' {
                            print $line
                            $progress
                        } else {
                            let step = (checks-progress-step $progress $result)
                            let failed_drv = ($step.reports | get --optional drv | compact | get --optional 0)
                            let failure = if $failed_drv == null { null } else { explain-build-failure $commit $result.attr $failed_drv }
                            for report in $step.reports {
                                let msg = if ($report.drv? | is-empty) { $report.msg } else { $"($report.msg)(build-failure-detail $failure)" }
                                report-status $report.state $msg --id $report.id
                            }
                            if $failure == null { $step.progress } else {
                                $step.progress | update explained {|progress| $progress.explained | upsert $result.attr $failure }
                            }
                        }
                    })
                { progress: $progress }
            } catch {|err| { error: $err.msg } }
            if $streamed.error? != null { return { status: "failed" error: $streamed.error } }
            let progress = $streamed.progress
            let recorded = (try { open --raw $ran | str trim } catch { "" })
            let exit_code = if $unit == null { unit-exit-code $recorded 0 } else {
                let systemd_run = (try { $recorded | into int } catch { 0 })
                unit-exit-code (try { open --raw $status | str trim } catch { "" }) $systemd_run
            }
            let outcome = if $exit_code == null {
                { status: "killed" error: "stopped before it finished" }
            } else {
                checks-outcome $exit_code $results $progress.explained
            }
            if $outcome.status != "killed" { return $outcome }
            let killed = (checks-killed $outcome.error $progress)
            for report in $killed.reports { report-status $report.state $report.msg --id $report.id }
            $killed.outcome
        }
    })
    let state = if $outcome.status == "success" { "success" } else { "failed" }
    { state: $state workflows: [{ name: "flake checks" status: $outcome.status error: ($outcome.error? | default "") }] }
}

# The check that gates a landing: the flake checks built on this machine,
# GitHub Actions on the mirror, or nixbot's check runs on the mirror.
def landing-gate [gate: string] {
    match $gate {
        "local" => {
            {
                name: $"local flake checks on (sys host | get hostname)"
                probe: {|commit| local-checks-state $commit }
                hint: ""
            }
        }
        "github" => {
            let github = (github-repo)
            {
                name: $"GitHub Actions on ($github)"
                probe: {|commit| github-checks-state $github $commit }
                hint: "If none started, check that .github/workflows/nix-ci.yml runs on pushes to jj-* branches."
            }
        }
        "nixbot" => {
            let github = (github-repo)
            {
                name: $"nixbot on ($github)"
                probe: {|commit| github-checks-state $github $commit $NIXBOT_REQUIRED_CHECKS }
                hint: $"If none started, check that ($NIXBOT_CONFIG) on main lists jj-* in build_branches, the project is enabled in nixbot, and the GitHub App's webhook deliveries succeed."
            }
        }
        _ => { error make { msg: $"Unknown clearance ($gate); use local, github, or nixbot." } }
    }
}

# Poll the gate until it passes `commit`. Stop at the first failure; never
# rebase or push.
def wait-for-pipeline [gate: record, commit: string, timeout: duration] {
    let deadline = (date now) + $timeout
    mut last = ""
    report-status working $"Waiting for ($gate.name)" --id clearance
    loop {
        let pipeline = (do $gate.probe $commit)
        if $pipeline.state == "success" {
            report-status done $"($gate.name) passed" --id clearance
            return
        }
        if $pipeline.state == "failed" {
            let failed = ($pipeline.workflows | where status != "success" | each {|workflow|
                let detail = if ($workflow.error? | is-empty) { "" } else { $" \(($workflow.error | lines | last))" }
                $"($workflow.name): ($workflow.status)($detail)"
            })
            report-status error $"($gate.name) rejected the head: ($failed | str join '; ')" --id clearance
            error make { msg: $"($gate.name) rejected ($commit | str substring 0..11): ($failed | str join '; '). Leave the task open." }
        }
        let status = if $pipeline.state == "missing" {
            $"waiting for ($gate.name) to start. ($gate.hint)" | str trim
        } else {
            $"($pipeline.workflows | where status != 'success' | length) workflow\(s) running"
        }
        if $status != $last {
            print $"(date now | format date '%H:%M:%S') ($status)"
            report-status working $"($gate.name): ($status)" --id clearance
            $last = $status
        }
        if (date now) > $deadline {
            report-status error $"No passing pipeline after ($timeout)" --id clearance
            error make { msg: $"No passing pipeline for ($commit | str substring 0..11) after ($timeout). ($gate.hint)" }
        }
        sleep 30sec
    }
}

def current-topic-id [] {
    current-change 'change_id'
}

def publication-state-path [] {
    let root = (git-command "locating the workspace" { ^jj root })
    $root | path join ".jj" "jj-ci-publication.json"
}

def publication-state [] {
    let path = (publication-state-path)
    if ($path | path exists) { open $path } else { {} }
}

def save-publication-state [state: record] {
    $state | to json | save --force (publication-state-path)
}

def publication-topics [] {
    (publication-state) | get topics? | default {}
}

def slugify [title: string] {
    $title
    | str lowercase
    | str replace --all --regex "[^a-z0-9]+" "-"
    | str substring 0..47
    # Trim after truncation so a cut at a word boundary leaves no dash.
    | str trim --char "-"
}

def publication-slug [] {
    slugify (current-change "description.first_line()")
}

def legacy-publication-bookmark [bookmark: string] {
    let result = (^jj log -r $"($bookmark) & @" --no-graph -T 'commit_id' | complete)
    $result.exit_code == 0 and ($result.stdout | str trim | is-not-empty)
}

# Remembers the bookmark under the current topic's change id, so it survives
# title edits without leaking into whatever other topic next runs in this
# workspace (a single unscoped bookmark previously caused `publish` to reuse
# an already-merged topic's bookmark and PR).
def remember-publication-bookmark [bookmark: string] {
    let topics = (publication-topics) | upsert (current-topic-id) $bookmark
    save-publication-state { topics: $topics }
}

def forget-publication-bookmark [topic_id?: string] {
    let topic_id = ($topic_id | default (current-topic-id))
    let topics = (publication-topics)
    if $topic_id in $topics {
        save-publication-state { topics: ($topics | reject $topic_id) }
    }
}

def publication-bookmark [topic_id?: string] {
    let topic_id = ($topic_id | default (current-topic-id))
    let topics = (publication-topics)
    let remembered = if $topic_id in $topics {
        $topics | get $topic_id
    } else {
        # Migrate the pre-per-topic single-bookmark state, but only if it
        # still names the bookmark actually checked out right now — otherwise
        # a stale entry left by a different, already-finished topic would
        # leak onto whatever topic asks next.
        let legacy_single = (publication-state) | get bookmark? | default ""
        if ($legacy_single | is-not-empty) and (legacy-publication-bookmark $legacy_single) {
            $legacy_single
        } else {
            ""
        }
    }
    if ($remembered | is-not-empty) { return $remembered }

    let legacy = $"jj-($topic_id)"
    if (legacy-publication-bookmark $legacy) { return $legacy }

    new-publication-bookmark $topic_id (publication-slug)
}

def new-publication-bookmark [topic_id: string, slug: string] {
    let short_id = ($topic_id | str substring 0..7)
    let label = if ($slug | is-empty) { "topic" } else { $slug }
    $"jj-($label)-($short_id)"
}

def push-bookmark [remote: string, bookmark: string] {
    # jj refuses to create a new bookmark on a remote it does not track.
    run-command $"tracking ($bookmark)@($remote)" {
        ^jj bookmark track $"($bookmark)@($remote)"
    } | ignore
    run-remote $"pushing ($bookmark) to ($remote)" {
        ^jj git push --remote $remote --bookmark $bookmark
    } | ignore
}

def push-topic-bookmark [bookmark: string] {
    push-bookmark (trunk-remote) $bookmark
}

def remote-bookmark-revset [bookmark: string, remote?: string] {
    let name = if $remote == null { trunk-remote } else { $remote }
    $"remote_bookmarks\(exact:'($bookmark)', exact:'($name)')"
}

# Delete a delivered topic's bookmark locally, on the trunk remote, and on
# any mirror that holds it: GitHub's when a GitHub-gated landing pushed it
# there, or the former trunk's after the trunk moved.
def delete-topic-bookmark [bookmark: string] {
    if (revset-change-ids (bookmark-revset $bookmark) | is-not-empty) {
        run-command $"deleting ($bookmark)" { ^jj ...(checkpoint-tag) bookmark delete $bookmark } | ignore
    }
    for remote in ([(trunk-remote)] | append $TRUNK_REMOTES | uniq) {
        if (revset-change-ids (remote-bookmark-revset $bookmark $remote) | is-not-empty) {
            run-remote $"deleting ($bookmark) from ($remote)" {
                ^jj git push --remote $remote --bookmark $bookmark
            } | ignore
        }
    }
}

# Whether the trunk remote's copy of a topic bookmark is already on main.
def topic-landed [bookmark: string] {
    revset-change-ids $"(remote-bookmark-revset $bookmark) & ::(trunk-revset)" | is-not-empty
}

# Published topics: every local `jj-*` bookmark that is on the trunk remote and
# has work above main. A topic built on another one is stacked on the nearest
# such topic below it, so the graph alone records every stack.
def topic-bookmarks [] {
    let remote = (trunk-remote)
    let trunk = "trunk()"
    let listing = (git-command "listing topic bookmarks" {
        ^jj bookmark list -T 'if(!remote && normal_target, name ++ "\t" ++ normal_target.commit_id() ++ "\n")' 'glob:jj-*'
    })
    let topics = ($listing | lines | where {|line| $line | is-not-empty } | each {|line|
        let fields = ($line | split row "\t")
        { name: ($fields | first) commit: ($fields | last) }
    } | where {|topic|
        let pushed = (revset-change-ids (remote-bookmark-revset $topic.name $remote) | is-not-empty)
        $pushed and (revset-change-ids $"($trunk)..(bookmark-revset $topic.name)" | is-not-empty)
    })
    $topics | each {|topic|
        let below = ($topics | where {|other|
            $other.commit != $topic.commit and (revset-change-ids $"(bookmark-revset $other.name) & ::(bookmark-revset $topic.name) ~ ::($trunk)" | is-not-empty)
        })
        let parent = if ($below | is-empty) {
            null
        } else {
            let heads = (revset-change-ids $"heads\(($below | each {|other| bookmark-revset $other.name } | str join ' | '))")
            $below | where {|other| (revset-change-ids (bookmark-revset $other.name) | first) in $heads } | first | get name
        }
        $topic | insert parent $parent
    }
}

def topic-revisions [] {
    let result = (^jj log -r $"(trunk-revset)..@" --no-graph -T 'change_id ++ "\t" ++ commit_id ++ "\t" ++ description.first_line() ++ "\n"' | complete)
    if $result.exit_code != 0 { error make { msg: ($result.stderr | str trim) } }
    $result.stdout
    | lines
    | where {|line| $line | str trim | is-not-empty }
    | reverse
    | each {|line|
        let fields = ($line | split row "\t")
        {
            change_id: ($fields | get 0)
            commit_id: ($fields | get 1)
            description: ($fields | skip 2 | str join "\t")
        }
    }
}

def push-tangled-stack [] {
    let series = (current-topic-id)
    let revisions = (topic-revisions)
    if ($revisions | is-empty) {
        error make { msg: "The current topic has no revisions above main." }
    }

    let remote = (trunk-remote)
    print $"Publishing ($revisions | length) Tangled stack layer\(s) for series ($series):"
    for revision in $revisions {
        let branch = $"stack/($series)/($revision.change_id)"
        run-remote $"pushing ($branch) to ($remote)" {
            ^jj git push --remote $remote --named $"($branch)=($revision.commit_id)"
        } | ignore
        print $"  ($branch): ($revision.description)"
    }
    print "Select `Submit as stacked PRs` in Tangled for these branches."
}

# A checkpoint lets `ci recover` undo the rewrite that follows it and nothing
# else. Every JJ command that rewrites history under a checkpoint carries its
# ID as `--config ci.checkpoint="ID"` (checkpoint-tag), and JJ keeps each
# command's arguments with the operations it records, so recovery reverts
# exactly those operations. Restoring the operation before the rewrite would
# rewind the whole repository instead: on 2026-10-16 a session restored a
# failed landing's recovery point 14 seconds later and undid another
# workspace's dispatch in between, leaving its pushed bookmark untracked.
const CHECKPOINT_KEY = "ci.checkpoint"
const RECOVERED_KEY = "ci.recovered"

# Record a checkpoint and tag the caller's later JJ rewrites with it. The tag
# lives in the caller's environment, so it ends when the caller returns.
def --env checkpoint [label: string] {
    let root = (git-command "locating the workspace" { ^jj root })
    let operation = (git-command "recording a recovery point" {
        ^jj op log -n 1 --no-graph -T 'self.id()'
    })
    let id = $"(date now | format date '%Y%m%dT%H%M%S%f')-($label)-(random chars --length 6)"
    let directory = ($root | path join ".jj" "jj-ci-checkpoints")
    mkdir $directory
    { id: $id label: $label operation: $operation } | to json --raw | save --force ($directory | path join $id)
    $env.CI_CHECKPOINT = $id
    print $"Recovery point: `ci recover ($id)` undoes this ($label) and nothing else."
}

# The arguments that tag a JJ command with the current checkpoint, if any.
def checkpoint-tag [] {
    let id = ($env.CI_CHECKPOINT? | default "")
    if $id == "" { [] } else { [--config $"($CHECKPOINT_KEY)=\"($id)\""] }
}

# How to undo the current checkpoint's rewrite, for an error message.
def recovery-hint [] {
    let id = ($env.CI_CHECKPOINT? | default "")
    if $id == "" { "" } else { $" To put the topic back as it was instead, run `ci recover ($id)`." }
}

# JJ's operation log, newest first, as rows of { id description attributes
# snapshot parents }.
def operation-log [] {
    let result = (local-complete {
        ^jj op log --no-graph --ignore-working-copy -T 'self.id() ++ "\x1f" ++ self.description().first_line() ++ "\x1f" ++ self.attributes() ++ "\x1f" ++ self.snapshot() ++ "\x1f" ++ self.parents().len() ++ "\x1e"'
    })
    if $result.exit_code != 0 { error make { msg: ($result.stderr | str trim) } }
    $result.stdout | split row (char -u "1e") | where {|row| $row | str trim | is-not-empty } | each {|row|
        let fields = ($row | str trim --left | split row (char -u "1f"))
        {
            id: $fields.0
            description: $fields.1
            attributes: $fields.2
            snapshot: ($fields.3 == "true")
            parents: ($fields.4 | into int)
        }
    }
}

# The operations checkpoint `id`'s rewrite recorded, newest first. A tagged
# command also tags the snapshot of edits made before it ran and the merge JJ
# records when it reconciles concurrent operations; neither is the rewrite,
# and reverting the merge would undo the other side's work.
def checkpoint-operations [operations: list, id: string] {
    let marker = $"($CHECKPOINT_KEY)=\"($id)\""
    $operations | where {|op| ($op.attributes | str contains $marker) and not $op.snapshot and $op.parents == 1 }
}

# The revset of the commits a rewrite's operations (newest first) made and
# left visible when its last operation finished.
def rewrite-results []: list -> string {
    let rewrite = $in
    let made = ($rewrite | each {|op| $"\(at_operation\(($op.id), all\()) ~ at_operation\(($op.id)-, all\()))" } | str join " | ")
    $"\(($made)) & at_operation\(($rewrite | first | get id), all\())"
}

# What stops `ci recover` from reverting `rewrite`, the operations of one
# checkpoint, or null. Reverting is safe only while the rewrite's results stand
# as it left them: once someone resolved, edited, or abandoned one of its
# commits, reverting would fork that work into a divergent copy.
def recovery-problem [operations: list, id: string, rewrite: list] {
    let recovered = $"($RECOVERED_KEY)=\"($id)\""
    if ($operations | any {|op| $op.attributes | str contains $recovered }) {
        return $"Checkpoint ($id) was already recovered."
    }
    if ($rewrite | is-empty) {
        return $"No operation carries checkpoint ($id): it rewrote nothing, or the rewrite predates `ci recover`."
    }
    # Not `~ all()`: all() also holds every hidden commit a revset names.
    let changed = (revset-change-ids $"\(($rewrite | rewrite-results)) ~ ::visible_heads\()")
    if ($changed | is-not-empty) {
        return $"Since checkpoint ($id), ($changed | str join ', ') changed again, so reverting would fork that work. Resolve the topic in place, or revert its operations by hand with `jj op revert`."
    }
    null
}

# Undo a checkpoint's rewrite and nothing else, reverting its operations
# newest first. Other workspaces' operations since the checkpoint stay.
def "main recover" [
    checkpoint?: string # The ID `ci` printed with "Recovery point"; defaults to this workspace's latest
] {
    require-jj-workspace-here
    let id = if $checkpoint != null { $checkpoint } else {
        let root = (git-command "locating the workspace" { ^jj root })
        let directory = ($root | path join ".jj" "jj-ci-checkpoints")
        let names = if ($directory | path exists) { ls $directory | get name | each { path basename } | sort } else { [] }
        if ($names | is-empty) { error make { msg: "This workspace has no checkpoint to recover." } }
        $names | last
    }
    with-topic-lock (current-topic-id) {
        let operations = (operation-log)
        let rewrite = (checkpoint-operations $operations $id)
        let problem = (recovery-problem $operations $id $rewrite)
        if $problem != null { error make { msg: $problem } }
        let moved = (other-workspaces-in ($rewrite | rewrite-results))
        for op in $rewrite {
            run-command $"reverting ($op.description)" {
                ^jj --config $"($RECOVERED_KEY)=\"($id)\"" op revert $op.id
            } | ignore
        }
        update-moved-workspaces $moved
        print $"Recovered checkpoint ($id): reverted ($rewrite | length) operation\(s); other workspaces' operations since then stay."
    }
}

def session-owner [] {
    let root = (git-command "locating the workspace" { ^jj root })
    let path = ($root | path join ".jj" "codex-session.json")
    if ($path | path exists) { open $path } else { null }
}

# How a Codex task's ownership record ends. `delivered` and `discarded` come
# from `finish` and `abandon`; `released` frees a workspace whose task left its
# change behind, and says nothing about the topic, which may continue elsewhere.
const OWNER_ENDINGS = ["delivered" "discarded" "released"]

# The state an ownership record declares: none, active, or one of the endings.
# A record from before `state` has only `finished`, which a hand edit could set
# as easily as `finish`, so it proves release but never delivery. Keep in step
# with owner-status in codex-session.nu and context-status.nu.
def owner-status [owner: any] {
    if $owner == null { return "none" }
    let state = ($owner.state? | default "")
    if $state == "active" or $state in $OWNER_ENDINGS { return $state }
    if ($owner.finished? | default false) { "released" } else { "active" }
}

# Run from a Git worktree nested in the repository, such as a Claude Code
# worktree, `jj` resolves to the shared checkout above it, so a topic command
# there would move or rewrite that checkout's working copy, as one session's
# `ci new` once moved another's (2026-10-07).
def require-jj-workspace-here [] {
    let root = (git-command "locating the workspace" { ^jj root })
    let worktree = (enclosing-git-worktree $env.PWD $root)
    if $worktree != null {
        error make { msg: $"($worktree) is a Git worktree, not a JJ workspace, so this command would act on the shared checkout at ($root). Run `ci start NAME` here, then work in ($worktree)/.jj-workspaces/NAME." }
    }
}

def require-owned-change [topic_id?: string] {
    require-jj-workspace-here
    let owner = (session-owner)
    if (owner-status $owner) == "active" {
        if $owner.change_id != ($topic_id | default (current-topic-id)) {
            error make { msg: "This workspace is on a different change from its active Codex task. Resolve ownership before continuing." }
        }
    }
    require-topic-checked-out
}

# Whether the working copy has wandered off the topic that `ci start`
# recorded, as after a manual `jj new main`: it is an empty change the topic is
# not an ancestor of, while the topic still holds unlanded work. A topic that
# was abandoned, squashed away, or landed no longer counts, and a stack or a
# split keeps the topic below the working copy, so neither trips this.
def topic-stranded [facts: record] {
    $facts.recorded and $facts.visible and not $facts.landed and not $facts.ancestor and $facts.working_copy_empty and not $facts.topic_empty
}

def topic-facts [] {
    let root = (^jj root | complete)
    if $root.exit_code != 0 { error make { msg: ($root.stderr | str trim) } }
    let marker = (owned-workspace-marker ($root.stdout | str trim))
    let topic = if ($marker | path exists) { open $marker | get change_id? } else { null }
    if $topic == null {
        return { recorded: false visible: false landed: false ancestor: false working_copy_empty: false topic_empty: false topic: null }
    }
    let has = {|revset| revset-change-ids $"change_id\(($topic)\) & \(($revset)\)" | is-not-empty }
    {
        recorded: true
        visible: (do $has "all()")
        landed: (do $has $"::(trunk-revset)")
        ancestor: (do $has "::@")
        working_copy_empty: ((current-change "empty") == "true")
        topic_empty: (do $has "empty() & description(exact:\"\")")
        topic: $topic
    }
}

def require-topic-checked-out [] {
    let facts = (topic-facts)
    if not (topic-stranded $facts) { return }
    let short = ($facts.topic | str substring 0..7)
    let title = (revision-field $"change_id\(($facts.topic)\)" "description.first_line()")
    let stray = (current-change "change_id.short()")
    error make { msg: $"The working copy \(($stray)) has left this workspace's topic ($short) \"($title)\", as after `jj new main`. Return with `jj edit ($short)` and `jj abandon ($stray)`, or run `jj abandon ($short)` if the topic is meant to be dropped." }
}

# With --allow-empty, an empty change passes undescribed: there is nothing
# to describe, and the checks that follow run on the tree it inherits.
def require-ready-change [--allow-empty] {
    require-owned-change
    if (current-change "conflict") == "true" {
        error make { msg: "Resolve JJ conflicts before publishing." }
    }
    if (current-change "empty") == "true" {
        if not $allow_empty { error make { msg: "The current JJ change is empty." } }
        return
    }
    if ((current-change "description.first_line()") | is-empty) {
        print "Describing the current JJ change."
        run-command "describing the current JJ change" { ^jj-describe } | ignore
        if ((current-change "description.first_line()") | is-empty) {
            error make { msg: "jj-describe did not describe the current JJ change." }
        }
    }
}

def conflicted-revisions [stack: string = "::@"] {
    let result = (^jj log -r $"conflicts\() & \(($stack)\)" --no-graph -T 'change_id ++ "\t" ++ description.first_line() ++ "\n"' | complete)
    if $result.exit_code != 0 { error make { msg: ($result.stderr | str trim) } }
    $result.stdout | lines | where {|line| $line | str trim | is-not-empty } | each {|line|
        let fields = ($line | split row "\t")
        {
            change_id: ($fields | first)
            description: ($fields | skip 1 | str join "\t")
        }
    }
}

def print-conflicted-files [revisions: list, indent: string] {
    for $revision in $revisions {
        print $"($indent)($revision.change_id) ($revision.description)"
        let files = (^jj resolve --list -r $revision.change_id | complete)
        if $files.exit_code == 0 {
            let paths = ($files.stdout | lines | where {|line| $line | str trim | is-not-empty })
            for $path in $paths { print $"($indent)  ($path)" }
        }
    }
}

def print-conflicts [context: string] {
    let revisions = (conflicted-revisions)
    if ($revisions | is-empty) {
        print $"($context): no conflicts in the current topic stack."
        return false
    }

    print $"($context): ($revisions | length) conflicted revision\(s):"
    print-conflicted-files $revisions "  "
    print ""
    print $"Topic tip before selecting a revision: (current-topic-id)"
    print "Resolve each revision in order, then run `ci conflicts` again."
    print "For a revision that is not @: run `jj edit CHANGE_ID`, edit or `jj resolve` its files, then return with `jj edit TOPIC_TIP`."
    print "Do not re-run `ci rebase` until the current topic is conflict-free; the rebase already completed."
    true
}

def fetch-trunk [] {
    let remote = (trunk-remote)
    run-remote $"fetching ($remote)" { ^jj git fetch --remote $remote } | ignore
}

def rebase-topic [] {
    require-owned-change
    if (print-conflicts "Before rebase") {
        error make { msg: "Resolve existing conflicts before rebasing onto main." }
    }
    checkpoint "rebase"
    fetch-trunk
    let trunk = (trunk-revset)
    let moved = (other-workspaces-in $"roots\(($trunk)..@)::")
    run-command "rebasing the topic stack" {
        ^jj ...(checkpoint-tag) rebase -s $"roots\(($trunk)..@)" -o $trunk --skip-emptied
    } | ignore
    update-moved-workspaces $moved
    if (print-conflicts "Rebase completed") {
        error make { msg: $"Rebase completed with conflicts. Resolve them before continuing.(recovery-hint)" }
    }
}

def revset-change-ids [revset: string] {
    let result = (local-complete { ^jj log -r $revset --no-graph -T 'change_id.short() ++ "\n"' })
    if $result.exit_code != 0 { error make { msg: ($result.stderr | str trim) } }
    $result.stdout | lines | where {|line| $line | str trim | is-not-empty }
}

# Every change declares its effect on the built machines with `ci impact set`,
# which records a `ci.impact.set` event in the ci log keyed by the full change
# ID. Change IDs survive rebases, so a declaration follows its change to
# trunk, and the latest one for a change wins. The description stays prose.
# Classes, from least to most disruptive:
#   refactor  every NixOS closure is unchanged (refactors, docs, CI, tooling)
#   behavior  user-facing change; landing it cuts a CalVer release
#   breaking  user-facing change that lists the manual steps it needs
const IMPACTS = ["refactor" "behavior" "breaking"]
const IMPACT_EVENT = "ci.impact.set"

# Why `impact` with manual `steps` is not a valid declaration, or null.
def impact-problem [impact: string, steps: list] {
    if $impact not-in $IMPACTS {
        return $"Declare the impact as one of ($IMPACTS | str join ', ') with `ci impact set`."
    }
    if ($steps | any {|step| ($step | describe) != "string" or ($step | str trim | is-empty) }) {
        return "Every manual step must be non-empty text."
    }
    if $impact == "breaking" and ($steps | is-empty) {
        return "A breaking change must list the manual steps it needs: `ci impact set breaking STEP...`."
    }
    if $impact != "breaking" and ($steps | is-not-empty) {
        return $"Only a breaking change lists manual steps; declare it breaking or drop the steps."
    }
    null
}

# The latest declaration for each change in `records` (from read-ci-log), as
# { CHANGE_ID: { impact, steps, time } }.
def impact-declarations [records: list] {
    $records
    | where event == $IMPACT_EVENT
    | reduce --fold {} {|record, declarations|
        let change = ($record.attributes."ci.change_id"? | default "")
        if ($change | is-empty) { return $declarations }
        $declarations | upsert $change {
            impact: ($record.attributes."ci.impact"? | default "")
            steps: ($record.attributes."ci.impact.steps"? | default [])
            time: $record.time
        }
    }
}

# `revisions` with each one's declared `impact` ("" when undeclared; not null,
# which `each` would drop) and `steps`.
def with-impacts [revisions: list] {
    let declarations = (impact-declarations (read-ci-log --event $IMPACT_EVENT))
    $revisions | each {|revision|
        let declaration = ($declarations | get --optional $revision.change_id)
        $revision
        | insert impact ($declaration.impact? | default "")
        | insert steps ($declaration.steps? | default [])
    }
}

# The combined impact of the revisions in `revset`, or null when it has none.
def revset-impact [revset: string] {
    combine-impacts (with-impacts (revisions-in $revset) | each {|revision| $revision.impact }) | get impact
}

# Impact used to be an `Impact:` trailer in the description. `ci impact
# import` reads one into a declaration; nothing else looks at descriptions.
const IMPACT_TRAILER = '^(?i)impact:\s*(?P<value>\S+)\s*$'

# The last `Impact:` trailer value in a description, lowercased, or "" when
# there is none.
def parse-impact [description: string] {
    let values = ($description | lines | parse --regex $IMPACT_TRAILER | get value | str lowercase)
    if ($values | is-empty) { "" } else { $values | last }
}

# A description without its subject line and `Impact:` trailer.
def description-body [description: string] {
    $description
    | lines
    | skip 1
    | where {|line| $line | parse --regex $IMPACT_TRAILER | is-empty }
    | str join "\n"
    | str trim
}

# The impact of one topic from the impacts of its revisions. A topic lands as
# a unit, so a refactor must not share one with a user-facing change: it would
# lose its closure-neutral guarantee and ship inside a release. Returns
# { impact, problem } with exactly one non-null.
def combine-impacts [impacts: list] {
    if ($impacts | is-empty) {
        return { impact: null problem: "The topic has no revisions to classify." }
    }
    let invalid = ($impacts | where {|impact| $impact not-in $IMPACTS })
    if ($invalid | is-not-empty) {
        return { impact: null problem: $"Every revision needs a declared impact: `ci impact set ($IMPACTS | str join '|') -r REV`." }
    }
    let user_facing = ($impacts | where {|impact| $impact != "refactor" })
    if ($user_facing | is-empty) {
        { impact: "refactor" problem: null }
    } else if ($user_facing | length) != ($impacts | length) {
        { impact: null problem: "This topic mixes refactor and user-facing revisions. Publish the refactor as its own topic, or as the parent layer of a stack if the change depends on it." }
    } else if "breaking" in $user_facing {
        { impact: "breaking" problem: null }
    } else {
        { impact: "behavior" problem: null }
    }
}

# Sort key that lands refactors before user-facing changes.
def impact-order [impact: any] {
    if $impact == "refactor" { 0 } else { 1 }
}

# The next CalVer release for `date` (YYYY.MM.DD) given the existing tags.
def next-version [date: string, tags: list<string>] {
    let pattern = ('^' + ($date | str replace --all '.' '\.') + '\.(?P<serial>[0-9]+)$')
    let serials = ($tags | parse --regex $pattern | get serial | into int)
    let serial = if ($serials | is-empty) { 1 } else { ($serials | math max) + 1 }
    $"($date).($serial)"
}

# Revisions in `base..@`, oldest first, with full descriptions.
def layer-revisions [base: string] {
    revisions-in $"($base)..@"
}

# Revisions in `revset`, oldest first, as { change_id, short, commit_id,
# description }.
def revisions-in [revset: string] {
    let template = 'change_id ++ "\t" ++ change_id.short() ++ "\t" ++ commit_id ++ "\t" ++ description.escape_json() ++ "\n"'
    let result = (local-complete { ^jj log -r $revset --no-graph -T $template })
    if $result.exit_code != 0 { error make { msg: ($result.stderr | str trim) } }
    $result.stdout
    | lines
    | where {|line| $line | str trim | is-not-empty }
    | reverse
    | each {|line|
        let fields = ($line | split row "\t")
        {
            change_id: ($fields | first)
            short: ($fields | get 1)
            commit_id: ($fields | get 2)
            description: ($fields | skip 3 | str join "\t" | from json)
        }
    }
}

# The combined impact of `revisions`, failing when any lacks a valid
# declaration or the topic mixes refactors with user-facing changes.
def require-impact [revisions: list] {
    let revisions = (with-impacts $revisions)
    for revision in ($revisions | where impact not-in $IMPACTS) {
        print --stderr $"($revision.short): no impact declared; run `ci impact set ($IMPACTS | str join '|') -r ($revision.short)`."
    }
    let result = (combine-impacts ($revisions | each {|revision| $revision.impact }))
    if $result.problem != null { error make { msg: $result.problem } }
    let problems = ($revisions | each {|revision|
        let problem = (impact-problem $revision.impact $revision.steps)
        if $problem == null { null } else { $"($revision.short): ($problem)" }
    } | compact)
    if ($problems | is-not-empty) { error make { msg: ($problems | str join "\n") } }
    $result.impact
}

# Record `impact` and `steps` for each revision in `revisions`. The log write
# must succeed: a declaration that was not recorded would silently vanish.
def declare-impact [revisions: list, impact: string, steps: list] {
    let problem = (impact-problem $impact $steps)
    if $problem != null { error make { msg: $problem } }
    for revision in $revisions {
        log-event $IMPACT_EVENT $"($revision.short) is ($impact)" {
            "ci.change_id": $revision.change_id
            "ci.impact": $impact
            "ci.impact.steps": $steps
            "vcs.ref.head.revision": $revision.commit_id
        } --required
        let title = ($revision.description | lines | get --optional 0 | default "(no description)")
        print $"($revision.short) ($title): ($impact)"
        for step in $steps { print $"  - ($step)" }
    }
}

# Host name to toplevel derivation for every NixOS configuration in a flake;
# a flake without `nixosConfigurations` has no hosts. The flake is loaded
# through its locked reference, since pure evaluation refuses an unlocked
# `builtins.getFlake`, so a missing output stays distinct from a host that
# fails to evaluate. The locked URL is percent-encoded and so holds no `${`,
# which makes its JSON form a valid Nix string.
def closure-fingerprint [flake: string] {
    let locked = (git-command $"locking ($flake)" {
        ^nix flake metadata --json --no-update-lock-file $flake
    } | from json | get url)
    git-command $"evaluating the NixOS closures of ($flake)" {
        ^nix eval --json --no-update-lock-file --apply 'flake: builtins.mapAttrs (_: c: builtins.unsafeDiscardStringContext c.config.system.build.toplevel.drvPath) (flake.nixosConfigurations or {})' --expr $"builtins.getFlake ($locked | to json)"
    } | from json
}

# Hosts whose closure differs between two fingerprints, including added and
# removed hosts.
def closure-differences [base: record, head: record] {
    $base | columns | append ($head | columns) | uniq | sort | where {|host|
        ($base | get --optional $host) != ($head | get --optional $host)
    }
}

def bookmark-revset [bookmark: string] {
    $"bookmarks\(exact:'($bookmark)')"
}

# Move the commits of `tip` that are in neither `onto` nor main onto `onto`.
# Commits that become empty were already delivered and are dropped. Returns
# the revset of the restacked topic. With a workspace root, the rebase runs
# there so that working copy moves with it instead of going stale.
def restack [tip: string, onto: string, workspace?: string] {
    let repository = if $workspace == null { [] } else { [--repository $workspace] }
    if (revset-change-ids $"($onto) & ~::($tip)" | is-not-empty) {
        run-command $"rebasing ($tip) onto ($onto)" {
            ^jj ...(checkpoint-tag) ...$repository rebase -s $"roots\(::($tip) ~ ::($onto) ~ ::(trunk-revset))" -o $onto --skip-emptied
        } | ignore
    }
    $"($onto)..($tip)"
}

# Names of the workspaces whose working copy is in `revset`.
def workspaces-in [revset: string] {
    let result = (^jj log -r $"\(($revset)) & working_copies\()" --no-graph -T 'working_copies.map(|w| w.name()).join("\n") ++ "\n"' | complete)
    if $result.exit_code != 0 { error make { msg: ($result.stderr | str trim) } }
    $result.stdout | lines | where {|name| $name | str trim | is-not-empty } | uniq
}

def workspace-root [name: string] {
    run-command $"locating workspace ($name)" { ^jj workspace root --name $name }
}

# Rewriting a change rebases its descendants, and every other workspace that
# has one of them checked out goes stale: its files still show the old commit,
# and JJ refuses to run there until `jj workspace update-stale`. Sessions kept
# finding their workspaces stale after another session rebased or abandoned a
# topic below theirs, and a switch once built a stale checkout (2026-10-07).
# So a `ci` command that rewrites names the other workspaces it will move
# before rewriting, and updates them afterwards. update-stale never
# overwrites a file edited there since JJ last snapshotted it.
def other-workspaces-in [revset: string] {
    let current = (git-command "locating the workspace" { ^jj root })
    workspaces-in $revset | where {|name|
        let root = (^jj workspace root --name $name | complete)
        $root.exit_code != 0 or ($root.stdout | str trim) != $current
    }
}

# Whether `jj workspace update-stale` found nothing to do.
def update-stale-noop [stderr: string] {
    $stderr | str contains "working copy is not stale"
}

def update-moved-workspaces [names: list<string>] {
    for name in $names {
        let found = (^jj workspace root --name $name | complete)
        let root = ($found.stdout | str trim)
        if $found.exit_code != 0 or not ($root | path exists) { continue }
        let updated = (local-complete { ^jj --repository $root workspace update-stale })
        if $updated.exit_code != 0 {
            print --stderr $"Could not update workspace ($name) at ($root): ($updated.stderr | str trim). Run `jj workspace update-stale` there."
        } else if not (update-stale-noop $updated.stderr) {
            print $"Updated workspace ($name), whose checked-out change this rewrite moved."
        }
    }
}

# Restack a topic that other workspaces have checked out. Each one is
# snapshotted first so no unrecorded edit is lost, the rebase runs only when a
# trial merge predicts no conflict, and the remaining workspaces are updated
# so none is left stale. Returns { stack } or, when the topic was left
# untouched, { reason }.
def restack-checked-out [bookmark: string, onto: string, workspaces: list<string>] {
    let roots = ($workspaces | each {|name| workspace-root $name })
    let unreachable = ($roots | where {|root| not ($root | path exists) })
    if ($unreachable | is-not-empty) {
        return { reason: $"cannot reach ($unreachable | str join ', ')" }
    }
    for root in $roots {
        run-command $"snapshotting ($root)" { ^jj --repository $root status } | ignore
    }
    if (conflicted-revisions $"($onto)..($bookmark)" | is-not-empty) {
        return { reason: "already conflicted" }
    }
    if (trial-merge [$onto (revision-id $bookmark)]).conflict {
        return { reason: "would conflict" }
    }
    let stack = (restack $bookmark $onto ($roots | first))
    for root in ($roots | skip 1) {
        run-command $"updating ($root)" { ^jj --repository $root workspace update-stale } | ignore
    }
    { stack: $stack }
}

# Whether a published topic needs rewriting. `ci land` rebases a topic
# onto main itself, so rebasing one that merely fell behind only restarts its
# pipeline. A stacked topic must follow its parent, and a conflicting one
# cannot land at all.
def refresh-needed [topic: record, all: bool] {
    $all or $topic.parent != null or (trial-merge [(trunk-revset) $topic.commit]).conflict
}

# Bring one published topic up to date with its base: the trunk's main, or its
# parent's bookmark for a stacked topic. Conflicts stay recorded in the local
# rewrite and block the push until someone resolves them.
def refresh-topic [topic: record, push: bool, all: bool] {
    let bookmark = $topic.name
    let label = $bookmark
    let result = {|state| { branch: $bookmark state: $state } }
    if not (refresh-needed $topic $all) {
        return (do $result "no rebase needed")
    }
    let stacked = $topic.parent != null
    let onto = if $stacked { bookmark-revset $topic.parent } else { (trunk-revset) }
    let workspaces = (workspaces-in $"\(($onto)..($bookmark))::")
    let restacked = if ($workspaces | is-empty) {
        { stack: (restack $bookmark $onto) }
    } else {
        restack-checked-out $bookmark $onto $workspaces
    }
    if $restacked.stack? == null {
        print $"($label): checked out in ($workspaces | str join ', ') and ($restacked.reason); left untouched for that workspace to resolve."
        return (do $result "checked out")
    }
    let stack = $restacked.stack
    let conflicts = (conflicted-revisions $stack)
    if ($conflicts | is-not-empty) {
        print $"($label): ($conflicts | length) conflicted revision\(s), not pushed:"
        print-conflicted-files $conflicts "  "
        print "  Resolve oldest first: `jj new CHANGE_ID`, fix the files or run `jj resolve`, then `jj squash`."
        return (do $result "conflicted")
    }
    let head = (revision-id $bookmark)
    let changed = $head != (revision-id (remote-bookmark-revset $bookmark))
    if not $push {
        if $changed { print $"($label): restacked cleanly to ($head | str substring 0..11); not pushed." }
        return (do $result (if $changed { "ready to push" } else { "current" }))
    }
    if $changed {
        push-topic-bookmark $bookmark
        print $"($label): pushed ($head | str substring 0..11)."
    }
    do $result (if $changed { "pushed" } else { "current" })
}

# Order topics so every parent is refreshed before the topics stacked on it.
def stack-order [topics: list] {
    mut ordered = []
    mut known = []
    mut remaining = $topics
    loop {
        let names = $known
        let ready = ($remaining | where {|topic| $topic.parent == null or $topic.parent in $names })
        if ($ready | is-empty) { break }
        $ordered = ($ordered | append $ready)
        $known = ($known | append ($ready | get name))
        let taken = ($ready | get name)
        $remaining = ($remaining | where {|topic| $topic.name not-in $taken })
    }
    $ordered
}

# Refresh topics parent-first. A topic whose parent is conflicted or otherwise
# blocked waits, and so does everything stacked above it.
def refresh-outcomes [ordered: list, refresh: closure] {
    mut results = []
    for topic in $ordered {
        let parent = ($results | where branch == $topic.parent | get --optional 0)
        let blocked = $parent != null and $parent.state in ["conflicted" "waiting on parent"]
        let outcome = if $blocked {
            { branch: $topic.name state: "waiting on parent" }
        } else {
            do $refresh $topic
        }
        $results = ($results | append $outcome)
    }
    $results
}

def refresh-topics [push: bool, all: bool] {
    checkpoint "refresh"
    fetch-trunk
    let results = (refresh-outcomes (stack-order (topic-bookmarks)) {|topic| refresh-topic $topic $push $all })
    print ($results | table)
    if ($results | where state == "conflicted" | is-not-empty) {
        error make { msg: "Some topics have conflicts. Resolve them locally, then run `ci sequence --apply` again." }
    }
}

# Topics stacked beyond this depth wait for an earlier layer to land instead.
const PLAN_MAX_STACK = 3

def revision-field [revision: string, template: string] {
    let result = (local-complete { ^jj log -r $revision --no-graph -T $template })
    if $result.exit_code != 0 { error make { msg: ($result.stderr | str trim) } }
    $result.stdout | str trim
}

def contains-main [revision: string] {
    revset-change-ids $"(trunk-revset) & ::($revision)" | is-not-empty
}

# Create a headless merge of the given revisions, report whether it conflicts
# and whether it changes main, then abandon it. Working copies are untouched.
# The probe is abandoned however the trial ends: one that failed after JJ made
# the merge, as when another session held .git/index.lock, left its probe
# behind for every later plan to count as a topic (2026-10-07).
def trial-merge [revisions: list<string>] {
    with-trial-merge $revisions {|probe|
        let conflict = (revision-field $probe 'conflict') == "true"
        let changes = (git-command "diffing the trial merge" {
            ^jj diff --name-only --from (trunk-revset) --to $probe
        } | is-not-empty)
        { conflict: $conflict changes: $changes }
    }
}

# Run `body` with the commit ID of a headless merge of `revisions`, then
# abandon the merge. Its tree is what rebasing the last revision onto the
# others would give, so a check can run on that tree before anything moves.
def with-trial-merge [revisions: list<string>, body: closure] {
    let marker = $"jj-ci-plan-probe-(random uuid)"
    let probes = $"description\(substring:'($marker)')"
    let outcome = try {
        git-command "creating a trial merge" { ^jj new --no-edit -m $marker ...$revisions } | ignore
        { value: (do $body (revision-field $probes 'commit_id')) error: null }
    } catch {|err| { value: null error: $err } }
    let abandoned = (do { ^jj abandon $probes } | complete)
    if $outcome.error != null { error make $outcome.error.raw }
    if $abandoned.exit_code != 0 {
        error make { msg: $"abandoning the trial merge failed with exit code ($abandoned.exit_code): ($abandoned.stderr | str trim)" }
    }
    $outcome.value
}

# Name each topic tip, from rows of { commit change }, by its change ID, which
# survives rewrites and so orders topics the same way in every workspace. The
# copies of a divergent change share that ID, so they are told apart by
# commit; JJ itself refuses the bare ID as a revision.
def tip-identities [rows: list] {
    let shared = ($rows | get change | uniq --repeated)
    $rows | each {|row|
        let tip = if $row.change in $shared { $"($row.change)/($row.commit | str substring 0..7)" } else { $row.change }
        { tip: $tip commit: $row.commit }
    }
}

def plan-topics [published: list] {
    let roots = ($published | each {|topic| bookmark-revset $topic.name } | append 'working_copies()' | str join ' | ')
    # A workspace parked on an empty, undescribed change contributes its parent.
    let placeholder = '(empty() & description(exact:""))'
    let trunk = (trunk-revset)
    let heads = $"heads\(\(($trunk)..\(($roots))) & mutable\() ~ ($placeholder))"
    # Every workspace's working copy is a candidate, so any of them going
    # divergent would stop every session's landing if the plan named tips by
    # change ID (2026-10-07). Revsets below therefore use commit IDs.
    let rows = (git-command "listing topic tips" {
        ^jj log -r $heads --no-graph -T 'commit_id ++ "\t" ++ change_id.short() ++ "\n"'
    } | lines | where {|line| $line | is-not-empty } | parse "{commit}\t{change}")
    tip-identities $rows | each {|tip|
        let commit = $tip.commit
        let bookmark = ($published | where {|topic| revset-change-ids $"(bookmark-revset $topic.name) & ::($commit)" | is-not-empty } | sort-by name | get --optional 0.name)
        let workspaces = (revision-field $"\(($trunk)..($commit) | children\(($commit))) & working_copies\()" 'working_copies ++ " "'
            | split row " " | where {|name| $name | is-not-empty } | uniq)
        let names = (if $bookmark != null { [$bookmark] } else { [] } | append $workspaces)
        let label = if ($names | is-empty) { $tip.tip | str substring 0..7 } else { $names | str join " " }
        let fork = $"fork_point\(($commit) | ($trunk))"
        {
            label: $label
            tip: $tip.tip
            commit: $commit
            bookmark: $bookmark
            description: (revision-field $commit 'description.first_line()')
            # Author time survives rewrites; committer time moves whenever a
            # topic is validated or redescribed, which would reorder topics.
            created: (revision-field $"($fork)..($commit)" 'author.timestamp().format("%s") ++ "\n"'
                | lines | into int | math min)
            files: (git-command "listing topic files" { ^jj diff --name-only --from $fork --to $commit } | lines)
            current: (contains-main $commit)
            impact: (revset-impact $"($fork)..($commit)")
        }
    }
}

def plan-main-status [topic: record] {
    let result = if $topic.current {
        {
            conflict: ((revision-field $topic.commit 'conflict') == "true")
            changes: (git-command "diffing the topic" { ^jj diff --name-only --from (trunk-revset) --to $topic.commit } | is-not-empty)
        }
    } else {
        trial-merge [(trunk-revset) $topic.commit]
    }
    if not $result.changes { "landed" } else if $result.conflict { "conflicts with main" } else { "clean" }
}

def plan-components [nodes: list<string>, edges: list] {
    mut seen = []
    mut components = []
    for node in $nodes {
        if $node in $seen { continue }
        mut component = [$node]
        mut frontier = [$node]
        while ($frontier | is-not-empty) {
            let current = ($frontier | first)
            $frontier = ($frontier | skip 1)
            let neighbours = ($edges
                | where {|edge| $edge.a == $current or $edge.b == $current }
                | each {|edge| if $edge.a == $current { $edge.b } else { $edge.a } }
                | where {|other| $other not-in $component })
            $component = ($component | append $neighbours)
            $frontier = ($frontier | append $neighbours)
        }
        $seen = ($seen | append $component)
        $components = ($components | append [$component])
    }
    $components
}

# Assign each conflict-free candidate a placement. Candidates arrive ordered
# published-first, so a chain never stacks a published topic on unpublished work.
def plan-proposals [candidates: list, edges: list] {
    plan-components ($candidates | get tip) $edges | each {|component|
        let chain = ($candidates | where tip in $component)
        $chain | enumerate | each {|entry|
            let action = if ($chain | length) == 1 {
                "independent"
            } else if $entry.index == 0 {
                "base"
            } else if $entry.index < $PLAN_MAX_STACK {
                "stack"
            } else {
                "hold"
            }
            let parent = if $action == "stack" { $chain | get ($entry.index - 1) } else { null }
            let proposal = match $action {
                "independent" => "independent topic"
                "base" => "base of stack"
                "stack" => $"stack on ($parent.label)"
                _ => $"hold until ($chain | get ($PLAN_MAX_STACK - 1) | get label) lands"
            }
            { tip: $entry.item.tip action: $action proposal: $proposal parent: $parent }
        }
    } | flatten
}

# Published topics go first so a pushed branch is never rebased onto unpublished
# work. Within each group refactors come first, so a conflicting user-facing
# change stacks on the refactor and each release stays a small behavior diff.
# Every key is stable under rewrites, so concurrent topics agree on which of
# them is the base; the change ID breaks the remaining ties.
def plan-order [topics: list] {
    $topics
    | insert unpublished {|topic| $topic.bookmark == null }
    | insert impact_order {|topic| impact-order $topic.impact }
    | sort-by unpublished impact_order created tip
}

def build-plan [published: list] {
    let topics = (plan-topics $published
        | each {|topic| $topic | insert main (plan-main-status $topic) }
        | plan-order $in)
    let candidates = ($topics | where main == "clean")
    let pairs = ($candidates | enumerate | each {|left|
        $candidates | skip ($left.index + 1) | each {|right| { a: $left.item right: $right } }
    } | flatten)
    let edges = ($pairs
        | where {|pair| $pair.a.files | any {|file| $file in $pair.right.files } }
        | where {|pair|
            let revisions = if $pair.a.current or $pair.right.current {
                [$pair.a.commit $pair.right.commit]
            } else {
                [(trunk-revset) $pair.a.commit $pair.right.commit]
            }
            (trial-merge $revisions).conflict
        }
        | each {|pair| { a: $pair.a.tip b: $pair.right.tip } })
    let proposals = (plan-proposals $candidates $edges)
    $topics | each {|topic|
        let placement = match $topic.main {
            "landed" => { action: "landed" proposal: "already in main; finish or abandon" parent: null }
            "conflicts with main" => { action: "resolve-main" proposal: "resolve against main first (ci rebase)" parent: null }
            _ => ($proposals | where tip == $topic.tip | get 0)
        }
        let conflicts = ($edges
            | where {|edge| $edge.a == $topic.tip or $edge.b == $topic.tip }
            | each {|edge| let other = if $edge.a == $topic.tip { $edge.b } else { $edge.a }; $topics | where tip == $other | get 0.label })
        {
            topic: $topic.label
            tip: $topic.tip
            commit: $topic.commit
            bookmark: $topic.bookmark
            change: ($topic.tip | str substring 0..7)
            description: $topic.description
            impact: $topic.impact
            main: $topic.main
            conflicts_with: $conflicts
            action: $placement.action
            proposal: $placement.proposal
            stack_on_bookmark: ($placement.parent | get bookmark? )
            stack_on: ($placement.parent | get label? )
        }
    }
}

def sync-main [] {
    require-jj-workspace-here
    if (owner-status (session-owner)) == "active" {
        error make { msg: "An active Codex topic owns this workspace. Use `ci rebase`, park the topic, or `ci unclaim` a claim its task left behind before syncing." }
    }
    if (current-change "empty") != "true" {
        error make { msg: "Sync needs an empty change. Use `ci rebase` to update this topic in place." }
    }
    checkpoint "sync"
    fetch-trunk
    let trunk = (trunk)
    run-command $"advancing the ($trunk.bookmark) bookmark" { ^jj ...(checkpoint-tag) bookmark move $trunk.bookmark --to "trunk()" } | ignore
    run-command "rebasing the working copy" { ^jj ...(checkpoint-tag) rebase -r @ -o "trunk()" } | ignore
}

def review-versions [] {
    let root = (run-command "locating the workspace" { ^jj root })
    let path = ($root | path join ".jj" "jj-ci-review-versions.json")
    if ($path | path exists) { open $path } else { [] }
}

def review-versions-path [] {
    let root = (run-command "locating the workspace" { ^jj root })
    $root | path join ".jj" "jj-ci-review-versions.json"
}

# What one Prek run reported: the hooks that failed, and whether any hook
# rewrote files, which Prek marks under the hook's status line.
def prek-outcome [exit_code: int, output: string] {
    let lines = ($output | ansi strip | lines)
    {
        exit_code: $exit_code
        failed: ($lines | parse --regex '^\s*(?P<hook>\S.*?)\.{3,}Failed\s*$' | get hook)
        modified: ($lines | any {|line| $line =~ 'files were modified by this hook' })
    }
}

# Whether preflight runs Prek again, and the error it ends with (null when it
# passes). A formatter's rewrite is the fix itself, so a first run that failed
# after rewriting files earns one more run on the formatted tree, and that run
# decides.
def prek-verdict [runs: list] {
    let last = ($runs | last)
    if $last.exit_code == 0 { return { rerun: false error: null } }
    if $last.modified and ($runs | length) == 1 { return { rerun: true error: null } }
    let hooks = if ($last.failed | is-empty) { "" } else { $": ($last.failed | str join ', ')" }
    let cause = if $last.modified {
        " Formatters rewrote files on both runs, so one of them is not idempotent or something else is editing this workspace."
    } else { "" }
    { rerun: false error: $"Prek failed($hooks).($cause) Its output is above." }
}

# The files Prek reads its hooks from, in the directory it runs in or the
# nearest parent that has one, up to the work tree's root.
const PREK_CONFIGS = ["prek.toml" ".pre-commit-config.yaml" ".pre-commit-config.yml"]

# The Prek configuration that applies in `dir` of the work tree `root`, or null
# when there is none. Prek never looks above the work tree, so neither does
# this: a workspace nested in another repository, as in a Claude Code worktree,
# would otherwise find that repository's configuration and run a Prek that
# finds none (2026-10-16).
def prek-config [dir: path, root: path] {
    let top = ($root | path expand)
    mut current = ($dir | path expand)
    loop {
        let dir = $current
        let found = ($PREK_CONFIGS | each {|name| $dir | path join $name } | where {|path| $path | path exists })
        if ($found | is-not-empty) { return ($found | first) }
        let parent = ($current | path dirname)
        if $current == $top or $parent == $current { return null }
        $current = $parent
    }
}

def run-prek [context: record, paths: list<string>] {
    let result = (do {
        with-env $context {
            cd $context.GIT_WORK_TREE
            ^prek run --files ...$paths
        }
    } | complete)
    if ($result.stdout | is-not-empty) { print --no-newline $result.stdout }
    if ($result.stderr | is-not-empty) { print --stderr --no-newline $result.stderr }
    prek-outcome $result.exit_code $"($result.stdout)\n($result.stderr)"
}

def validate-change [] {
    run-command "fixing the current JJ change" { ^jj fix -s @ } | ignore
    let context = (git-context)
    # A repository without hooks has nothing for Prek to run, and Prek
    # fails there instead of passing; its flake checks still gate landing.
    if (prek-config $context.GIT_WORK_TREE $context.GIT_WORK_TREE) == null {
        print $"No Prek configuration in ($context.GIT_WORK_TREE); no hooks to run."
        record-validation
        return
    }
    let files = (do {
        cd $context.GIT_WORK_TREE
        ^jj file list
    } | complete)
    if $files.exit_code != 0 { error make { msg: ($files.stderr | str trim) } }
    let paths = ($files.stdout | lines | where {|p| $p != "" })
    mut runs = [(run-prek $context $paths)]
    if (prek-verdict $runs).rerun {
        let rerun = "Prek's formatters rewrote files; checking the formatted tree once more."
        print $rerun
        report-status working $rerun --id preflight
        $runs = ($runs | append (run-prek $context $paths))
    }
    let verdict = (prek-verdict $runs)
    if $verdict.error != null { error make { msg: $verdict.error } }
    record-validation
}

def validation-path [] {
    let root = (git-command "locating the workspace" { ^jj root })
    $root | path join ".jj" "jj-ci-validation.json"
}

# Remember the exact commit Prek passed. Any later edit snapshots a new commit,
# so the record goes stale by itself; context-status reads it to report lint
# freshness without running Prek.
def record-validation [] {
    {
        change_id: (current-topic-id)
        commit_id: (current-change "commit_id")
        validated_at: (date now | format date "%+")
    } | to json | save --force (validation-path)
}

# The commit a remote bookmark points at, or null when it is not on the remote.
def remote-bookmark-commit [bookmark: string, remote: string] {
    let result = (^jj log -r (remote-bookmark-revset $bookmark $remote) --no-graph -T 'commit_id' | complete)
    if $result.exit_code != 0 { return null }
    let commit = ($result.stdout | str trim)
    if ($commit | is-empty) { null } else { $commit }
}

# One probe's verdict, or `unknown` with the reason when it could not be read.
def probe-state [probe: closure] {
    try { do $probe | select state } catch {|err| { state: "unknown" error: $err.msg } }
}

# A topic's trip to main uses flight words: `new`, `sequence`, `preflight`
# and `sim`, `dispatch`, `land --clearance`, then `park` (or `cancel`), and
# `verify` once the release runs. Preflight is everything before activation;
# inflight is everything on a running machine. Tools keep plain VCS words.
def main [] {
    print "A topic's trip: `ci new` → `ci sequence` → `ci preflight` / `ci sim` → `ci dispatch` → `ci land` on a clear runway, or `ci queue` to be landed in turn → `ci park` (or `ci cancel`), then `ci verify` once the release runs."
    print "Also: `ci tower`, `ci start`, `ci status`, `ci queue list`, `ci queue drop`, `ci sync`, `ci rebase`, `ci conflicts`, `ci recover`, `ci review snapshot`, `ci interdiff`, `ci unclaim`, `ci prune`, `ci impact set`, `ci impact show`, `ci impact check`, `ci release`, `ci version`, `ci trace export`."
}

# The control tower: a live terminal view of every workspace's topic, each
# run's phases and log, and trunk's releases, from which a key runs the next
# step. Runs it starts are ordinary ci MCP jobs that agents can follow.
def --wrapped "main tower" [...args] {
    if (which ci-tower | is-empty) {
        error make { msg: "ci-tower is not on PATH; it ships in the ci package, or run `nix run path:.#ci-tower` in the ci repository." }
    }
    exec ci-tower ...$args
}

# Old command names keep working for a while and point at the new ones.
def renamed [old: string, new: string] {
    print --stderr $"`ci ($old)` is now `ci ($new)`."
}

def "main status" [] {
    ^jj status
    # A trunk remote that is not on Tangled has no pull requests.
    let repo = (try { tangled-repo } catch { null })
    let pulls = if $repo == null { [] } else { open-pulls $repo }
    topic-bookmarks | each {|topic|
        {
            topic: $topic.name
            stacked_on: $topic.parent
            pull: ($pulls | where branch == $topic.name | get --optional 0.title)
        }
    }
}

# The current topic's publication and pipeline facts as JSON. It reads the
# remotes' last-fetched state and the forges' APIs; it never fetches, pushes,
# or rewrites anything, so a background status refresh can run it safely.
def "main ci-state" [] {
    let topic_id = (current-topic-id)
    let topics = (publication-topics)
    let branch = if $topic_id in $topics { $topics | get $topic_id } else { null }
    let remote = (try { trunk-remote } catch { null })
    let head = if $branch == null or $remote == null { null } else { remote-bookmark-commit $branch $remote }
    let base = {
        change_id: $topic_id
        branch: $branch
        published_head: $head
        landed: false
        pull: null
        github: null
    }
    if $head == null { return ($base | to json) }
    let repo = (try { tangled-repo } catch { null })
    let github = if (remote-bookmark-commit $branch $GITHUB_REMOTE) == $head {
        probe-state { github-checks-state (github-repo) $head }
    } else { null }
    $base | merge {
        landed: (topic-landed $branch)
        pull: (if $repo == null { null } else {
            try { open-pulls $repo | where branch == $branch | get --optional 0.title } catch { null }
        })
        github: $github
    } | to json
}

def "main sync" [] {
    sync-main
}

def "main worktree-status" [] {
    let root = (git-command "locating the Git repository" { ^git rev-parse --show-toplevel })
    let trunk = (trunk | $"($in.remote)/($in.bookmark)")
    let main = (git-command $"locating ($trunk)" { ^git -C $root rev-parse $"refs/remotes/($trunk)" })
    let main_short = ($main | str substring 0..6)
    let listing = (git-command "listing Git worktrees" { ^git -C $root worktree list --porcelain })
    let worktrees = ($listing
        | split row "\n\n"
        | where {|entry| ($entry | str trim | is-not-empty) }
        | each {|entry|
            let path_line = ($entry | lines | where {|line| $line starts-with "worktree " } | first)
            git-worktree ($path_line | str substring 9..) $main
        })
    print $"($trunk): ($main_short)"
    for worktree in $worktrees {
        let details = $"($worktree.dirty), ($worktree.vcs)"
        print $"($worktree.state) ($worktree.branch) ($worktree.head) ($details) ($worktree.path)"
    }
}

# Every check that runs before activation, on the current change. A fresh,
# empty change has no edits of its own, so preflight checks the tree it
# inherits from its parent instead of failing.
def "main preflight" [] {
    require-ready-change --allow-empty
    if (current-change "empty") == "true" {
        let parents = (current-change 'parents.map(|p| p.change_id().short()).join(", ")')
        print $"The current JJ change is empty; checking the tree it inherits from ($parents)."
    }
    validate-change
}

# Run this repository's property suites (tests/*-properties.nu), each in its
# own Nushell, and report every property as it finishes, so `watch-job` and
# the MCP `property_tests` tool stream the results. A failing suite stops at
# its first failed property; the other suites still run.
def "main test" [
    --seed: string  # PBT_SEED to replay (default: the suites' own)
    ...suites: string  # Suites to run, such as ci-properties (default: all)
] {
    let root = (run-command "locating the workspace" { ^jj root } | str trim)
    let tests = ($root | path join "tests")
    if not ($tests | path join "pbt.nu" | path exists) {
        error make { msg: $"($root) has no property suites \(tests/pbt.nu\)." }
    }
    let names = if ($suites | is-not-empty) { $suites } else {
        glob ($tests | path join "*-properties.nu") | sort | each { path basename | str replace --regex '\.nu$' '' }
    }
    # Set here rather than with `with-env`, whose block drops the suite's exit
    # status, so a failing suite would read as passed.
    if $seed != null { $env.PBT_SEED = $seed }
    # A child nu does not take the parsed NU_LIB_DIRS list as its module path,
    # where ci.nu, which ci-properties sources, finds `pst`.
    let lib_dirs = ($env.NU_LIB_DIRS? | default [] | each {|dirs| $dirs | split row (char esep) } | flatten | where {|dir| $dir | is-not-empty })
    let include = if ($lib_dirs | is-empty) { [] } else { ["--include-path" ($lib_dirs | str join (char record_sep))] }
    cd $tests
    let failed = ($names | each {|suite|
        report-status working $"Running ($suite)" --id $suite
        let passed = try {
            ^$nu.current-exe --no-config-file ...$include --commands $"source ($suite).nu"
            | lines
            | each {|line|
                print $line
                if ($line | str starts-with "ok ") {
                    report-status done ($line | str substring 3..) --id $"($suite)/(property-name $line)"
                } else if ($line | str starts-with "FAIL ") {
                    report-status error ($line | str substring 5..) --id $"($suite)/(property-name $line)"
                }
            }
            | ignore
            true
        } catch { false }
        if $passed { report-status done $"($suite) passed" --id $suite } else { report-status error $"($suite) failed" --id $suite }
        if $passed { null } else { $suite }
    } | compact)
    if ($failed | is-not-empty) {
        error make { msg: $"Property suites failed: ($failed | str join ', ')" }
    }
    print $"All ($names | length) property suites passed."
}

# A status id segment for the property a result line from tests/pbt.nu's
# for-all names. pst takes at most 32 of `[A-Za-z0-9_.+-]` per segment, so a
# long name is cut and keeps a hash of the whole to stay distinct.
def property-name [line: string] {
    let name = ($line | parse --regex '^(?:ok|FAIL) (?<name>.*?)(?: \(\d+ cases\)|: .*)?$' | get --optional 0.name | default $line)
    let slug = ($name | str lowercase |str replace --all --regex '[^a-z0-9]+' '-' | str trim --char '-')
    if ($slug | str length) <= 32 { return $slug }
    $"($slug | str substring 0..<25 | str trim --char '-')-($name | hash sha256 | str substring 0..<6)"
}

def "main validate" [] {
    renamed "validate" "preflight"
    main preflight
}

def "main review snapshot" [label: string] {
    require-ready-change
    let versions = (review-versions)
    if (($versions | where label == $label | is-not-empty)) {
        error make { msg: $"A review snapshot named '($label)' already exists in this workspace." }
    }
    let entry = {
        label: $label
        base: (revision-id (trunk-revset))
        tip: (revision-id "@")
        bookmark: (publication-bookmark)
        created_at: (date now | format date "%Y-%m-%dT%H:%M:%S%:z")
    }
    (review-versions | append $entry | to json) | save --force (review-versions-path)
    print $"Saved review snapshot '($label)': ($entry.base)..($entry.tip)"
}

def "main interdiff" [old: string, new: string] {
    let versions = (review-versions)
    let old_matches = ($versions | where label == $old)
    let new_matches = ($versions | where label == $new)
    if ($old_matches | is-empty) {
        error make { msg: $"No review snapshot named '($old)' exists in this workspace." }
    }
    if ($new_matches | is-empty) {
        error make { msg: $"No review snapshot named '($new)' exists in this workspace." }
    }
    let old_version = ($old_matches | first)
    let new_version = ($new_matches | first)
    let old_range = $"($old_version.base)..($old_version.tip)"
    let new_range = $"($new_version.base)..($new_version.tip)"
    let context = (git-context)
    print $"Interdiff: ($old) -> ($new)"
    print $"  old: ($old_range)"
    print $"  new: ($new_range)"
    run-command "computing interdiff" {
        with-env $context {
            cd $context.GIT_WORK_TREE
            ^git range-diff $old_range $new_range
        }
    } | ignore
}

def "main rebase" [] {
    rebase-topic
}

# Like air traffic control ordering arrivals: show how in-flight topics stack
# on the ones they conflict with, or with --apply, restack them.
def "main sequence" [
    --json # Print the sequence as JSON
    --apply # Restack stacked or conflicting topics, pushing conflict-free rebases
    --no-push # With --apply, rebase and report conflicts without pushing
    --all # With --apply, also rebase conflict-free topics merely behind main
] {
    if $apply {
        refresh-topics (not $no_push) $all
        return
    }
    fetch-trunk
    let plan = (build-plan (topic-bookmarks | where parent == null))
    if $json {
        print ($plan | to json)
        return
    }
    if ($plan | is-empty) {
        print "No in-flight topics."
        return
    }
    for entry in $plan {
        let description = if ($entry.description | is-empty) { "(no description)" } else { $entry.description }
        print $"($entry.topic) [($entry.change)] ($description)"
        print $"  impact: ($entry.impact | default 'unclassified')"
        print $"  main: ($entry.main)"
        if ($entry.conflicts_with | is-not-empty) {
            print $"  conflicts with: ($entry.conflicts_with | str join ', ')"
        }
        print $"  plan: ($entry.proposal)"
        let parent = ($plan | where topic == ($entry.stack_on | default "") | get 0?)
        if $entry.impact == "refactor" and $parent != null and $parent.impact != "refactor" {
            print $"  note: this refactor stacks on user-facing ($parent.topic) only because that topic is already published."
        }
    }
}

def "main plan" [
    --json # Print the sequence as JSON
] {
    renamed "plan" "sequence"
    main sequence --json=$json
}

# Home Manager is embedded in this host; there is no standalone homeConfigurations output.
const PREVIEW_ATTRIBUTE = "nixosConfigurations.asus.config.home-manager.users.schlich.home.activationPackage"

def preview-link [] {
    $env.XDG_STATE_HOME? | default ($env.HOME | path join ".local" "state") | path join "jj-ci" "preview-home"
}

# Published topics to preview: the requested ones, or every behavior or
# breaking topic (all of them with `all`). Refactors leave every closure
# unchanged, so they add merge risk without anything to try.
def preview-topics [names: list<string>, all: bool] {
    let topics = (topic-bookmarks | each {|topic|
        let revset = (bookmark-revset $topic.name)
        # A stacked topic is classified by its own layer; the merge still
        # includes its parent, since the parent is an ancestor of its head.
        let base = if $topic.parent == null { (trunk-revset) } else { bookmark-revset $topic.parent }
        $topic
        | insert revset $revset
        | insert title (revision-field $revset 'description.first_line()')
        | insert impact (revset-impact $"($base)..($revset)")
    })
    if ($names | is-not-empty) {
        let missing = ($names | where {|name| $name not-in ($topics | get name) })
        if ($missing | is-not-empty) {
            error make { msg: $"Not published topics: ($missing | str join ', ')" }
        }
        return ($topics | where name in $names)
    }
    if $all { return $topics }
    $topics | where impact in ["behavior" "breaking"]
}

# Configuration files that differ between two Home Manager generations. Each
# entry is a symlink into the store, so a changed target is a changed file;
# comparing targets also tolerates links whose destination no longer exists.
def preview-changed-files [current: string, preview: string] {
    let old = ($current | path join "home-files" | path expand)
    let new = ($preview | path join "home-files" | path expand)
    let result = (^diff --recursive --brief --no-dereference $old $new | complete)
    if $result.exit_code > 1 { error make { msg: $"comparing configuration files failed: ($result.stderr | str trim)" } }
    $result.stdout | lines | each {|line|
        let only = ($line | parse --regex '^Only in (?P<directory>.+): (?P<name>.+)$')
        if ($only | is-not-empty) {
            let entry = ($only | first)
            let status = if ($entry.directory | str starts-with $new) { "added" } else { "removed" }
            let path = ($entry.directory | str replace $new "" | str replace $old "" | path join $entry.name)
            { status: $status path: $"~($path)" }
        } else {
            let path = ($line | parse --regex $"($old | str replace --all '.' '\.')\(?P<path>/[^’'\\s]*\)" | get 0?.path | default "")
            { status: "changed" path: $"~($path)" }
        }
    }
}

# Build the Home Manager generation that trunk plus in-flight topics would
# produce, without activating it. The merge exists only in a temporary
# workspace and is abandoned afterwards; nothing is pushed or rewritten.
def "main preview" [
    ...topics: string # Topic branches to include (default: every published behavior or breaking topic)
    --all # Include refactor topics when no branches are given
    --shell # Open Nushell with the simulation's programs first on PATH
    --config # With --shell, also read configuration from the simulation (read-only)
    --active # Compare against the active generation instead of trunk's
] {
    renamed "preview" "sim"
    main sim ...$topics --all=$all --shell=$shell --config=$config --active=$active
}

def "main sim" [
    ...topics: string # Topic branches to include (default: every published behavior or breaking topic)
    --all # Include refactor topics when no branches are given
    --shell # Open Nushell with the simulation's programs first on PATH
    --config # With --shell, also read configuration from the simulation (read-only)
    --active # Compare against the active generation instead of trunk's
] {
    fetch-trunk
    let included = (preview-topics $topics $all)
    if ($included | is-empty) {
        print "No published user-facing topics to preview."
        return
    }
    for topic in $included { print $"Including ($topic.name) ($topic.title)" }

    let heads = ($included | get revset | append (trunk-revset) | str join " | ")
    let parents = (git-command "resolving topic heads" {
        ^jj log -r $"heads\(($heads))" --no-graph -T 'commit_id ++ "\n"'
    } | lines)
    let marker = $"jj-ci-preview-(random uuid)"
    git-command "creating the preview merge" { ^jj new --no-edit -m $marker ...$parents } | ignore
    let merge = (revision-field $"description\(substring:'($marker)')" 'commit_id')
    let discard = {|| git-command "abandoning the preview merge" { ^jj abandon $"($merge)::" } | ignore }

    if (revision-field $merge 'conflict') == "true" {
        let files = (git-command "listing conflicted files" { ^jj resolve --list -r $merge })
        do $discard
        print "The selected topics conflict when merged:"
        print ($files | lines | each {|line| $"  ($line)" } | str join "\n")
        error make { msg: "Preview a subset with `ci sim BRANCH ...`, or see `ci sequence` for how to stack them." }
    }

    let name = ($marker | str substring 0..21)
    let directory = (mktemp --directory --tmpdir "jj-ci-preview.XXXXXX")
    let tree = ($directory | path join "tree")
    let link = (preview-link)
    mkdir ($link | path dirname)
    let built = (try {
        git-command "checking out the preview" { ^jj workspace add --revision $merge --name $name $tree } | ignore
        ^nix build --no-update-lock-file --out-link $link $"path:($tree)#($PREVIEW_ATTRIBUTE)"
        if not $active {
            git-command "checking out trunk" { ^jj --repository $tree new (trunk-revset) } | ignore
            ^nix build --no-update-lock-file --out-link $"($link)-trunk" $"path:($tree)#($PREVIEW_ATTRIBUTE)"
        }
        null
    } catch {|error| $error.msg })
    do { ^jj workspace forget $name } | complete | ignore
    rm --recursive --force $directory
    do $discard
    if $built != null { error make { msg: $"Building the preview failed: ($built)" } }

    let preview = ($link | path expand)
    let baseline = if $active {
        { name: "the active generation" path: ($env.HOME | path join ".local" "state" "home-manager" "gcroots" "current-home") }
    } else {
        { name: "trunk" path: $"($link)-trunk" }
    }
    print $"\nPreview generation: ($preview)"
    if ($baseline.path | path expand) == $preview {
        print $"\nNo Home Manager changes against ($baseline.name)."
    } else if ($baseline.path | path exists) {
        print $"\nPackage changes against ($baseline.name):"
        ^nix store diff-closures $baseline.path $preview
        let files = (preview-changed-files ($baseline.path | path expand) $preview)
        print "\nConfiguration file changes:"
        print (if ($files | is-empty) { "  none" } else { $files | each {|file| $"  ($file.status | fill --width 8)($file.path)" } | str join "\n" })
    }
    if not $shell {
        print $"\nTry programs from ($preview | path join 'home-path' 'bin'), or re-run with --shell."
        return
    }
    let overrides = { PATH: ($env.PATH | prepend ($preview | path join "home-path" "bin")) JJ_CI_PREVIEW: $preview }
    let overrides = if $config {
        $overrides | insert XDG_CONFIG_HOME ($preview | path join "home-files" ".config")
    } else {
        $overrides
    }
    print "\nEntering the preview shell. Exit to return; nothing was activated."
    with-env $overrides { ^nu }
}

def "main refresh" [
    --no-push # Rebase and report conflicts without pushing
    --all # Also rebase conflict-free topics that are merely behind main
] {
    renamed "refresh" "sequence --apply"
    refresh-topics (not $no_push) $all
}

def "main conflicts" [] {
    require-owned-change
    if (print-conflicts "Conflict status") {
        error make { msg: "The current topic has unresolved conflicts." }
    }
}

# Choose the branch a topic should stack on. A topic built on top of another
# published topic depends on it and stacks on the nearest one; otherwise
# `ci sequence` decides. Returns null when the topic can go straight to main.
def plan-parent-for-current-topic [branch: string] {
    let published = (topic-bookmarks | where name != $branch)
    let below = ($published | where {|topic|
        revset-change-ids $"(bookmark-revset $topic.name) & ::@- ~ ::(trunk-revset)" | is-not-empty
    })
    if ($below | is-not-empty) {
        let heads = (revset-change-ids $"heads\(($below | each {|topic| bookmark-revset $topic.name } | str join ' | '))")
        let nearest = ($below | where {|topic| (revset-change-ids (bookmark-revset $topic.name) | first) in $heads } | first)
        print $"Built on ($nearest.name); stacking on it."
        return $nearest.name
    }
    let tip = (current-change 'change_id.short()')
    # Plan with the topic's own bookmark, as `ci sequence` does. Without it a
    # dispatched topic ranks as unpublished, behind every other published topic
    # and unpublished refactor in its conflict component, so a component of
    # four or more held each of its published topics and none could land
    # (2026-10-17).
    let entry = (build-plan (topic-bookmarks | where parent == null) | where tip == $tip | get 0?)
    if $entry == null { return null }
    match $entry.action {
        "hold" => {
            error make { msg: $"This topic conflicts with a stack that is already ($PLAN_MAX_STACK) layers deep \(($entry.proposal)). Hold it locally until a layer lands." }
        }
        "stack" => {
            # Waiting on a topic that is not published can block indefinitely
            # when its task is idle. Publish independently; whichever lands
            # second resolves the conflict when it rebases.
            if $entry.stack_on_bookmark == null {
                print $"Conflicts with unpublished work in ($entry.stack_on); publishing as an independent topic. Whichever lands second resolves the conflict."
                return null
            }
            print $"Conflicts with ($entry.conflicts_with | str join ', '); stacking on ($entry.stack_on_bookmark)."
            $entry.stack_on_bookmark
        }
        _ => null
    }
}

def restack-topic [parent: string] {
    require-owned-change
    if (print-conflicts "Before restack") {
        error make { msg: "Resolve existing conflicts before restacking." }
    }
    let onto = (bookmark-revset $parent)
    if (revset-change-ids $onto | is-empty) {
        error make { msg: $"The parent branch ($parent) has no local bookmark. Fetch and track it first." }
    }
    checkpoint "restack"
    let moved = (other-workspaces-in $"roots\(::@ ~ ::($onto) ~ ::(trunk-revset))::")
    let stack = (restack "@" $onto)
    update-moved-workspaces $moved
    let conflicts = (conflicted-revisions $stack)
    if ($conflicts | is-not-empty) {
        print $"Restacked onto ($parent) with ($conflicts | length) conflicted revision\(s):"
        print-conflicted-files $conflicts "  "
        error make { msg: $"Resolve these conflicts locally, oldest first, then run `ci dispatch` again.(recovery-hint)" }
    }
}

# Rebase or restack the current topic, validate it, and push its bookmark to
# the trunk remote. A topic keeps one bookmark for its whole life, so every
# publish updates the same branch and any pull request opened from it.
def publish-topic [] {
    require-ready-change
    let branch = (publication-bookmark)
    fetch-trunk
    if (topic-landed $branch) {
        error make { msg: "This topic already landed on main. Park it with `ci park` before starting new work." }
    }
    let parent = (plan-parent-for-current-topic $branch)
    let base = if $parent == null { (trunk-revset) } else { bookmark-revset $parent }
    # Classify before rewriting anything so an unclassified topic fails fast.
    let impact = (require-impact (layer-revisions $base))
    let onto = if $parent == null { (trunk-revset) } else { $parent }
    phase rebase $"Rebasing onto ($onto)" {
        if $parent == null { rebase-topic } else { restack-topic $parent }
    }
    require-ready-change
    phase preflight "Running preflight" { validate-change }
    run-command "setting the publication bookmark" { ^jj bookmark set $branch -r @ } | ignore
    remember-publication-bookmark $branch
    phase push $"Pushing ($branch)" { push-topic-bookmark $branch }
    mirror-topic $branch
    { branch: $branch parent: $parent impact: $impact head: (current-change "commit_id") }
}

# Fast-forward main on the trunk remote to `head`, which `clearance` passed,
# then mirror it and tag a release for each user-facing revision in
# `base..head`. `label` names what landed. If main moved since `head` was
# rebased onto it, landing would not be a fast-forward of what was tested, so
# this returns false without touching main. Delivery is never a squash,
# rebase, or merge on a forge: every remote receives the same commits.
def advance-main [head: string, base: string, label: string, clearance: string] {
    let trunk = (trunk)
    let remote = $trunk.remote
    let main = $trunk.bookmark
    # The runway keeps other landings on this machine from moving main,
    # but another machine, or a push by hand, still may.
    fetch-trunk
    if not (contains-main $head) { return false }
    post-landing-status $remote $head $clearance
    run-command $"advancing ($main)" { ^jj bookmark set $main -r $head } | ignore
    # The first landing creates the bookmark on the trunk remote, which jj
    # pushes only once the bookmark is tracked there.
    if (revset-change-ids (remote-bookmark-revset $main $remote) | is-empty) {
        run-command $"tracking ($main)@($remote)" { ^jj bookmark track $"($main)@($remote)" } | ignore
    }
    let pushed = (remote-complete $"advancing ($main)" { ^jj git push --remote $remote --bookmark $main })
    if $pushed.exit_code != 0 {
        # The lease lost a race with a push after the fetch above. Put the
        # local bookmark back on the trunk so the retry starts from it.
        fetch-trunk
        if not (contains-main $head) {
            run-command $"resetting ($main)" { ^jj bookmark set $main -r "trunk()" --allow-backwards } | ignore
            return false
        }
        error make { msg: $"landing on ($remote) failed with exit code ($pushed.exit_code): ($pushed.stderr | str trim)" }
    }
    report-status done $"Landed ($label) on main at ($head | str substring 0..11)" --id land
    mirror-main
    cut-releases $"($base)..($head)" false
    true
}

# Fail now on what would otherwise fail only after clearance: a stacked topic
# cannot land before its parent, and a declared refactor must leave every
# closure unchanged. A refactor once proved at `proven` is not proved again
# while its head stays the same. On 2026-10-16 a refactor's proof ran only
# after a restart, and the landing failed 16 minutes after it started.
def require-landable [published: record, proven?: string] {
    if $published.parent != null {
        error make { msg: $"This topic is stacked on ($published.parent). Land that topic first, then land this one." }
    }
    if $published.impact == "refactor" and $published.head != $proven {
        phase closures "Proving every NixOS closure unchanged" { require-closure-neutral "trunk()" $published.head }
    }
}

# Land a published topic from the runway. The fast checks run before it takes
# the runway, so a topic that cannot land fails before it holds anyone up.
# `ci land` takes the runway only when it is clear and refuses otherwise; the
# drainer, landing a held topic, waits its turn. On the runway, a topic
# rebases onto main only if main moved meanwhile, runs the fast checks again
# on the new head, and takes clearance. No other landing on this machine
# moves main from then on; only something else can, such as another machine
# or a push by hand, and `attempts` bounds how many times that may send it
# back to rebase and take clearance again. A rebase conflict or failed
# clearance still stops it. `--hold` (`ci queue`) holds the topic for the
# drainer instead of taking the runway.
# Stately owns the next legal operation and the retry bound. Snapshots stay
# inside this locked command: restarting an interrupted command re-observes
# the repository rather than replaying a possibly completed remote effect.
# CI_AGENT_SCRIPT selects the topic's machine when developing with CI_SCRIPT.
def topic-agent-step [state?: record, event?: record, --land, --hold, --attempts: int = 5] {
    let request = if $state == null {
        { input: { land: $land hold: $hold attempts: $attempts } }
    } else { { snapshot: $state.snapshot event: $event } }
    if ($env.CI_AGENT_SCRIPT? | is-empty) and (which ci-agent | is-empty) {
        # Only a ci.nu newer than the installed package meets this: the
        # launcher builds the matching ci-agent when it can, and falls back to
        # the package's, which predated the agent until 2026-10-16.
        error make { msg: "ci-agent is not on PATH. It ships beside `ci` in the ci package; this ci.nu is newer than the installed package and the launcher could not build its agent. Update the ci package, or run `nix develop path:. --command ci` in the ci repository." }
    }
    let response = (do {
        if ($env.CI_AGENT_SCRIPT? | is-not-empty) {
            $request | to json --raw | ^node $env.CI_AGENT_SCRIPT
        } else {
            $request | to json --raw | ^ci-agent
        }
    } | complete)
    if $response.exit_code != 0 {
        error make { msg: $"CI agent refused the transition: ($response.stderr | str trim)" }
    }
    $response.stdout | from json
}

# Execute only the effect named by the machine. Existing operations retain
# ownership checks, checkpoints, exact-head clearance, and lease-protected
# fast-forwards. No failure is automatically retried or conflict resolved.
# `held` names the hold files a drainer's landing flies for: it waits its turn
# on the runway instead of refusing a busy one.
def drive-topic-agent [state: record, published: record, timeout: duration, gate: string, --held: string] {
    mut step = $state
    mut current = $published
    mut base = ""
    # Typed `any`: a bare `null` would fix the variable's type to nothing,
    # and the hold record assigned later would not fit (2026-10-19).
    mut holding: any = null
    while not $step.done {
        report-status working $"CI agent: ($step.state)" --id agent
        let active = $step
        if $active.state == "approaching" {
            let approaching = $current
            with-runway (lock-topic $approaching.head) --alone=($held == null) --hold $held --busy {|ahead|
                let refused = (topic-agent-step $active { type: RUNWAY_BUSY ahead: $ahead })
                report-status error $"The runway is busy: ($refused.context.error)" --id runway
                error make { msg: $"The runway is busy: ($ahead). `ci queue` holds this topic and lands it in turn, without keeping this session waiting." }
            } {
                drive-topic-agent (topic-agent-step $active { type: ON_RUNWAY }) $approaching $timeout $gate
            }
            return
        }
        let event = try { match $active.state {
            "checking" => {
                require-landable $current
                { type: LANDABLE }
            }
            "holding" => {
                $holding = (hold-topic $current $gate $timeout $active.context.limit)
                { type: HELD head: $current.head }
            }
            "refreshing" => {
                fetch-trunk
                { type: REFRESHED fresh: (contains-main $current.head) }
            }
            "republishing" => {
                let moved = $"main moved; rebasing and redispatching \(attempt ($active.context.attempt) of ($active.context.limit))."
                print $moved
                report-status working $moved --id land
                $current = (publish-topic)
                { type: PUBLISHED head: $current.head }
            }
            "proving" => {
                require-landable $current $active.context.proven
                { type: LANDABLE }
            }
            "clearing" => {
                let checker = (landing-gate $gate)
                $base = (fork-point "trunk()" $current.head)
                if $gate in $GITHUB_CLEARANCES { push-bookmark $GITHUB_REMOTE $current.branch }
                print $"Waiting for ($checker.name) to pass ($current.head | str substring 0..11)."
                wait-for-pipeline $checker $current.head $timeout
                { type: CLEARED head: $current.head }
            }
            "advancing" => {
                { type: ADVANCED head: $current.head landed: (advance-main $current.head $base $current.branch $gate) }
            }
            _ => { error make { msg: $"Unknown CI agent state: ($active.state)" } }
        } } catch {|err|
            let blocked = (topic-agent-step $active { type: FAILED message: (error-summary $err) })
            report-status blocked $"CI agent: ($blocked.context.error)" --id agent
            error make $err.raw
        }
        $step = (topic-agent-step $step $event)
    }
    if $step.state == "held" {
        report-status done "CI agent: held" --id agent
        let ahead = if $holding.ahead == 0 { "first in line" } else { $"behind ($holding.ahead) other held topic\(s)" }
        print $"Held ($holding.hold.topic) for the drainer, ($ahead). It lands in turn; follow it with `watch-job ($holding.hold.log)`, or see the line with `ci queue list`. `ci queue drop` takes it out."
        return
    }
    if $step.state == "exhausted" {
        error make { msg: $"main moved outside the runway during each of ($step.context.limit) landing attempts. Nothing landed; run `ci land` again once main is quiet." }
    }
    if $step.state != "landed" { error make { msg: $"CI agent stopped in ($step.state)." } }
    report-status done "CI agent: landed" --id agent
    print $"Landed ($current.branch) on main. `ci park` frees the workspace."
}

def publish-with-agent [land: bool, attempts: int, --hold] {
    # Reject invalid run input before publishing anything.
    let initial = (topic-agent-step --land=$land --hold=$hold --attempts $attempts)
    report-status working "CI agent: publishing" --id agent
    let published = try { publish-topic } catch {|err|
        let blocked = (topic-agent-step $initial { type: FAILED message: (error-summary $err) })
        report-status blocked $"CI agent: ($blocked.context.error)" --id agent
        error make $err.raw
    }
    { published: $published state: (topic-agent-step $initial { type: PUBLISHED head: $published.head }) }
}

# Why a topic in `ci sequence` cannot join a train, or null when it can.
# `facts` holds the plan entry's `main` status and `impact`, whether its
# local bookmark is the one `pushed` to the trunk remote, and whether its
# plan tip is that bookmark (`dispatched`), with no edits above it.
def train-exclusion [facts: record] {
    if $facts.main != "clean" { return $facts.main }
    if not $facts.pushed { return "local bookmark differs from the dispatched one" }
    if not $facts.dispatched { return "has edits since its dispatch" }
    if $facts.impact not-in $IMPACTS { return "has no single declared impact" }
    null
}

# Find where clearance first fails in a train of `count` topics that failed
# as a whole with `failure`: `clear` takes a prefix length and runs clearance
# on the chain up to it, returning { passed, error }. Main itself, the empty
# prefix, counts as passing. Bisection needs about log2(count) more
# clearances. Returns { passing, culprit, failure }: the longest prefix found
# to pass, the index of the topic after it, which failed clearance on top of
# that prefix, and that clearance's error.
def bisect-train [count: int, failure: any, clear: closure] {
    mut passing = 0
    mut failing = $count
    mut error = $failure
    while $failing - $passing > 1 {
        let middle = ($passing + $failing) // 2
        let verdict = (do $clear $middle)
        if $verdict.passed {
            $passing = $middle
        } else {
            $failing = $middle
            $error = $verdict.error
        }
    }
    { passing: $passing culprit: ($failing - 1) failure: $error }
}

# Run clearance on the train's `entry`, the tip of a prefix, and report
# whether it passed. Remote clearance needs the head pushed to the mirror.
def train-clearance [checker: record, gate: string, entry: record, timeout: duration] {
    if $gate in $GITHUB_CLEARANCES { push-bookmark $GITHUB_REMOTE $entry.name }
    print $"Waiting for ($checker.name) to pass ($entry.name) at ($entry.head | str substring 0..11)."
    try {
        wait-for-pipeline $checker $entry.head $timeout
        { passed: true error: null }
    } catch {|err| { passed: false error: $err.msg } }
}

# Release the topic locks a train took, as { lock, claim } records.
def release-topic-locks [claims: list] {
    for claim in $claims { swap-local-checks-lock $claim.lock ($claim.claim | hash sha256) "" | ignore }
}

# Land every dispatched topic that can go in one fast-forward: one
# clearance for the lot instead of one per topic. From the runway, the topics in `ci sequence` order are rebased into one
# linear chain on main. A topic is left out, untouched, when it is not
# dispatched as it stands, would conflict with the chain, has no single
# declared impact, or is moved by another `ci` (its topic lock is held). A
# declared refactor must prove its closures unchanged against the chain
# below it, on a trial merge, before it joins. Clearance then runs once on
# the chain's tip, and main fast-forwards to it, with a release tagged for
# each user-facing revision. If clearance fails, bisection finds the first
# topic that fails it: the passing prefix lands, and that topic and every
# one after it return to main for their owners to land again. `checker`
# and `fingerprint` stand in for the landing gate and closure-fingerprint in
# tests.
#
# Started by `ci land --train`, it takes only a clear runway, as `ci land`
# does. The drainer passes `held`, the hold files of the topics it flies
# together: the train then waits its turn and takes only those topics.
def land-train [timeout: duration, gate: string, --checker: record, --fingerprint: closure, --held: string] {
    let checker = if $checker == null { landing-gate $gate } else { $checker }
    let fingerprint = (select-fingerprint $fingerprint {|flake| closure-fingerprint $flake })
    let only = if $held == null { null } else {
        $held | split row ":" | where {|path| $path | is-not-empty } | each {|path| open --raw $path | from json | get branch }
    }
    with-runway 'train "ci land --train"' --alone=($held == null) --hold $held --busy {|ahead|
        report-status error $"The runway is busy: ($ahead)" --id runway
        error make { msg: $"The runway is busy: ($ahead). Hold each topic with `ci queue` instead; the drainer lands held topics together as a train." }
    } {
        fetch-trunk
        checkpoint "train"
        let base = (revision-id "trunk()")
        let published = (topic-bookmarks | where parent == null)
        # Snapshot every workspace with work above main first, so edits made
        # there since the last JJ command show as undispatched.
        let busy = (workspaces-in $"(trunk-revset)..working_copies\()")
        for name in $busy {
            let root = (try { workspace-root $name } catch { "" })
            if ($root | path exists) and $root != "" {
                local-complete { ^jj --repository $root status } | ignore
            }
        }
        let plan = (build-plan $published | where bookmark != null | where {|entry| $only == null or $entry.bookmark in $only })
        let moved = if ($published | is-empty) { [] } else {
            other-workspaces-in $"\(($published | each {|topic| bookmark-revset $topic.name } | str join ' | '))::"
        }
        mut claims = []
        mut chain = []
        mut skipped = []
        let outcome = try {
            mut tip = $base
            for entry in $plan {
                let bookmark = (bookmark-revset $entry.bookmark)
                let head = (revision-id $bookmark)
                let reason = (train-exclusion {
                    main: $entry.main
                    impact: $entry.impact
                    pushed: ($head == (try { revision-id (remote-bookmark-revset $entry.bookmark) } catch { "" }))
                    dispatched: ($entry.commit == $head)
                })
                if $reason != null {
                    $skipped = ($skipped | append { topic: $entry.bookmark outcome: $"skipped: ($reason)" })
                    continue
                }
                let change = (revision-field $head 'change_id')
                let lock = (topic-lock-path $change)
                mkdir ($lock | path dirname)
                let claim = ({ topic: (lock-topic $head) pid: $nu.pid start: (process-start $nu.pid) workspace: $env.PWD } | to json --raw)
                let holder = (claim-local-checks-lock $lock $claim)
                if $holder != null {
                    $skipped = ($skipped | append { topic: $entry.bookmark outcome: $"skipped: pid ($holder.pid? | default '?') is moving it" })
                    continue
                }
                $claims = ($claims | append { lock: $lock claim: $claim })
                let on_tip = (contains-main $head) and $tip == $base
                let candidate = $tip
                let trial = if $on_tip { { conflict: false } } else { trial-merge [$candidate $head] }
                if $trial.conflict {
                    $skipped = ($skipped | append { topic: $entry.bookmark outcome: "skipped: conflicts with the train" })
                    continue
                }
                if $entry.impact == "refactor" {
                    let proof = (try {
                        phase closures $"Proving ($entry.bookmark) closure-neutral on the train" {
                            if $on_tip {
                                require-closure-neutral $candidate $head --fingerprint $fingerprint
                            } else {
                                with-trial-merge [$candidate $head] {|probe|
                                    require-closure-neutral $candidate $probe --fingerprint $fingerprint
                                }
                            }
                        }
                        null
                    } catch {|err| $err.msg })
                    if $proof != null {
                        $skipped = ($skipped | append { topic: $entry.bookmark outcome: $"skipped: ($proof | lines | first)" })
                        continue
                    }
                }
                if not $on_tip {
                    restack $bookmark $candidate | ignore
                    if (conflicted-revisions $"($candidate)..($bookmark)" | is-not-empty) {
                        error make { msg: $"Rebasing ($entry.bookmark) onto the train conflicted although its trial merge did not.(recovery-hint)" }
                    }
                }
                let rebased = (revision-id $bookmark)
                print $"($entry.bookmark) joins the train at ($rebased | str substring 0..11)."
                $chain = ($chain | append { name: $entry.bookmark head: $rebased below: $candidate impact: $entry.impact })
                $tip = $rebased
            }
            if ($chain | is-empty) {
                print "No dispatched topic can join a train."
                { value: { landed: 0 chain: [] failure: null } error: null }
            } else {
                report-status working $"Clearing a train of ($chain | length) topics" --id train
                let whole = (train-clearance $checker $gate ($chain | last) $timeout)
                let found = if $whole.passed {
                    { passing: ($chain | length) culprit: null failure: null }
                } else {
                    let train = $chain
                    let split = (bisect-train ($train | length) $whole.error {|length|
                        train-clearance $checker $gate ($train | get ($length - 1)) $timeout
                    })
                    { passing: $split.passing culprit: ($train | get $split.culprit | get name) failure: $split.failure }
                }
                mut landed = $found.passing
                if $landed > 0 {
                    let last = ($chain | get ($landed - 1))
                    for entry in ($chain | first $landed) { push-topic-bookmark $entry.name }
                    if not (advance-main $last.head $base $"a train of ($landed) topics" $gate) {
                        print --stderr "main moved outside the runway while the train cleared; nothing landed."
                        $landed = 0
                    }
                }
                { value: { landed: $landed chain: $chain failure: $found } error: null }
            }
        } catch {|err| { value: null error: $err } }
        if $outcome.error != null {
            release-topic-locks $claims
            update-moved-workspaces $moved
            error make $outcome.error.raw
        }
        let result = $outcome.value
        # Return every topic that did not land to main: the first stays where
        # it is, on the landed prefix or on main; the rest are moved onto
        # main newest first, so the commits above the topic below each one
        # are still its own.
        let returned = ($result.chain | skip $result.landed)
        let returns = ($returned | enumerate | reverse | each {|entry|
            if $entry.index > 0 {
                let own = $"roots\(($entry.item.below)..(bookmark-revset $entry.item.name))"
                run-command $"returning ($entry.item.name) to main" {
                    ^jj ...(checkpoint-tag) rebase -s $own -o (trunk-revset) --skip-emptied
                } | ignore
            }
            let conflicted = (conflicted-revisions $"(trunk-revset)..(bookmark-revset $entry.item.name)" | is-not-empty)
            if not $conflicted { push-topic-bookmark $entry.item.name }
            { topic: $entry.item.name conflicted: $conflicted }
        } | reverse)
        update-moved-workspaces $moved
        release-topic-locks $claims
        let culprit = $result.failure.culprit?
        let rows = (($result.chain | first $result.landed | each {|entry| { topic: $entry.name outcome: "landed" } })
            ++ ($returns | each {|entry|
                let state = if $entry.conflicted { "returned to main with conflicts; resolve before landing" } else { "returned to main" }
                { topic: $entry.topic outcome: (if $entry.topic == $culprit { $"failed clearance, ($state)" } else { $state }) }
            })
            ++ $skipped)
        if ($rows | is-not-empty) { print ($rows | table) }
        if $culprit != null {
            let message = $"($culprit) failed clearance on top of the ($result.landed) topic\(s) that landed: ($result.failure.failure? | default 'no reason given')"
            report-status error $message --id train
            error make { msg: $message }
        }
        if $result.landed > 0 {
            report-status done $"Landed a train of ($result.landed) topics" --id train
            print $"Landed a train of ($result.landed) topics. Each topic's owner runs `ci park`."
        }
        if ($result.chain | is-not-empty) and $result.landed == 0 {
            error make { msg: "main moved outside the runway while the train cleared. Nothing landed; every topic is back on main. Run `ci land --train` again once main is quiet." }
        }
    }
}

# Fast-forward main on every mirror to the trunk's. The trunk is
# authoritative, so a rejected mirror push leaves the landing in place and
# reports how to retry, as an error under `mirror` that does not fail the run.
# A repository without a mirror has nothing to do.
def mirror-main [] {
    let trunk = (trunk)
    let main = $trunk.bookmark
    for mirror in (mirror-remotes $trunk.remote (remotes | get name)) {
        let fetched = (remote-complete $"fetching ($main) from ($mirror)" { ^jj git fetch --remote $mirror --branch $main })
        # jj refuses to create a new bookmark on a remote it does not track.
        do { ^jj bookmark track $"($main)@($mirror)" } | complete | ignore
        let pushed = if $fetched.exit_code == 0 {
            remote-complete $"mirroring ($main) to ($mirror)" { ^jj git push --remote $mirror --bookmark $main }
        } else { $fetched }
        if $pushed.exit_code != 0 {
            let failure = $"Landed on ($trunk.remote), but mirroring ($main) to ($mirror) failed: ($pushed.stderr | str trim). Retry with `jj git push --remote ($mirror) --bookmark ($main)`."
            print --stderr $failure
            report-status error $failure --id mirror
        } else {
            report-status done $"Mirrored ($main) to ($mirror)" --id mirror
        }
    }
}

# Push the release tag `version` to every mirror. Like main's mirror push, a
# rejected one is reported under `mirror` and does not fail the landing.
def mirror-tag [version: string] {
    let remote = (trunk-remote)
    for mirror in (mirror-remotes $remote (remotes | get name)) {
        # jj refuses to create a new tag on a remote it does not track.
        do { ^jj tag track $"($version)@($mirror)" } | complete | ignore
        let pushed = (remote-complete $"mirroring ($version) to ($mirror)" { ^jj git push --remote $mirror --tag $version })
        if $pushed.exit_code != 0 {
            let failure = $"Released ($version) on ($remote), but mirroring it to ($mirror) failed: ($pushed.stderr | str trim). Retry with `jj git push --remote ($mirror) --tag ($version)`."
            print --stderr $failure
            report-status error $failure --id mirror
        }
    }
}

# Push a dispatched topic's branch to the GitHub mirror too when the topic
# holds nixbot.toml, so nixbot builds it while it waits to land and
# `ci land` then finds its checks built or substitutes them. The trunk is
# authoritative and the mirror only a head start, so a rejected push is
# reported under `mirror-topic` without failing the dispatch.
def mirror-topic [branch: string] {
    if (trunk-remote) == $GITHUB_REMOTE or $GITHUB_REMOTE not-in (remotes | get name) { return }
    let config = (do { ^jj file list -r @ $"root-file:\"($NIXBOT_CONFIG)\"" } | complete)
    if $config.exit_code != 0 or ($config.stdout | str trim | is-empty) { return }
    let pushed = (try {
        push-bookmark $GITHUB_REMOTE $branch
        null
    } catch {|err| $err.msg })
    if $pushed != null {
        let failure = $"Mirroring ($branch) to ($GITHUB_REMOTE) for nixbot failed: ($pushed). `ci land --clearance nixbot` pushes it again."
        print --stderr $failure
        report-status error $failure --id mirror-topic
    } else {
        report-status done $"Mirrored ($branch) to ($GITHUB_REMOTE) for nixbot" --id mirror-topic
    }
}

# Clear the topic for departure: rebase, run preflight, and push its branch,
# where it waits to land. --stack pushes each layer as its own branch for
# stacked review on Tangled instead.
def "main dispatch" [
    --land # Land the topic once it has clearance
    --clearance: string = "local" # What must pass the head before --land: local, github, or nixbot
    --timeout: duration = 2hr # How long --land waits for the pipeline
    --attempts: int = 5 # How many times --land starts over when something outside the runway moves main
    --stack # Push one branch per revision for Tangled's stacked pull requests
] {
    if $stack {
        if $land { error make { msg: "--stack is for review only; land the topic with `ci land`." } }
        dispatch-stack
        return
    }
    report-run (if $land { "Landed the topic" } else { "Dispatched the topic" }) {
        with-topic-lock (current-topic-id) {
            let run = (publish-with-agent $land $attempts)
            let published = $run.published
            # The push is the dispatch; reading Tangled only adds review links,
            # so a trunk remote elsewhere, or an unreachable index, skips them.
            let repo = (try { tangled-repo } catch { null })
            let pull = if $repo == null { null } else {
                try { open-pulls $repo | where branch == $published.branch | get --optional 0 } catch { null }
            }
            if $repo == null {
                print $"Pushed ($published.branch) to (trunk-remote)."
            } else if $pull == null {
                let form = ({ source: "branch" sourceBranch: $published.branch targetBranch: (trunk).bookmark } | url build-query)
                print $"Pushed ($published.branch). Open a pull request to review it on Tangled: ($repo.web)/pulls/new?($form)"
            } else {
                print $"Pushed ($published.branch), which updates the pull request \"($pull.title)\"."
            }
            if $published.parent != null {
                print $"Stacked on ($published.parent); it lands after that topic."
            }
            print $"Impact: ($published.impact)"
            if $land {
                drive-topic-agent $run.state $published $timeout $clearance
            } else {
                report-status done "CI agent: dispatched" --id agent
                print "Dispatched this topic in place. Further edits update the same JJ series and branch; `ci land` delivers it."
            }
        }
    }
}

def "main publish" [
    --land # Land the topic once it has clearance
    --gate: string = "local" # What must pass the head before --land: local, github, or nixbot
    --timeout: duration = 2hr # How long --land waits for the pipeline
    --attempts: int = 5 # How many times --land starts over when something outside the runway moves main
] {
    renamed "publish" "dispatch"
    main dispatch --land=$land --clearance $gate --timeout $timeout --attempts $attempts
}

# Land the topic now, from this session. It takes the runway only when the
# runway is clear: with another landing in flight or a topic held for the
# drainer, it refuses and names them, and `ci queue` holds the topic instead.
def "main land" [
    --clearance: string = "local" # What must pass the head: local, github, or nixbot
    --gate: string # Renamed to --clearance
    --timeout: duration = 2hr # How long to wait for the pipeline
    --attempts: int = 5 # How many times to start over when something outside the runway moves main
    --train # Land every dispatched, conflict-free topic in one fast-forward, clearing the chain once
    --held: string # The drainer's: hold files of the topics this run lands, joined by ":"
] {
    let cleared_by = if $gate == null { $clearance } else {
        print --stderr "`ci land --gate` is now `ci land --clearance`."
        $gate
    }
    if $train {
        report-run "Landed the train" {
            require-jj-workspace-here
            land-train $timeout $cleared_by --held $held
        }
        return
    }
    report-run "Landed the topic" {
        with-topic-lock (current-topic-id) {
            if $held != null { require-held-head $held }
            let run = (publish-with-agent true $attempts)
            drive-topic-agent $run.state $run.published $timeout $cleared_by --held $held
        }
    }
}

# Fail unless this workspace still has the change the hold at `path` holds,
# at the head it holds: the drainer lands only what `ci queue` held.
def require-held-head [path: string] {
    let hold = (try { open --raw $path | from json } catch {
        error make { msg: $"The hold ($path) is gone; the topic was dropped or already taken." }
    })
    let change = (current-topic-id)
    let head = (current-change 'commit_id')
    if $change != $hold.change or $head != $hold.head {
        error make { msg: $"($hold.topic) changed since it was queued \(now ($change | str substring 0..<8) at ($head | str substring 0..11)); `ci queue` it again to land the new head." }
    }
}

# Hold this topic for the drainer instead of landing it from this session:
# dispatch it, run the fast checks, and record its exact head. The drainer, a
# transient systemd unit, lands held topics in the order they were held, as
# one train when several share a repository and clearance, and waits its
# turn on the runway for each, so this session can end at once. An edit after
# `ci queue` ends the hold instead of landing a head nobody queued.
def "main queue" [
    --clearance: string = "local" # What must pass the head: local, github, or nixbot
    --timeout: duration = 2hr # How long to wait for the pipeline once on the runway
    --attempts: int = 5 # How many times to start over when something outside the runway moves main
] {
    report-run "Held the topic" {
        with-topic-lock (current-topic-id) {
            let change = (current-topic-id)
            for entry in (held-topics | where {|entry| $entry.hold.change == $change }) {
                finish-hold $entry { exit_code: 1 error: "dropped: queued again" }
            }
            let run = (publish-with-agent false $attempts --hold)
            drive-topic-agent $run.state $run.published $timeout $clearance
        }
    }
}

# The runway and the topics held for it: what is landing, what waits, the
# drainer, and how the latest held topics ended.
def "main queue list" [
    --json # Print the record instead of tables
] {
    let queue = (runway-path)
    mkdir $queue
    let runway = (runway-tickets $queue | each {|ticket|
        { topic: ($ticket.holder.topic? | default "") pid: $ticket.holder.pid? workspace: ($ticket.holder.workspace? | default "") }
    })
    let held = (held-topics | each {|entry|
        {
            topic: $entry.hold.topic
            head: ($entry.hold.head | str substring 0..11)
            clearance: $entry.hold.clearance
            held_at: $entry.hold.held_at
            log: $entry.hold.log
        }
    })
    let holder = (try { open --raw (drainer-lock-path) | from json } catch { null })
    let drainer = if $holder != null and (try { lock-holder-alive $holder } catch { false }) { { pid: $holder.pid unit: $holder.unit? } } else { null }
    let outcomes = ((holds-path) | path join "outcomes.jsonl")
    let recent = if ($outcomes | path exists) {
        open --raw $outcomes | lines | each {|line| try { $line | from json } catch { null } } | compact | last 10
    } else { [] }
    let report = { runway: $runway held: $held drainer: $drainer recent: $recent }
    if $json { return ($report | to json) }
    print (if ($runway | is-empty) { "Runway: clear." } else { "Runway:" })
    if ($runway | is-not-empty) { print ($runway | table) }
    print (if ($held | is-empty) { "Held: none." } else { "Held, in landing order:" })
    if ($held | is-not-empty) { print ($held | table) }
    print (if $drainer == null { "Drainer: not running." } else { $"Drainer: pid ($drainer.pid) \(($drainer.unit? | default 'no unit'))." })
    if ($recent | is-not-empty) {
        print "Recent held landings:"
        print ($recent | select --optional at topic exit_code error | table)
    }
}

# Take this topic out of the line: its hold ends without landing.
def "main queue drop" [] {
    let change = (current-topic-id)
    let mine = (held-topics | where {|entry| $entry.hold.change == $change })
    if ($mine | is-empty) {
        print "This topic is not held."
        return
    }
    for entry in $mine { finish-hold $entry { exit_code: 1 error: "dropped by its owner" } }
    print $"Dropped ($mine | first | get hold.topic) from the line."
}

# The drainer: land every held topic in turn, then exit. `ci queue` starts
# it as a transient user unit; running it by hand does the same work.
def "main queue drain" [
    --unit: string # The transient unit this drainer runs in, so a lock check sees it alive
] {
    drain-holds $unit
}

# Export each revision in `revisions` (a record of name to commit) into its own
# temporary directory, run `body` with a record of name to path, and remove
# the directories again. An export holds exactly the commit's tree and no
# `.git`, so a check that reads its own source as a flake cannot follow a Git
# pointer out of the Nix store. In a JJ workspace the commits live in its Git
# backend, so Git is pointed there; a plain Git checkout needs nothing extra.
# Only the export sees that Git environment, not `body`.
def with-commit-trees [revisions: record, body: closure] {
    let backend = (try { ^jj git root | complete } catch { { exit_code: 1 stdout: "" } })
    let environment = if $backend.exit_code == 0 { { GIT_DIR: ($backend.stdout | str trim) } } else { {} }
    let root = (mktemp --directory --tmpdir "jj-ci-tree.XXXXXX")
    let trees = ($revisions | columns | reduce --fold {} {|name, trees| $trees | insert $name ($root | path join $name) })
    let outcome = try {
        with-env $environment {
            for name in ($revisions | columns) {
                let tree = ($trees | get $name)
                mkdir $tree
                let exported = (do { ^git archive --format=tar ($revisions | get $name) | ^tar -x -C $tree } | complete)
                if $exported.exit_code != 0 {
                    error make { msg: $"exporting ($name) failed: ($exported.stderr | str trim)" }
                }
            }
        }
        { value: (do $body $trees) error: null }
    } catch {|err|
        { value: null error: $err }
    }
    rm --recursive --force $root
    if $outcome.error != null { error make $outcome.error.raw }
    $outcome.value
}

# The commit `head` forks from `onto`: the newest commit both contain. It
# stays put when `onto` moves on, so trunk advancing after a rebase never
# changes what a topic is compared against.
def fork-point [onto: string, head: string] {
    revision-id $"heads\(::\(($onto)) & ::\(($head)))"
}

# Prove every NixOS closure at `head` matches the commit it forks from `onto`,
# or fail naming the hosts that changed. Evaluating every host twice is heavy,
# so the proof holds the local checks lock, and finds that commit only once it
# has the lock: while it waits another session may land, and work that landed
# meanwhile is not the topic's (2026-10-16). `fingerprint` stands in for
# closure-fingerprint in tests.
def select-fingerprint [fingerprint: any, fallback: closure] {
    if $fingerprint == null { $fallback } else { $fingerprint }
}

def require-closure-neutral [onto: string, head: string, --fingerprint: closure] {
    let fingerprint = (select-fingerprint $fingerprint {|flake| closure-fingerprint $flake })
    let differences = (with-local-checks-lock $head {
        with-commit-trees { base: (fork-point $onto $head) head: $head } {|trees|
            closure-differences (do $fingerprint $"path:($trees.base)") (do $fingerprint $"path:($trees.head)")
        }
    })
    if ($differences | is-not-empty) {
        error make { msg: $"Declared refactor, but these host closures changed: ($differences | str join ', '). Make the change closure-neutral or reclassify it as behavior or breaking." }
    }
    print "Every NixOS closure matches the base."
}

# Classify the revisions in `base..head` from their declarations and, for a
# refactor, prove that every NixOS closure matches the merge base. The
# declarations are in this machine's ci log, so it runs where the topic was
# declared; `ci land` runs the same proof itself.
def "main impact check" [base: string, head: string] {
    let impact = (require-impact (revisions-in $"($base)..($head)"))
    print $"Impact: ($impact)"
    if $impact != "refactor" { return }
    require-closure-neutral $base (revision-id $head)
}

# Declare the impact of `--revision` (default the working-copy change; a
# revset declares every revision in it): `refactor`, `behavior`, or
# `breaking` followed by each manual step activating it needs. Declaring
# again replaces the earlier declaration.
def "main impact set" [
    impact: string # refactor, behavior, or breaking
    ...steps: string # The manual steps a breaking change needs, in order
    --revision (-r): string = "@" # The revisions to declare
] {
    let revisions = (revisions-in $revision)
    if ($revisions | is-empty) { error make { msg: $"($revision) names no revisions." } }
    declare-impact $revisions $impact $steps
}

# The declared impact of each revision in `revset` (default the current topic).
def "main impact show" [revset?: string] {
    let revset = ($revset | default $"(trunk-revset)..@")
    with-impacts (revisions-in $revset) | each {|revision|
        {
            change: $revision.short
            title: ($revision.description | lines | get --optional 0 | default "")
            impact: (if ($revision.impact | is-empty) { null } else { $revision.impact })
            steps: $revision.steps
        }
    }
}

# Declare each undeclared revision in `revset` (default the current topic)
# from the `Impact:` trailer its description carried before impact moved to
# the ci log. A breaking revision's description body becomes its one manual
# step. Revisions without a valid trailer are listed, not guessed.
def "main impact import" [revset?: string] {
    let revset = ($revset | default $"(trunk-revset)..@")
    for revision in (with-impacts (revisions-in $revset) | where impact not-in $IMPACTS) {
        let impact = (parse-impact $revision.description)
        let body = (description-body $revision.description)
        let steps = if $impact == "breaking" and ($body | is-not-empty) { [$body] } else { [] }
        if (impact-problem $impact $steps) != null {
            print --stderr $"($revision.short): no usable Impact trailer; run `ci impact set` for it."
            continue
        }
        declare-impact [$revision] $impact $steps
    }
}

const RELEASE_TAG_GLOB = "[0-9][0-9][0-9][0-9].[0-9][0-9].[0-9][0-9].*"

# Tag a CalVer release on every user-facing revision in `range`, oldest first,
# and push each tag to the trunk remote. The tag names the release; the
# revision description and its declared manual steps are its notes, printed
# and recorded in the ci log as `ci.release`.
def cut-releases [range: string, dry_run: bool] {
    let tags = (git-command "listing release tags" {
        ^jj tag list -T 'name ++ "\n"' $"glob:'($RELEASE_TAG_GLOB)'"
    } | lines | uniq)
    let revisions = (git-command "listing unreleased revisions" {
        ^jj log -r $range --reversed --no-graph -T 'commit_id ++ "\t" ++ change_id ++ "\t" ++ committer.timestamp().utc().format("%Y.%m.%d") ++ "\t" ++ description.escape_json() ++ "\n"'
    } | lines | where {|line| $line | is-not-empty } | each {|line|
        let fields = ($line | split row "\t")
        {
            commit: ($fields | first)
            change_id: ($fields | get 1)
            date: ($fields | get 2)
            description: ($fields | skip 3 | str join "\t" | from json)
        }
    } | with-impacts $in)
    mut known = $tags
    for revision in $revisions {
        if $revision.impact not-in ["behavior" "breaking"] { continue }
        let version = (next-version $revision.date $known)
        let title = $"($version): ($revision.description | lines | get --optional 0 | default '')"
        if $dry_run {
            print $"would release ($title) at ($revision.commit | str substring 0..11)"
        } else {
            run-command $"tagging ($version)" { ^jj tag set $version -r $revision.commit } | ignore
            let remote = (trunk-remote)
            run-remote $"pushing ($version) to ($remote)" { ^jj git push --remote $remote --tag $version } | ignore
            mirror-tag $version
            print $"released ($title)"
            for step in $revision.steps { print $"  manual step: ($step)" }
            log-event "ci.release" $title {
                "ci.release.version": $version
                "ci.change_id": $revision.change_id
                "ci.impact": $revision.impact
                "ci.impact.steps": $revision.steps
                "vcs.ref.head.revision": $revision.commit
            }
            report-status done $"Released ($title)" --id $"release/($version)"
        }
        $known = ($known | append $version)
    }
}

# Release every user-facing revision on main since the newest release. `ci
# land` releases what it lands; this catches up after a failed tag push.
# Without an earlier release, only main itself is considered.
def "main release" [--dry-run] {
    let newest = (^jj log -r $"latest\(tags\(glob:'($RELEASE_TAG_GLOB)') & ::(trunk-revset))" --no-graph -T commit_id | complete)
    let range = if $newest.exit_code == 0 and ($newest.stdout | str trim | is-not-empty) {
        $"($newest.stdout | str trim)..(trunk-revset)"
    } else {
        (trunk-revset)
    }
    cut-releases $range $dry_run
}

# The newest CalVer release contained in the current revision.
# Export, as OpenTelemetry traces, every run the ci log or the ci MCP job
# store records that the trace ledger does not list yet: one trace per
# dispatch or landing, with a span for each attempt, phase, check, and wait
# on another topic's local checks. Runs export themselves as they end once an
# endpoint is set; this sends the ones recorded before, or while the
# collector was down.
def "main trace export" [
    --endpoint: string # OTLP/HTTP traces URL; default: OTEL_EXPORTER_OTLP_TRACES_ENDPOINT, or OTEL_EXPORTER_OTLP_ENDPOINT/v1/traces
    --since: datetime # Only runs that started at or after this time
    --dry-run # List the runs and their spans without sending anything
] {
    # A run with no outcome that reported lately may still be going; sending
    # it now would list it in the ledger before it finished.
    let quiet_since = ((date now) - $TRACE_RUN_GAP | into int)
    let runs = (recorded-runs
        | where {|run| $run.records | any {|record| $record.state == "working" } }
        | where {|run| $since == null or ($run.records | first | get time) >= ($since | into int) }
        | where {|run| (
            ($run.records | any {|record| $record.id == "" and $record.state in ["done" "error"] })
            or ($run.records | last | get time) < $quiet_since
        ) })
    if $dry_run {
        return ($runs | each {|run|
            let spans = (status-spans $run.records --name (run-name $run))
            {
                started: ($spans.0.start | into datetime)
                name: $spans.0.name
                took: (($spans.0.end - $spans.0.start) | into duration | format duration sec)
                attempts: ($spans | where name =~ '^attempt ' | length)
                spans: ($spans | length)
                status: $spans.0.status
                job: ($run.job? | default null)
            }
        })
    }
    let target = ($endpoint | default (otlp-traces-endpoint))
    if ($target | is-empty) {
        error make { msg: "No traces endpoint: pass --endpoint, or set OTEL_EXPORTER_OTLP_ENDPOINT (e.g. http://127.0.0.1:4318)." }
    }
    export-traces $runs $target
}

def "main version" [] {
    let commit = (current-change "commit_id")
    run-command "describing the current revision" {
        with-env (git-context) { ^git describe --tags --match $RELEASE_TAG_GLOB $commit }
    }
}

# A verification records that a person tried a release on a real machine. The
# landing gate proves only that each closure builds, so this is the evidence
# that the running configuration behaves as the release describes. Each host
# keeps its own under the state directory and sends a copy to homelab, whose
# SSH account for it can only append one record.
const VERIFICATION_REMOTE = "config-verifications@homelab"
# OpenSSH's second port on homelab; Tailscale SSH owns port 22 there and
# would ignore the account's forced command.
const VERIFICATION_PORT = "2222"
# Written by the activation script in modules/nixos/core.nix.
const ACTIVATION_LOG = "/var/log/nixos-activations.jsonl"

def verification-dir [] {
    $env.XDG_STATE_HOME? | default ($env.HOME | path join ".local" "state") | path join "config-verifications"
}

def read-jsonl [path: string] {
    if not ($path | path exists) { return [] }
    open --raw $path | lines | where {|line| $line | str trim | is-not-empty } | each {|line| $line | from json }
}

# Release tags, newest first, with their commits and titles.
def releases [] {
    let tags = (git-command "listing releases" {
        ^jj tag list -T 'name ++ "\t" ++ normal_target.commit_id() ++ "\t" ++ normal_target.description().first_line() ++ "\n"' $"glob:'($RELEASE_TAG_GLOB)'"
    } | lines | where {|line| $line | is-not-empty } | parse "{release}\t{commit}\t{title}")
    $tags | insert order {|tag| $tag.release | split row "." | into int } | sort-by order --reverse | reject order
}

# The toplevel store path `host` would run at `commit`. Evaluates; builds nothing.
def release-toplevel [commit: string, host: string] {
    with-commit-trees { release: $commit } {|trees|
        git-command $"evaluating ($host) at ($commit | str substring 0..11)" {
            ^nix eval --raw --no-update-lock-file $"path:($trees.release)#nixosConfigurations.($host).config.system.build.toplevel.outPath"
        }
    }
}

# Send queued verifications to homelab in order, stopping at the first
# failure so an unreachable homelab keeps the rest queued.
def flush-verifications [] {
    let outbox = (verification-dir | path join "outbox.jsonl")
    if not ($outbox | path exists) { return }
    let pending = (open --raw $outbox | lines | where {|line| $line | str trim | is-not-empty })
    mut sent = 0
    mut failure = ""
    # Name the user config explicitly, as git's core.sshCommand does: inside
    # Claude Desktop's sandbox ssh rejects the store-owned ~/.ssh/config.
    let user_config = ($env.HOME | path join ".ssh" "config")
    let config_args = if ($user_config | path exists) { ["-F" $user_config] } else { [] }
    for line in $pending {
        let result = ($line | ^ssh ...$config_args -T -p $VERIFICATION_PORT -o BatchMode=yes -o ConnectTimeout=10 $VERIFICATION_REMOTE | complete)
        if $result.exit_code != 0 {
            $failure = ($result.stderr | str trim)
            break
        }
        $sent += 1
    }
    let remaining = ($pending | skip $sent)
    if ($remaining | is-empty) {
        rm $outbox
    } else {
        $remaining | each {|line| $"($line)\n" } | str join | save --force $outbox
    }
    if $sent > 0 { print $"Sent ($sent) verification\(s) to homelab." }
    if ($remaining | is-not-empty) {
        print --stderr $"Could not reach homelab \(($failure)); ($remaining | length) verification\(s) stay queued. Retry with `ci verify flush`."
    }
}

# Record that this host runs RELEASE and that you tested it, then send the
# record to homelab. Refuses unless the running system is exactly that
# release's toplevel for this host.
def "main verify" [
    release?: string # The CalVer release to verify; defaults to the newest
    --message (-m): string # How you tested it
] {
    if ($message | default "" | str trim | is-empty) {
        error make { msg: "Say how you tested the release with --message." }
    }
    let host = (sys host | get hostname)
    let running = ("/run/current-system" | path expand)
    let target = if $release == null {
        # A newer release may not be activated yet, so take the newest recent
        # one that this host is running. Each candidate costs an evaluation.
        mut found = []
        for tag in (releases | first 5) {
            print --stderr $"Checking ($tag.release)…"
            if (release-toplevel $tag.commit $host) == $running {
                $found = [$tag]
                break
            }
        }
        if ($found | is-empty) {
            error make { msg: $"None of the 5 newest releases builds the running system ($running) for ($host). Name the release with `ci verify RELEASE`." }
        }
        $found | first
    } else {
        let tag = (releases | where release == $release | get --optional 0)
        if $tag == null { error make { msg: $"No release named ($release)." } }
        let expected = (release-toplevel $tag.commit $host)
        if $expected != $running {
            error make { msg: $"This host is not running ($release): it runs ($running), but ($release) builds ($expected) for ($host). Activate the release first." }
        }
        $tag
    }
    # The latest switch to this toplevel, if the activation hook saw one.
    let activation = (read-jsonl $ACTIVATION_LOG | where toplevel == $running | reverse | get --optional 0)
    let record = {
        host: $host
        release: $target.release
        commit: $target.commit
        title: $target.title
        toplevel: $running
        profile: ($activation.profile? | default null)
        activated_at: ($activation.time? | default null)
        verified_at: (date now | format date "%+")
        note: ($message | str trim)
    }
    let dir = (verification-dir)
    mkdir $dir
    let line = $"($record | to json --raw)\n"
    $line | save --append ($dir | path join "verified.jsonl")
    $line | save --append ($dir | path join "outbox.jsonl")
    print $"Verified ($target.release) on ($host): ($record.note)"
    flush-verifications
}

# Resend verifications that have not reached homelab yet.
def "main verify flush" [] {
    flush-verifications
}

# Recent releases and whether this host has verified them.
def "main verify list" [
    --count: int = 10 # How many releases to show
] {
    let host = (sys host | get hostname)
    let dir = (verification-dir)
    let verified = (read-jsonl ($dir | path join "verified.jsonl") | where host == $host)
    let queued = (read-jsonl ($dir | path join "outbox.jsonl") | length)
    if $queued > 0 { print --stderr $"($queued) verification\(s) not yet sent to homelab; run `ci verify flush`." }
    releases | first $count | each {|tag|
        let latest = ($verified | where release == $tag.release | reverse | get --optional 0)
        {
            release: $tag.release
            title: $tag.title
            verified: ($latest.verified_at? | default null)
            note: ($latest.note? | default null)
        }
    }
}

def dispatch-stack [] {
    require-ready-change
    rebase-topic
    require-ready-change
    validate-change
    push-tangled-stack
}

def "main tangled stack-publish" [] {
    renamed "tangled stack-publish" "dispatch --stack"
    dispatch-stack
}

def list-workspaces [] {
    git-command "listing workspaces" {
        ^jj workspace list -T 'name ++ "\t" ++ root ++ "\n"'
    } | lines | where {|line| $line | is-not-empty } | each {|line|
        let fields = ($line | split row "\t")
        { name: ($fields | first) root: ($fields | last) }
    }
}

def current-workspace [] {
    let root = (run-command "locating the workspace" { ^jj root })
    list-workspaces | where root == $root | first
}

# `ci start` writes this marker. A workspace that carries it belongs to its
# topic, and `finish` or `abandon` removes it when the topic ends.
def owned-workspace-marker [root: string] {
    $root | path join ".jj" "jj-ci-workspace.json"
}

# Forget a workspace and delete its directory. JJ abandons its empty working
# copy; the operation log keeps every other commit recoverable. The caller
# moves to the default checkout, since the dropped one may be its own.
def --env drop-workspace [workspace: record] {
    let default_root = (workspace-root "default")
    run-command $"forgetting ($workspace.name)" {
        ^jj --repository $default_root workspace forget $workspace.name
    } | ignore
    cd $default_root
    if ($workspace.root | path exists) { rm --recursive $workspace.root }
}

# The Codex hook's per-session record, which maps a task to its workspace.
def codex-session-state-path [session_id: string] {
    let state_dir = ($env.XDG_STATE_HOME? | default ($env.HOME | path join ".local" "state"))
    $state_dir | path join "codex-jj-sessions" $"($session_id).json"
}

# End a Codex task's ownership record with `outcome`, in the workspace and in
# the task's session record, and remove the claim that serialized its startup.
# `finished` stays for hooks built before `state` existed.
def end-ownership [root: string, outcome: string] {
    let owner_path = ($root | path join ".jj" "codex-session.json")
    if ($owner_path | path exists) {
        let owner = (open $owner_path | upsert state $outcome | upsert finished true)
        $owner | to json | save --force $owner_path
        let session_id = ($owner.session_id? | default "")
        if $session_id =~ '^[a-zA-Z0-9_-]+$' {
            let session_path = (codex-session-state-path $session_id)
            if ($session_path | path exists) {
                open $session_path | upsert state $outcome | upsert finished true | to json | save --force $session_path
            }
        }
    }
    let claim = ($root | path join ".jj" "codex-session-claim")
    if ($claim | path exists) { rm --recursive $claim }
}

# Release the topic onto an empty change on main. A workspace that `ci start`
# created is then dropped; any other one stays and its Codex owner records
# `outcome` (delivered or discarded).
def --env release-workspace [summary: string, change: string, keep: bool, outcome: string] {
    let workspace = (current-workspace)
    run-command "leaving a clean workspace on main" { ^jj new (trunk-revset) } | ignore
    let marker = (owned-workspace-marker $workspace.root)
    if not $keep and $workspace.name != "default" and ($marker | path exists) {
        drop-workspace $workspace
        print $"($summary) Removed workspace ($workspace.name); continue from ($env.PWD)."
        return
    }
    # A kept workspace joins the pool: its next task starts a fresh topic, so
    # the finished topic's marker must not pin the next session to it.
    if ($marker | path exists) { rm $marker }
    let owner_path = ($workspace.root | path join ".jj" "codex-session.json")
    if ($owner_path | path exists) and (open $owner_path).change_id? == $change {
        end-ownership $workspace.root $outcome
    }
    print $"($summary) Workspace is on main; the Codex task can now be archived."
}

# What `ci unclaim` may do, from the ownership record's status, whether the
# owner's change is still checked out here, and whether a claim remains. It
# never releases a change that is checked out: `finish` or `abandon` owns that.
def unclaim-verdict [facts: record] {
    # An ended record from before `state` is rewritten as released, so no
    # reader can mistake its `finished` for delivery.
    let nothing = { release: false clear_claim: false normalize: (($facts.legacy? | default false) and $facts.status != "active") refuse: null }
    match $facts.status {
        "none" => (if $facts.claim {
            $nothing | upsert clear_claim true
        } else {
            $nothing | upsert refuse "No Codex task owns this workspace."
        })
        "active" => (if $facts.at_owner_change {
            $nothing | upsert refuse "The owning task's change is checked out here. Use `ci park` or `ci cancel` to end the topic."
        } else {
            { release: true clear_claim: true normalize: false refuse: null }
        })
        _ => ($nothing | upsert clear_claim $facts.claim)
    }
}

# The changes this workspace holds: @, and its parent when @ is an empty,
# undescribed scratch change on top of it.
def checked-out-changes [] {
    let scratch = (current-change 'empty && description == ""') == "true"
    let revset = if $scratch { "@ | @-" } else { "@" }
    git-command "reading the checked-out changes" {
        ^jj log -r $revset --no-graph -T 'change_id ++ "\n"'
    } | lines | where {|line| $line | is-not-empty }
}

# The linked Git worktree that holds `dir` inside the JJ workspace `root`, or
# null. Claude Code's desktop app gives each session such a worktree under
# .claude/worktrees and refuses edits outside it. Keep in step with
# enclosing-git-worktree in context-status.nu.
def enclosing-git-worktree [dir: path, root: path] {
    mut current = ($dir | path expand)
    while ($current | str starts-with $"($root)/") {
        if ($current | path join ".git" | path type) == "file" { return $current }
        $current = ($current | path dirname)
    }
    null
}

# Where `ci start` puts a workspace: inside the Git worktree it runs from, so
# a session confined to that worktree can edit it, or else beside the default
# checkout.
def start-parent [default_root: string, worktree: any] {
    $worktree | default $default_root | path join ".jj-workspaces"
}

def "main start" [
    name: string # Workspace and topic name
] {
    if $name !~ '^[a-z0-9][a-z0-9-]*$' {
        error make { msg: "Use a lowercase name of letters, digits, and hyphens." }
    }
    if $name in (list-workspaces | get name) {
        error make { msg: $"Workspace ($name) already exists. Park or cancel its topic first, or start a topic there with `ci new`." }
    }
    let default_root = (workspace-root "default")
    let root = (start-parent $default_root (enclosing-git-worktree $env.PWD $default_root) | path join $name)
    if ($root | path exists) {
        error make { msg: $"($root) already exists. Inspect it with `ci prune` before reusing the name." }
    }
    fetch-trunk
    mkdir ($root | path dirname)
    let trunk = (trunk)
    run-command $"creating workspace ($name)" {
        ^jj --repository $default_root workspace add --revision "trunk()" --name $name $root
    } | ignore
    # The working-copy change JJ just created is the topic; recording it lets
    # later commands notice when the working copy leaves it.
    let topic = (^jj --repository $root log -r @ --no-graph -T change_id | complete)
    if $topic.exit_code != 0 { error make { msg: ($topic.stderr | str trim) } }
    { name: $name created: (date now | format date "%+") change_id: ($topic.stdout | str trim) } | to json | save (owned-workspace-marker $root)
    print $"Created ($root) on ($trunk.bookmark)@($trunk.remote). Edit and run `jj` and `ci` there; `ci park` or `ci cancel` removes it when the topic ends."
}

# Why `ci new` may not start another topic in this workspace, or null. A
# workspace that an active task or `ci start` dedicated to one topic keeps it
# until `finish` or `abandon`; any other one holds sibling topics. An empty
# working copy that is unnamed, or that its owner claimed before naming it,
# becomes the topic in place (`in_place`), which moves nothing.
def new-topic-refusal [facts: record] {
    if $facts.owner == "active" and not $facts.in_place {
        return "An active agent session owns this workspace's change. Start concurrent work in a free workspace or with `ci start NAME`."
    }
    if $facts.dedicated and not $facts.topic_done {
        return "This workspace belongs to one unfinished topic from `ci start`. Finish or abandon it, or start concurrent work with `ci start NAME`."
    }
    null
}

# Start a topic on the trunk's main in this workspace. An empty working copy that
# is unnamed, or that an agent session claimed before naming it, becomes the
# topic itself, so the change a session owns keeps its ID. Otherwise a new
# change starts, and the current topic stays where it is, as a sibling; return
# to it with `jj edit`.
def "main new" [
    --message (-m): string # Description for the new topic
] {
    require-jj-workspace-here
    let root = (git-command "locating the workspace" { ^jj root })
    let marker = (owned-workspace-marker $root)
    let facts = (topic-facts)
    let owner = (session-owner)
    let current = (current-topic-id)
    let empty = (current-change "empty") == "true"
    let unnamed = $empty and (current-change "description") == ""
    let immutable = (current-change "immutable") == "true"
    let in_place = $empty and not $immutable and ($unnamed or ((owner-status $owner) == "active" and $owner.change_id? == $current))
    let refusal = (new-topic-refusal {
        owner: (owner-status $owner)
        dedicated: ($marker | path exists)
        topic_done: ($facts.landed or not $facts.visible or $facts.topic_empty)
        in_place: $in_place
    })
    if $refusal != null { error make { msg: $refusal } }
    fetch-trunk
    let at = (trunk | $"($in.bookmark)@($in.remote)")
    let trunk = "trunk()"
    if $in_place {
        if (revset-change-ids $"@- & ($trunk)" | is-empty) {
            run-command $"moving the empty change onto ($at)" { ^jj rebase -r @ -o $trunk } | ignore
        }
        if $message != null {
            run-command "naming the topic" { ^jj describe --message $message } | ignore
        }
        # A marker naming another topic would strand this one.
        if ($marker | path exists) and (open $marker).change_id? != $current { rm $marker }
        print $"Started topic (current-change 'change_id.short()') on ($at)."
        return
    }
    # Work parked on main is delivered, not a sibling to return to.
    let previous = if $immutable { null } else { { id: (current-change "change_id.short()") title: (current-change "description.first_line()") } }
    let args = if $message == null { [] } else { [--message $message] }
    run-command $"starting a topic on ($at)" { ^jj new $trunk ...$args } | ignore
    # A pool workspace's marker named the landed topic; the new one is not it.
    if ($marker | path exists) { rm $marker }
    let created = (current-change "change_id.short()")
    if $previous == null {
        print $"Started topic ($created) on ($at)."
    } else {
        let title = if ($previous.title | is-empty) { "(no description)" } else { $previous.title }
        print $"Started topic ($created) on ($at). ($previous.id) \"($title)\" stays as a sibling; return with `jj edit ($previous.id)`."
    }
}

# The topic that `finish` closes. Landing fast-forwards main onto the topic
# head, which makes the working-copy commit immutable, so jj parks the
# workspace on a new empty child. That child has no publication of its own;
# the landed parent it sits on is the topic.
def finish-topic-id [] {
    let current = (current-topic-id)
    if (current-change "empty") != "true" or (current-change "description") != "" {
        return $current
    }
    let parent = (^jj log -r "@- ~ root()" --no-graph -T 'change_id ++ "\n"' | complete)
    let parents = ($parent.stdout | lines | where {|line| $line | is-not-empty })
    if $parent.exit_code == 0 and ($parents | length) == 1 and ($parents | first) in (publication-topics) {
        $parents | first
    } else {
        $current
    }
}

# Taxi in and shut down: confirm the topic landed, then free its workspace.
def --env "main park" [
    --keep # Keep a workspace that `ci start` created
] {
    let change = (finish-topic-id)
    require-owned-change $change
    let branch = (publication-bookmark $change)
    let empty = (current-change "empty") == "true"
    checkpoint "park"
    fetch-trunk
    # An empty working copy is either an unpublished topic or one parked on top
    # of its landed work; a published branch must be on main either way.
    let published = (revset-change-ids (remote-bookmark-revset $branch) | is-not-empty)
    if $empty {
        if $published and not (topic-landed $branch) {
            error make { msg: $"($branch) is dispatched but not on main. Land it or cancel it explicitly before parking." }
        }
    } else if (revset-change-ids $"@ & ::(trunk-revset)" | is-empty) {
        error make { msg: "The current revision is not on main. Land it with `ci land`, and leave the task open until it has." }
    }
    delete-topic-bookmark $branch
    forget-publication-bookmark $change
    let main = (trunk).bookmark
    run-command $"advancing ($main)" { ^jj ...(checkpoint-tag) bookmark move $main --to "trunk()" } | ignore
    let summary = if $published { $"Parked ($branch)." } else { "Parked an undispatched topic." }
    # Past the checks above, a published or non-empty topic is on main.
    release-workspace $summary $change $keep (if $published or not $empty { "delivered" } else { "discarded" })
    report-status done $summary --id park
}

def --env "main finish" [
    --keep # Keep a workspace that `ci start` created
] {
    renamed "finish" "park"
    main park --keep=$keep
}

def --env "main abandon" [
    --keep # Keep a workspace that `ci start` created
] {
    renamed "abandon" "cancel"
    main cancel --keep=$keep
}

# Scrub the flight: abandon the topic's revisions and free its workspace.
def --env "main cancel" [
    --keep # Keep a workspace that `ci start` created
] {
    require-owned-change
    let change = (current-change "change_id")
    let branch = (publication-bookmark)
    let repo = (try { tangled-repo } catch {|err|
        print --stderr $"Not checking for an open pull request: ($err.msg)"
        null
    })
    let open = if $repo == null { [] } else { open-pulls $repo | where branch == $branch }
    if ($open | is-not-empty) {
        error make { msg: $"The pull request \"($open | first | get title)\" is still open. Close it deliberately before cancelling the topic." }
    }
    let revisions = (topic-revisions)
    checkpoint "cancel"
    forget-publication-bookmark
    delete-topic-bookmark $branch
    if ($revisions | is-not-empty) {
        let moved = (other-workspaces-in $"\(($revisions | get commit_id | str join ' | '))::")
        run-command "abandoning the topic" { ^jj ...(checkpoint-tag) abandon ...($revisions | get change_id) } | ignore
        update-moved-workspaces $moved
    }
    release-workspace $"Cancelled the topic and abandoned ($revisions | length) revision\(s)." $change $keep "discarded"
}

# Release a Codex task's claim on this workspace when the task left its change
# behind without `finish` or `abandon`, or clear a claim left without an owner.
# The topic itself is untouched: its revisions, branch, and pull request stay
# where they are, and it can continue in another workspace.
def "main unclaim" [] {
    let root = (git-command "locating the workspace" { ^jj root })
    let owner = (session-owner)
    let claim = ($root | path join ".jj" "codex-session-claim")
    let verdict = (unclaim-verdict {
        status: (owner-status $owner)
        at_owner_change: ($owner != null and ($owner.change_id? in (checked-out-changes)))
        claim: ($claim | path exists)
        legacy: ($owner != null and ($owner.state? | default "") == "")
    })
    if $verdict.refuse != null { error make { msg: $verdict.refuse } }
    if $verdict.normalize {
        # end-ownership also removes the claim.
        end-ownership $root "released"
        print $"Marked the pre-`state` record for change ($owner.change_id? | default 'unknown' | str substring 0..7) as vacated; it no longer reads as parked."
    } else if $verdict.release {
        end-ownership $root "released"
        # This workspace no longer holds the topic, so its publication entry
        # would only mislead a later task here.
        forget-publication-bookmark $owner.change_id
        print $"Vacated change ($owner.change_id | str substring 0..7) from Codex task ($owner.session_id? | default 'unknown'). Its revisions and branch are unchanged."
    } else if $verdict.clear_claim {
        rm --recursive $claim
        print "Removed a session claim that no active task holds."
    } else {
        print "Nothing to vacate."
    }
}

# Hand the topic checked out here to the next agent session that edits the
# workspace. Agents claim only a workspace idle on trunk on their own, so a
# topic someone started by hand, or one whose session ended, stays theirs
# until this hands it over.
def "main adopt" [] {
    require-jj-workspace-here
    let root = (git-command "locating the workspace" { ^jj root })
    let owner = (session-owner)
    if (owner-status $owner) == "active" {
        error make { msg: $"Agent session ($owner.session_id? | default 'unknown') owns this workspace's change ($owner.change_id? | default 'unknown' | str substring 0..7). `ci unclaim` frees it once that session has left it." }
    }
    if (revset-change-ids $"\((trunk-revset)..@) ~ empty\()" | is-empty) {
        error make { msg: "Nothing here to hand over: the workspace is idle on trunk, and the next session to edit it claims it anyway." }
    }
    let change = (current-topic-id)
    { change_id: $change created: (date now | format date "%+") } | to json | save --force ($root | path join ".jj" "jj-ci-adopt.json")
    print $"Handed topic ($change | str substring 0..7) \"(current-change 'description.first_line()')\" to the next agent session that edits ($root)."
}

def owner-state [root: string] {
    let path = ($root | path join ".jj" "codex-session.json")
    owner-status (if ($path | path exists) { open $path } else { null })
}

# A Codex task archived or abandoned without `ci park` leaves its record
# active, and prune kept such workspaces forever: three from 2026-10-01 were
# still held five days later. Codex appends to the task's rollout file while
# the task runs, so a rollout quiet for this long, or archived, ends the claim
# as far as prune is concerned. Work above trunk is kept either way.
const OWNER_QUIET = 2day

# Whether a Codex task still runs, from its rollout file: `ended` when the
# rollout was archived or has been quiet past OWNER_QUIET, `live` when it was
# written since, and `unknown` when no rollout names the session.
def owner-liveness [facts: record] {
    if $facts.archived { return "ended" }
    if $facts.last_write == null { return "unknown" }
    if ($facts.now - $facts.last_write) > $OWNER_QUIET { "ended" } else { "live" }
}

# A Claude Code session that claimed a workspace on its first edit records
# its transcript, which it appends to as it runs; a Codex task is found by
# its rollout file. Keep in step with owner-idle in context-status.nu.
def session-transcript-facts [record: record] {
    let transcript = ($record.transcript_path? | default "")
    if ($transcript | is-not-empty) and ($transcript | path exists) {
        return { archived: false last_write: (ls --long $transcript | first | get modified) }
    }
    codex-rollout-facts ($record.session_id? | default "")
}

def codex-rollout-facts [session_id: string] {
    let home = ($env.CODEX_HOME? | default ($env.HOME | path join ".codex"))
    if $session_id !~ '^[a-zA-Z0-9_-]+$' { return { archived: false last_write: null } }
    let live = (glob $"($home)/sessions/**/*($session_id).jsonl")
    let archived = (glob $"($home)/archived_sessions/**/*($session_id).jsonl")
    {
        archived: ($archived | is-not-empty)
        last_write: (if ($live | is-empty) { null } else { $live | each {|file| ls --long $file | first | get modified } | math max })
    }
}

# When this workspace was last used: the newer of its `ci start` marker and
# JJ's tree state, which a snapshot that found edits or a checkout rewrites.
# (Its `checkout` file is no guide: operations in other workspaces rewrite
# it.) Read from the filesystem, so asking never snapshots anyone's edits.
def workspace-last-used [root: string] {
    let dot_jj = ($root | path join ".jj")
    let candidates = [($dot_jj | path join "jj-ci-workspace.json") ($dot_jj | path join "working_copy" "tree_state")]
    let times = ($candidates | where {|path| $path | path exists } | each {|path| ls --long $path | first | get modified })
    if ($times | is-empty) { null } else { $times | math max }
}

# The facts prune decides from. Running JJ inside a workspace snapshots any
# unrecorded edits first, so a workspace used within `idle` is kept before
# any JJ call reaches it. A stale workspace is updated only when `refresh` is
# set, because updating rewrites its files.
def workspace-facts [workspace: record, current: string, refresh: bool, idle: duration] {
    let exists = ($workspace.root | path exists)
    let owner_path = ($workspace.root | path join ".jj" "codex-session.json")
    let owner = (owner-state $workspace.root)
    let liveness = if $owner == "active" {
        let record = (try { open $owner_path } catch { {} })
        owner-liveness (session-transcript-facts $record | insert now (date now))
    } else { "none" }
    let last_used = if $exists { workspace-last-used $workspace.root } else { null }
    let facts = {
        name: $workspace.name
        current: ($workspace.root == $current)
        exists: $exists
        git_worktree: ($workspace.root | path join ".git" | path exists)
        codex_worktree: ($workspace.root | str starts-with ($env.CODEX_HOME? | default ($env.HOME | path join ".codex") | path join "worktrees"))
        owner: $owner
        owner_ended: ($liveness == "ended")
        last_used: $last_used
        recent: ($last_used != null and ((date now) - $last_used) < $idle)
        stale: false
        error: null
        pending: false
    }
    if $workspace.name == "default" or $facts.current or not $facts.exists or $facts.git_worktree or $facts.codex_worktree or $facts.recent or ($facts.owner == "active" and not $facts.owner_ended) {
        return $facts
    }
    let probe = {|| do { ^jj --repository $workspace.root log -r @ --no-graph -T commit_id } | complete }
    mut state = (do $probe)
    if $state.exit_code != 0 and ($state.stderr | str contains "stale") {
        if not $refresh { return ($facts | upsert stale true) }
        let updated = (do { ^jj --repository $workspace.root workspace update-stale } | complete)
        if $updated.exit_code != 0 { return ($facts | upsert error ($updated.stderr | str trim)) }
        $state = (do $probe)
    }
    if $state.exit_code != 0 { return ($facts | upsert error ($state.stderr | str trim | lines | first)) }
    # Everything above trunk except an empty, undescribed working copy. Landed
    # work is on main itself, so it never counts.
    let pending = (do {
        ^jj --repository $workspace.root log -r $"heads\(\((trunk-revset)..@) ~ \(@ & empty\() & description\(exact:\"\")))" --no-graph -T 'change_id ++ "\n"'
    } | complete)
    if $pending.exit_code != 0 { return ($facts | upsert error ($pending.stderr | str trim | lines | first)) }
    $facts | upsert pending ($pending.stdout | str trim | is-not-empty)
}

# Why prune must keep a workspace, or null when nothing in it is live: it is
# missing, or nothing above trunk remains except an empty undescribed working
# copy.
def prune-verdict [facts: record] {
    if $facts.name == "default" { return "default workspace" }
    if $facts.current { return "current workspace" }
    if not $facts.exists { return null }
    if $facts.git_worktree { return "Git worktree; remove it with its owner" }
    if $facts.codex_worktree { return "Codex worktree; archive its task instead" }
    if ($facts.recent? | default false) { return "used recently; `--idle` keeps it" }
    if $facts.owner == "active" and not ($facts.owner_ended? | default false) { return "owned by an active task" }
    if $facts.stale { return "stale; `ci prune --apply` updates it and decides again" }
    if $facts.error != null { return $"unreadable: ($facts.error)" }
    if $facts.pending { return "has undelivered changes" }
    null
}

def prune-checkpoints [root: string, cutoff: datetime, apply: bool] {
    let directory = ($root | path join ".jj" "jj-ci-checkpoints")
    if not ($directory | path exists) { return 0 }
    let old = (ls $directory | where modified < $cutoff)
    if $apply { $old | each {|file| rm $file.name } | ignore }
    $old | length
}

# Topic branches whose every copy, local or on a remote, is already on main,
# from rows of { name, landed } per copy. A topic landed without `ci park`
# kept its branch: seventeen such `jj-*` branches stood on 2026-10-07.
# Branches a remaining workspace still records for its topic stay for its
# `ci park`, which reads them to tell a delivered topic from a discarded one.
# A `stack/SERIES/CHANGE` layer that `ci dispatch --stack` pushed stays until
# every layer of its series has landed, since the stacked pull request above
# it targets its branch; landed layers had piled up beside an open one
# (2026-10-19).
def landed-branches [copies: list, in_use: list] {
    let pending = ($copies | where {|copy| not $copy.landed } | each {|copy| stack-series $copy.name } | where {|series| $series != null } | uniq)
    $copies | group-by name | transpose name rows
    | where {|branch| ($branch.rows | all {|copy| $copy.landed }) and $branch.name not-in $in_use }
    | where {|branch| (stack-series $branch.name) == null or (stack-series $branch.name) not-in $pending }
    | get name
}

# The series a `stack/SERIES/CHANGE` layer branch belongs to, or null for any
# other branch.
def stack-series [name: string] {
    let parts = ($name | split row "/")
    if ($parts | length) == 3 and ($parts | first) == "stack" { $parts | get 1 } else { null }
}

def topic-branch-copies [] {
    let trunk = (trunk-revset)
    git-command "listing topic branches" {
        ^jj bookmark list --all-remotes -T 'if(normal_target, name ++ "\t" ++ normal_target.commit_id() ++ "\n")' 'glob:jj-*' 'glob:stack/*'
    } | lines | where {|line| $line | is-not-empty } | parse "{name}\t{commit}" | uniq
    | each {|copy| { name: $copy.name landed: (revset-change-ids $"($copy.commit) & ::($trunk)" | is-not-empty) } }
}

# The branches a workspace's `ci` publication state records for its topics.
def recorded-branches [root: string] {
    let path = ($root | path join ".jj" "jj-ci-publication.json")
    if not ($path | path exists) { return [] }
    try { open $path | get topics? | default {} | values } catch { [] }
}

# Prune is the backstop for owners that never released their workspace: a
# crashed or archived task, a topic landed without `ci park`, or a workspace
# created before `ci start`. The daily `ci-prune` user timer runs it with
# `--apply --idle 1day`.
def --env "main prune" [
    --apply # Update stale workspaces, then forget and delete the listed workspaces, branches, and checkpoints
    --keep-days: int = 14 # Keep checkpoints newer than this
    --idle: duration = 0sec # Keep workspaces used more recently than this, without running JJ in them
] {
    fetch-trunk
    let current = (git-command "locating the workspace" { ^jj root })
    if $apply { checkpoint "prune" }
    let reviewed = (list-workspaces | each {|workspace|
        let facts = (workspace-facts $workspace $current $apply $idle)
        $workspace | insert keep (prune-verdict $facts) | insert owner_ended $facts.owner_ended | insert last_used $facts.last_used
    })
    let removable = ($reviewed | where keep == null)
    let kept = ($reviewed | where keep != null)
    let cutoff = (date now) - ($keep_days * 1day)
    for workspace in $removable {
        if $apply {
            # Close an ended task's record so its session state agrees.
            if $workspace.owner_ended and ($workspace.root | path exists) { end-ownership $workspace.root "released" }
            drop-workspace $workspace
        }
        let why = if $workspace.owner_ended { " (its Codex task ended without parking)" } else { "" }
        print $"(if $apply { 'removed' } else { 'would remove' }) ($workspace.name): ($workspace.root)($why)"
    }
    for workspace in $kept {
        # Work nobody has touched for days needs a person: land it or cancel it.
        let untouched = if $workspace.last_used == null { null } else { (date now) - $workspace.last_used }
        let age = if $untouched != null and $untouched > 1day { $", untouched for ($untouched // 1day) days" } else { "" }
        print $"kept ($workspace.name): ($workspace.keep)($age)"
    }
    let in_use = ($kept | where {|workspace| $workspace.root | path exists } | each {|workspace| recorded-branches $workspace.root } | flatten)
    for branch in (landed-branches (topic-branch-copies) $in_use) {
        if $apply {
            try { delete-topic-bookmark $branch } catch {|err| print --stderr $"could not delete ($branch): ($err.msg)" }
        }
        print $"(if $apply { 'deleted' } else { 'would delete' }) landed branch ($branch)"
    }
    let checkpoints = ($kept | where {|workspace| $workspace.root | path exists } | each {|workspace| prune-checkpoints $workspace.root $cutoff $apply } | math sum)
    print $"(if $apply { 'Removed' } else { 'Would remove' }) ($checkpoints) checkpoint\(s) older than ($keep_days) days."
    if not $apply { print "Dry run only. Re-run with `ci prune --apply` to remove them." }
}
