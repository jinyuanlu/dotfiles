;;; init-roam.el -- -*- lexical-binding: t -*-
;;; Commentary:
;;; Code:

(require-package 'org-roam)

(setq org-roam-directory (file-truename "~/Private/org/wiki/"))

(setq org-roam-v2-ack t)

(provide 'init-roam)
;;; init-roam.el ends here
