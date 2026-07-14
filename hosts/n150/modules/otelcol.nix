{ config, pkgs, ... }:

{
  users.groups.otelcol = {};
  users.users.otelcol = {
    isSystemUser = true;
    group = "otelcol";
  };

  environment.etc."otelcol/config.yaml".source = ../otelcol/config.yaml;

  systemd.services.otelcol = {
    description = "OpenTelemetry Collector (journald -> Loki)";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.systemd ];
    # Restart when the config changes so `nixos-rebuild switch` picks up edits;
    # otherwise the running collector keeps its old in-memory config.
    restartTriggers = [ config.environment.etc."otelcol/config.yaml".source ];
    serviceConfig = {
      User = "otelcol";
      Group = "otelcol";
      SupplementaryGroups = [ "systemd-journal" ];
      ExecStart = "${pkgs.opentelemetry-collector-contrib}/bin/otelcol-contrib --config /etc/otelcol/config.yaml";
      Restart = "on-failure";
      RestartSec = "5s";
      MemoryMax = "256M";
      StateDirectory = "otelcol";
      StateDirectoryMode = "0750";
    };
  };
}
