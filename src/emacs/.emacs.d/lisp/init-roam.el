;;; init-roam.el -- -*- lexical-binding: t -*-
;;; Commentary:
;;; Code:

(require-package 'org-roam)

(setq org-roam-directory (file-truename "~/Private/org/wiki/"))
(setq org-roam-dailies-directory "journal/")
(setq org-roam-v2-ack t)


;; key bindings
(global-set-key (kbd "C-c n f") 'org-roam-node-find)
(global-set-key (kbd "C-c n i") 'org-roam-node-insert)
(global-set-key (kbd "C-c n j") 'org-roam-dailies-capture-today)
(global-set-key (kbd "C-c n g") 'org-roam-graph)
(global-set-key (kbd "C-c n t") 'org-roam-buffer-toggle)
(global-set-key (kbd "C-c n s") 'org-roam-db-sync)
(global-set-key (kbd "C-c n d f") 'org-roam-dailies-find-directory)



(setq org-roam-dailies-capture-templates
      '(("d" "default" entry
         "* %?"
         :target (file+head "%<%Y-%m-%d>.org"
                            "#+title: %<%Y-%m-%d>\n"))))

(provide 'init-roam)
;;; init-roam.el ends here
