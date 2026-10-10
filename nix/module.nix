{
  perSystem = { self', pkgs, ... }: {
    packages = {
      default = self'.packages.logseq-md;
      logseq-md = pkgs.callPackage ./package.nix { };
    };
  };
}
