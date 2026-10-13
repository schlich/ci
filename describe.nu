def main [
    revset: string = "@"
    --prompt: string
] {
    print $"[jj-describe] Running for revset: ($revset)"
    cd (^jj root | str trim)
    let change = (^jj show --color never -r $revset | str trim)
    let prompt_context = if $prompt == null {
        ""
    } else {
        $"\nThe first user prompt for this session was:\n---\n($prompt)\n---\nUse it as the primary source for the subject, even if the changeset is empty."
    }
    let request = $"Describe this Jujutsu changeset. Return only the description text: an imperative subject of at most 72 characters and, only when useful, a concise body explaining why. Do not use markdown fences or preamble. Do not describe unrelated working-copy changes.\n\nChangeset:\n---\n($change)\n---\n($prompt_context)"
    let output_file = (mktemp | str trim)
    let result = (with-env { CODEX_JJ_SESSION_HOOK: "1" } {
        ^codex exec --sandbox read-only --skip-git-repo-check --color never --output-last-message $output_file $request | complete
    })

    if $result.exit_code != 0 {
        rm $output_file
        error make { msg: $"codex exec failed: ($result.stderr | str trim)" }
    }

    let description = (open $output_file | str trim)
    rm $output_file
    if ($description | is-empty) {
        error make { msg: "codex exec returned an empty changeset description" }
    }

    print $"[jj-describe] Updating ($revset)."
    ^jj desc -r $revset -m $description
    print $"[jj-describe] Finished ($revset)."
}
