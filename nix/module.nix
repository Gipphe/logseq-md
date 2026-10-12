{
  perSystem =
    {
      self',
      pkgs,
      system,
      ...
    }:
    {
      packages = {
        default = self'.packages.logseq-md;
        logseq-md = pkgs.callPackage ./package.nix { };
        logseq-md-android = pkgs.callPackage ./android.nix { };
      };

      apps = pkgs.lib.optionalAttrs (system == "x86_64-linux") {
        logseq-md-emulator =
          let
            script = pkgs.callPackage ./emulator.nix {
              logseq-md-android = self'.packages.logseq-md-android;
            };
          in
          {
            type = "app";
            program = "${script}/bin/logseq-md-emulator";
          };
      };

      devShells.default = pkgs.mkShell {
        packages = builtins.attrValues {
          inherit (pkgs)
            nixfmt
            ;
        };
      };
    };
}
