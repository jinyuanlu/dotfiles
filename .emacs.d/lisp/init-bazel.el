;;; init-bazel.el --- Basic support for programming in Bazel -*- lexical-binding: t -*-
;;; Commentary:
;;; Code:

(require-package 'bazel)

(add-auto-mode 'bazel-mode "WORKSPACE")
(add-auto-mode 'bazel-mode "BUILD")
(add-auto-mode 'bazel-mode "\\.bazel\\'")

(provide 'init-bazel)
;;; init-bazel.el ends herepp
