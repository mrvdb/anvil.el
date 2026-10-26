;;; anvil-offload-preview-test.el --- Literal diagnostic escaping -*- lexical-binding: t; -*-

(require 'ert)
(require 'anvil-offload)

(ert-deftest anvil-offload-line-preview-escapes-newlines-literally ()
  "Diagnostic previews flatten CR/LF without interpreting replacement escapes."
  (should (equal (anvil-offload--line-preview "first\r\nsecond\nthird")
                 "first\\nsecond\\nthird")))

(provide 'anvil-offload-preview-test)
;;; anvil-offload-preview-test.el ends here
