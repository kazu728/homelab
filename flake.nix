{
  description = "Homelab development environments";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # The midilab capture workspace, built from source (it ships no flake).
    midilab = {
      url = "github:kazu728/midilab";
      flake = false;
    };
  };

  outputs =
    { nixpkgs, sops-nix, midilab, ... }:
    let
      systems = [
        "aarch64-darwin"
        "x86_64-linux"
      ];

      forAllSystems = nixpkgs.lib.genAttrs systems;

      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
          config.allowUnfreePredicate =
            pkg:
            builtins.elem (nixpkgs.lib.getName pkg) [
              "terraform"
            ];
        };

      # Build the midilogd daemon and the exporter from the midilab repo. Only
      # midilogd links ALSA; the exporter is a plain OTLP pusher.
      midiOverlay = final: prev: {
        midilogd = final.rustPlatform.buildRustPackage {
          pname = "midilogd";
          version = "0.1.0";
          src = midilab;
          cargoLock.lockFile = "${midilab}/Cargo.lock";
          buildAndTestSubdir = "crates/midilogd";
          nativeBuildInputs = [ final.pkg-config ];
          buildInputs = [ final.alsa-lib ];
        };
        midi-exporter = final.rustPlatform.buildRustPackage {
          pname = "midi-exporter";
          version = "0.1.0";
          src = midilab;
          cargoLock.lockFile = "${midilab}/Cargo.lock";
          buildAndTestSubdir = "crates/midi-exporter";
        };
      };

    in
    {
      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              terraform
              terraform-ls
              tflint
              zizmor
              actionlint
            ];
          };
        }
      );

      nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit midilab; };
        modules = [
          sops-nix.nixosModules.sops
          ./hosts/n150/configuration.nix
          {
            nixpkgs.overlays = [ midiOverlay ];
            nix.registry.nixpkgs.flake = nixpkgs;
            nix.nixPath = [ "nixpkgs=${nixpkgs}" ];
          }
        ];
      };

    };
}
