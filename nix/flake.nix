{
  description = "Rust dev shell with Fenix (stable + nightly) and cargo +nightly shim";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.systems.url = "github:nix-systems/default";
  inputs.flake-utils = {
    url = "github:numtide/flake-utils";
    inputs.systems.follows = "systems";
  };
  inputs.fenix.url = "github:nix-community/fenix";

  outputs =
    {
      nixpkgs,
      flake-utils,
      systems,
      fenix,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        llvm = pkgs.llvmPackages;

        fenixPkgs = fenix.packages.${system};

        # Derive Cargo target triple + env var name (like server flake)
        cargoTarget = pkgs.stdenv.hostPlatform.rust.rustcTargetSpec or pkgs.stdenv.hostPlatform.config;

        cargoTargetEnvVar = builtins.replaceStrings [ "-" ] [ "_" ] (pkgs.lib.toUpper cargoTarget);

        # Fenix toolchains
        rustStable = fenixPkgs.stable.withComponents [
          "cargo"
          "rustc"
          "rustfmt"
          "clippy"
          "rust-src"
        ];

        # "latest" in Fenix is effectively nightly
        rustNightly = fenixPkgs.latest.withComponents [
          "cargo"
          "rustc"
          "rustfmt"
          "clippy"
          "rust-src"
        ];

        rustAnalyzer = fenixPkgs.rust-analyzer;

        # Shim to emulate `cargo +nightly ...` like rustup does
        cargoShim = pkgs.writeShellScriptBin "cargo" ''
          #!${pkgs.bash}/bin/bash
          set -euo pipefail

          case "''${1-}" in
            +nightly)
              shift
              # Put nightly toolchain bin first, so rustfmt/clippy/etc are nightly
              export PATH="${rustNightly}/bin:${rustStable}/bin:${rustAnalyzer}/bin:$PATH"
              exec ${rustNightly}/bin/cargo "$@"
              ;;
            +stable)
              shift
              # Explicit stable
              export PATH="${rustStable}/bin:${rustAnalyzer}/bin:$PATH"
              exec ${rustStable}/bin/cargo "$@"
              ;;
            *)
              # Default: stable toolchain
              export PATH="${rustStable}/bin:${rustAnalyzer}/bin:$PATH"
              exec ${rustStable}/bin/cargo "$@"
              ;;
          esac
        '';
      in
      {
        devShells.default = pkgs.mkShell {
          nativeBuildInputs = [
            # Our cargo shim (handles +nightly)
            cargoShim

            # Put both toolchains in PATH so nightly's internal tools are found
            rustStable
            rustNightly
            rustAnalyzer

            # Build helpers
            llvm.clang
            llvm.libclang
            pkgs.rustPlatform.bindgenHook # sets LIBCLANG_PATH and include flags for bindgen
            pkgs.pkg-config
            pkgs.cmake # often needed by native crates
            pkgs.python3 # some build scripts need python
            pkgs.openssl.dev
            pkgs.gnumake
            pkgs.mold
          ];

          buildInputs = [
            pkgs.openssl
          ];

          packages = [
            pkgs.just
          ];

          # OpenSSL
          OPENSSL_NO_VENDOR = "1";
          OPENSSL_DIR = "${pkgs.openssl.dev}";
          OPENSSL_LIB_DIR = "${pkgs.openssl.out}/lib";
          OPENSSL_INCLUDE_DIR = "${pkgs.openssl.dev}/include";

          # Tell Cargo which linker to use for this target (clang + mold)
          "CARGO_TARGET_${cargoTargetEnvVar}_LINKER" = "${pkgs.llvmPackages.clangUseLLVM}/bin/clang";

          # Bindgen / libclang
          LIBCLANG_PATH = "${llvm.libclang.lib}/lib";
          BINDGEN_EXTRA_CLANG_ARGS = "-I${pkgs.glibc.dev}/include";
          C_INCLUDE_PATH = "${pkgs.glibc.dev}/include";

          # Runtime search path for native libs
          LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [
            pkgs.openssl
            pkgs.llvmPackages.libclang.lib
          ];

          # Default perf flags (same spirit as server)
          RUSTFLAGS = "-Clink-arg=-fuse-ld=${pkgs.mold}/bin/mold";

          # to remove the foritfy fail on just check
          # Remove the hardening added by nix to fix jmalloc compilation error.
          # More info: https://github.com/tikv/jemallocator/issues/108
          hardeningDisable = [ "fortify" ];
          # CARGO_PROFILE_DEV_OPT_LEVEL = "1";
          # CARGO_PROFILE_TEST_OPT_LEVEL = "1";
          # CARGO_PROFILE_CHECK_OPT_LEVEL = "1";

          # "layout rust" equivalent: per-project cargo bin dir on PATH
          shellHook = ''
            # Per-project cargo dir
            export CARGO_HOME="$PWD/.direnv/cargo"
            mkdir -p "$CARGO_HOME/bin"

            # Per-project toolchain for IDEs
            TOOLROOT="$PWD/.direnv/nix-toolchain"
            TOOLBIN="$TOOLROOT/bin"
            mkdir -p "$TOOLBIN"

            # === Symlinks exposed as "toolchain" for RustRover ===

            # cargo: use our shim so RustRover also supports `cargo +nightly ...`
            ln -sf "${cargoShim}/bin/cargo"      "$TOOLBIN/cargo"

            # rustc / rustfmt / clippy from STABLE by default
            ln -sf "${rustStable}/bin/rustc"     "$TOOLBIN/rustc"
            ln -sf "${rustStable}/bin/rustfmt"   "$TOOLBIN/rustfmt"
            ln -sf "${rustStable}/bin/clippy-driver" "$TOOLBIN/clippy-driver"

            # rust-analyzer
            ln -sf "${rustAnalyzer}/bin/rust-analyzer" "$TOOLBIN/rust-analyzer"

            # PATH: shim first (cargo), then TOOLBIN (rustc, rustfmt, etc.)
            export PATH="${cargoShim}/bin:$TOOLBIN:$CARGO_HOME/bin:$PATH"

            # Stdlib src for IDEs / rust-analyzer ===
            # Fenix ships rust-src; stdlib lives here:
            export RUST_SRC_PATH="${rustStable}/lib/rustlib/src/rust/library"
            SRC="''${RUST_SRC_PATH:-}"
            mkdir -p "$TOOLROOT"
            ln -sfn "$SRC" "$TOOLROOT/rust-src"

            echo "which cargo: $(command -v cargo)"
            echo "cargo is:   $(readlink -f "$(command -v cargo)" || command -v cargo)"
            echo "rustc: $(rustc --version)"
            echo "CARGO_HOME=$CARGO_HOME"
            echo "Toolchain symlinks in $TOOLBIN"
            echo "rust-src linked at $TOOLROOT/rust-src"
          '';
        };
      }
    );
}
