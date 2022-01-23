;;; init-latex.el --- Support for working with LATEX -*- lexical-binding: t -*-
;;; Commentary:
;;; Code:

;; Enable scala-mode for highlighting, indentation and motion commands
(when (maybe-require-package 'latex-mode)
  (require-package 'latex-extra)
  )

(setenv "PATH" (concat (getenv "PATH") ":/usr/local/texlive/2020/bin/x86_64-darwin/"))
(setq exec-path (append exec-path '("/usr/local/texlive/2020/bin/x86_64-darwin/")))
(setq org-latex-pdf-process '("xelatex -interaction nonstopmode %f" "xelatex -interaction nonstopmode %f"))


(provide 'init-latex)
;;; init-latex.el ends here
