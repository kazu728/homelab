{ config, ... }:

{
  sops.secrets."restic-password" = {
    key = "restic_password";
  };
  # Also carries RESTIC_REPOSITORY, which keeps the Cloudflare account ID out of
  # this public repository.
  sops.secrets."restic-r2-env" = {
    key = "restic_r2_env";
  };

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
  };

  # Persistent=true makes the daily timer fire at boot, which can land before
  # the Wi-Fi uplink is up.
  systemd.services.restic-backups-piano-capture = {
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
  };
}
