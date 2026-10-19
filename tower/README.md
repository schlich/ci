# ci tower

The live terminal view behind `ci tower`; see
["Control tower"](../docs/workflow.md#control-tower) for what it shows and
its keys.

It links `../lifecycle` by path, so the board's stages always come from the
same machine as `context-status`. Develop it from the repository's dev shell:

```nu
cargo test
cargo clippy --all-targets
cargo run -- ~/dotfiles --snapshot 120x36 --view runs   # one frame, no terminal
```
