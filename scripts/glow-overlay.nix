# You can symlink this overlay into your ~/.config/nixpkgs/overlays/
# to make muknglow available to your nix-env -iA muknglow.
# TODO: try src = builtins.fetchGit ./. and extracting version from THAT, and/or lib.commitIdFromGitRepo.
pkgs: super: rec {
  inherit (super) lib fetchFromGitLab fetchgit
     gerbil-unstable gambit-support gerbil-support gerbilPackages-unstable;

  ver = if builtins.pathExists ./version.ss
        then let m =
          builtins.match "\\(import :utils/versioning\\)\n\\(register-software \"([-_.A-Za-z0-9]+)\" \"([-_.A-Za-z0-9]+)\"\\) ;; ([-0-9]+)\n"
            (builtins.readFile ./version.ss); in
            { version = builtins.elemAt m 2; git-version = builtins.elemAt m 1; }
        else { version = "0.0"; git-version = "0.0"; };

  muknglow = gerbil-support.gerbilPackage {
    pname = "muknglow";
    version = ver.version;
    git-version = ver.git-version;
    gerbil-package = "glow";
    gerbil = gerbil-unstable;
    gambit-params = gambit-support.unstable-params;
    gerbilInputs = with gerbilPackages-unstable; [gerbil-utils gerbil-crypto gerbil-ethereum];
    version-path = "version";
    src = builtins.filterSource
      (path: type: let baseName = baseNameOf path; in
        ! (baseName == ".git" || baseName == "run" || baseName == "result" ||
           baseName == "BLAH" || lib.hasSuffix "~" baseName))
      ./..;

    #src = fetchFromGitLab { owner = "mukn"; repo = "glow";
    #  rev = "d0ad110a22b622844a4b916326b221ed3bbe66c4";
    #  sha256 = "1xyslg5maz60wxrc4jqndx8czfi8b2b9f0n0rsm00000000giddf"; };
    meta = {
      description = "Decentralized Application Language";
      homepage    = "https://gitlab.com/mukn/glow";
      license     = lib.licenses.asl20;
      platforms   = lib.platforms.unix;
      maintainers = with lib.maintainers; [ fare ];
    };
  };
}