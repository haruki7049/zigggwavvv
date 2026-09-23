{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    flake-compat.url = "github:edolstra/flake-compat";
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      imports = [
        inputs.treefmt-nix.flakeModule
      ];

      perSystem =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        let
          ZIG = pkgs.zig_0_16;

          zigggwavvv = pkgs.stdenv.mkDerivation {
            name = "zigggwavvv";
            src = lib.cleanSource ./.;
            doCheck = true;

            nativeBuildInputs = [
              ZIG.hook
            ];

            postConfigure = ''
              ln -s ${pkgs.callPackage ./.deps.nix { }} zig-pkg
            '';
          };
        in
        {
          treefmt = {
            projectRootFile = ".git/config";

            # Nix
            programs.nixfmt.enable = true;

            # Zig
            programs.zig.enable = true;
            settings.formatter.zig.command = lib.getExe ZIG;

            # GitHub Actions
            programs.actionlint.enable = true;

            # Markdown
            programs.mdformat.enable = true;
          };

          packages = {
            inherit zigggwavvv;
            default = zigggwavvv;
          };

          checks = {
            inherit zigggwavvv;
          };

          devShells.default = pkgs.mkShell {
            nativeBuildInputs = [
              ZIG # Zig compiler
              pkgs.zls_0_16 # Zig LSP
              pkgs.nil # Nix LSP
              pkgs.zon2nix # zon2nix
            ];

            inputsFrom = [
              config.treefmt.build.devShell
            ];
          };
        };
    };
}
