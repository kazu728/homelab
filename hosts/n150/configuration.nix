{ pkgs, ... }:

{
  imports =
    [
      ./hardware-configuration.nix
      ./modules/network-recover.nix
      ./modules/k3s.nix
      ./modules/otelcol.nix
      ./modules/tailscale.nix
      ./modules/midi.nix
    ];

  # Bootloader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  # Track the latest stable kernel to improve rtw89_8852be Wi-Fi stability.
  boot.kernelPackages = pkgs.linuxPackages_latest;

  networking.hostName = "nixos";

  networking.networkmanager.enable = true;
  # Disable Wi-Fi power saving to reduce link drops.
  networking.networkmanager.wifi.powersave = false;

  services.networkRecover.enable = true;

  time.timeZone = "Asia/Tokyo";
  i18n.defaultLocale = "en_US.UTF-8";

  # Reachable over tailscale only; each service module opens its own ports.
  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 22 ];

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

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  environment.systemPackages = with pkgs; [
    neovim
  ];

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "25.11"; # Did you read the comment?

}
