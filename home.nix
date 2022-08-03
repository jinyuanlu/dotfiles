{ config, lib, pkgs, ... }:

{
  # Home Manager needs a bit of information about you and the
  # paths it should manage.
  home.username = "admin";
  home.homeDirectory = "/Users/admin";

  home.packages = with pkgs; [
    tmux
    jq
    graphviz
    gnupg
    tree
    ripgrep
    stack
    ledger
    direnv
    # count disk
    du-dust
    # count code
    tokei
    # faster find
    fd
    # dev tools
    # -- For: metals-emacs
    jdk8
    coursier
    # -- For: metals-emacs
    sbt
    scala_2_12
    nodejs
    yarn
    rustc
    cargo
    coq
    bazel_5
    terraform
    shellcheck
    nixfmt
    pgformatter
    pre-commit
    git-filter-repo
    # font
    source-code-pro
    # lsp
    pyright
    ccls
    nodePackages.typescript-language-server
    # cloud
    kind
    kustomize
    awscli2

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
    # Need to override on work machine
    userEmail = "lu.j@ctw.inc";
    ignores = [ ".DS_Store" "*.pyc" ];
  };

}
