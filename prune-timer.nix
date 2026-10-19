# A Home Manager module for the daily backstop docs/workflow.md describes: topics
# landed without `ci park` and tasks that ended without it leave workspaces
# and branches behind, and `ci prune --apply` reclaims them. The timer once
# lived in one consumer's configuration and was lost when ci moved to its own
# repository, after which landed branches piled up again (2026-10-19).
{ ci }:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.ci-prune;
  # One failing checkout must not keep the others from being pruned.
  prune = pkgs.writeShellScript "ci-prune" ''
    status=0
    for repository in ${lib.escapeShellArgs cfg.repositories}; do
      echo "ci-prune: $repository"
      (cd "$repository" && ${lib.getExe cfg.package} prune --apply --idle ${lib.escapeShellArg cfg.idle}) || status=1
    done
    exit "$status"
  '';
in
{
  options.services.ci-prune = {
    enable = lib.mkEnableOption "a daily `ci prune --apply` in each listed checkout";
    package = lib.mkOption {
      type = lib.types.package;
      default = ci;
      defaultText = lib.literalExpression "ci.packages.\${system}.ci";
      description = "The ci package to run.";
    };
    jujutsu = lib.mkOption {
      type = lib.types.package;
      default = pkgs.jujutsu;
      defaultText = lib.literalExpression "pkgs.jujutsu";
      description = "The jj that ci runs, with the user's configuration if it is wrapped with one.";
    };
    repositories = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "/home/me/dotfiles" ];
      description = "Default checkouts of the repositories to prune.";
    };
    idle = lib.mkOption {
      type = lib.types.str;
      default = "1day";
      description = "Keep every workspace used more recently than this Nushell duration, without running JJ in it.";
    };
    sshAuthSock = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "%t/gcr/ssh";
      description = "SSH agent socket for fetching the trunk remote, in systemd specifier syntax.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.user.services.ci-prune = {
      Unit.Description = "Remove landed ci workspaces and topic branches";
      Service = {
        Type = "oneshot";
        ExecStart = "${prune}";
        Environment = [
          "PATH=${
            lib.makeBinPath [
              cfg.jujutsu
              pkgs.openssh
              pkgs.util-linux
              pkgs.coreutils
            ]
          }"
        ]
        ++ lib.optional (cfg.sshAuthSock != null) "SSH_AUTH_SOCK=${cfg.sshAuthSock}";
      };
    };
    systemd.user.timers.ci-prune = {
      Unit.Description = "Prune landed ci workspaces and topic branches daily";
      Timer = {
        OnCalendar = "daily";
        Persistent = true;
        RandomizedDelaySec = "1h";
      };
      Install.WantedBy = [ "timers.target" ];
    };
  };
}
