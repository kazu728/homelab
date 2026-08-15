{ config, pkgs, ... }:

let
  textfileDir = "/var/lib/node-exporter/textfile";
  metricsFile = "${textfileDir}/restic-piano-capture.prom";
in
{
  sops.secrets."restic-password" = {
    key = "restic_password";
  };
  # Also carries RESTIC_REPOSITORY, which keeps the Cloudflare account ID out of
  # this public repository.
  sops.secrets."restic-r2-env" = {
    key = "restic_r2_env";
  };

  systemd.tmpfiles.rules = [ "d ${textfileDir} 0755 root root -" ];

  services.restic.backups.piano-capture = {
    paths = [ "/var/lib/midilogd/capture" ];
    passwordFile = config.sops.secrets."restic-password".path;
    environmentFile = config.sops.secrets."restic-r2-env".path;
    initialize = true;
    # The capture log is append-only, so the newest snapshot already holds every
    # day; older snapshots only guard against an accidental deletion.
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

  # Persistent=true makes the daily timer fire at boot, which can land before
  # the Wi-Fi uplink is up.
  systemd.services.restic-backups-piano-capture = {
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
  };
}
