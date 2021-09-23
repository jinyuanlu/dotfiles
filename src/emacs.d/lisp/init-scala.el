;;; init-scala.el --- Support for working with SCALA -*- lexical-binding: t -*-
;;; Commentary:
;;; Code:

;; Enable scala-mode for highlighting, indentation and motion commands
(when (maybe-require-package 'scala-mode)
  (maybe-require-package 'sbt-mode))


(provide 'init-scala)
;;; init-scala.el ends here
