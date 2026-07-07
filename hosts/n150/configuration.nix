{ config, lib, pkgs, ... }:

let
  k3sBootstrapManifestDir = ../../k8s/bootstrap;
  k3sBootstrapManifestNames =
    builtins.attrNames (
      lib.filterAttrs
        (name: type: type == "regular" && lib.hasSuffix ".yaml" name)
        (builtins.readDir k3sBootstrapManifestDir)
    );
  k3sBootstrapManifestArgs = lib.concatMapStringsSep " " lib.escapeShellArg k3sBootstrapManifestNames;
in
{
  imports =
    [
      ./hardware-configuration.nix
      ./modules/network-recover.nix
    ];

  # Bootloader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  # Track the latest stable kernel to improve rtw89_8852be Wi-Fi stability.
  boot.kernelPackages = pkgs.linuxPackages_latest;
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
  };
  # ALSA sequencer for capturing USB-MIDI from the piano.
  boot.kernelModules = [ "snd-seq" ];

  networking.hostName = "nixos";

  networking.networkmanager.enable = true;
  # Disable Wi-Fi power saving to reduce link drops.
  networking.networkmanager.wifi.powersave = false;

  services.networkRecover.enable = true;

  time.timeZone = "Asia/Tokyo";
  i18n.defaultLocale = "en_US.UTF-8";

  # Firewall: only expose ports via tailscale; trust pod networks.
  networking.firewall = {
    # 22 SSH, 6443 k3s API, 443/8443 fronted by `tailscale serve` (Grafana / Argo CD).
    interfaces.tailscale0.allowedTCPPorts = [ 22 443 8443 6443 ];
    trustedInterfaces = [ "cni0" "flannel.1" ];
  };

  # Use compressed RAM swap to soften OOMs without disk swap.
  zramSwap = {
    enable = true;
    memoryPercent = 50;
    priority = 100;
  };

  services.logind.settings.Login = {
    HandleSuspendKey = "ignore";
    HandleHibernateKey = "ignore";
    HandleLidSwitch = "ignore";
    IdleAction = "ignore";
  };

  services.journald.extraConfig = ''
  Storage=persistent
  '';

  services.tailscale.enable = true;
  systemd.services.tailscale-serve-grafana = {
    description = "Tailscale HTTPS serve for Grafana and Argo CD";
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
  services.openssh = {
    enable = true;
    openFirewall = false;
    settings.PasswordAuthentication = false;
    settings.KbdInteractiveAuthentication = false;
  };

  users.users.kazuki = {
    isNormalUser = true;
    description = "Kazuki Matsuo";
    extraGroups = [ "k3s-admin" "networkmanager" "wheel" "audio" ];
  };
  users.groups.k3s-admin = {};
  users.groups.otelcol = {};
  users.users.otelcol = {
    isSystemUser = true;
    group = "otelcol";
  };

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  environment.systemPackages = with pkgs; [
    neovim
    kubectl
    kubernetes-helm
    k9s
    alsa-utils
  ];
  # Make kubectl point to k3s kubeconfig by default.
  environment.sessionVariables.KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";
  environment.etc."otelcol/config.yaml".source = ./otelcol/config.yaml;

  sops.defaultSopsFile = ./secrets.yaml;
  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
  sops.secrets."alertmanager-slack-webhook-url" = {
    key = "alertmanager_slack_webhook_url";
    owner = "root";
    group = "root";
    mode = "0400";
    restartUnits = [ "homelab-kubernetes-secrets.service" ];
  };
  sops.secrets."grafana-admin-password" = {
    sopsFile = ./grafana-secrets.yaml;
    key = "grafana_admin_password";
    owner = "root";
    group = "root";
    mode = "0400";
    restartUnits = [ "homelab-kubernetes-secrets.service" ];
  };

  # Lightweight single-node k3s
  services.k3s = {
    enable = true;
    role = "server";
    clusterInit = true;
    extraFlags = "--write-kubeconfig-mode=640 --write-kubeconfig-group=k3s-admin --disable traefik --disable servicelb --kubelet-arg=max-pods=50 --resolv-conf=/etc/resolv.conf";
  };

  # Keep real files in k3s' watched manifests directory so bootstrap chart
  # changes are observed during `nixos-rebuild switch`.
  system.activationScripts.k3s-bootstrap-manifests.text = ''
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
        grafana_password=$(cat "$grafana_admin_password_file")
        kubectl -n observability exec "$grafana_pod" -c grafana \
          -- grafana cli admin reset-admin-password "$grafana_password" >/dev/null 2>&1 \
          || kubectl -n observability exec "$grafana_pod" -c grafana \
            -- grafana-cli admin reset-admin-password "$grafana_password" >/dev/null
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

  systemd.services.otelcol = {
    description = "OpenTelemetry Collector (journald -> Loki)";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.systemd ];
    serviceConfig = {
      User = "otelcol";
      Group = "otelcol";
      SupplementaryGroups = [ "systemd-journal" ];
      ExecStart = "${pkgs.opentelemetry-collector-contrib}/bin/otelcol-contrib --config /etc/otelcol/config.yaml";
      Restart = "on-failure";
      RestartSec = "5s";
      StateDirectory = "otelcol";
      StateDirectoryMode = "0750";
    };
  };

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "25.11"; # Did you read the comment?

}
