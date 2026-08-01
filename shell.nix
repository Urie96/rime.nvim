{
  pkgs ? import <nixpkgs> { },
}:

pkgs.mkShell {
  name = "rime.nvim";
  buildInputs = with pkgs; [
    librime
    pkg-config
    cargo
    rustc
  ];
  shellHook = ''
    export RIME_LIB_DIR=${pkgs.librime}/lib
    export RIME_INCLUDE_DIR=${pkgs.librime}/include
  '';
}
