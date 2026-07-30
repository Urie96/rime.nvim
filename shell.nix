{
  pkgs ? import <nixpkgs> { },
}:

pkgs.mkShell {
  name = "rime.nvim";
  buildInputs = with pkgs; [
    librime
    pkg-config
    gnumake
  ];
}
