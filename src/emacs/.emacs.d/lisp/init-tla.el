;;; init-tla.el --- Support for working with TLA+ -*- lexical-binding: t -*-
;;; Commentary:
;;; Code:

;; tla-pcal-mode is not on any package archive; it lives in mrc/tla-tools.
(unless (package-installed-p 'tla-tools)
  (package-vc-install "https://github.com/mrc/tla-tools"))

;; Its autoload stub runs `define-polymode' before `poly-tla-pcal-hostmode'
;; exists, so load the real file on first use instead.
(defun sanityinc/tla-pcal-mode ()
  "Load `tla-pcal-mode' properly, then enable it."
  (require 'tla-pcal-mode)
  (tla-pcal-mode))

(when (package-installed-p 'tla-tools)
  (add-to-list 'auto-mode-alist '("\\.tla\\'" . sanityinc/tla-pcal-mode)))

(provide 'init-tla)
;;; init-tla.el ends here
