;;; init-scala.el --- Support for working with SCALA -*- lexical-binding: t -*-
;;; Commentary:
;;; Code:

;; Enable scala-mode for highlighting, indentation and motion commands
(when (maybe-require-package 'scala-mode)
  (require-package 'sbt-mode)
  (require-package 'lsp-metals)
  (require-package 'lsp-mode)
  (require-package 'lsp-ui)
  )

(with-eval-after-load 'scala-mode
  (add-hook 'scala-mode-hook 'lsp)
  )

(with-eval-after-load 'lsp-mode
  (add-hook 'lsp-mode-hook 'lsp-lens-mode)
  )



(provide 'init-scala)
;;; init-scala.el ends here
