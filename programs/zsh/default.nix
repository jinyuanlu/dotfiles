{ pkgs, ... }: {
  home.packages = [ pkgs.fzf pkgs.starship pkgs.zoxide ];

  programs.zsh = {
    enable = true;
    zplug = {
      enable = true;
      plugins = [
        { name = "zsh-users/zsh-autosuggestions"; }
        { name = "zsh-users/zsh-syntax-highlighting"; }
      ];
    };

    shellAliases = {
      setproxy = "export ALL_PROXY=socks5://127.0.0.1:1080";
      unsetproxy = "unset ALL_PROXY";
      bal = "ledger -f ~/.fin/fin.dat balance";
      ee = "emacsclient";
      formatnix = "fd -e nix -X nixfmt";
      ls = "ls -G";
      eth =
        "curl 'https://min-api.cryptocompare.com/data/price?fsym=ETH&tsyms=BTC,USD,CNY' | python -m json.tool";
      btc =
        "curl 'https://min-api.cryptocompare.com/data/price?fsym=BTC&tsyms=BTC,USD,CNY' | python -m json.tool";
      # get finder current directory
      fcd = ''osascript -e "tell app \"Finder\" to POSIX path of (insertion location as alias)"'';
    };

    initExtra = builtins.readFile ./zshrc;
  };
}
