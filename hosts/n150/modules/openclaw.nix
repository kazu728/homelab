{ config, lib, pkgs, ... }:

let
  secretFile = ../secrets/openclaw/discord-token.age;
  hasDiscordSecret = builtins.pathExists secretFile;

  openclawBaseConfig = {
    agents.defaults.model.primary = "openai-codex/gpt-5.3-codex";

    gateway.mode = "local";

    plugins = {
      enabled = true;
      entries = {
        discord = {
          enabled = true;
        };
      };
    };

    tools = {
      profile = "minimal";
    };

    channels = {
      discord = {
        enabled = true;
        dmPolicy = "pairing";
        groupPolicy = "disabled";
        dm.groupEnabled = false;
      };
    };
  };
in
{
  nixpkgs.overlays = [
    (final: prev: {
      openclaw = final.callPackage ../pkgs/openclaw.nix { };
    })
  ];

  environment.systemPackages = [
    pkgs.openclaw
    pkgs.ragenix
  ];

  users.groups.openclaw = { };
  users.users.openclaw = {
    isSystemUser = true;
    group = "openclaw";
    home = "/var/lib/openclaw";
  };

  age.identityPaths = [
    "/etc/ssh/ssh_host_ed25519_key"
  ];

  age.secrets.openclaw-discord-token = lib.mkIf hasDiscordSecret {
    file = secretFile;
    owner = "openclaw";
    group = "openclaw";
    mode = "0400";
  };

  environment.etc."openclaw/openclaw.base.json".text = builtins.toJSON openclawBaseConfig;

  systemd.services.openclaw-gateway = lib.mkIf hasDiscordSecret {
    description = "OpenClaw Gateway";
    after = [ "network-online.target" "tailscaled.service" ];
    wants = [ "network-online.target" "tailscaled.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.bash pkgs.coreutils pkgs.jq pkgs.openclaw ];

    serviceConfig = {
      Type = "simple";
      User = "openclaw";
      Group = "openclaw";
      WorkingDirectory = "/var/lib/openclaw";
      StateDirectory = "openclaw";
      StateDirectoryMode = "0750";
      Environment = [
        "OPENCLAW_STATE_DIR=/var/lib/openclaw"
        "OPENCLAW_CONFIG_PATH=/var/lib/openclaw/openclaw.json"
      ];
      ExecStartPre = pkgs.writeShellScript "openclaw-render-config" ''
        set -euo pipefail

        token="$(${pkgs.coreutils}/bin/tr -d '\n' < ${config.age.secrets.openclaw-discord-token.path})"
        ${pkgs.jq}/bin/jq --arg token "$token" \
          '.channels.discord.token = $token' \
          /etc/openclaw/openclaw.base.json \
          > /var/lib/openclaw/openclaw.json

        ${pkgs.coreutils}/bin/chmod 600 /var/lib/openclaw/openclaw.json
      '';
      ExecStart = "${pkgs.openclaw}/bin/openclaw gateway --bind loopback --port 18789";
      Restart = "always";
      RestartSec = "5s";
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ReadWritePaths = [ "/var/lib/openclaw" ];
    };
  };

  networking.firewall.interfaces.tailscale0.allowedTCPPorts = lib.mkAfter [ 9443 ];

  systemd.services.tailscale-serve-grafana.serviceConfig.ExecStart = lib.mkAfter [
    "${pkgs.tailscale}/bin/tailscale serve --bg --yes --https 9443 http://127.0.0.1:18789"
  ];

  warnings = lib.optional (!hasDiscordSecret) ''
    OpenClaw service is disabled because secret file is missing:
      hosts/n150/secrets/openclaw/discord-token.age
    Create it with:
      ragenix -e hosts/n150/secrets/openclaw/discord-token.age
  '';
}
