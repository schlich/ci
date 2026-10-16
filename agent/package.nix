{ pkgs }:
let
  lock = builtins.fromJSON (builtins.readFile ./package-lock.json);
  dependencies = builtins.removeAttrs lock.packages [ "" ];
  unpack =
    path:
    let
      dependency = dependencies.${path};
      archive = pkgs.fetchurl {
        url = dependency.resolved;
        hash = dependency.integrity;
      };
    in
    ''
      mkdir -p "$out/lib/ci-agent/${path}"
      tar -xf ${archive} --strip-components=1 -C "$out/lib/ci-agent/${path}"
    '';
in
pkgs.runCommand "ci-agent-0.1.0" { nativeBuildInputs = [ pkgs.makeWrapper ]; } ''
  mkdir -p "$out/lib/ci-agent" "$out/bin"
  cp ${./machine.mjs} "$out/lib/ci-agent/machine.mjs"
  cp ${./cli.mjs} "$out/lib/ci-agent/cli.mjs"
  ${builtins.concatStringsSep "\n" (map unpack (builtins.attrNames dependencies))}
  makeWrapper ${pkgs.nodejs}/bin/node "$out/bin/ci-agent" \
    --add-flags "$out/lib/ci-agent/cli.mjs"
''
