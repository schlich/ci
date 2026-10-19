# The ci MCP server: the same `ci` launcher as the shell, as agent tools. It
# announces jobs on cross.stream through `xs` when one is given or on PATH;
# without it, watchers fall back to polling. Jobs run in transient systemd
# user units, which resolve their command on the host, so the job shell is a
# store path rather than a sandbox's `sh`. `state_diagram` asks context-status
# for the workspace's machine state and the lifecycle for the drawing. The ruff check lints the source;
# writers.writePython3 would run flake8 instead.
{
  lib,
  runCommand,
  runtimeShell,
  makeWrapper,
  python3,
  git,
  gh,
  ci,
  lifecycle,
  context-status,
  xs ? null,
}:
runCommand "ci-mcp"
  {
    nativeBuildInputs = [ makeWrapper ];
    meta.mainProgram = "ci-mcp";
  }
  ''
    makeWrapper ${python3.withPackages (ps: [ ps.mcp ])}/bin/python "$out/bin/ci-mcp" \
      --add-flags ${./mcp.py} \
      --prefix PATH : ${
        lib.makeBinPath (
          [
            git
            gh
          ]
          ++ lib.optional (xs != null) xs
        )
      } \
      --set CI_MCP_CI ${lib.getExe ci} \
      --set CI_MCP_LIFECYCLE ${lib.getExe lifecycle} \
      --set CI_MCP_CONTEXT_STATUS ${context-status}/bin/context-status \
      --set CI_MCP_SH ${runtimeShell}
  ''
