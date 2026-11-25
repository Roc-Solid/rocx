# rocx, Roc Solid's command, prebuilt (spike/install/DESIGN.md §3): the release nix/release.json
# names, for macOS on Apple silicon and Linux on arm64 and x86_64. `nix run github:Roc-Solid/rocx`,
# `nix profile install github:Roc-Solid/rocx`, or this flake as an input: packages.<system>.default.
# The release workflow writes nix/release.json when it publishes a release; until the first, it
# names none, and the flake has no package.
{
  description = "rocx, Roc Solid's command: web apps in Roc, a native server and the browser";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      release = builtins.fromJSON (builtins.readFile ./nix/release.json);
      forEachSystem = f: nixpkgs.lib.genAttrs (builtins.attrNames release.systems)
        (system: f system nixpkgs.legacyPackages.${system});
    in
    {
      packages = forEachSystem (system: pkgs: {
        # The archive's folder as it is, in $out/lib/rocx: rocx finds its platforms, packages,
        # templates and compiler (bin/roc) beside its binary. Under /nix/store it downloads nothing.
        default = pkgs.stdenvNoCC.mkDerivation {
          pname = "rocx";
          version = release.version;
          src = pkgs.fetchurl { inherit (release.systems.${system}) url hash; };
          dontConfigure = true;
          dontBuild = true;
          # The Linux binaries are static (musl) and the Mac's signed: nothing to patch or strip.
          dontFixup = true;
          installPhase = ''
            runHook preInstall
            mkdir -p $out/lib/rocx $out/bin
            cp -R . $out/lib/rocx
            ln -s $out/lib/rocx/bin/rocx $out/bin/rocx
            runHook postInstall
          '';
          meta = {
            description = "Roc Solid's command: web apps in Roc, a native server and the browser";
            homepage = "https://roc-solid.github.io/";
            license = pkgs.lib.licenses.mit;
            mainProgram = "rocx";
            platforms = builtins.attrNames release.systems;
            sourceProvenance = [ pkgs.lib.sourceTypes.binaryNativeCode ];
          };
        };
      });

      apps = forEachSystem (system: pkgs: {
        default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/rocx";
          meta.description = "rocx";
        };
      });

      # rocx on PATH, for working on an app.
      devShells = forEachSystem (system: pkgs: {
        default = pkgs.mkShellNoCC { packages = [ self.packages.${system}.default ]; };
      });
    };
}
