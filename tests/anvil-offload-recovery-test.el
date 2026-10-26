;;; anvil-offload-recovery-test.el --- Post-kill ownership -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'anvil-offload)
(require 'anvil-server)
(require 'anvil-offload-stub)

(defconst anvil-offload-recovery-test--directory
  (file-name-directory (or load-file-name buffer-file-name)))

(defmacro anvil-offload-recovery-test--with-state (&rest body)
  "Run BODY with isolated custody and reap every real fixture child."
  (declare (indent 0))
  `(let ((anvil-offload--pool nil)
         (anvil-offload--pending (make-hash-table :test #'eql))
         (anvil-offload--round-robin 0)
         (anvil-offload--next-id 0)
         (anvil-offload--pool-retiring-p nil)
         (anvil-offload--pool-cleanup-active-p nil)
         (anvil-offload--submission-active-p nil)
         (anvil-offload--transaction-state (vector nil nil))
         (anvil-offload--stop-retiring-p nil)
         (anvil-offload--retired-pools nil)
         (anvil-offload--ownership-table-registry nil)
         (anvil-offload--fallback-processes (make-hash-table :test #'eq))
         (anvil-offload--isolated-processes (make-hash-table :test #'eq))
         (anvil-offload-spawn-environment-function nil))
     (unwind-protect
         (progn ,@body)
       (anvil-offload-stop-repl)
       (let ((deadline (+ (float-time) 1)))
         (while (and (> (hash-table-count anvil-offload--pending) 0)
                     (< (float-time) deadline))
           (accept-process-output nil 0.01)))
       (should-not (anvil-offload--owned-auxiliary-processes))
       (should (= 0 (hash-table-count anvil-offload--pending))))))

(defun anvil-offload-recovery-test--state ()
  "Return fixture process ownership and pending state without payloads."
  (list :slots (anvil-offload-pool-status)
        :pending
        (let (items)
          (maphash (lambda (id future)
                     (push (list :id id :status (anvil-future-status future)
                                 :pid (process-id (anvil-future--process future))) items))
                   (anvil-offload--ensure-pending))
          items)))

(defun anvil-offload-recovery-test--exercise ()
  "Hold both termination paths through timeout; return responses and custody.
This controlled timing window uses real workers and real termination.  It
does not establish the historical macOS failure's root cause."
  (anvil-offload-recovery-test--with-state
   (let ((anvil-offload--pool nil) (anvil-offload--pending nil)
        (anvil-offload--round-robin 0) (anvil-offload-pool-size 1)
        (anvil-server--tools (make-hash-table :test #'equal))
        (anvil-server--tools-list-cache (make-hash-table :test #'equal))
        (native-kill (symbol-function 'kill-process))
        (native-send (symbol-function 'process-send-string))
        (metrics (make-anvil-server-metrics))
        (old nil) (new nil) (held nil) (before nil) (timeout nil)
        (after nil) (follow nil) (at-kill nil) (after-send nil)
        (old-death-observed nil) (reused nil) (retiring-at-kill nil) (result nil))
    (unwind-protect
        (progn
          (anvil-server-register-tool
           'anvil-offload-stub-pid-tool :id "pid" :description "PID fixture"
           :server-id "recovery" :offload t :offload-timeout 5
           :offload-require 'anvil-offload-stub
           :offload-load-path (list anvil-offload-recovery-test--directory))
          (anvil-server-register-tool
           'anvil-offload-stub-sleep :id "sleep" :description "Timeout fixture"
           :server-id "recovery" :offload t :offload-timeout 0.05
           :offload-require 'anvil-offload-stub
           :offload-load-path (list anvil-offload-recovery-test--directory))
          (setq before (anvil-server--handle-tools-call
                        "before" '((name . "pid") (arguments . ((tag . "before"))))
                        metrics "recovery")
                old (aref anvil-offload--pool 0))
          (cl-letf (((symbol-function 'kill-process)
                     (lambda (proc &optional _current-group)
                       (setq held proc)))
                    ((symbol-function 'delete-process)
                     (lambda (proc) (setq held proc))))
            (setq timeout (anvil-server--handle-tools-call
                           "timeout" '((name . "sleep") (arguments . ((_ignored . "x"))))
                           metrics "recovery")))
          (setq at-kill (anvil-offload-recovery-test--state)
                retiring-at-kill (process-get old 'anvil-offload-retiring))
          (cl-letf (((symbol-function 'process-send-string)
                     (lambda (proc string)
                       (when held
                         (setq reused (eq proc held))
                         (when (process-live-p held)
                           (funcall native-kill held))
                         (let ((deadline (+ (float-time) 1)))
                           (while (and (process-live-p held) (< (float-time) deadline))
                             (accept-process-output held 0.01)))
                         (setq old-death-observed (not (process-live-p held))
                               held nil))
                       (funcall native-send proc string))))
            (setq after (anvil-server--handle-tools-call
                         "after" '((name . "pid") (arguments . ((tag . "after-é"))))
                         metrics "recovery")))
          (setq new (aref anvil-offload--pool 0)
                after-send (anvil-offload-recovery-test--state)
                follow (anvil-server--handle-tools-call
                        "follow" '((name . "pid") (arguments . ((tag . "follow-é"))))
                        metrics "recovery")
                result (list :before before :timeout timeout :after after :follow follow
                             :at-kill at-kill :after-send after-send
                             :retiring-at-kill retiring-at-kill
                             :reused reused :old-death-observed old-death-observed
                             :old-pid (process-id old)
                             :new-pid (and new (process-id new)))))
      (dolist (proc (delete-dups (delq nil (append (list old new held)
                                                  (append anvil-offload--pool nil)))))
        (when (process-live-p proc) (funcall native-kill proc))
        (let ((deadline (+ (float-time) 1)))
          (while (and (process-live-p proc) (< (float-time) deadline))
            (accept-process-output proc 0.01)))
        (when (process-live-p proc) (error "Fixture worker remains alive")))
      (accept-process-output nil 0.01)
      (setq result (plist-put result :pending-after-cleanup
                              (hash-table-count (anvil-offload--ensure-pending)))))
    result)))

(ert-deftest anvil-offload-recovery-never-sends-to-retiring-worker ()
  (let* ((result (anvil-offload-recovery-test--exercise))
         (timeout (json-read-from-string (plist-get result :timeout)))
         (after (json-read-from-string (plist-get result :after)))
         (follow (json-read-from-string (plist-get result :follow))))
    (ert-info ((format "recovery evidence: %S" result))
      (should (eq t (alist-get 'isError (alist-get 'result timeout))))
      (should (string-match-p
               "Offload budget exceeded"
               (alist-get 'text (aref (alist-get 'content (alist-get 'result timeout)) 0))))
      (should (plist-get result :old-death-observed))
      (should (plist-get result :retiring-at-kill))
      (should (plist-get (car (plist-get (plist-get result :at-kill) :slots)) :alive))
      (should-not (plist-get (plist-get result :at-kill) :pending))
      (should-not (plist-get result :reused))
      (should-not (alist-get 'error after))
      (should-not (eq t (alist-get 'isError (alist-get 'result after))))
      (should (string-match-p "tag:after-é"
                              (alist-get 'text (aref (alist-get 'content (alist-get 'result after)) 0))))
      (should (string-match-p "tag:follow-é"
                              (alist-get 'text (aref (alist-get 'content (alist-get 'result follow)) 0))))
      (should-not (= (plist-get result :old-pid) (plist-get result :new-pid)))
      (should (= (plist-get result :pending-after-cleanup) 0)))))

(ert-deftest anvil-offload-recovery-detaches-only-owned-slots ()
  (anvil-offload-recovery-test--with-state
    (let* ((anvil-offload-pool-size 2)
           (future (anvil-offload '(sleep-for 30)))
           (other (anvil-offload '(sleep-for 30)))
           (owner (anvil-future--process future))
           (peer (anvil-future--process other)))
      ;; Exercise all references to the exact child, including duplicate slots.
      (setq anvil-offload--pool (vector owner peer owner))
      (anvil-future-kill future)
      (should-not (process-live-p owner))
      (should (equal anvil-offload--pool (vector nil peer nil)))
      (should (eq (anvil-future-status future) 'killed))
      (should-not (gethash (anvil-future--id future) anvil-offload--pending))
      (should (eq (gethash (anvil-future--id other) anvil-offload--pending) other))
      (should (eq (anvil-future-status other) 'pending))
      (should (process-live-p peer)))))

(ert-deftest anvil-offload-recovery-failed-kill-preserves-ownership ()
  (anvil-offload-recovery-test--with-state
    (let* ((anvil-offload-pool-size 1)
           (future (anvil-offload '(sleep-for 30)))
           (owner (anvil-future--process future)))
      (cl-letf (((symbol-function 'kill-process)
                 (lambda (_proc &optional _group) (error "Fixture kill failed")))
                ((symbol-function 'delete-process)
                 (lambda (_proc) (error "Fixture delete failed"))))
        (anvil-future-kill future)
        ;; Result delivery settles once; custody persists independently until reap.
        (should (eq (anvil-future-status future) 'killed))
        (should (eq (anvil-future--terminal-reason future) 'killed))
        (should-not (gethash (anvil-future--id future) anvil-offload--pending))
        (should (eq owner (aref anvil-offload--pool 0)))
        (should (process-live-p owner))
        (should (process-get owner 'anvil-offload-retiring))
        (should (memq owner (anvil-offload--owned-auxiliary-processes)))
        (should-error (anvil-offload--ensure-slot 0)))
      ;; The next dispatch retries real deletion before publishing a replacement.
      (let ((replacement (anvil-offload--ensure-slot 0)))
        (should-not (eq owner replacement))
        (should-not (process-live-p owner))
        (should-not (memq owner (process-list)))
        (should-not (memq owner (anvil-offload--owned-auxiliary-processes)))
        (should (process-live-p replacement)))
      (should (eq (anvil-future-status future) 'killed)))))

(provide 'anvil-offload-recovery-test)
;;; anvil-offload-recovery-test.el ends here
