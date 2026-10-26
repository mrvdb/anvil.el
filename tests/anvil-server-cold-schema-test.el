;;; anvil-server-cold-schema-test.el --- Cold schema dependency regressions -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(require 'anvil-server)

(defun anvil-server-cold-schema-test--handler (_context name &optional _private count)
  "Cold schema fixture.

MCP Parameters:
  name - visible name
  count - (integer) optional count"
  (list name count))

(ert-deftest anvil-server-cold-schema-register-without-cl-seq-autoload ()
  "A cold registration builds and caches a real schema without cl-remove-if."
  (let ((anvil-server--tools (make-hash-table :test 'equal))
        (anvil-server--tools-list-cache (make-hash-table :test 'equal))
        (anvil-server--schema-cache nil)
        (anvil-server--schema-cache-loaded t))
    (cl-letf (((symbol-function 'cl-remove-if)
               (lambda (&rest _args) (error "cl-seq autoload must remain blocked")))
              ((symbol-function 'anvil-server--schema-cache-write) #'ignore))
      (anvil-server-register-tool
       #'anvil-server-cold-schema-test--handler
       :id "cold-fixture" :description "Cold fixture" :server-id "cold-test")
      (let* ((tool (gethash "cold-fixture" (gethash "cold-test" anvil-server--tools)))
             (schema (plist-get tool :schema))
             (properties (alist-get 'properties schema)))
        (should (equal (alist-get 'required schema) ["name"]))
        (should (= (length properties) 2))
        (should (equal (alist-get 'type (cdr (assoc "name" properties))) "string"))
        (should (equal (alist-get 'type (cdr (assoc "count" properties))) "integer"))
        (should-not (assoc "_context" properties))
        (should-not (assoc "_private" properties))
        (should (stringp (plist-get tool :json-fragment)))
        (should (= (length anvil-server--schema-cache) 1))
        (should (equal (plist-get (car anvil-server--schema-cache) :schema) schema))))))

(ert-deftest anvil-server-cold-schema-cache-filter-preserves-order-and-input ()
  "Replacing a cache identity keeps other signatures in their original order."
  (let* ((original (list (list :id "keep-a" :signature "a")
                         (list :id "replace" :signature "old")
                         (list :id "replace" :signature "other")
                         (list :id "keep-b" :signature "b")
                         (list :id "replace" :signature "old")))
         (snapshot (copy-tree original))
         (anvil-server--schema-cache original)
         (anvil-server--schema-cache-loaded t))
    (cl-letf (((symbol-function 'cl-remove-if)
               (lambda (&rest _args) (error "cl-seq autoload must remain blocked")))
              ((symbol-function 'anvil-server--schema-cache-write) #'ignore))
      (anvil-server--schema-cache-put "replace" "old" '((type . "object")) "{}")
      (should (equal original snapshot))
      (should (equal (mapcar (lambda (entry) (plist-get entry :signature))
                            anvil-server--schema-cache)
                     '("old" "a" "other" "b"))))))

(provide 'anvil-server-cold-schema-test)
;;; anvil-server-cold-schema-test.el ends here
