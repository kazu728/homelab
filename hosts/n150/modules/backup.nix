{ config, pkgs, ... }:

let
  textfileDir = "/var/lib/node-exporter/textfile";
  metricsFile = "${textfileDir}/restic-piano-capture.prom";
in
{
  sops.secrets."restic-password" = {
    key = "restic_password";
  };
  sops.secrets."restic-r2-env" = {
    key = "restic_r2_env";
  };

  systemd.tmpfiles.rules = [ "d ${textfileDir} 0755 root root -" ];

  services.restic.backups.piano-capture = {
    paths = [ "/var/lib/midilogd/capture" ];
    passwordFile = config.sops.secrets."restic-password".path;
    environmentFile = config.sops.secrets."restic-r2-env".path;
    initialize = true;
    # Append-only logs make the newest snapshot complete; older ones cover deletion.
    pruneOpts = [
      "--keep-daily 7"
      "--keep-weekly 4"
      "--keep-monthly 12"
    ];
    runCheck = true;

    backupCleanupCommand = ''
      #!${pkgs.runtimeShell}
      set -euo pipefail

      [ "$SERVICE_RESULT" = success ] || exit 0

      size=$(${pkgs.restic}/bin/restic stats --mode raw-data --json \
        | ${pkgs.jq}/bin/jq --exit-status .total_size) || exit 0

      staged=${metricsFile}.new
      touch "$staged"
      chmod 0644 "$staged"
      cat > "$staged" <<EOF
      # HELP restic_repository_size_bytes Deduplicated size of the restic repository.
      # TYPE restic_repository_size_bytes gauge
      restic_repository_size_bytes{backup="piano-capture"} $size
      EOF
      mv "$staged" ${metricsFile}
    '';
  };

  # Persistent timers may run before Wi-Fi; order the backup after network-online.
  systemd.services.restic-backups-piano-capture = {
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
  };
}
