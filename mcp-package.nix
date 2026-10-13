# The ci MCP server: the same `ci` launcher as the shell, as agent tools. It
# announces jobs on cross.stream through `xs` when one is given or on PATH;
# without it, watchers fall back to polling. The ruff check lints the source;
# writers.writePython3 would run flake8 instead.
{
  lib,
  runCommand,
  makeWrapper,
  python3,
  git,
  gh,
  ci,
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
      --set CI_MCP_CI ${lib.getExe ci}
  ''
