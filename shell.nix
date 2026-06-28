{ pkgs ? import <nixpkgs> {} }:

let
  runtimeLibs = with pkgs; [
    stdenv.cc.cc.lib
    fontconfig
    freetype
    libxkbcommon
    wayland
    libGL
    openssl
    zlib
    systemd
    xorg.libX11
    xorg.libXcursor
    xorg.libXi
    xorg.libXrandr
    xorg.libxcb
  ];

  projectRoot = toString ./.;

    compile = pkgs.writeShellScriptBin "compile" ''
    set -e

    BOILERPLATE_CMD="${projectRoot}/.boilerplate/bin/boilerplate-compile"

    if [ ! -x "$BOILERPLATE_CMD" ]; then
      echo "Error: file tidak ditemukan atau tidak executable:"
      echo "$BOILERPLATE_CMD"
      exit 1
    fi

    case "''${1:-help}" in
      stats)
        shift
        exec "$BOILERPLATE_CMD" sccache-stats "$@"
        ;;

      clear)
        shift
        exec "$BOILERPLATE_CMD" clean "$@"
        ;;

      prune)
        shift
        exec "$BOILERPLATE_CMD" purge "$@"
        ;;

      *)
        exec "$BOILERPLATE_CMD" "$@"
        ;;
    esac
  '';
in
pkgs.mkShell {
  packages = with pkgs; [
    bash
    cargo
    clang
    clippy
    cmake
    coreutils
    docker-client
    docker-compose
    file
    git
    gnutar
    jq
    openssh
    patchelf
    pkg-config
    rust-analyzer
    rustc
    rustfmt

    compile
  ];

  shellHook = ''
    export PATH="${projectRoot}/.boilerplate/bin:$PATH"
    export BOILERPLATE_LIBRARY_PATH="${pkgs.lib.makeLibraryPath runtimeLibs}"
    export BOILERPLATE_DYNAMIC_LINKER="$(cat ${pkgs.stdenv.cc}/nix-support/dynamic-linker)"

    echo ""
    echo "Rust remote compiler siap."
    echo ""
    echo "Perintah:"
    echo "  compile help              Lihat bantuan command"
    echo "  compile doctor            Cek koneksi SSH, Docker VPS, dan konfigurasi"
    echo "  compile build             Build debug di VPS"
    echo "  compile build --release   Build release di VPS"
    echo "  compile run               Build di VPS lalu jalankan binary di NixOS lokal"
    echo "  compile dev               Jalankan server di VPS dan akses lewat localhost"
    echo "  compile check             Cek kode Rust tanpa membuat binary final"
    echo "  compile test              Jalankan test Rust di VPS"
    echo "  compile stats             Lihat statistik cache sccache"
    echo "  compile status            Lihat status resource builder di VPS"
    echo "  compile stop              Hentikan container aplikasi remote"
    echo "  compile clear             Bersihkan resource project aktif"
    echo "  compile prune             Hapus seluruh resource builder di VPS"
    echo ""
  '';
}