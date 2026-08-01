{ config, lib, pkgs, ... }:

let
  cfg = config.services.networkRecover;
in
{
  options.services.networkRecover = {
    enable = lib.mkEnableOption "auto recover Wi-Fi/NM when default route is missing";
  };

  config = lib.mkIf cfg.enable {
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

        nmcli_rc=0
        dev_status="$(${pkgs.networkmanager}/bin/nmcli -t -f DEVICE,TYPE dev status 2>/dev/null)" || nmcli_rc=$?
        if [ "$nmcli_rc" -ne 0 ]; then
          echo "nmcli dev status failed (rc=$nmcli_rc)"
          exit 0
        fi

        wifi_dev="$(printf '%s\n' "$dev_status" \
          | ${pkgs.gnugrep}/bin/grep ':wifi$' \
          | ${pkgs.coreutils}/bin/head -n1 \
          | ${pkgs.coreutils}/bin/cut -d: -f1 || true)"
        if [ -z "$wifi_dev" ]; then
          echo "NetworkManager lists no wifi device"
          exit 0
        fi

        route_rc=0
        route="$(${pkgs.iproute2}/bin/ip route get 1.1.1.1 2>/dev/null \
          | ${pkgs.coreutils}/bin/head -n1)" || route_rc=$?
        if [ -n "$route" ]; then
          echo "route lookup answered: $route"
          exit 0
        fi

        echo "route lookup returned nothing (rc=$route_rc); reconnecting $wifi_dev"
        disconnect_rc=0
        ${pkgs.networkmanager}/bin/nmcli dev disconnect "$wifi_dev" || disconnect_rc=$?
        ${pkgs.coreutils}/bin/sleep 2
        connect_rc=0
        ${pkgs.networkmanager}/bin/nmcli dev connect "$wifi_dev" || connect_rc=$?
        ${pkgs.coreutils}/bin/sleep 5

        route="$(${pkgs.iproute2}/bin/ip route get 1.1.1.1 2>/dev/null \
          | ${pkgs.coreutils}/bin/head -n1 || true)"
        if [ -n "$route" ]; then
          echo "after reconnect (disconnect rc=$disconnect_rc, connect rc=$connect_rc) route lookup answered: $route"
          exit 0
        fi

        # Wi-Fi may not be reconnected when the restart command returns.
        echo "after reconnect (disconnect rc=$disconnect_rc, connect rc=$connect_rc) route lookup returned nothing; restarting NetworkManager"
        restart_rc=0
        ${pkgs.systemd}/bin/systemctl restart NetworkManager.service || restart_rc=$?
        echo "NetworkManager restart returned rc=$restart_rc"
        exit "$restart_rc"
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
