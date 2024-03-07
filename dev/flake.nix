{
  description = "Nomad K8s Operator";

  inputs = {
    flake-utils.url = "github:numtide/flake-utils";
    nixpkgs-unstable.url = "nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        unstable = nixpkgs-unstable.legacyPackages.${system};
        pkgs = nixpkgs.legacyPackages.${system};
        package = unstable.buildGoModule {
          pname = "cockroach-operator";
          version = "0.0.0";
          src = ../src;
          doCheck = false;
          vendorHash = "sha256-zHuq7zlLoC/JjWkldDMfcoedm3i6c7yrBqy+4GDFENQ=";
          postInstallPhase = ''
            cp cmd $out
          '';
        };
        dockerPackage = pkgs.dockerTools.buildImage {
          name = "nomad-k8s-operator";
          fromImageName = "gcr.io/distroless/static";
          fromImageTag = "nonroot";
          copyToRoot = pkgs.buildEnv {
            name = "operator";
            paths = [ package ];
            pathsToLink = [ "/bin" ];
          };
          config = {
            Cmd = [ "/bin/cmd" ];
            WorkingDir = "/";
            User = "65532:65532";
          };
        };
      in with pkgs; {
        packages.default = package;
        packages.dockerImage = dockerPackage;
        devShells.default = mkShell {
          buildInputs = [ nixfmt unstable.gopls operator-sdk unstable.go kubernetes-helm ];
        };
      });
}
