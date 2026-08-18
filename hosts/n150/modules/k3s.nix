{ config, lib, pkgs, ... }:

let
  # Keep the node IP outside k3s and LAN CIDRs to avoid DHCP-related API failures.
  nodeIp = "10.99.0.1";

  k3sBootstrapManifestDir = ../../../k8s/bootstrap;
  k3sBootstrapManifestNames =
    builtins.attrNames (
      lib.filterAttrs
        (name: type: type == "regular" && lib.hasSuffix ".yaml" name)
        (builtins.readDir k3sBootstrapManifestDir)
    );
  k3sBootstrapManifestArgs = lib.concatMapStringsSep " " lib.escapeShellArg k3sBootstrapManifestNames;
in
{
  boot.kernel.sysctl."net.ipv4.ip_forward" = 1;

  networking.firewall = {
    interfaces.tailscale0.allowedTCPPorts = [ 6443 ];
    trustedInterfaces = [ "cni0" "flannel.1" ];
  };

  # Single-node address on loopback; a second node needs another IP.
  networking.interfaces.lo.ipv4.addresses = [
    { address = nodeIp; prefixLength = 32; }
  ];

  # Make k3s require the loopback address unit; deviceDependency does not start it.
  systemd.services.network-addresses-lo = {
    before = [ "k3s.service" ];
    requiredBy = [ "k3s.service" ];
  };

  users.groups.k3s-admin = {};

  environment.systemPackages = with pkgs; [
    kubectl
    kubernetes-helm
    k9s
  ];
  environment.sessionVariables.KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";

  sops.secrets."alertmanager-slack-webhook-url" = {
    key = "alertmanager_slack_webhook_url";
    restartUnits = [ "homelab-kubernetes-secrets.service" ];
  };
  sops.secrets."grafana-admin-password" = {
    sopsFile = ../grafana-secrets.yaml;
    key = "grafana_admin_password";
    restartUnits = [ "homelab-kubernetes-secrets.service" ];
  };

  # NodePorts only serve local proxies, so keep them off LAN interfaces.
  services.k3s = {
    enable = true;
    role = "server";
    # Pin Kubernetes minor upgrades separately from the OS.
    package = pkgs.k3s_1_35;
    nodeIP = nodeIp;
    extraFlags = "--write-kubeconfig-mode=640 --write-kubeconfig-group=k3s-admin --disable traefik --disable servicelb --kubelet-arg=max-pods=50 --kube-proxy-arg=nodeport-addresses=127.0.0.0/8 --resolv-conf=/etc/resolv.conf";
  };

  # k3s watches this directory for bootstrap manifest changes.
  system.activationScripts.k3s-bootstrap-manifests.text = ''
    # Keep strict shell options local to this activation snippet.
    (
    set -euo pipefail

    src=${k3sBootstrapManifestDir}
    dst=/var/lib/rancher/k3s/server/manifests
    state="$dst/.homelab-bootstrap-manifests"
    next_state="$dst/.homelab-bootstrap-manifests.next"

    ${pkgs.coreutils}/bin/install -d -m 0755 "$dst"

    : > "$next_state"
    for name in ${k3sBootstrapManifestArgs}; do
      ${pkgs.coreutils}/bin/printf '%s\n' "$name" >> "$next_state"
      if ! ${pkgs.diffutils}/bin/cmp -s "$src/$name" "$dst/$name"; then
        tmp="$dst/.$name.tmp"
        ${pkgs.coreutils}/bin/install -m 0644 "$src/$name" "$tmp"
        ${pkgs.coreutils}/bin/mv -f -- "$tmp" "$dst/$name"
      fi
    done

    if [ -f "$state" ]; then
      while IFS= read -r name; do
        [ -n "$name" ] || continue
        if ! ${pkgs.gnugrep}/bin/grep -qxF -- "$name" "$next_state"; then
          ${pkgs.coreutils}/bin/rm -f -- "$dst/$name"
        fi
      done < "$state"
    fi

    ${pkgs.coreutils}/bin/mv -f -- "$next_state" "$state"
    )
  '';

  systemd.services.homelab-kubernetes-secrets = {
    description = "Sync homelab secrets into Kubernetes";
    after = [ "k3s.service" ];
    wants = [ "k3s.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [
      pkgs.coreutils
      pkgs.kubectl
    ];
    serviceConfig = {
      Type = "oneshot";
    };
    script = ''
      set -euo pipefail

      alertmanager_webhook_file=${lib.escapeShellArg config.sops.secrets."alertmanager-slack-webhook-url".path}
      grafana_admin_password_file=${lib.escapeShellArg config.sops.secrets."grafana-admin-password".path}

      for secret_file in "$alertmanager_webhook_file" "$grafana_admin_password_file"; do
        if [ -s "$secret_file" ]; then
          continue
        fi
        echo "Missing homelab secret file: $secret_file" >&2
        exit 1
      done

      export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

      for _ in $(seq 120); do
        if kubectl get --raw=/readyz >/dev/null 2>&1; then
          ready=1
          break
        fi
        sleep 1
      done
      if [ "''${ready:-0}" != 1 ]; then
        echo "Timed out waiting for k3s API readiness" >&2
        exit 1
      fi

      kubectl create namespace observability --dry-run=client -o yaml \
        | kubectl apply -f -
      kubectl -n observability create secret generic homelab-alertmanager-webhook \
        --from-file=url="$alertmanager_webhook_file" \
        --dry-run=client -o yaml \
        | kubectl apply -f -
      kubectl -n observability create secret generic grafana-admin \
        --from-literal=admin-user=admin \
        --from-file=admin-password="$grafana_admin_password_file" \
        --dry-run=client -o yaml \
        | kubectl apply -f -

      if kubectl -n observability wait --for=condition=Ready pod \
        -l app.kubernetes.io/name=grafana,app.kubernetes.io/instance=grafana \
        --timeout=10s >/dev/null 2>&1; then
        grafana_pod=$(kubectl -n observability get pod \
          -l app.kubernetes.io/name=grafana,app.kubernetes.io/instance=grafana \
          -o jsonpath='{.items[0].metadata.name}')
        # Grafana only seeds this password during DB initialization; reset it on each sync.
        # Pass it via stdin so it does not appear in process arguments.
        if ! reset_output=$(kubectl -n observability exec -i "$grafana_pod" -c grafana \
          -- grafana cli admin reset-admin-password --password-from-stdin \
          < "$grafana_admin_password_file" 2>&1); then
          printf '%s\n' "$reset_output" >&2
          exit 1
        fi
      else
        echo "Grafana pod is not ready; admin password reset will retry on the next timer run" >&2
      fi
    '';
  };

  systemd.timers.homelab-kubernetes-secrets = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "10min";
    };
  };
}
