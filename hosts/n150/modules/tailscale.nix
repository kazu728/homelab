{ config, pkgs, ... }:

{
  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 443 8443 ];

  services.tailscale = {
    enable = true;
    # Use a preauthorized, non-ephemeral OAuth key for unattended rebuilds.
    authKeyFile = config.sops.secrets."tailscale-authkey".path;
    extraUpFlags = [ "--advertise-tags=tag:homelab" ];
  };
  sops.secrets."tailscale-authkey".key = "tailscale_authkey";
  systemd.services.tailscale-serve-homelab = {
    description = "Tailscale HTTPS serve for homelab services";
    after = [ "network-online.target" "tailscaled.service" ];
    wants = [ "network-online.target" "tailscaled.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = "30s";
      # Wait for tailscaled to have an address before configuring serve.
      ExecStartPre = "${pkgs.bash}/bin/bash -c 'for i in $(${pkgs.coreutils}/bin/seq 60); do ${pkgs.tailscale}/bin/tailscale ip -4 >/dev/null 2>&1 && exit 0; ${pkgs.coreutils}/bin/sleep 1; done; exit 1'";
      ExecStart = [
        "${pkgs.tailscale}/bin/tailscale serve --bg --yes --https 443 http://127.0.0.1:30300"
        "${pkgs.tailscale}/bin/tailscale serve --bg --yes --https 8443 https+insecure://127.0.0.1:32443"
      ];
      ExecStop = "${pkgs.tailscale}/bin/tailscale serve reset";
    };
  };
}
