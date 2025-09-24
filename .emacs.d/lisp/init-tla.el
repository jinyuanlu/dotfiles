;;; init-tla.el --- Support for working with TLA+ -*- lexical-binding: t -*-
;;; Commentary:
;;; Code:
(require-package 'tla-pcal-mode)
(add-to-list 'auto-mode-alist '("\\.tla\\'" . tla-pcal-mode))

(provide 'init-tla)
;;; init-tla.el ends here