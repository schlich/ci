# Shared by the shell, Starship, and the agent SessionStart hooks, so each
# refers to the same derivation.
{ pkgs }:
let
  script = pkgs.writeNuScriptBin "context-status" (builtins.readFile ./context-status.nu);
  lifecycle = pkgs.callPackage ./lifecycle/package.nix { };
in
pkgs.symlinkJoin {
  name = "context-status";
  paths = [ script ];
  nativeBuildInputs = [ pkgs.makeWrapper ];
  # The stage and next step come from the lifecycle state machine.
  postBuild = ''
    wrapProgram "$out/bin/context-status" --prefix PATH : ${lifecycle}/bin
  '';
}
