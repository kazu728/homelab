# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ pkgs, ... }:

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

  networking.hostName = "nixos";
  # networking.wireless.enable = true;  # Enables wireless support via wpa_supplicant.

  networking.networkmanager.enable = true;
  # Disable Wi-Fi power saving to reduce link drops.
  networking.networkmanager.wifi.powersave = false;

  # Disabled by default; enable when you're ready to apply.
  services.networkRecover.enable = true;

  hardware.graphics.enable = false;

  time.timeZone = "Asia/Tokyo";
  i18n.defaultLocale = "en_US.UTF-8";

  # Firewall: expose k3s API only via tailscale; trust pod networks.
  networking.firewall = {
    enable = true;
    interfaces.tailscale0.allowedTCPPorts = [ 22 443 8443 6443 32443 30300 31000 11434 ];
    trustedInterfaces = [ "cni0" "flannel.1" ];
  };

  # Use compressed RAM swap to soften OOMs without disk swap.
  zramSwap = {
    enable = true;
    memoryPercent = 50;
    priority = 100;
  };

  services.logind.extraConfig = ''
  HandleSuspendKey=ignore
  HandleHibernateKey=ignore
  HandleLidSwitch=ignore
  IdleAction=ignore
  '';

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
    settings.PubkeyAuthentication = true;
  };

  # Local LLM on host via Ollama (reachable only through tailscale firewall rules).
  services.ollama = {
    enable = true;
    acceleration = false; # CPU-first for lower power usage.
    host = "0.0.0.0";
    port = 11434;
    openFirewall = false; # Keep control at interface-specific firewall rules.
    loadModels = [ "qwen2.5:14b" ];
    environmentVariables = {
      OLLAMA_NUM_PARALLEL = "1";
      OLLAMA_MAX_LOADED_MODELS = "1";
      OLLAMA_KEEP_ALIVE = "0s";
      OLLAMA_CONTEXT_LENGTH = "16384";
    };
  };
  systemd.services.ollama.serviceConfig = {
    CPUQuota = "200%";
    MemoryMax = "10G";
  };


  # Define a user account. Don't forget to set a password with 'passwd'.
  users.users.kazuki = {
    isNormalUser = true;
    description = "Kazuki Matsuo";
    extraGroups = [ "networkmanager" "wheel" ];
  };
  users.groups.otelcol = {};
  users.users.otelcol = {
    isSystemUser = true;
    group = "otelcol";
    extraGroups = [ "systemd-journal" ];
  };

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [
    neovim
    kubectl
    kubernetes-helm
    kubeseal
    k9s
    cloudflared
  ];
  # Make kubectl point to k3s kubeconfig by default.
  environment.sessionVariables.KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";
  environment.etc."otelcol/config.yaml".source = ./otelcol/config.yaml;

  # Lightweight single-node k3s
  services.k3s = {
    enable = true;
    role = "server";
    clusterInit = true;
    extraFlags = "--write-kubeconfig-mode=644 --disable traefik --disable servicelb --kubelet-arg=max-pods=50 --resolv-conf=/etc/resolv.conf";
  };

  systemd.services.k3s-manifests = {
    description = "Link k3s bootstrap manifests from /etc/nixos";
    before = [ "k3s.service" ];
    wantedBy = [ "k3s.service" ];
    serviceConfig = {
      Type = "oneshot";
    };
    script = ''
      set -euo pipefail

      src=/etc/nixos/k8s/bootstrap
      dst=/var/lib/rancher/k3s/server/manifests

      ${pkgs.coreutils}/bin/install -d -m 0755 "$dst"
      if [ -d "$src" ]; then
        for f in "$src"/*.yaml; do
          [ -e "$f" ] || continue
          ${pkgs.coreutils}/bin/ln -sf "$f" "$dst/$(basename "$f")"
        done
      fi
      for link in "$dst"/*.yaml; do
        if [ -L "$link" ] && [ ! -e "$link" ]; then
          ${pkgs.coreutils}/bin/rm -f "$link"
        fi
      done
    '';
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
  # Some programs need SUID wrappers, can be configured further or are
  # started in user sessions.
  # programs.mtr.enable = true;
  # programs.gnupg.agent = {
  #   enable = true;
  #   enableSSHSupport = true;
  # };

  # List services that you want to enable:

  # Open ports in the firewall.
  # networking.firewall.allowedTCPPorts = [ ... ];
  # networking.firewall.allowedUDPPorts = [ ... ];
  # Or disable the firewall altogether.
  # networking.firewall.enable = false;

  # ============================================================
  # GUI Recovery Configuration (for emergency use)
  # 画面復旧用設定（緊急時のみ使用）
  # ============================================================
  services.xserver.enable = false;
  services.xserver.displayManager.gdm.enable = false;
  services.xserver.desktopManager.gnome.enable = false;

  services.libinput.enable = true;
  services.xserver.xkb = {
    layout = "jp";
    variant = "";
  };


  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "25.11"; # Did you read the comment?

}
