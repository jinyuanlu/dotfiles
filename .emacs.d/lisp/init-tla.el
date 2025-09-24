;;; init-tla.el --- Support for working with TLA+ -*- lexical-binding: t -*-
;;; Commentary:
;;; Code:
(require-package 'tla-mode)
(add-to-list 'auto-mode-alist '("\\.tla\\'" . tla-mode))

(provide 'init-tla)
;;; init-tla.el ends here