;;; init-roam.el -- -*- lexical-binding: t -*-
;;; Commentary:
;;; Code:

(require-package 'org-roam)

(setq org-roam-directory
      (expand-file-name
       "wiki"
       (file-name-directory
        (directory-file-name
         "~/.org/"))))

(setq org-roam-buffer-position 'bottom)

(provide 'init-roam)
;;; init-roam.el ends here
