{ config, lib, pkgs, ... }:

let
  cfg = config.services.networkRecover;
in
{
  options.services.networkRecover = {
    enable = lib.mkEnableOption "auto recover Wi-Fi/NM when default route is missing";
  };

  config = lib.mkIf cfg.enable {
    # Auto-recover Wi-Fi by reconnecting first, then restart NetworkManager if needed.
    systemd.services.network-recover = {
      description = "Recover Wi-Fi/NM when default route is missing";
      after = [ "NetworkManager.service" ];
      wants = [ "NetworkManager.service" ];
      serviceConfig = {
        Type = "oneshot";
      };
      path = [
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.iproute2
        pkgs.networkmanager
        pkgs.systemd
      ];
      script = ''
        set -euo pipefail

        wifi_dev="$(${pkgs.networkmanager}/bin/nmcli -t -f DEVICE,TYPE dev status \
          | ${pkgs.gnugrep}/bin/grep ':wifi$' \
          | ${pkgs.coreutils}/bin/head -n1 \
          | ${pkgs.coreutils}/bin/cut -d: -f1 || true)"
        if [ -z "$wifi_dev" ]; then
          exit 0
        fi

        # If there is a valid default route, nothing to do.
        if ${pkgs.iproute2}/bin/ip route get 1.1.1.1 >/dev/null 2>&1; then
          exit 0
        fi

        # First try a Wi-Fi reconnect (minimal impact).
        ${pkgs.networkmanager}/bin/nmcli dev disconnect "$wifi_dev" || true
        ${pkgs.coreutils}/bin/sleep 2
        ${pkgs.networkmanager}/bin/nmcli dev connect "$wifi_dev" || true
        ${pkgs.coreutils}/bin/sleep 5

        # If still no route, restart NetworkManager as a fallback.
        if ! ${pkgs.iproute2}/bin/ip route get 1.1.1.1 >/dev/null 2>&1; then
          ${pkgs.systemd}/bin/systemctl restart NetworkManager.service
        fi
      '';
    };

    systemd.timers.network-recover = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2m";
        OnUnitActiveSec = "2m";
      };
    };
  };
}
