;;; init-dired.el --- Dired customisations -*- lexical-binding: t -*-
;;; Commentary:
;;; Code:
(require-package 'smex)
(smex-initialize) ; Can be omitted. This might cause a (minimal) delay
                                        ; when Smex is auto-initialized on its first run.
(global-set-key (kbd "M-x") 'smex)
(global-set-key (kbd "M-X") 'smex-major-mode-commands)
;; This is your old M-x.
(global-set-key (kbd "C-c C-c M-x") 'execute-extended-command)

(provide 'init-smex)
;;; init-smex.el ends here
