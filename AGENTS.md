# Repository workflows

- This is a colocated Jujutsu repository. Use `jj` for every change and
  description; Git is only JJ's backend.
- The user's shell is Nushell; give user-facing commands in Nushell syntax,
  and use Nushell for scripts and data processing.
- `ci.nu` implements the protocol modelled in `JjCi.tla` and `lifecycle/`.
  Change the model, the machine, and the workflow together; `ci-model`,
  `ci-lifecycle`, and `ci-properties` check them against each other.
- The tower (`tower/`), `context-status.nu`, and the MCP server read the
  records `ci.nu` writes (`.jj/jj-ci-*.json`, the ci MCP job store, OSC 7501
  status files, and the locks under `$XDG_STATE_HOME/jj-ci`). Change a
  record's shape in every reader at once.
- Other repositories run the `ci.nu` their flake.lock pins. Keep
  `ci-launch.nu`'s choice rules in step with `tests/ci-launch-properties.nu`,
  and test a workflow change from another repository with
  `CI_SCRIPT=/path/to/ci.nu ci ...`.
- The tower only reads, except for jobs a user starts from ACTION mode. Keep
  JJ reads on `--ignore-working-copy`, and keep every key it binds in the
  hint bar of the mode where it works, with Esc returning to NORMAL.
- Check changes with `nix flake check path:.`; `cargo test` in `lifecycle/`
  and `tower/`, and `nu --no-config-file -c "source <suite>.nu"` in `tests/`
  (with the dev shell's NU_LIB_DIRS), run the parts quickly.
