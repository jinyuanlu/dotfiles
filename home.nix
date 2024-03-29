{ config, lib, pkgs, ... }:

{
  # Home Manager needs a bit of information about you and the
  # paths it should manage.
  home.username = "jinyuanlu";
  home.homeDirectory = "/Users/jinyuanlu";

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
    kdash
    # count disk
    du-dust
    # count code
    tokei
    # faster find
    fd
    # find & replace
    sd
    # dev tools
    # -- For: metals-emacs
    coursier
    # -- For: metals-emacs
    skaffold
    kubectl
    minikube
    maven
    sbt
    scala_2_12
    # Run arbitrary commands when files change
    entr
    elmPackages.elm
    nodejs
    elmPackages.elm
    nodePackages.http-server
    xsv
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
  home.stateVersion = "23.05";

  imports = [ ./programs/emacs/emacs.nix ./programs/zsh/default.nix ];

  # Let Home Manager install and manage itself.
  programs.home-manager.enable = true;

  programs.java = {
    enable = true;
    package = pkgs.jdk11;
  };


  programs.git = {
    enable = true;
    userName = "Jinyuan Lu";
    userEmail = "me@jinyuanlu.net";
    ignores = [ ".DS_Store" "*.pyc" ];
  };

}
