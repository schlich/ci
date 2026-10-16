# `ci`: the launcher in ci-launch.nu, which runs the ci.nu bundled here, or a
# newer one inside the ci repository itself, plus `ci-tower` for `ci tower`.
# Shared by Home Manager, the dev shell, and the ci MCP server. Whichever
# ci.nu the launcher runs inherits NU_LIB_DIRS, where it finds `pst`.
{ pkgs, osc7501-nu }:
pkgs.symlinkJoin {
  name = "ci";
  paths = [
    (pkgs.writeNuScriptBin "ci" (builtins.readFile ./ci-launch.nu))
    (pkgs.callPackage ./tower/package.nix { })
    (pkgs.callPackage ./agent/package.nix { inherit pkgs; })
  ];
  nativeBuildInputs = [ pkgs.makeWrapper ];
  meta.mainProgram = "ci";
  postBuild = ''
    # The launcher runs jj before any ci.nu. Append it so CI runners without
    # jj have one, while a user's own jj still comes first. `ci tower` finds
    # the ci-tower bundled beside it.
    wrapProgram "$out/bin/ci" --prefix PATH : $out/bin:${pkgs.git}/bin:${pkgs.gh}/bin \
      --suffix PATH : ${pkgs.jujutsu}/bin \
      --prefix NU_LIB_DIRS : ${osc7501-nu} \
      --set CI_BUNDLED_SCRIPT ${./ci.nu}
    # Deprecated alias for the former `jj-ci` name.
    ln -s ci "$out/bin/jj-ci"
  '';
}
