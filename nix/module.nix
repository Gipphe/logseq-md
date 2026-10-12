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

      devShells.default = pkgs.mkShell {
        packages = builtins.attrValues {
          inherit (pkgs)
            nixfmt
            ;
        };
      };
    };
  };
}
