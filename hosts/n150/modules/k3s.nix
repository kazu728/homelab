{ config, lib, pkgs, ... }:

let
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
  # IPv4 forwarding for flannel pod networking.
  boot.kernel.sysctl."net.ipv4.ip_forward" = 1;

  # Expose the k3s API and trust the pod networks over the firewall.
  networking.firewall = {
    interfaces.tailscale0.allowedTCPPorts = [ 6443 ];
    trustedInterfaces = [ "cni0" "flannel.1" ];
  };

  users.groups.k3s-admin = {};

  environment.systemPackages = with pkgs; [
    kubectl
    kubernetes-helm
    k9s
  ];
  # Make kubectl point to k3s kubeconfig by default.
  environment.sessionVariables.KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";

  sops.secrets."alertmanager-slack-webhook-url" = {
    key = "alertmanager_slack_webhook_url";
    owner = "root";
    group = "root";
    mode = "0400";
    restartUnits = [ "homelab-kubernetes-secrets.service" ];
  };
  sops.secrets."grafana-admin-password" = {
    sopsFile = ../grafana-secrets.yaml;
    key = "grafana_admin_password";
    owner = "root";
    group = "root";
    mode = "0400";
    restartUnits = [ "homelab-kubernetes-secrets.service" ];
  };

  # Lightweight single-node k3s. Bind NodePort to loopback only (nodeport-addresses):
  # all consumers reach it via localhost, dropping its LAN exposure through FORWARD.
  services.k3s = {
    enable = true;
    role = "server";
    # Pin the minor explicitly: the unversioned `k3s` alias would follow a
    # flake.lock bump, and this nixpkgs already carries k3s_1_36. Keeping the
    # OS and Kubernetes upgrades as separate events.
    package = pkgs.k3s_1_35;
    extraFlags = "--write-kubeconfig-mode=640 --write-kubeconfig-group=k3s-admin --disable traefik --disable servicelb --kubelet-arg=max-pods=50 --kube-proxy-arg=nodeport-addresses=127.0.0.0/8 --resolv-conf=/etc/resolv.conf";
  };

  # Keep real files in k3s' watched manifests directory so bootstrap chart
  # changes are observed during `nixos-rebuild switch`.
  system.activationScripts.k3s-bootstrap-manifests.text = ''
    # Run in a subshell so `set -euo pipefail` stays local to this snippet.
    # NixOS concatenates every activation snippet into one shell (bashOptions =
    # []; failures are recorded via trap ERR and execution continues); leaking
    # these options would abort later snippets (sops-nix setup, the final
    # /run/current-system swap) on the first non-zero exit meant to be logged.
    (
    set -euo pipefail

    src=${k3sBootstrapManifestDir}
    dst=/var/lib/rancher/k3s/server/manifests
    state="$dst/.homelab-bootstrap-manifests"
    next_state="$dst/.homelab-bootstrap-manifests.next"

    ${pkgs.coreutils}/bin/install -d -m 0755 "$dst"

    for link in "$dst"/*.yaml; do
      [ -L "$link" ] || continue
      target=$(${pkgs.coreutils}/bin/readlink "$link")
      case "$target" in
        /etc/nixos/k8s/bootstrap/*)
          ${pkgs.coreutils}/bin/rm -f -- "$link"
          ;;
      esac
    done

    : > "$next_state"
    for name in ${k3sBootstrapManifestArgs}; do
      ${pkgs.coreutils}/bin/printf '%s\n' "$name" >> "$next_state"
      if [ -L "$dst/$name" ] || ! ${pkgs.diffutils}/bin/cmp -s "$src/$name" "$dst/$name"; then
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
        # Feed the password over stdin: as argv it would sit in the cmdline of
        # both the host kubectl and the in-pod grafana process, world-readable
        # via /proc every time the timer fires.
        kubectl -n observability exec -i "$grafana_pod" -c grafana \
          -- grafana cli admin reset-admin-password --password-from-stdin \
          < "$grafana_admin_password_file" >/dev/null
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
      Unit = "homelab-kubernetes-secrets.service";
    };
  };
}
