# `ci tower`, the live terminal view of every topic, run, and release. It
# classifies topics with the lifecycle crate beside it, so its source holds
# both; building the package runs its tests.
{
  lib,
  rustPlatform,
  makeWrapper,
  jujutsu,
}:
rustPlatform.buildRustPackage {
  pname = "ci-tower";
  version = "0.1.0";
  src = lib.fileset.toSource {
    root = ./..;
    fileset = lib.fileset.unions [
      ./Cargo.toml
      ./Cargo.lock
      ./src
      ../lifecycle/Cargo.toml
      ../lifecycle/src
    ];
  };
  cargoRoot = "tower";
  buildAndTestSubdir = "tower";
  cargoLock.lockFile = ./Cargo.lock;
  nativeBuildInputs = [ makeWrapper ];
  # The tower reads the graph with jj; a user's own jj still comes first.
  postInstall = ''
    wrapProgram "$out/bin/ci-tower" --suffix PATH : ${jujutsu}/bin
  '';
  meta = {
    description = "A live terminal control tower for the ci topic workflow";
    mainProgram = "ci-tower";
    platforms = [ "x86_64-linux" ];
  };
}
