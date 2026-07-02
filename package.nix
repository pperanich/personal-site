{
  lib,
  stdenv,
  bun2nix,
  autoPatchelfHook,
}:
stdenv.mkDerivation {
  pname = "personal-site";
  version = "0.0.1";
  src = ./.;

  nativeBuildInputs = [
    bun2nix.hook
    autoPatchelfHook
  ];

  # libstdc++ is needed by sharp's native bindings.
  buildInputs = [ stdenv.cc.cc.lib ];

  # Musl variants are installed but unused on glibc systems.
  autoPatchelfIgnoreMissingDeps = [ "libc.musl-*" ];

  bunDeps = bun2nix.fetchBunDeps {
    bunNix = ./bun.nix;
  };

  # Isolated linker requires npm manifest cache files that bun2nix
  # doesn't generate, causing downloads that fail in the NixOS sandbox.
  # Hoisted + copyfile avoids this by using the cache directly.
  # See: https://github.com/nix-community/bun2nix/issues/50
  #      https://github.com/nix-community/bun2nix/issues/77
  bunInstallFlags = [
    "--linker=hoisted"
    "--backend=copyfile"
  ];

  # Cache copy from nix store retains read-only permissions.
  # See: https://github.com/nix-community/bun2nix/issues/73
  preBunNodeModulesInstallPhase = ''
    chmod -R u+w "$BUN_INSTALL_CACHE_DIR"
  '';

  # autoPatchelfHook runs in fixupPhase (after build), but sharp's native
  # bindings must be loadable during the astro build. Patch node_modules early.
  postBunNodeModulesInstallPhase = ''
    chmod -R u+w node_modules
    addAutoPatchelfSearchPath node_modules/@img/sharp-libvips-linux-x64/lib
    autoPatchelf node_modules
  '';

  buildPhase = ''
    # autoPatchelf resolves libstdc++ but leaves libvips-cpp unresolved on the
    # sharp binding (empty rpath), so sharp fails to load during astro's
    # prerender. node_modules never reach $out (only ./dist is installed), so
    # LD_LIBRARY_PATH for the build process is sufficient and robust across
    # bun/bun2nix/autoPatchelf versions. Glob covers glibc libvips dirs for
    # any arch (linux-x64, linux-arm64, ...) but must NOT match linuxmusl-*:
    # the musl libvips would shadow the glibc one and fail to load.
    for vipsdir in node_modules/@img/sharp-libvips-linux-*/lib; do
      export LD_LIBRARY_PATH="$PWD/$vipsdir''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    done
    export LD_LIBRARY_PATH="''${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}${lib.makeLibraryPath [ stdenv.cc.cc.lib ]}"
    bun run build --minify
  '';

  installPhase = ''
    cp -r ./dist $out
  '';
}
