;;; anvil-package-lint-test.el --- Profile and backend contract tests -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(when-let ((directory (getenv "PACKAGE_LINT_DIR")))
  (add-to-list 'load-path directory))
(add-to-list 'load-path (expand-file-name "../scripts" (file-name-directory (or load-file-name buffer-file-name))))
(require 'anvil-package-lint)
(require 'anvil-builtin-backend)
(require 'anvil-treesit-backend)

(defun anvil-package-lint-test--fixture (main &optional call)
  "Lint injected CALL, or a direct Emacs 29 call, against MAIN."
  (let ((file (make-temp-file "anvil-lint-negative-" nil ".el")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert ";;; fixture.el --- Profile fixture -*- lexical-binding: t; -*-\n"
                    ";; Keywords: tools\n;;; Commentary:\n;; Fixture.\n;;; Code:\n"
                    "(defun anvil-fixture ()\n  "
                    (or call "(sqlite-select nil \"select 1\")") ")\n"
                    "(provide 'fixture)\n;;; fixture.el ends here\n"))
          (anvil-package-lint-file file main))
      (delete-file file))))

(ert-deftest anvil-package-lint-core-negative-control ()
  "A new direct optional builtin in core must fail, not be suppressed."
  (let* ((main (expand-file-name "anvil.el" anvil-package-lint-root))
         (diagnostics (anvil-package-lint-test--fixture main)))
    (should (cl-some (lambda (item)
                       (and (eq (nth 2 item) 'error)
                            (string-match-p "29.1.*sqlite-select" (nth 3 item))))
                     diagnostics))))

(ert-deftest anvil-package-lint-same-line-negative-control ()
  "The structural guard catches calls that share a line with a definition."
  (let ((file (make-temp-file "anvil-lint-inline-" nil ".el")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "(defun anvil-fixture () (sqlite-select nil \"sql\"))\n"))
          (should (anvil-package-lint-core-references file '(sqlite-select))))
      (delete-file file))))

(ert-deftest anvil-package-lint-quoted-indirect-negative-control ()
  "Both linters reject quoted indirect callees while preserving probes/data."
  (let ((main (expand-file-name "anvil.el" anvil-package-lint-root)))
    (dolist (call '("(funcall 'sqlite-open \"db\")"
                    "(apply 'sqlite-open '(\"db\"))"))
      (should
       (cl-some (lambda (item)
                  (and (eq (nth 2 item) 'error)
                       (string-match-p "29.1.*sqlite-open" (nth 3 item))))
                (anvil-package-lint-test--fixture main call)))
      (should (anvil-package-lint--builtin-reference (read call) '(sqlite-open)))))
  (should-not (anvil-package-lint--builtin-reference
               '(fboundp 'sqlite-open) '(sqlite-open)))
  (should-not (anvil-package-lint--builtin-reference
               '(list 'sqlite-open '(sqlite-open)) '(sqlite-open))))

(ert-deftest anvil-package-lint-availability-probes-are-core-compatible ()
  "Quoted symbols in availability guards are allowed without weakening calls."
  (should-not
   (anvil-package-lint--builtin-reference
    '(and (fboundp 'sqlite-select) (fboundp 'treesit-node-type))
    '(sqlite-select treesit-node-type)))
  (should
   (anvil-package-lint--builtin-reference
    '(mapcar #'treesit-node-type nodes) '(treesit-node-type))))

(ert-deftest anvil-package-lint-optional-profile-positive-control ()
  "The same builtin is accepted only under the explicit optional profile."
  (let* ((directory (make-temp-file "anvil-lint-optional-" t))
         (main (expand-file-name "anvil.el" directory)))
    (unwind-protect
        (progn
          (with-temp-file main
            (insert-file-contents (expand-file-name "anvil.el" anvil-package-lint-root))
            (goto-char (point-min))
            (search-forward "((emacs \"28.2\"))")
            (replace-match "((emacs \"29.1\"))" t t))
          (should-not (cl-some (lambda (item) (string-match-p "sqlite-select" (nth 3 item)))
                              (anvil-package-lint-test--fixture main))))
      (delete-directory directory t))))

(ert-deftest anvil-package-lint-backend-delegates-current-builtins ()
  "Adapters retain arguments, return values and dynamic builtin replacements."
  (cl-letf (((symbol-function 'sqlite-select) (lambda (&rest args) (cons 'sqlite args)))
            ((symbol-function 'treesit-node-type) (lambda (&rest args) (cons 'tree args))))
    (should (equal (anvil-builtin-sqlite-select 'db "sql" '(1) 'list)
                   '(sqlite db "sql" (1) list)))
    (should (equal (anvil-builtin-treesit-node-type 'node) '(tree node)))))

(ert-deftest anvil-package-lint-backend-preserves-missing-builtin ()
  "Loading the optional boundary never manufactures builtin availability."
  (cl-letf (((symbol-function 'sqlite-select) nil))
    (should-not (fboundp 'sqlite-select))
    (should-error (anvil-builtin-sqlite-select nil "sql") :type 'void-function)))

(ert-deftest anvil-package-lint-plist-compatibility ()
  "The core plist predicate handles empty, odd and improper lists."
  (dolist (object '(nil (:type "node") (:a 1 :b 2)))
    (should (anvil-treesit-backend--plist-p object)))
  (dolist (object '((:type) (:a 1 :b) (:a . 1) [1 2] symbol))
    (should-not (anvil-treesit-backend--plist-p object))))

(provide 'anvil-package-lint-test)
;;; anvil-package-lint-test.el ends here
