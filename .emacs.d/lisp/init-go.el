;;; init-go.el --- Support for working with GO -*- lexical-binding: t -*-
;;; Commentary:
;;; Code:
(require-package 'go-mode)
(add-to-list 'auto-mode-alist '("\\.go\\'" . go-mode))

(provide 'init-go)
;;; init-go.el ends here
