;;; init-local.el --- Local setting -*- lexical-binding: t -*-
;;; Commentary:
;;; Code:
(defun set-buffer-to-courier ()
  (face-remap-add-relative 'default '(:family "Courier" :height 110)))

(add-hook 'calendar-mode-hook 'set-buffer-to-courier)

(provide 'init-local)
;;; init-local.el ends here
