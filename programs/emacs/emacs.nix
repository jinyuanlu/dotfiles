{ config, pkgs, ... }:

let sources = import ../../nix/sources.nix;
in {
  programs.emacs = { enable = true; };

  home.file = {
    ".emacs.d" = {
      source = ../../src/emacs/.emacs.d;
      recursive = true;
    };
  };
}
