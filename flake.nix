{
  description = "Homelab development environments";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs =
    { nixpkgs, ... }:
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

      androidUsageReceiverPackage =
        pkgs:
        let
          inherit (pkgs) buildGo125Module;
        in
        buildGo125Module {
          pname = "android-usage-receiver";
          version = "0.0.0";

          src = ./apps/android-usage-receiver;
          subPackages = [ "cmd/android-usage-receiver" ];

          vendorHash = "sha256-bZOejICNfZiG1Tfq674M8hH1tVKGN5Ot3CKPUqP3wuo=";

          ldflags = [
            "-s"
            "-w"
          ];

          checkPhase = ''
            runHook preCheck
            go test ./...
            runHook postCheck
          '';
        };
    in
    {
      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          inherit (pkgs) mkShell;

          homelabShell = mkShell {
            packages = with pkgs; [
              go_1_25
              gopls
              gotools
              go-tools
              google-cloud-sdk
              terraform
              terraform-ls
              tflint
              zizmor
              actionlint
            ];

            GOTOOLCHAIN = "local";
          };
        in
        {
          default = homelabShell;
          homelab = homelabShell;
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          android-usage-receiver = androidUsageReceiverPackage pkgs;
        }
      );
    };
}
