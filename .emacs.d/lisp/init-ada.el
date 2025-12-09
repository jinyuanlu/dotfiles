;;; init-ada.el --- Support for the Ada language -*- lexical-binding: t -*-
;;; Commentary:
;;; Code:

(when (maybe-require-package 'ada-mode)
  ;; Use eglot backend instead of wisi parser (requires ada_language_server)
  (setq ada-face-backend 'eglot)
  (setq ada-indent-backend 'eglot)
  (setq ada-xref-backend 'eglot)

  ;; Associate Ada file extensions with ada-mode
  (add-to-list 'auto-mode-alist '("\\.ads\\'" . ada-mode))  ;; Ada specification
  (add-to-list 'auto-mode-alist '("\\.adb\\'" . ada-mode))  ;; Ada body
  (add-to-list 'auto-mode-alist '("\\.ada\\'" . ada-mode))  ;; Ada source

  ;; Enable LSP support
  (add-hook 'ada-mode-hook 'eglot-ensure)
  )

(provide 'init-ada)
;;; init-ada.el ends here
