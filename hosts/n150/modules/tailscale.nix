{ pkgs, ... }:

{
  # 443/8443 fronted by `tailscale serve` (Grafana / Argo CD). The loopback
  # NodePorts must match k8s/argocd/observability/grafana.yaml (30300) and
  # k8s/bootstrap/argocd-helmchart.yaml (32443).
  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 443 8443 ];

  services.tailscale.enable = true;
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
      # `tailscale serve` exits with "unexpected state: NoState" if it runs
      # before tailscaled has brought the backend up (e.g. when tailscaled is
      # restarted mid nixos-rebuild). Wait until the node has an address.
      ExecStartPre = "${pkgs.bash}/bin/bash -c 'for i in $(${pkgs.coreutils}/bin/seq 60); do ${pkgs.tailscale}/bin/tailscale ip -4 >/dev/null 2>&1 && exit 0; ${pkgs.coreutils}/bin/sleep 1; done; exit 1'";
      ExecStart = [
        "${pkgs.tailscale}/bin/tailscale serve --bg --yes --https 443 http://127.0.0.1:30300"
        "${pkgs.tailscale}/bin/tailscale serve --bg --yes --https 8443 https+insecure://127.0.0.1:32443"
      ];
      ExecStop = "${pkgs.tailscale}/bin/tailscale serve reset";
    };
  };
}
