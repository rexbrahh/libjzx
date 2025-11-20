{
  description = "libjzx development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        zigPkg = pkgs.zig;
      in {
        devShells.default = pkgs.mkShell {
          buildInputs = [
            zigPkg
            pkgs.clang
            pkgs.pkg-config
            pkgs.gnumake
            pkgs.cmake
          ];

          shellHook = ''
            export ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-cache"
          '';
        };
      });
}
