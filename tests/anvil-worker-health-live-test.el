;;; anvil-worker-health-live-test.el --- Real nonblocking monitor test -*- lexical-binding: t; -*-

(require 'ert)

(defconst anvil-worker-health-live-test--directory
  (file-name-directory (or load-file-name buffer-file-name)))

(ert-deftest anvil-worker-health-live-test/foreign-client-and-stop ()
  "An unresponsive worker must not stall a different real client."
  (let ((python (or (executable-find "python3") (executable-find "python")
                    (ert-skip "Python unavailable")))
        (emacs (expand-file-name invocation-name invocation-directory)))
    (with-temp-buffer
      (let ((status (call-process
                     python nil t nil
                     (expand-file-name "anvil-worker-health-live-test.py"
                                       anvil-worker-health-live-test--directory)
                     "--emacs" emacs)))
        (ert-info ((format "Live health status=%S output=%s" status (buffer-string)))
          (should (equal status 0))
          (should (string-match-p "PASS" (buffer-string))))))))

(provide 'anvil-worker-health-live-test)
;;; anvil-worker-health-live-test.el ends here
