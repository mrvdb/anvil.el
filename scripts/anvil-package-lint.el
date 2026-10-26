;;; anvil-package-lint.el --- Audit core and optional package profiles -*- lexical-binding: t; -*-

;;; Commentary:
;; Audit every root module.  Optional modules are reviewed in the manifest;
;; all other modules inherit the real main file's Emacs 28.2 dependency.

;;; Code:
(require 'cl-lib)
(require 'json)
(unless (require 'package-lint nil t)
  (error "Install package-lint locally or set PACKAGE_LINT_DIR to its directory"))

(defconst anvil-package-lint-root
  (file-name-directory (directory-file-name
                        (file-name-directory (or load-file-name buffer-file-name)))))

(defun anvil-package-lint-file (file main)
  "Return diagnostics for FILE using MAIN as its package metadata authority."
  (with-temp-buffer
    (insert-file-contents file t)
    (emacs-lisp-mode)
    (let ((package-lint-main-file main))
      (package-lint-buffer))))

(defun anvil-package-lint--builtin-reference (form symbols)
  "Return a direct builtin reference in FORM belonging to SYMBOLS, if any.
Availability probes using quoted symbols remain valid in core modules."
  (when (consp form)
    (cond
     ((eq (car form) 'quote) nil)
     ((and (memq (car form) '(funcall apply))
           (eq (car-safe (cadr form)) 'quote)
           (memq (cadr (cadr form)) symbols))
      (cadr (cadr form)))
     ((eq (car form) 'function)
      (if (symbolp (cadr form))
          (and (memq (cadr form) symbols) (cadr form))
        (anvil-package-lint--builtin-reference (cadr form) symbols)))
     (t (or (and (memq (car form) symbols) (car form))
            (anvil-package-lint--builtin-reference (car form) symbols)
            (let ((tail (cdr form)) found)
              (while (and (consp tail) (not found))
                (setq found (anvil-package-lint--builtin-reference (car tail) symbols)
                      tail (cdr tail)))
              found))))))

(defun anvil-package-lint-core-references (file symbols)
  "Report direct optional builtin calls in core FILE, including same-line calls."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (let (diagnostics)
      (condition-case nil
          (while t
            (let* ((start (point))
                   (form (read (current-buffer)))
                   (builtin (anvil-package-lint--builtin-reference form symbols)))
              (when builtin
                (push (list (line-number-at-pos start) 0 'error
                            (format "Direct optional builtin `%s' must stay behind the reviewed backend boundary" builtin))
                      diagnostics))))
        (end-of-file nil))
      (nreverse diagnostics))))

(defun anvil-package-lint-run ()
  "Audit all modules against their explicit profile; return diagnostic count."
  (let* ((root anvil-package-lint-root)
         (manifest (json-read-file (expand-file-name "scripts/package-lint-profiles.json" root)))
         (optional (append (alist-get 'optional_files manifest) nil))
         (builtins (mapcar #'intern (append (alist-get 'builtin_symbols manifest) nil)))
         (core-version (alist-get 'core_emacs manifest))
         (optional-version (alist-get 'optional_emacs manifest))
         (main (expand-file-name "anvil.el" root))
         (files (directory-files root t "\\`anvil.*\\.el\\'"))
         (temporary (make-temp-file "anvil-lint-profile-" t))
         (optional-main (expand-file-name "anvil.el" temporary))
         (count 0) (core-count 0) (optional-count 0))
    (unless (and (equal core-version "28.2") (equal optional-version "29.1")
                 (= (length optional) (length (delete-dups (copy-sequence optional))))
                 (cl-every (lambda (file) (member (expand-file-name file root) files)) optional))
      (error "Invalid package-lint manifest"))
    (unwind-protect
        (progn
          (with-temp-buffer
            (insert-file-contents main)
            (goto-char (point-min))
            (unless (search-forward "Package-Requires: ((emacs \"28.2\"))" nil t)
              (error "Core package floor must stay at Emacs 28.2"))
            (replace-match "Package-Requires: ((emacs \"29.1\"))" t t)
            (write-region (point-min) (point-max) optional-main nil 'silent))
          (dolist (file files)
            (let* ((is-optional (member (file-name-nondirectory file) optional))
                   (diagnostics
                    (append (anvil-package-lint-file file (if is-optional optional-main main))
                            (unless is-optional
                              (anvil-package-lint-core-references file builtins)))))
              (if is-optional (cl-incf optional-count) (cl-incf core-count))
              (dolist (diagnostic diagnostics)
                (cl-incf count)
                (princ (format "%s:%d:%d: %s: %s\n"
                               (file-name-nondirectory file) (nth 0 diagnostic)
                               (nth 1 diagnostic) (nth 2 diagnostic) (nth 3 diagnostic))))))
          (princ (format "package-lint: core28=%d optional29=%d diagnostics=%d\n"
                         core-count optional-count count)))
      (delete-directory temporary t))
    count))

(defun anvil-package-lint-batch ()
  "Run both profiles, failing on every warning or error."
  (kill-emacs (if (zerop (anvil-package-lint-run)) 0 1)))

(provide 'anvil-package-lint)
;;; anvil-package-lint.el ends here
