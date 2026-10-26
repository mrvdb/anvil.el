"""Exercise health monitoring in a private real Emacs server and TCP endpoint."""
import argparse
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import threading
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--repo', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--emacs', default=shutil.which('emacs'))
    parser.add_argument('--output', type=Path)
    parser.add_argument('--expect-blocked', action='store_true')
    args = parser.parse_args()
    emacs = Path(args.emacs).resolve()
    client = emacs.with_name('emacsclient.exe' if os.name == 'nt' else 'emacsclient')
    if not client.exists():
        raise RuntimeError('The matching emacsclient executable is required')
    result = {}
    with tempfile.TemporaryDirectory(prefix='anvil-health-live-') as directory:
        root = Path(directory)
        q = lambda path: json.dumps(str(path).replace('\\', '/'))
        listener = socket.socket()
        listener.bind(('127.0.0.1', 0))
        listener.listen()
        listener.settimeout(0.1)
        stopped = threading.Event()
        connections = []

        def accept_connections():
            while not stopped.is_set():
                try:
                    connection, _ = listener.accept()
                    connections.append(connection)
                except socket.timeout:
                    pass

        thread = threading.Thread(target=accept_connections, daemon=True)
        thread.start()
        init = root / 'init.el'
        init.write_text(f''';;; -*- lexical-binding: t; -*-
(require 'server)
(require 'json)
(require 'cl-lib)
(setq user-emacs-directory {q(root / 'home')})
(make-directory user-emacs-directory t)
(setq server-use-tcp t server-auth-dir {q(root / 'server')}
      server-name "private-async-health")
(make-directory server-auth-dir t)
(set-file-modes server-auth-dir #o700)
(add-to-list 'load-path {q(args.repo.resolve())})
(require 'anvil-worker)
(setq anvil-worker-lifecycle-log {q(root / 'worker.log')}
      anvil-worker-emacs-bin {q(emacs)}
      anvil-worker-alive-check-timeout 2.0
      anvil-worker-health-check-interval 3600)
(defvar investigation-spawns 0)
(advice-add 'anvil-worker--spawn-worker :override
            (lambda (&rest _) (setq investigation-spawns (1+ investigation-spawns))))
(defun investigation-probe-count ()
  (cl-count-if (lambda (p) (and (process-live-p p)
                               (string-match-p "probe" (process-name p))))
               (process-list)))
(defun investigation-setup (paths)
  (setq anvil-worker--pool
        (list :write (vconcat
                      (mapcar (lambda (path)
                                (list :lane :write :name (file-name-base path)
                                      :server-file path :last-state 'dead
                                      :busy nil :demanded t)) paths))))
  (anvil-worker-health-timer-start)
  (run-with-timer
   0.1 nil
   (lambda ()
     (let ((start (float-time)))
       (with-temp-file {q(root / 'started')} (insert "started"))
       (anvil-worker--health-check)
       (with-temp-file {q(root / 'returned')}
         (insert (json-encode (list (cons "callback_seconds" (- (float-time) start))
                                   (cons "pending_probes" (investigation-probe-count))))))))))
(server-start)
(with-temp-file {q(root / 'pid')} (insert (number-to-string (emacs-pid))))
(while t (accept-process-output nil 0.01))
''', encoding='utf-8')
        log = open(root / 'daemon.log', 'w', encoding='utf-8')
        daemon = subprocess.Popen([str(emacs), '-Q', '--batch', '-l', str(init)], stdout=log, stderr=log)
        auth = root / 'server/private-async-health'

        def wait_file(path):
            deadline = time.monotonic() + 15
            while not path.exists():
                if daemon.poll() is not None or time.monotonic() >= deadline:
                    log.flush()
                    raise RuntimeError((root / 'daemon.log').read_text(encoding='utf-8')[-1500:])
                time.sleep(0.005)

        def evaluate(form):
            start = time.monotonic()
            output = subprocess.run([str(client), '-f', str(auth), '-e', form],
                                    capture_output=True, text=True, timeout=15)
            if output.returncode or output.stdout.startswith('*ERROR*'):
                raise RuntimeError((output.stdout + output.stderr)[:800])
            return time.monotonic() - start, output.stdout.strip()

        try:
            wait_file(root / 'pid')
            pid = int((root / 'pid').read_text())
            result['baseline_seconds'], reply = evaluate('42')
            assert reply == '42', reply
            paths = []
            for index in range(3):
                path = root / f'worker-{index}.auth'
                path.write_text(f'127.0.0.1:{listener.getsockname()[1]} {pid}\n' + 'x' * 64 + '\n')
                paths.append(path)
            evaluate('(investigation-setup (list ' + ' '.join(q(p) for p in paths) + '))')
            wait_file(root / 'started')
            result['client_seconds'], reply = evaluate('42')
            assert reply == '42', reply
            wait_file(root / 'returned')
            result.update(json.loads((root / 'returned').read_text()))
            if not args.expect_blocked:
                assert result['callback_seconds'] < 1.0, result
                assert result['client_seconds'] < 1.0, result
                assert 0 < result['pending_probes'] <= 2, result
                _, before = evaluate('(investigation-probe-count)')
                evaluate('(progn (anvil-worker--health-check) (anvil-worker--health-check) t)')
                _, after = evaluate('(investigation-probe-count)')
                assert int(after) <= 2 and int(after) <= int(before), (before, after)
                result['no_duplicate_probes'] = True
                evaluate('(progn (anvil-worker-health-timer-stop) t)')
                _, pending = evaluate('(investigation-probe-count)')
                assert int(pending) == 0, pending
                result['stop_reaped_probes'] = True
                # Keep servicing the daemon beyond the original deadline: a stale
                # timeout must not launch recovery or recreate probe children.
                time.sleep(2.3)
                _, settled = evaluate('(json-encode (list (cons "probes" (investigation-probe-count)) (cons "spawns" investigation-spawns)))')
                state = json.loads(json.loads(settled))
                assert state == {'probes': 0, 'spawns': 0}, state
                result['stale_callbacks_inert'] = True
            else:
                assert result['callback_seconds'] >= 3.5, result
                assert result['client_seconds'] >= 3.5, result
                result['old_stall_reproduced'] = True
        finally:
            if daemon.poll() is None:
                try:
                    evaluate('(kill-emacs)')
                except (RuntimeError, subprocess.TimeoutExpired):
                    pass
                try:
                    daemon.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    daemon.kill()
                    daemon.wait(timeout=5)
            result['private_daemon_stopped'] = daemon.poll() is not None
            stopped.set()
            thread.join(timeout=1)
            listener.close()
            for connection in connections:
                connection.close()
            log.close()
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    print('PASS ' + json.dumps(result, sort_keys=True))


if __name__ == '__main__':
    main()
