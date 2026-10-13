# The `ci` topic lifecycle as a statig state machine. Its tests check the
# machine against JjCi.tla, so building the package is the conformance check.
{ lib, rustPlatform }:
rustPlatform.buildRustPackage {
  pname = "jj-ci-lifecycle";
  version = "0.1.0";
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./Cargo.toml
      ./Cargo.lock
      ./src
      ./tests
    ];
  };
  cargoLock.lockFile = ./Cargo.lock;
  meta = {
    description = "The jj ci topic lifecycle from JjCi.tla as an executable state machine";
    mainProgram = "jj-ci-lifecycle";
    platforms = [ "x86_64-linux" ];
  };
}
