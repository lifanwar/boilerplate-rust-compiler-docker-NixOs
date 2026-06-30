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
  ];

  shellHook = ''
    export PATH="${projectRoot}/.boilerplate/bin:$PATH"
    export BOILERPLATE_LIBRARY_PATH="${pkgs.lib.makeLibraryPath runtimeLibs}"
    export BOILERPLATE_DYNAMIC_LINKER="$(cat ${pkgs.stdenv.cc}/nix-support/dynamic-linker)"

    compile() {
      boilerplate-compile "$@"
    }
    export -f compile
  
    echo "boilerplate-compile siap. Jalankan: compile help"
  '';
}
