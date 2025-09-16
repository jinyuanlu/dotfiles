;;; init-claude-code.el --- Claude Code IDE integration -*- lexical-binding: t -*-
;;; Commentary:
;;; Code:

(use-package claude-code-ide
  :straight (:type git :host github :repo "manzaltu/claude-code-ide.el")
  :bind ("C-c C-'" . claude-code-ide-menu) ; Set your favorite keybinding
  :config
  (claude-code-ide-emacs-tools-setup)) ; Optionally enable Emacs MCP tools

(provide 'init-claude-code)

;;; init-claude-code.el ends here
