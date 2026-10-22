;;; init-go.el --- Support for working with GO -*- lexical-binding: t -*-
;;; Commentary:
;;; Code:
(require-package 'go-mode)
(add-to-list 'auto-mode-alist '("\\.go\\'" . go-mode))

;; Enable eglot (LSP) for Go files
(add-hook 'go-mode-hook 'eglot-ensure)

;; Optional: Format on save
(add-hook 'go-mode-hook
          (lambda ()
            (add-hook 'before-save-hook #'eglot-format-buffer nil t)))

(provide 'init-go)
;;; init-go.el ends here
