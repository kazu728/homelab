{ pkgs, midilab, ... }:

{
  imports = [ "${midilab}/nix/module.nix" ];

  # ALSA sequencer for capturing USB-MIDI from the piano.
  boot.kernelModules = [ "snd-seq" ];
  environment.systemPackages = [ pkgs.alsa-utils ];

  users.groups.midi-exporter = { };
  users.users.midi-exporter = {
    isSystemUser = true;
    group = "midi-exporter";
  };

  systemd.services.midi-exporter = {
    description = "Export OTLP metrics derived from the midilogd capture log";
    after = [ "midilogd.service" "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      User = "midi-exporter";
      Group = "midi-exporter";
      SupplementaryGroups = [ "midilogd" ];
      Environment = [ "OTEL_EXPORTER_OTLP_ENDPOINT=http://10.43.0.100:4318" ];
      ExecStart = "${pkgs.midi-exporter}/bin/midi-exporter --capture-dir /var/lib/midilogd/capture";
      Restart = "on-failure";
      RestartSec = "5s";
      MemoryMax = "128M";
    };
  };
}
