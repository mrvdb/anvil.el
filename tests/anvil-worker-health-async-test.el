;;; anvil-worker-health-async-test.el --- Async health ownership tests -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(require 'anvil-worker)

(defmacro anvil-health-test--pool (&rest body)
  "Run BODY in an isolated demanded three-worker pool with real probe children."
  (declare (indent 0))
  `(let ((anvil-worker--pool nil)
         (server-use-tcp t)
         (anvil-worker--health-generation 0)
         (anvil-worker--health-queue nil)
         (anvil-worker--health-probes nil)
         (anvil-worker--health-sweep nil)
         (anvil-worker--health-pumping nil)
         (anvil-worker--health-cursor 0)
         (anvil-worker--health-timer nil)
         (anvil-worker-read-pool-size 3)
         (anvil-worker-write-pool-size 0)
         (anvil-worker-batch-pool-size 0)
         (anvil-worker--spawn-times (make-hash-table :test #'equal))
         (anvil-worker--owned-processes (make-hash-table :test #'equal))
         (anvil-worker-alive-check-timeout 0.2)
         (original-make-process (symbol-function 'make-process))
         (real-emacs (expand-file-name invocation-name invocation-directory))
         children spawned)
     (anvil-worker--init-pool)
     (anvil-worker--map-pool (lambda (worker) (plist-put worker :demanded t)))
     (unwind-protect
         (cl-letf (((symbol-function 'make-process)
                    (lambda (&rest args)
                      (setq args (plist-put args :command
                                            (list real-emacs "-Q" "--batch"
                                                  "--eval" "(sleep-for 30)")))
                      (let ((proc (apply original-make-process args)))
                        (push proc children) proc)))
                   ((symbol-function 'anvil-worker--quick-alive-p) (lambda (_) t))
                   ((symbol-function 'anvil-worker--log) #'ignore)
                   ((symbol-function 'anvil-worker--spawn-worker)
                    (lambda (worker) (push worker spawned))))
           ,@body)
       (anvil-worker-health-timer-stop)
       (dolist (child children)
         (when (process-live-p child) (delete-process child))))))

(ert-deftest anvil-health-async-returns-and-bounds-overlap ()
  "The timer returns while real children remain pending; repeated ticks coalesce."
  (anvil-health-test--pool
    (cl-letf (((symbol-function 'accept-process-output)
               (lambda (&rest _) (ert-fail "Health sweep waited for output")))
              ((symbol-function 'sit-for)
               (lambda (&rest _) (ert-fail "Health sweep yielded synchronously")))
              ((symbol-function 'sleep-for)
               (lambda (&rest _) (ert-fail "Health sweep slept"))))
      (anvil-worker--health-check))
    (should (= (length children) 2))
    (should (cl-every #'process-live-p children))
    (anvil-worker--health-check)
    (should (= (length children) 2))
    (should (= (length anvil-worker--health-probes) 2))))

(ert-deftest anvil-health-async-stop-invalidates-resources-and-callbacks ()
  (anvil-health-test--pool
    (anvil-worker--health-check)
    (let ((records (copy-sequence anvil-worker--health-probes)))
      (anvil-worker-health-timer-stop)
      (should-not anvil-worker--health-probes)
      (should-not anvil-worker--health-sweep)
      (dolist (record records)
        (should-not (process-live-p (plist-get record :process)))
        (should-not (buffer-live-p (plist-get record :buffer)))
        (should-not (memq (plist-get record :timer) timer-list))
        (anvil-worker--health-finish record nil))
      (should-not spawned))))

(ert-deftest anvil-health-async-timeout-fairness-and-busy-guard ()
  (anvil-health-test--pool
    (let ((worker (anvil-worker--worker :read 0)))
      (plist-put worker :busy t)
      (anvil-worker--health-check)
      (let ((deadline (+ (float-time) 3)))
        (while (and anvil-worker--health-sweep (< (float-time) deadline))
          (accept-process-output nil 0.03)))
      (should-not anvil-worker--health-sweep)
      (should (= 0 (plist-get worker :hung-checks)))
      (should (= 1 (plist-get (anvil-worker--worker :read 1) :hung-checks)))
      (should-not spawned)
      (anvil-worker--health-check)
      (should (cl-find (anvil-worker--worker :read 2) anvil-worker--health-probes
                       :key (lambda (record) (plist-get record :worker)))))))

(ert-deftest anvil-health-async-pool-replacement-disposes-old-generation ()
  (anvil-health-test--pool
    (anvil-worker--health-check)
    (let ((record (car anvil-worker--health-probes)))
      (anvil-worker--init-pool)
      (anvil-worker--health-finish record nil)
      (should-not spawned)
      (should-not anvil-worker--health-probes)
      (should-not (process-live-p (plist-get record :process))))))

(ert-deftest anvil-health-async-constructor-error-cleans-sweep ()
  (anvil-health-test--pool
    (cl-letf (((symbol-function 'make-process) (lambda (&rest _) (error "constructor"))))
      (should-error (anvil-worker--health-check)))
    (should-not anvil-worker--health-probes)
    (should-not anvil-worker--health-sweep)
    (should-not (get-buffer " *anvil-health-probe*"))))

(ert-deftest anvil-health-async-constructor-quit-cleans-sweep ()
  (anvil-health-test--pool
    (cl-letf (((symbol-function 'make-process) (lambda (&rest _) (signal 'quit nil))))
      (should (eq 'quit (condition-case nil (anvil-worker--health-check)
                         (quit 'quit)))))
    (should-not anvil-worker--health-probes)
    (should-not anvil-worker--health-sweep)))

(ert-deftest anvil-health-async-lazy-and-missing-endpoints ()
  (anvil-health-test--pool
    (plist-put (anvil-worker--worker :read 0) :demanded nil)
    (cl-letf (((symbol-function 'anvil-worker--quick-alive-p) (lambda (_) nil)))
      (anvil-worker--health-check))
    (should (= 2 (length spawned)))
    (should-not children)
    (should-not anvil-worker--health-sweep)))

(ert-deftest anvil-health-async-stale-result-does-not-recover ()
  (anvil-health-test--pool
    (anvil-worker--health-check)
    (let ((record (car anvil-worker--health-probes)))
      (setq anvil-worker--pool (copy-sequence anvil-worker--pool))
      (anvil-worker--health-finish record t)
      (should-not (plist-get (plist-get record :worker) :last-state))
      (should-not spawned))))

(ert-deftest anvil-health-async-reentrant-stop-during-construction ()
  (anvil-health-test--pool
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest args)
                 (anvil-worker-health-timer-stop)
                 (let ((proc (apply original-make-process
                                    (plist-put args :command
                                               (list real-emacs "-Q" "--batch"
                                                     "--eval" "(sleep-for 30)")))))
                   (push proc children) proc))))
      (anvil-worker--health-check))
    (should (= 1 (length children)))
    (should-not (process-live-p (car children)))
    (should-not anvil-worker--health-probes)))

(ert-deftest anvil-health-async-reentrant-stop-during-timer-construction ()
  (anvil-health-test--pool
    (let ((original-timer (symbol-function 'run-at-time)) timers)
      (cl-letf (((symbol-function 'run-at-time)
                 (lambda (&rest args)
                   (anvil-worker-health-timer-stop)
                   (let ((timer (apply original-timer args)))
                     (push timer timers) timer))))
        (anvil-worker--health-check))
      (should-not anvil-worker--health-probes)
      (should-not (process-live-p (car children)))
      (should (cl-every (lambda (timer) (not (memq timer timer-list))) timers)))))

(ert-deftest anvil-health-async-reentrant-stop-during-sentinel-setup ()
  (anvil-health-test--pool
    (let ((original-setter (symbol-function 'set-process-sentinel)) stopped)
      (cl-letf (((symbol-function 'set-process-sentinel)
                 (lambda (proc sentinel)
                   (unless (or stopped (eq sentinel #'ignore))
                     (setq stopped t)
                     (anvil-worker-health-timer-stop))
                   (funcall original-setter proc sentinel))))
        (anvil-worker--health-check))
      (should stopped)
      (should-not anvil-worker--health-probes)
      (should (cl-every (lambda (proc) (not (process-live-p proc))) children)))))

(ert-deftest anvil-health-async-peer-error-and-quit-cleanup ()
  (dolist (failure '(error quit))
    (anvil-health-test--pool
      (let ((original-constructor (symbol-function 'make-process)) (count 0))
        (cl-letf (((symbol-function 'make-process)
                   (lambda (&rest args)
                     (if (= (cl-incf count) 2) (signal failure '("synthetic"))
                       (apply original-constructor args)))))
          (should (eq failure
                      (condition-case nil (anvil-worker--health-check)
                        (error 'error) (quit 'quit))))))
      (should (= 1 (length children)))
      (should-not (process-live-p (car children)))
      (should-not anvil-worker--health-probes)
      (should-not anvil-worker--health-sweep))))

(ert-deftest anvil-health-async-replaced-worker-endpoint-and-owner-are-inert ()
  (dolist (replacement '(worker endpoint owner))
    (anvil-health-test--pool
      (anvil-worker--health-check)
      (let* ((record (car anvil-worker--health-probes))
             (worker (plist-get record :worker)))
        (pcase replacement
          ('worker (aset (anvil-worker--lane-pool :read) (plist-get worker :index)
                         (copy-sequence worker)))
          ('endpoint (plist-put worker :server-file "replacement-endpoint"))
          ('owner (puthash (plist-get worker :name) 'replacement-owner
                           anvil-worker--owned-processes)))
        (anvil-worker--health-finish record nil)
        (should-not (plist-get worker :last-state))
        (should (= 0 (plist-get worker :hung-checks)))
        (should-not spawned)))))

(ert-deftest anvil-health-async-cancel-release-error-still-drains-peers ()
  (anvil-health-test--pool
    (anvil-worker--health-check)
    (let ((original-setter (symbol-function 'set-process-sentinel)) (count 0))
      (cl-letf (((symbol-function 'set-process-sentinel)
                 (lambda (proc sentinel)
                   (if (= (cl-incf count) 1) (error "synthetic cleanup failure")
                     (funcall original-setter proc sentinel)))))
        (should-error (anvil-worker-health-timer-stop)))
      (should (cl-every (lambda (proc) (not (process-live-p proc))) children))
      ;; Failed releases retain custody and can be retried by stop.
      (anvil-worker-health-timer-stop)
      (should-not anvil-worker--health-probes))))

(ert-deftest anvil-health-async-stop-and-restart-cancel-timer-before-release-error ()
  (dolist (operation '(anvil-worker-health-timer-stop anvil-worker-health-timer-start))
    (anvil-health-test--pool
      (anvil-worker--health-check)
      (let ((timer (run-with-timer 30 30 #'ignore))
            (original-setter (symbol-function 'set-process-sentinel)) (count 0))
        (setq anvil-worker--health-timer timer)
        (cl-letf (((symbol-function 'set-process-sentinel)
                   (lambda (proc sentinel)
                     (if (= (cl-incf count) 1) (error "synthetic release error")
                       (funcall original-setter proc sentinel)))))
          (should-error (funcall operation)))
        (should-not anvil-worker--health-timer)
        (should-not (memq timer timer-list))))))

(ert-deftest anvil-health-async-immediate-success-and-duplicate-finish ()
  (anvil-health-test--pool
    (setq anvil-worker-alive-check-timeout 5)
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest args)
                 (let ((proc (apply original-make-process
                                    (plist-put args :command
                                               (list real-emacs "-Q" "--batch"
                                                     "--eval" "t")))))
                   (push proc children)
                   ;; Force constructor-return-after-exit, outside monitor code.
                   (while (process-live-p proc) (accept-process-output proc 0.1))
                   proc))))
      (anvil-worker--health-check))
    (should-not anvil-worker--health-probes)
    (should-not anvil-worker--health-sweep)
    (anvil-worker--map-pool
     (lambda (worker) (should (eq 'alive (plist-get worker :last-state)))))
    (should-not spawned)))

(ert-deftest anvil-health-async-duplicate-settlement-counts-once ()
  (anvil-health-test--pool
    (anvil-worker--health-check)
    (let* ((record (car anvil-worker--health-probes))
           (worker (plist-get record :worker)))
      (anvil-worker--health-finish record nil)
      (anvil-worker--health-finish record nil)
      (should (= 1 (plist-get worker :hung-checks))))))

(ert-deftest anvil-health-async-stop-during-observation-and-logging ()
  (dolist (hook '(observation logging))
    (anvil-health-test--pool
      (cl-letf (((symbol-function 'anvil-worker--quick-alive-p)
                 (lambda (_)
                   (when (eq hook 'observation) (anvil-worker-health-timer-stop))
                   nil))
                ((symbol-function 'anvil-worker--log)
                 (lambda (&rest _)
                   (when (eq hook 'logging) (anvil-worker-health-timer-stop)))))
        (anvil-worker--health-check))
      (should-not spawned)
      (should-not children))))

(ert-deftest anvil-health-async-unix-real-connect-and-stale-socket ()
  "Exercise real local :nowait connect and stale socket recovery on Unix."
  (skip-unless (and (not (eq system-type 'windows-nt)) (executable-find "python3")))
  (dolist (live '(t nil))
    (anvil-health-test--pool
      (let* ((server-use-tcp nil)
             (path (make-temp-name (expand-file-name "anvil-health-" temporary-file-directory)))
             (worker (anvil-worker--worker :read 0))
             (server (and live (make-network-process :name "health-test-server"
                                                     :family 'local :server t
                                                     :service path :noquery t))))
        (unwind-protect
            (progn
              (unless live
                (should (= 0 (call-process "python3" nil nil nil "-c"
                                           "import socket,sys;s=socket.socket(socket.AF_UNIX);s.bind(sys.argv[1]);s.close()"
                                           path))))
              (anvil-worker--map-pool (lambda (entry) (plist-put entry :demanded nil)))
              (plist-put worker :demanded t)
              (plist-put worker :server-file path)
              (setq anvil-worker--health-sweep t
                    anvil-worker--health-deadline (+ (float-time) 2))
              (let ((record (anvil-worker--health-record worker)))
                (push record anvil-worker--health-probes)
                (setf (plist-get record :timer)
                      (run-at-time 2 nil #'anvil-worker--health-finish record nil))
                (anvil-worker--health-connect record)
                (let ((deadline (+ (float-time) 3)))
                  (while (and anvil-worker--health-probes (< (float-time) deadline))
                    (accept-process-output nil 0.02)))
                (should-not anvil-worker--health-probes)
                (if live
                    (progn (should-not spawned) (should (file-exists-p path)))
                  (should (equal spawned (list worker)))
                  (should-not (file-exists-p path)))))
          (when (and server (process-live-p server)) (delete-process server))
          (when (file-exists-p path) (delete-file path)))))))

(ert-deftest anvil-health-auth-windows-identity ()
  "PID reuse is evidence only when executable or start metadata proves it."
  (let ((file (make-temp-file "anvil-health-auth"))
        (server-use-tcp t)
        (anvil-worker-emacs-bin "C:/Emacs/bin/emacs.exe"))
    (unwind-protect
        (progn
          (with-temp-file file (insert "127.0.0.1:1234 5992\nsecret\n"))
          (set-file-times file (seconds-to-time 1000000))
          (dolist (case `((((comm . "other.exe")) . t)
                          (((comm . "emacs.exe") (start . ,(seconds-to-time 1000001))) . t)
                          (((comm . "EMACS") (start . ,(seconds-to-time 999999))) . nil)
                          (((pid . 5992)) . nil)
                          (((comm . "") (start . unknown)) . nil)))
            (cl-letf (((symbol-function 'process-attributes) (lambda (_) (car case)))
                      ((symbol-function 'w32-convert-standard-filename) #'identity))
              (let ((system-type 'windows-nt))
                (should (eq (and (anvil-worker--server-file-stale-p file) t) (cdr case)))))))
      (delete-file file))))

(ert-deftest anvil-health-async-unix-full-backlog-preserves-live-socket ()
  (skip-unless (and (not (eq system-type 'windows-nt)) (executable-find "python3")))
  (anvil-health-test--pool
    (let* ((server-use-tcp nil)
           (path (make-temp-name (expand-file-name "anvil-backlog-" temporary-file-directory)))
           (ready (concat path ".ready"))
           (worker (anvil-worker--worker :read 0))
           (server (funcall original-make-process
                    :name "health-backlog" :noquery t :connection-type 'pipe
                    :command (list "python3" "-c"
                    "import socket,sys,time; s=socket.socket(socket.AF_UNIX);s.bind(sys.argv[1]);s.listen(0);c=socket.socket(socket.AF_UNIX);c.connect(sys.argv[1]);open(sys.argv[2],'w').close();time.sleep(30)"
                    path ready))))
      (unwind-protect
          (progn
            (let ((deadline (+ (float-time) 3)))
              (while (and (not (file-exists-p ready)) (< (float-time) deadline))
                (accept-process-output nil 0.02)))
            (should (file-exists-p ready))
            (plist-put worker :server-file path)
            (setq anvil-worker--health-sweep t
                  anvil-worker--health-deadline (+ (float-time) 0.2))
            (let ((record (anvil-worker--health-record worker)))
              (push record anvil-worker--health-probes)
              (setf (plist-get record :timer)
                    (run-at-time 0.2 nil #'anvil-worker--health-finish record nil))
              (anvil-worker--health-connect record)
              (let ((deadline (+ (float-time) 2)))
                (while (and anvil-worker--health-probes (< (float-time) deadline))
                  (accept-process-output nil 0.02)))
              (should-not anvil-worker--health-probes)
              (should (file-exists-p path))
              (should-not spawned)))
        (when (process-live-p server) (delete-process server))
        (dolist (file (list ready path))
          (when (file-exists-p file) (delete-file file)))))))

(provide 'anvil-worker-health-async-test)
