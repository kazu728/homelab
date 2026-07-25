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
      # memory_limiter caps the heap at 200MiB and upstream notes the process
      # total sits ~50MiB above that, so ~250MiB is the expected peak — and
      # cgroup v2 also charges page cache, which here includes the bbolt mmap
      # behind file_storage. Keep the cap clear of that instead of level with
      # it; back-pressure is memory_limiter's job, this is only the backstop.
      MemoryMax = "320M";
      StateDirectory = "otelcol";
      StateDirectoryMode = "0750";
    };
  };
}
