{
  description = "Preston Peranich's personal site";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    bun2nix = {
      url = "github:nix-community/bun2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      bun2nix,
    }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
          overlays = [ bun2nix.overlays.default ];
        };
    in
    {
      packages = forAllSystems (system: {
        personal-site = (pkgsFor system).callPackage ./package.nix { };
        default = self.packages.${system}.personal-site;
      });

      devShells = forAllSystems (system: {
        default =
          let
            pkgs = pkgsFor system;
          in
          pkgs.mkShell {
            packages = [
              pkgs.bun
              pkgs.bun2nix
              pkgs.nodejs
            ];
          };
      });

      overlays.default = final: prev: {
        personal-site = final.callPackage ./package.nix { };
      };
    };
}
