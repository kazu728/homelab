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

    };
}
