;;; init-claude-code.el --- Claude Code IDE integration -*- lexical-binding: t -*-
;;; Commentary:
;;; Code:

;; Install claude-code-ide from GitHub if not already present
(unless (package-installed-p 'claude-code-ide)
  (package-vc-install "https://github.com/manzaltu/claude-code-ide.el"))

(when (package-installed-p 'claude-code-ide)
  (with-suppressed-warnings ((bytecomp))
    (require 'claude-code-ide))
  (global-set-key (kbd "C-c C-'") 'claude-code-ide-menu)
  (claude-code-ide-emacs-tools-setup))

(provide 'init-claude-code)

;;; init-claude-code.el ends here
