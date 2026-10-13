# Jump between JJ workspaces of the current repository.

def jj-workspace-names [] {
    ^jj workspace list --ignore-working-copy -T 'name ++ "\n"' | lines
}

# Change to the root of the named JJ workspace.
def --env jw [name: string@jj-workspace-names] {
    cd (^jj workspace root --ignore-working-copy --name $name)
}
