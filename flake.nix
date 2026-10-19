{
  description = "ci: carry Jujutsu topics to trunk through preflight, dispatch, clearance, and landing";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # The `pst` Nushell module (OSC 7501 program status) that ci.nu reports
    # its phases with; every runner of ci.nu puts it on NU_LIB_DIRS.
    osc7501-nu = {
      url = "github:schlich/osc7501.nu";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      osc7501-nu,
    }:
    let
      system = "x86_64-linux";
      # nushellWith's writeNuScriptBin, which the package files also find in
      # a consumer's pkgs that already carries that overlay.
      pkgs = import nixpkgs {
        inherit system;
        overlays = [
          (final: _: {
            writeNuScriptBin =
              name: text:
              final.writeScriptBin name ''
                #!${final.lib.getExe final.nushell}

                ${text}
              '';
          })
        ];
      };
      lib = nixpkgs.lib;
      ci = import ./ci-package.nix { inherit pkgs osc7501-nu; };
      lifecycle = pkgs.callPackage ./lifecycle/package.nix { };
      tower = pkgs.callPackage ./tower/package.nix { };
      agent = pkgs.callPackage ./agent/package.nix { inherit pkgs; };
      source =
        files:
        lib.fileset.toSource {
          root = ./.;
          fileset = lib.fileset.unions files;
        };
    in
    {
      packages.${system} = {
        default = ci;
        inherit ci;
        ci-tower = tower;
        ci-agent = agent;
        jj-ci-lifecycle = lifecycle;
        context-status = import ./context-status.nix { inherit pkgs; };
        ci-mcp = pkgs.callPackage ./mcp-package.nix { inherit ci; };
        jj-describe = pkgs.writeNuScriptBin "jj-describe" (builtins.readFile ./describe.nu);
        codex-jj-session = pkgs.writeNuScriptBin "codex-jj-session" (builtins.readFile ./codex-session.nu);
      };

      # services.ci-prune: the daily `ci prune --apply` backstop.
      homeModules.default = import ./prune-timer.nix { inherit ci; };

      apps.${system}.default = {
        type = "app";
        program = "${ci}/bin/ci";
      };

      lib = {
        # Shell integration that consumers source rather than install: the
        # completions, the `jj new` guard, and `jw`.
        nushell = {
          completions = ./completions.nu;
          guard = ./guard.nu;
          workspace = ./workspace.nu;
        };
        # The agent skill describing when to use each command.
        skills.ci = ./.agents/skills/ci;
      };

      checks.${system} = {
        ci = pkgs.runCommand "ci-package-check" { } ''
          test -x ${ci}/bin/ci
          test -x ${ci}/bin/ci-tower
          test -x ${ci}/bin/ci-agent
          touch "$out"
        '';
        # TLC explores every state of the bounded model and checks its
        # invariants.
        ci-model = pkgs.runCommand "ci-model-check" { nativeBuildInputs = [ pkgs.tlaplus ]; } ''
          cp ${./JjCi.tla} JjCi.tla
          cp ${./JjCi.cfg} JjCi.cfg
          tlc -metadir "$TMPDIR/tlc" -config JjCi.cfg JjCi.tla
          touch "$out"
        '';
        # Its tests check the state machine against every action and
        # invariant of the same bounded model.
        ci-lifecycle = lifecycle;
        ci-agent = pkgs.runCommand "ci-agent-check" { } ''
          cp ${./agent/machine.test.mjs} machine.test.mjs
          cp ${./agent/machine.mjs} machine.mjs
          ln -s ${agent}/lib/ci-agent/node_modules node_modules
          ${pkgs.nodejs}/bin/node --test machine.test.mjs
          touch "$out"
        '';
        # Its unit tests run as the package builds.
        ci-tower = tower;
        ci-properties =
          let
            src = source [
              ./ci.nu
              ./ci-launch.nu
              ./codex-session.nu
              ./context-status.nu
              ./guard.nu
              ./tests
            ];
          in
          pkgs.runCommand "ci-properties-check"
            {
              # util-linux provides the flock(1) that the local checks lock uses;
              # the closure proof's test runs in a JJ repository it exports
              # with git.
              nativeBuildInputs = [
                pkgs.git
                pkgs.jujutsu
                pkgs.nushell
                pkgs.util-linux
              ];
            }
            ''
              export HOME="$TMPDIR/home"
              export NU_LIB_DIRS=${osc7501-nu}
              mkdir -p "$HOME"
              cd ${src}/tests
              for suite in ci-properties ci-launch-properties codex-session-properties context-status-properties; do
                nu --no-config-file -c "source $suite.nu"
              done
              touch "$out"
            '';
        ruff = pkgs.runCommand "ruff-check" { nativeBuildInputs = [ pkgs.ruff ]; } ''
          ruff check --no-cache ${./mcp.py}
          ruff format --no-cache --check ${./mcp.py}
          touch "$out"
        '';
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          cargo
          clippy
          ci
          gh
          git
          jujutsu
          nushell
          ruff
          rust-analyzer
          rustc
          rustfmt
          tlaplus
          util-linux
        ];
        # This jj honours the JJ_CONFIG the test suites set, which a user's
        # jj wrapped with its own JJ_CONFIG would override. Hand it the user's
        # configuration instead, read from their jj, so `ci land`'s preflight
        # runs their fix.tools (2026-10-16).
        shellHook = ''
          export NU_LIB_DIRS=${osc7501-nu}
          if [ -z "''${JJ_CONFIG-}" ]; then
            for candidate in $(type -ap jj); do
              if [ "$candidate" != ${pkgs.jujutsu}/bin/jj ]; then
                if config="$("$candidate" config path --user 2>/dev/null)"; then
                  export JJ_CONFIG="$config"
                fi
                break
              fi
            done
          fi
        '';
      };

      formatter.${system} = pkgs.nixfmt-tree;
    };
}
