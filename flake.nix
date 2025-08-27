{
  description = "Nix flake for Lightdash Helm Chart development environment";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      # This covers typical Linux and macOS architectures.x
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      forAllSystems = f: nixpkgs.lib.genAttrs supportedSystems (system: f system);
    in
    {
      devShells = forAllSystems (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config = {
              allowUnfreePredicate =
                pkg:
                builtins.elem (nixpkgs.lib.getName pkg) [
                ];
            };
          };

          kAlias = pkgs.writeShellScriptBin "k" ''
            exec ${pkgs.kubecolor}/bin/kubecolor "$@"
          '';
        in
        {
          default = pkgs.mkShell {
            name = "lightdash-helm-chart-dev-shell";

            buildInputs = with pkgs; [
              nodejs_20
              python312

              kubernetes-helm
              minikube

              kAlias
              kubecolor
              kubectl
              stern

            ];
          };
        }
      );
    };
}
