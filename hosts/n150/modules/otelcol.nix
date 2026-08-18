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
    # Restart the collector when this config changes.
    restartTriggers = [ config.environment.etc."otelcol/config.yaml".source ];
    serviceConfig = {
      User = "otelcol";
      Group = "otelcol";
      SupplementaryGroups = [ "systemd-journal" ];
      ExecStart = "${pkgs.opentelemetry-collector-contrib}/bin/otelcol-contrib --config /etc/otelcol/config.yaml";
      Restart = "on-failure";
      RestartSec = "5s";
      # Leave headroom for collector overhead and file_storage's mmap/page cache.
      MemoryMax = "320M";
      StateDirectory = "otelcol";
      StateDirectoryMode = "0750";
    };
  };
}
