# Nushell completions for ci. Keep these signatures in step with the
# `main` subcommands in ci.nu.

def "nu-complete ci review-labels" [] {
    let root = (^jj root | complete)
    if $root.exit_code != 0 { return [] }
    let path = ($root.stdout | str trim | path join ".jj" "jj-ci-review-versions.json")
    if not ($path | path exists) { return [] }
    open $path | each {|version| { value: $version.label, description: $version.created_at? } }
}

def "nu-complete ci topics" [] {
    let topics = (^jj bookmark list --template 'if(!remote, name ++ "\t" ++ normal_target.description().first_line() ++ "\n")' 'glob:jj-*' | complete)
    if $topics.exit_code != 0 { return [] }
    $topics.stdout | lines | where {|line| $line | is-not-empty } | each {|line|
        let fields = ($line | split row "\t")
        { value: ($fields | first), description: ($fields | skip 1 | str join "\t") }
    }
}

def "nu-complete ci clearances" [] {
    [
        { value: "local", description: "The flake checks built on this machine" }
        { value: "spindle", description: "The Tangled repository's spindle" }
        { value: "github", description: "GitHub Actions on the origin mirror" }
    ]
}

def "nu-complete ci impacts" [] {
    [
        { value: "refactor", description: "Every NixOS closure is unchanged" }
        { value: "behavior", description: "A user-facing change; landing it cuts a release" }
        { value: "breaking", description: "A user-facing change that needs the manual steps it lists" }
    ]
}

def "nu-complete ci revisions" [] {
    let bookmarks = (^jj bookmark list --all-remotes --template 'name ++ if(remote, "@" ++ remote) ++ "\n"' | complete)
    if $bookmarks.exit_code != 0 { return [] }
    $bookmarks.stdout | lines | uniq
}

# Carry JJ topics to main: sequence, preflight, dispatch, land, park, verify
export extern "ci" []

# Show the working copy and each published topic with its pipeline and pull request
export extern "ci status" []

def "nu-complete ci tower-themes" [] {
    [
        { value: "synthwave", description: "Neon truecolor on the terminal's background" }
        { value: "ansi", description: "The terminal's own sixteen colors" }
    ]
}

# Watch every topic, run, and release live, and run the next step from a key
export extern "ci tower" [
    dir?: path # A directory inside the JJ repository
    --theme: string@"nu-complete ci tower-themes" # synthwave (truecolor) or ansi (the terminal's palette)
    --json # Print the collected topics, runs, and locks, then exit
    --snapshot: string # Render one frame at WxH as text, then exit
]

# Print the current topic's published head, pipeline verdicts, and pull request as JSON
export extern "ci ci-state" []

# Fetch Tangled, advance main, and rebase the empty working copy onto it
export extern "ci sync" []

# Report Git worktrees and how far they are from tangled/main
export extern "ci worktree-status" []

# Run every pre-activation check on the current change
export extern "ci preflight" []

# Record the current change as a named review version
export extern "ci review snapshot" [
    label: string # Name for this review version
]

# Show the diff between two recorded review versions
export extern "ci interdiff" [
    old: string@"nu-complete ci review-labels" # Earlier review version
    new: string@"nu-complete ci review-labels" # Later review version
]

# Rebase the current topic onto main
export extern "ci rebase" []

# Undo a checkpoint's rewrite and nothing else, keeping other workspaces' work
export extern "ci recover" [
    checkpoint?: string # The ID printed with "Recovery point"; defaults to this workspace's latest
]

# Show how in-flight topics stack on the ones they conflict with, or restack them
export extern "ci sequence" [
    --json # Print the sequence as JSON
    --apply # Restack stacked or conflicting topics, pushing conflict-free rebases
    --no-push # With --apply, rebase and report conflicts without pushing
    --all # With --apply, also rebase conflict-free topics merely behind main
]

# Build the Home Manager generation of trunk plus published topics without activating it
export extern "ci sim" [
    ...topics: string@"nu-complete ci topics" # Topic branches to include (default: every published behavior or breaking topic)
    --all # Include refactor topics when no branches are given
    --shell # Open Nushell with the simulation's programs first on PATH
    --config # With --shell, also read configuration from the simulation (read-only)
    --active # Compare against the active generation instead of trunk's
]

# List conflicted revisions and files in the current topic
export extern "ci conflicts" []

# Rebase, run preflight, and push the current topic to Tangled to await landing
export extern "ci dispatch" [
    --land # Land the topic once it has clearance
    --clearance: string@"nu-complete ci clearances" # What must pass the head before --land (default local)
    --timeout: duration # How long --land waits for the pipeline (default 2hr)
    --attempts: int # How many times --land starts over when something outside the landing queue moves main (default 5)
    --stack # Push one branch per revision for Tangled's stacked pull requests
]

# Dispatch the current topic, wait for clearance, and fast-forward main
export extern "ci land" [
    --clearance: string@"nu-complete ci clearances" # What must pass the head (default local)
    --timeout: duration # How long to wait for the pipeline (default 2hr)
    --attempts: int # How many times to start over when something outside the landing queue moves main (default 5)
]

# Check the declared impact of the revisions between two revisions
export extern "ci impact check" [
    base: string@"nu-complete ci revisions" # Base revision
    head: string@"nu-complete ci revisions" # Head revision
]

# Declare a revision's impact in the ci log
export extern "ci impact set" [
    impact: string@"nu-complete ci impacts" # refactor, behavior, or breaking
    ...steps: string # The manual steps a breaking change needs, in order
    --revision(-r): string@"nu-complete ci revisions" # The revisions to declare (default @)
]

# Show each revision's declared impact
export extern "ci impact show" [
    revset?: string@"nu-complete ci revisions" # Revisions to show (default the current topic)
]

# Declare undeclared revisions from their former Impact: trailers
export extern "ci impact import" [
    revset?: string@"nu-complete ci revisions" # Revisions to import (default the current topic)
]

# Tag a release for behavior or breaking changes since the last release
export extern "ci release" [
    --dry-run # Report the release without tagging it
]

# Describe the current revision against release tags
export extern "ci version" []

# Record that this host runs a release and how you tested it, and send it to homelab
export extern "ci verify" [
    release?: string # CalVer release (default: the newest one this host runs)
    --message (-m): string # How you tested it
]

# Recent releases and whether this host has verified them
export extern "ci verify list" [
    --count: int # How many releases to show (default 10)
]

# Resend verifications that have not reached homelab yet
export extern "ci verify flush" []

# Create a workspace at main@tangled for a concurrent actor's topic
export extern "ci start" [
    name: string # Workspace and topic name
]

# Start a topic as a new change on main@tangled in this workspace
export extern "ci new" [
    --message (-m): string # Description for the new topic
]

# Confirm the current head landed on main and free the workspace
export extern "ci park" [
    --keep # Keep a workspace that `ci start` created
]

# Abandon the current topic's revisions and free the workspace
export extern "ci cancel" [
    --keep # Keep a workspace that `ci start` created
]

# Vacate a Codex task's claim that its task left behind, without touching the topic
export extern "ci unclaim" []

# Hand the topic checked out here to the next agent session that edits the workspace
export extern "ci adopt" []

# List stale workspaces and checkpoints
export extern "ci prune" [
    --apply # Forget and delete the listed workspaces and checkpoints
    --keep-days: int # Keep checkpoints newer than this (default 14)
]
