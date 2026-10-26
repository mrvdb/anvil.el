;;; anvil-builtin-backend.el --- Optional builtin SQLite and tree-sitter adapters -*- lexical-binding: t; -*-

;;; Commentary:

;; This optional Emacs 29 implementation boundary keeps callers with alternate
;; backends loadable on Emacs 28.  Callers retain their original availability
;; checks; every adapter delegates to the current builtin, including test stubs.

;;; Code:

(defun anvil-builtin-sqlite-available-p (&rest args)
  "Delegate ARGS to `sqlite-available-p'."
  (apply #'sqlite-available-p args))

(defun anvil-builtin-sqlite-close (&rest args)
  "Delegate ARGS to `sqlite-close'."
  (apply #'sqlite-close args))

(defun anvil-builtin-sqlite-execute (&rest args)
  "Delegate ARGS to `sqlite-execute'."
  (apply #'sqlite-execute args))

(defun anvil-builtin-sqlite-more-p (&rest args)
  "Delegate ARGS to `sqlite-more-p'."
  (apply #'sqlite-more-p args))

(defun anvil-builtin-sqlite-next (&rest args)
  "Delegate ARGS to `sqlite-next'."
  (apply #'sqlite-next args))

(defun anvil-builtin-sqlite-open (&rest args)
  "Delegate ARGS to `sqlite-open'."
  (apply #'sqlite-open args))

(defun anvil-builtin-sqlite-select (&rest args)
  "Delegate ARGS to `sqlite-select'."
  (apply #'sqlite-select args))

(defun anvil-builtin-sqlitep (&rest args)
  "Delegate ARGS to `sqlitep'."
  (apply #'sqlitep args))

(defun anvil-builtin-treesit-node-at (&rest args)
  "Delegate ARGS to `treesit-node-at'."
  (apply #'treesit-node-at args))

(defun anvil-builtin-treesit-node-check (&rest args)
  "Delegate ARGS to `treesit-node-check'."
  (apply #'treesit-node-check args))

(defun anvil-builtin-treesit-node-child (&rest args)
  "Delegate ARGS to `treesit-node-child'."
  (apply #'treesit-node-child args))

(defun anvil-builtin-treesit-node-child-by-field-name (&rest args)
  "Delegate ARGS to `treesit-node-child-by-field-name'."
  (apply #'treesit-node-child-by-field-name args))

(defun anvil-builtin-treesit-node-child-count (&rest args)
  "Delegate ARGS to `treesit-node-child-count'."
  (apply #'treesit-node-child-count args))

(defun anvil-builtin-treesit-node-children (&rest args)
  "Delegate ARGS to `treesit-node-children'."
  (apply #'treesit-node-children args))

(defun anvil-builtin-treesit-node-end (&rest args)
  "Delegate ARGS to `treesit-node-end'."
  (apply #'treesit-node-end args))

(defun anvil-builtin-treesit-node-language (&rest args)
  "Delegate ARGS to `treesit-node-language'."
  (apply #'treesit-node-language args))

(defun anvil-builtin-treesit-node-next-sibling (&rest args)
  "Delegate ARGS to `treesit-node-next-sibling'."
  (apply #'treesit-node-next-sibling args))

(defun anvil-builtin-treesit-node-on (&rest args)
  "Delegate ARGS to `treesit-node-on'."
  (apply #'treesit-node-on args))

(defun anvil-builtin-treesit-node-parent (&rest args)
  "Delegate ARGS to `treesit-node-parent'."
  (apply #'treesit-node-parent args))

(defun anvil-builtin-treesit-node-start (&rest args)
  "Delegate ARGS to `treesit-node-start'."
  (apply #'treesit-node-start args))

(defun anvil-builtin-treesit-node-text (&rest args)
  "Delegate ARGS to `treesit-node-text'."
  (apply #'treesit-node-text args))

(defun anvil-builtin-treesit-node-type (&rest args)
  "Delegate ARGS to `treesit-node-type'."
  (apply #'treesit-node-type args))

(defun anvil-builtin-treesit-parser-create (&rest args)
  "Delegate ARGS to `treesit-parser-create'."
  (apply #'treesit-parser-create args))

(defun anvil-builtin-treesit-parser-root-node (&rest args)
  "Delegate ARGS to `treesit-parser-root-node'."
  (apply #'treesit-parser-root-node args))

(defun anvil-builtin-treesit-query-capture (&rest args)
  "Delegate ARGS to `treesit-query-capture'."
  (apply #'treesit-query-capture args))

(provide 'anvil-builtin-backend)
;;; anvil-builtin-backend.el ends here
