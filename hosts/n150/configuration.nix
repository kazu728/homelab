{ config, pkgs, ... }:

{
  imports =
    [
      ./hardware-configuration.nix
      ./modules/network-recover.nix
      ./modules/k3s.nix
      ./modules/otelcol.nix
      ./modules/tailscale.nix
      ./modules/midi.nix
      ./modules/backup.nix
    ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  # Track the latest stable kernel to improve rtw89_8852be Wi-Fi stability.
  boot.kernelPackages = pkgs.linuxPackages_latest;

  networking.hostName = "nixos";

  # Secrets are sops-encrypted to an age key derived from this host's SSH host
  # key (.sops.yaml); a rebuilt node must restore that key to decrypt them.
  sops.defaultSopsFile = ./secrets.yaml;
  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

  networking.networkmanager.enable = true;
  # Disable Wi-Fi power saving to reduce link drops.
  networking.networkmanager.wifi.powersave = false;
  # Declare the Wi-Fi profile so a rebuilt node reconnects without console
  # input. $WIFI_SSID/$WIFI_PSK are substituted from the sops env file.
  networking.networkmanager.ensureProfiles = {
    environmentFiles = [ config.sops.secrets."wifi-env".path ];
    profiles.home-wifi = {
      connection = {
        id = "home-wifi";
        type = "wifi";
      };
      wifi.ssid = "$WIFI_SSID";
      wifi-security = {
        key-mgmt = "wpa-psk";
        psk = "$WIFI_PSK";
      };
    };
  };
  sops.secrets."wifi-env" = {
    key = "wifi_env";
    restartUnits = [ "NetworkManager-ensure-profiles.service" ];
  };

  services.networkRecover.enable = true;

  time.timeZone = "Asia/Tokyo";

  # Reachable over tailscale only; each service module opens its own ports.
  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 22 ];

  # Use compressed RAM swap to soften OOMs without disk swap.
  zramSwap = {
    enable = true;
    priority = 100;
  };

  services.logind.settings.Login = {
    HandleSuspendKey = "ignore";
    HandleHibernateKey = "ignore";
    HandleLidSwitch = "ignore";
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
    openssh.authorizedKeys.keys = [
      "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBHxrSOVyERLr5n6WAxcHo8lKeiVR4ai2bqbC68lR/Vt8MEv2JKmvZQh6aoO9eSbs6m3vG3czdB1Dn6nQkErOcRA= github@secretive.mba.local"
    ];
  };

  # Login is gated by the Secure Enclave SSH key (password auth disabled above),
  # so drop the redundant sudo password for the single wheel user.
  security.sudo.wheelNeedsPassword = false;

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  environment.systemPackages = with pkgs; [
    neovim
  ];

  # Keep the initial install release to preserve stateful defaults.
  system.stateVersion = "25.11";

}
