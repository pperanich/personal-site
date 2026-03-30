{
  stdenv,
  bun2nix,
}:
stdenv.mkDerivation {
  pname = "personal-site";
  version = "0.0.1";
  src = ./.;

  nativeBuildInputs = [ bun2nix.hook ];

  bunDeps = bun2nix.fetchBunDeps {
    bunNix = ./bun.nix;
  };

  buildPhase = ''
    bun run build --minify
  '';

  installPhase = ''
    cp -r ./dist $out
  '';
}
