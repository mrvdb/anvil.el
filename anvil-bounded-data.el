;;; anvil-bounded-data.el --- Pure bounded snapshots of Lisp data -*- lexical-binding: t; -*-

;; Copyright (C) 2025-2026 zawatton

;; This file is part of anvil.el.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Code:

(require 'cl-lib)

(defvar anvil-bounded-data--snapshot-node-limit 512)
(defvar anvil-bounded-data--snapshot-depth-limit 8)
(defvar anvil-bounded-data--snapshot-char-limit 4096)

(defun anvil-bounded-data--bounded-snapshot (value &optional maxchars)
  "Copy VALUE into a bounded printable data tree.
MAXCHARS limits leaf characters; return :value, :nodes, and :chars."
  (let ((left (if (and (integerp maxchars) (>= maxchars 0))
                  (min maxchars anvil-bounded-data--snapshot-char-limit)
                anvil-bounded-data--snapshot-char-limit))
        (chars 0) (nodes 0) (path (make-hash-table :test #'eq)))
    (cl-labels
        ((token (s)
           (let ((n (min left (length s))))
             (setq left (- left n) chars (+ chars n))
             (substring-no-properties s 0 n)))
         (walk (x depth)
           (cond
            ((>= nodes anvil-bounded-data--snapshot-node-limit)
             (token "<nodes>"))
            (t
             (setq nodes (1+ nodes))
             (cond
              ((stringp x)
               (let ((out (token x))) (set-text-properties 0 (length out) nil out) out))
              ((symbolp x)
               (let ((n (length (symbol-name x))))
                 (if (and (<= n 128) (<= n left))
                     (progn (setq left (- left n) chars (+ chars n)) x)
                   (token "<symbol>"))))
              ((or (null x) (eq x t) (and (integerp x) (<= most-negative-fixnum x most-positive-fixnum))
                   (floatp x)) x)
              ((or (integerp x) (hash-table-p x) (recordp x)) (token "<opaque>"))
              ((or (consp x) (vectorp x))
               (cond ((>= depth anvil-bounded-data--snapshot-depth-limit) (token "<depth>"))
                     ((gethash x path) (token "<cycle>"))
                     (t
                      (puthash x t path)
                      (let ((out
                             (if (consp x)
                                 (cons (walk (car x) (1+ depth))
                                       (walk (cdr x) (1+ depth)))
                               (let ((i 0) (n (length x)) (items nil))
                                 (while (and (< i n) (< nodes anvil-bounded-data--snapshot-node-limit))
                                   (push (walk (aref x i) (1+ depth)) items)
                                   (setq i (1+ i)))
                                 (vconcat (nreverse items))))))
                        (remhash x path) out))))
              (t (token "<opaque>")))))))
      (list :value (walk value 0) :nodes nodes :chars chars))))

(provide 'anvil-bounded-data)
;;; anvil-bounded-data.el ends here
