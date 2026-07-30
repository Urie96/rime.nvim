{
  pkgs ? import <nixpkgs> { },
}:

pkgs.stdenv.mkDerivation {
  name = "rime.nvim";

  # 只包含真正编译必需的源：
  #   Makefile + rime.nobj.c + include/ (LuaJIT 头文件)
  src = pkgs.lib.sourceByRegex ./. [
    "^Makefile$"
    "^rime\\.nobj\\.c$"
    "^include(/.*)?$"          # include 目录自身及其下所有文件
  ];

  nativeBuildInputs = [ pkgs.pkg-config ];
  buildInputs = [ pkgs.librime ];

  buildPhase = ''
    # rime.nobj.c 在 Makefile 里声明了 .nobj.lua 依赖，
    # 但已提交的 rime.nobj.c 不需要重新生成。touch 空文件
    # 让 make 能通过依赖检查，跳过重新生成步骤。
    mkdir -p lua src
    touch rime.nobj.lua src/traits.nobj.lua src/session.nobj.lua
    make
  '';

  installPhase = ''
    mkdir -p $out/lua
    cp lua/rime.so $out/lua/rime.so
  '';
}
