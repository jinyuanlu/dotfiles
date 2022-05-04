{ config, lib, pkgs, ... }:

{
  # Home Manager needs a bit of information about you and the
  # paths it should manage.
  home.username = "lujinyuan";
  home.homeDirectory = "/Users/lujinyuan";

  home.packages = with pkgs; [
    ripgrep
    stack
    ledger
    # count disk
    du-dust
    # count code
    tokei
    # faster find
    fd
    # dev tools
    shellcheck
    nixfmt
    pgformatter
    # font
    source-code-pro
  ];

  home.activation = {
    aliasApplications = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      ln -sfn $genProfilePath/home-path/Applications "$HOME/Applications/Home Manager Applications"
    '';
  };

  # This value determines the Home Manager release that your
  # configuration is compatible with. This helps avoid breakage
  # when a new Home Manager release introduces backwards
  # incompatible changes.
  #
  # You can update Home Manager without changing this value. See
  # the Home Manager release notes for a list of state version
  # changes in each release.xf
  home.stateVersion = "21.11";

  imports = [ ./programs/emacs/emacs.nix ./programs/zsh/default.nix ];

  # Let Home Manager install and manage itself.
  programs.home-manager.enable = true;

  programs.git = {
    enable = true;
    userName = "Jinyuan Lu";
    userEmail = "me@jinyuanlu.net";
    ignores = [ ".DS_Store" "*.pyc" ];
  };

  programs.mpv = {
    enable = true;
    config = {
      hwdec = "auto";
    };
  };

}
