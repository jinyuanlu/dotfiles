;;; early-init.el --- Emacs 27+ pre-initialisation config

;;; Commentary:

;; Emacs 27+ loads this file before (normally) calling
;; `package-initialize'.  We use this file to suppress that automatic
;; behaviour so that startup is consistent across Emacs versions.

;;; Code:

(setq package-enable-at-startup nil)

;; Third-party lint from background native-comp is noise, not actionable:
;; keep it logged in *Warnings* but never pop the window. (On 30.2,
;; `native-comp-async-report-warnings-errors' 'silent did not stop it.)
(setq warning-suppress-types '((native-compiler)))

;; So we can detect this having been loaded
(provide 'early-init)

;;; early-init.el ends here
