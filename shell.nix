{
  pkgs ? import <nixpkgs> { },
}:

let
  native_objects = pkgs.stdenv.mkDerivation {
    pname = "native_objects";
    version = "0.5.2";

    src = pkgs.fetchFromGitHub {
      owner = "Neopallium";
      repo = "LuaNativeObjects";
      rev = "178711500a5dd1dc211539cd64579d3edd5e934c";
      sha256 = "1f3hb5y4pkw5wn8sms3l1vk3nya2j1lggjp7d4wlh0nnqk30igav";
    };

    nativeBuildInputs = [ pkgs.makeWrapper ];
    buildInputs = [ pkgs.lua5_4 ];

    installPhase = ''
      runHook preInstall
      make install DESTDIR=$out PREFIX= LUA_VERSION=${pkgs.lua5_4.luaversion}
      # wrap the real script so the command works standalone (lua on PATH,
      # native_objects/*.lua modules discoverable via LUA_PATH)
      wrapProgram $out/bin/native_objects.lua \
        --prefix PATH : ${pkgs.lua5_4}/bin \
        --set LUA_PATH "$out/share/lua/${pkgs.lua5_4.luaversion}/?.lua;;"
      # expose it as `native_objects` (in addition to native_objects.lua)
      ln -s native_objects.lua $out/bin/native_objects
      runHook postInstall
    '';
  };
in
pkgs.mkShell {
  name = "rime.nvim";
  buildInputs = with pkgs; [
    librime
    pkg-config
    gnumake
    lua5_4
    native_objects
  ];
}
