#!/usr/bin/env python3
"""Black-box contract checks for bounded anvil-stdio emacsclient calls."""
import argparse
import json
import os
import pathlib
import platform
import shutil
import signal
import subprocess
import tempfile
import threading
import time
from contextlib import contextmanager


def alive(pid):
    try:
        os.kill(pid, 0)
        stat_file = pathlib.Path(f"/proc/{pid}/stat")
        if stat_file.exists():
            # A zombie cannot retain descriptors or execute code.
            stat = stat_file.read_text().split()
            return len(stat) < 3 or stat[2] != "Z"
        ps = shutil.which("ps")
        if ps:
            result = subprocess.run([ps, "-o", "stat=", "-p", str(pid)],
                                    capture_output=True, text=True)
            if result.returncode != 0:
                return True
            state = result.stdout.strip()
            return not state.startswith("Z")
        return True
    except (ProcessLookupError, FileNotFoundError):
        return False
    except PermissionError:
        return True


def frame(body):
    return f"Content-Length: {len(body.encode())}\r\n\r\n{body}"


def request(method, ident=None):
    value = {"jsonrpc": "2.0", "method": method}
    if ident is not None:
        value["id"] = ident
    return json.dumps(value, separators=(",", ":"))


def check(ok, message):
    if not ok:
        raise AssertionError(message)


def outcome_evidence(rc, actual, expected, elapsed, stderr):
    """Describe an outcome without copying unbounded transport output."""
    def preview(value):
        if isinstance(value, (bytes, str)):
            return repr(value[:512]) + ("..." if len(value) > 512 else "")
        return repr(value)[:512]  # Expected fixture values are small constants.

    return (f"rc={rc!r} actual={preview(actual)} expected={preview(expected)} "
            f"elapsed={elapsed:.3f}s stderr={preview(stderr)}")


def check_json_outcome(rc, out, stderr, elapsed, expected, label):
    """Check exact response semantics separately from the timing envelope."""
    evidence = outcome_evidence(rc, out, expected, elapsed, stderr)
    try:
        actual = [json.loads(line) for line in out.splitlines()]
    except (ValueError, UnicodeDecodeError) as error:
        raise AssertionError(f"{label}: invalid JSON ({type(error).__name__}); {evidence}") from error
    check(rc == 0 and actual == expected, f"{label}: {evidence}")


REQUEST_WATCHDOG_SECONDS = 6.0


def batch_outer_budget(environment, request_count, lifecycle=False):
    """Outlive the sequential bounded phases, independently of dispatch custody.

    The runner envelope follows the readiness harness: execution/termination,
    kill escalation and whole-second FIFO rounding.  A request can frame,
    prepare three metadata/response phases, probe readiness, and dispatch.
    EOF cleanup can require two further metadata runners.
    """
    kill_after = int(environment["ANVIL_EMACSCLIENT_KILL_AFTER_TIMEOUT"])

    def runner(seconds):
        return 2 * seconds + 3 * kill_after + 3

    parse = runner(int(environment.get("ANVIL_MCP_REQUEST_PARSE_TIMEOUT", "10")))
    frame_budget = runner(int(environment.get("ANVIL_MCP_FRAME_READ_TIMEOUT", "10")))
    readiness = runner(int(environment["ANVIL_EMACSCLIENT_READINESS_TIMEOUT"]))
    dispatch_value = environment["ANVIL_EMACSCLIENT_DISPATCH_TIMEOUT"]
    dispatch = runner(int(dispatch_value)) if dispatch_value.isdigit() else 0
    per_request = frame_budget + 3 * parse + readiness + dispatch + 2
    lifecycle_budget = 2 * (readiness + dispatch) if lifecycle else 0
    control = int(environment.get("ANVIL_MCP_RUNNER_CONTROL_TIMEOUT", "10"))
    return request_count * per_request + lifecycle_budget + 2 * parse + 2 * control


@contextmanager
def managed_tempdir(processes, pid_file):
    """Reap bridge groups and fake clients before TemporaryDirectory removes PID records."""
    with tempfile.TemporaryDirectory(prefix="anvil-stdio-timeout-") as td:
        root = pathlib.Path(td)
        try:
            yield root
        finally:
            for proc in processes:
                if proc.poll() is None:
                    try: os.killpg(proc.pid, signal.SIGKILL)
                    except ProcessLookupError: pass
            try:
                pids = map(int, pid_file[0].read_text().splitlines()) if pid_file[0] else ()
                for pid in pids:
                    try: os.kill(pid, signal.SIGKILL)
                    except ProcessLookupError: pass
            except FileNotFoundError:
                pass
            for proc in processes:
                if proc.poll() is None:
                    try: proc.communicate(timeout=2)
                    except subprocess.TimeoutExpired:
                        proc.kill()
                        try: proc.communicate(timeout=1)
                        except subprocess.TimeoutExpired: pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--script", required=True, type=pathlib.Path)
    ap.add_argument("--baseline", action="store_true")
    ap.add_argument("--force-cleanup-check", action="store_true")
    ap.add_argument("--backend", choices=("gnu", "perl"), default="gnu",
                    help="Historical environment profile; execution uses the owned runner")
    args = ap.parse_args()
    script = args.script.resolve()
    timeout = shutil.which("timeout")
    if args.backend == "gnu":
        if platform.system() != "Linux" or not timeout:
            print("SKIP GNU timeout contract requires Linux coreutils")
            return
        version = subprocess.run([timeout, "--version"], capture_output=True, text=True).stdout
        if "GNU coreutils" not in version:
            print("SKIP GNU timeout contract requires Linux coreutils")
            return
    elif not shutil.which("perl"):
        print("SKIP Perl timeout contract requires Perl")
        return
    bash = shutil.which("bash")
    if not bash:
        raise RuntimeError("bash unavailable")
    passed = 0
    max_request_duration = 0.0
    max_batch_duration = 0.0
    processes = []
    pid_file = [None]
    with managed_tempdir(processes, pid_file) as root:
        run_script = script
        if args.backend == "perl":
            run_script = root / "anvil-stdio-installed.sh"
            shutil.copy2(script, run_script)
        bin_dir = root / "bin"
        bin_dir.mkdir()
        path_dir = bin_dir
        if args.backend == "perl":
            path_dir = root / "perl-path"
            path_dir.mkdir()
            for name in ("awk", "base64", "cut", "date", "dirname", "env", "grep", "head",
                         "perl", "ps", "python3", "rm", "sed", "sleep", "tr", "wc"):
                executable = shutil.which(name)
                if executable:
                    (path_dir / name).symlink_to(executable)
        state = root / "state"
        log = root / "calls.jsonl"
        pids = root / "pids"
        pid_file[0] = pids
        state.write_text("0")
        client = bin_dir / "emacsclient"
        client.write_text('''#!/usr/bin/env python3
import base64, json, os, pathlib, re, signal, sys, time
root = pathlib.Path(os.environ["CASE_ROOT"])

def record_custody(started, method, role):
    with (root / "timings.jsonl").open("a") as stream:
        stream.write(json.dumps({"pid": os.getpid(), "started": started,
                                 "method": method, "role": role}) + "\\n")

args = sys.argv[1:]
expr = args[args.index("-e") + 1]
if expr == "t":
    time.sleep(float(os.environ.get("ANVIL_TEST_TIMEOUT_PROBE_DELAY_SEC", "0")))
    mode = os.environ.get("PROBE_MODE", "plain")
    n = int((root / "state").read_text())
    (root / "state").write_text(str(n + 1))
    with (root / "calls.jsonl").open("a") as f:
        f.write(json.dumps({"probe": mode}) + "\\n")
    if (mode == "retry" and n == 0) or (mode == "exhaust" and n < 2):
        print("can't find socket", file=sys.stderr)
        raise SystemExit(1)
    print("t")
    raise SystemExit
if expr.startswith("(") and not "base64-decode-string" in expr:
    with (root / "calls.jsonl").open("a") as f: f.write(expr + "\\n")
    print('"anvil-mcp-lifecycle-complete"')
    raise SystemExit
encoded = expr.split('base64-decode-string "', 1)[1].split('"', 1)[0]
req = json.loads(base64.b64decode(encoded))
method = req["method"]
started = time.monotonic()
record_custody(started, method, "client")
with (root / "calls.jsonl").open("a") as f: f.write(json.dumps(req) + "\\n")
time.sleep(float(os.environ.get("ANVIL_TEST_TIMEOUT_CLIENT_STARTUP_DELAY_SEC", "0")))
if method == "hang":
    child = os.fork()
    if child == 0:
        record_custody(started, method, "child")
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        signal.signal(signal.SIGALRM, signal.SIG_IGN)
        with (root / "pids").open("a") as f: f.write(str(os.getpid()) + "\\n")
        while True: time.sleep(1)
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    signal.signal(signal.SIGALRM, signal.SIG_IGN)
    with (root / "pids").open("a") as f: f.write(str(os.getpid()) + "\\n")
    while True: time.sleep(1)
if method == "orphan":
    read_fd, write_fd = os.pipe()
    child = os.fork()
    if child == 0:
        record_custody(started, method, "child")
        os.close(read_fd)
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        with (root / "pids").open("a") as f: f.write(str(os.getpid()) + "\\n")
        os.write(write_fd, b"1")
        os.close(write_fd)
        while True: time.sleep(1)
    os.close(write_fd)
    os.read(read_fd, 1)
    os.close(read_fd)
if method == "exhaust":
    print("can't find socket", file=sys.stderr)
    raise SystemExit(1)
if method == "immediate":
    print("elisp evaluation failed", file=sys.stderr)
    raise SystemExit(1)
body = {"jsonrpc":"2.0", "id":req.get("id"), "result":{"method":method}}
wire = json.dumps(body, separators=(",", ":")).encode() if "id" in req else b""
paths = [pathlib.Path(base64.b64decode(value).decode())
         for value in re.findall(r'base64-decode-string "([A-Za-z0-9+/=]+)"', expr)]
stages = [path for path in paths if re.fullmatch(r"\\.response-tmp\\.[0-9]+\\..+", path.name)]
if len(stages) != 1:
    raise RuntimeError(f"missing unique authenticated response stage: {paths!r}")
stage = stages[0]
sequence = int(stage.name.split(".")[2])
with stage.open("wb") as stream:
    stream.write(wire)
os.link(stage, stage.parent / f"response.{sequence}.json")
os.link(stage, stage.parent / f"proof.{sequence}.json")
stage.unlink()
print(f'"anvil-mcp-response-staged:{sequence}:{len(wire)}"')
''')
        client.chmod(0o755)
        env = os.environ.copy()
        path = str(bin_dir) + os.pathsep + str(path_dir)
        if args.backend == "gnu":
            path += os.pathsep + env.get("PATH", "")
        env.update(PATH=path,
                   CASE_ROOT=str(root), ANVIL_EMACSCLIENT_PROBE_TIMEOUT="1",
                   ANVIL_EMACSCLIENT_READINESS_TIMEOUT="2",
                   ANVIL_EMACSCLIENT_STARTUP_DISPATCH_TIMEOUT="1",
                   ANVIL_EMACSCLIENT_KILL_AFTER_TIMEOUT="1",
                   ANVIL_EMACSCLIENT_RETRY_MAX="2", ANVIL_EMACSCLIENT_RETRY_DELAY_MS="0")

        def run(data, framed=False, timeout_value="1", init=False, force_fail=False):
            nonlocal max_request_duration, max_batch_duration
            env["ANVIL_EMACSCLIENT_DISPATCH_TIMEOUT"] = timeout_value
            env["PROBE_MODE"] = "retry" if b'"retry"' in data else (
                "exhaust" if b'"exhaust"' in data else "plain")
            state.write_text("0")
            timings = root / "timings.jsonl"
            timings.write_text("")
            call_start = len(log.read_text().splitlines()) if log.exists() else 0
            cmd = [str(run_script)]
            if init:
                cmd += ["--init-function=init-fn", "--stop-function=stop-fn"]
            start = time.monotonic()
            proc = subprocess.Popen([bash] + cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, env=env, start_new_session=True)
            processes.append(proc)
            try:
                if force_fail:
                    proc.stdin.write(data)
                    proc.stdin.flush()
                    for _ in range(40):
                        if pids.exists() and len(pids.read_text().splitlines()) >= 2: break
                        time.sleep(0.05)
                    raise RuntimeError("injected harness failure")
                count = data.count(b"Content-Length: ") if framed else len(data.splitlines())
                outer_budget = batch_outer_budget(env, count, lifecycle=init)
                watchdog_stop = threading.Event()
                violations = []
                observed = {}

                def watch_requests():
                    while not watchdog_stop.is_set():
                        for line in timings.read_text().splitlines():
                            try:
                                event = json.loads(line)
                            except json.JSONDecodeError:
                                continue  # Another process is appending this record.
                            pid = event["pid"]
                            if pid in observed:
                                continue
                            duration = time.monotonic() - event["started"]
                            if not alive(pid):
                                observed[pid] = duration
                            elif duration >= REQUEST_WATCHDOG_SECONDS:
                                violations.append(event)
                                try: os.killpg(proc.pid, signal.SIGKILL)
                                except ProcessLookupError: pass
                                for owned in map(int, pids.read_text().splitlines()) if pids.exists() else ():
                                    try: os.kill(owned, signal.SIGKILL)
                                    except ProcessLookupError: pass
                                watchdog_stop.set()
                                return
                        watchdog_stop.wait(0.02)

                watcher = threading.Thread(target=watch_requests, daemon=True)
                watcher.start()
                try:
                    out, err = proc.communicate(data, timeout=outer_budget)
                finally:
                    watchdog_stop.set()
                    watcher.join(timeout=1)
                check(not watcher.is_alive(), "request watchdog did not stop")
                check(not violations,
                      f"request custody watchdog expired (limit={REQUEST_WATCHDOG_SECONDS:g}s): {violations!r}")
                # After EOF no dispatched client or recorded descendant may survive.
                events = [json.loads(line) for line in timings.read_text().splitlines()]
                calls = [json.loads(line) for line in log.read_text().splitlines()[call_start:]
                         if line.startswith("{")] if log.exists() else []
                check(sum(event["role"] == "client" for event in events) ==
                      sum("method" in call for call in calls),
                      "dispatch timing records did not cover every stateful invocation")
                check(all(not alive(event["pid"]) for event in events),
                      "bridge returned while request custody remained live")
                for event in events:
                    observed.setdefault(event["pid"], time.monotonic() - event["started"])
                check(all(duration < REQUEST_WATCHDOG_SECONDS for duration in observed.values()),
                      f"six-second per-request duration exceeded: {observed!r}")
                max_request_duration = max(max_request_duration, max(observed.values(), default=0))
            except BaseException:
                try: os.killpg(proc.pid, signal.SIGKILL)
                except ProcessLookupError: pass
                for pid in map(int, pids.read_text().splitlines()) if pids.exists() else ():
                    try: os.kill(pid, signal.SIGKILL)
                    except ProcessLookupError: pass
                proc.communicate(timeout=2)
                raise
            elapsed = time.monotonic() - start
            check(elapsed < outer_budget,
                  f"configured batch phase envelope exceeded: elapsed={elapsed:.3f}s "
                  f"budget={outer_budget:.3f}s requests={count} lifecycle={init}")
            max_batch_duration = max(max_batch_duration, elapsed)
            return proc.returncode, out, err, elapsed

        if args.force_cleanup_check:
            try:
                run((request("hang", 1) + "\n").encode(), force_fail=True)
            except RuntimeError as exc:
                check(str(exc) == "injected harness failure", "unexpected forced failure")
            else:
                raise AssertionError("forced harness failure did not occur")
            ids = list(map(int, pids.read_text().splitlines()))
            for _ in range(40):
                if all(not alive(pid) for pid in ids): break
                time.sleep(0.05)
            check(len(ids) == 2 and all(not alive(pid) for pid in ids),
                  f"forced failure leaked fake client process group: {[(pid, alive(pid)) for pid in ids]}")
            passed = 1
        elif args.baseline:
            # The pre-patch implementation must hang past the outer watchdog.
            data = (request("hang") + "\n" + request("after", 2) + "\n").encode()
            env["ANVIL_EMACSCLIENT_TIMEOUT"] = "1"
            proc = subprocess.Popen([bash, str(script)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, env=env, start_new_session=True)
            processes.append(proc)
            try:
                proc.communicate(data, timeout=3.5)
                raise AssertionError("baseline unexpectedly bounded TERM-resistant client")
            except subprocess.TimeoutExpired:
                try: os.killpg(proc.pid, signal.SIGKILL)
                except ProcessLookupError: pass
                for pid in map(int, pids.read_text().splitlines()) if pids.exists() else ():
                    try: os.kill(pid, signal.SIGKILL)
                    except ProcessLookupError: pass
                proc.communicate(timeout=2)
                ids = list(map(int, pids.read_text().splitlines())) if pids.exists() else []
                for _ in range(40):
                    if all(not alive(pid) for pid in ids): break
                    time.sleep(0.05)
                check(len(ids) == 2 and all(not alive(pid) for pid in ids),
                      f"baseline cleanup leaked client group: {[(pid, alive(pid)) for pid in ids]}")
            passed += 1
        else:
            # Timeout notification is silent; bridge remains usable, both wire modes.
            for framed in (False, True):
                previous_ids = len(pids.read_text().splitlines()) if pids.exists() else 0
                data = [request("hang", 1), request("hang"), request("after", 2)]
                wire = "".join(frame(x) if framed else x + "\n" for x in data).encode()
                rc, out, err, elapsed = run(wire, framed=framed)
                expected = {"jsonrpc":"2.0", "id":2, "result":{"method":"after"}}
                expected_body = json.dumps(expected, separators=(",", ":"))
                if framed:
                    header, rest = out.split(b"\r\n\r\n", 1)
                    failure_len = int(header.split(b":", 1)[1])
                    failure_body = rest[:failure_len]
                    next_frame = rest[failure_len:]
                    next_body = expected_body.encode()
                else:
                    next_frame = None
                    failure_body, next_body = out.splitlines()
                failure_obj = json.loads(failure_body)
                message = failure_obj.get("error", {}).get("message", "")
                failure_data = failure_obj.get("error", {}).get("data", {})
                check(failure_obj.get("id") == 1 and "Bridge synthetic error" in message and
                      failure_data == {"phase": "dispatch", "dispatched": True,
                                       "replayed": False, "emacsclientRc": 124},
                      f"timeout response mismatch: {failure_obj!r}")
                check(rc == 0 and next_body == expected_body.encode(),
                      f"framing/next request mismatch: {rc} {out!r} {err!r}")
                if framed:
                    check(next_frame == frame(expected_body).encode(),
                          f"next Content-Length frame mismatch: {next_frame!r}")
                # Two configured deadline/grace pairs consume at least four
                # seconds.  Individual custody is independently capped at six;
                # preparation overhead belongs to the derived batch envelope.
                deadline_and_grace = (int(env["ANVIL_EMACSCLIENT_DISPATCH_TIMEOUT"]) +
                                      int(env["ANVIL_EMACSCLIENT_KILL_AFTER_TIMEOUT"]))
                check(elapsed >= 2 * deadline_and_grace,
                      f"two timeout/grace phases ended prematurely: elapsed={elapsed:.3f}s "
                      f"minimum={2 * deadline_and_grace}s")
                ids = list(map(int, pids.read_text().splitlines()))[previous_ids:]
                # Each hanging call and its same-group child must be gone.
                for _ in range(20):
                    if all(not alive(pid) for pid in ids): break
                    time.sleep(0.05)
                check(len(ids) == 4 and all(not alive(pid) for pid in ids),
                      f"TERM-resistant process survived: {[(pid, alive(pid)) for pid in ids]}")
                passed += 2
            if args.backend == "perl":
                # A single integer phase timeout also bounds the process group.
                previous_ids = len(pids.read_text().splitlines())
                rc, out, err, elapsed = run((request("hang", 8) + "\n").encode(), timeout_value="1")
                check(rc == 0 and b"Bridge synthetic error" in out and
                      json.loads(out)["error"]["data"]["emacsclientRc"] == 124,
                      "integer timeout response mismatch: " +
                      outcome_evidence(rc, out, "dispatch timeout rc=124", elapsed, err))
                deadline_and_grace = (int(env["ANVIL_EMACSCLIENT_DISPATCH_TIMEOUT"]) +
                                      int(env["ANVIL_EMACSCLIENT_KILL_AFTER_TIMEOUT"]))
                check(elapsed >= deadline_and_grace,
                      f"integer timeout/grace ended prematurely: elapsed={elapsed:.3f}s "
                      f"minimum={deadline_and_grace}s")
                ids = list(map(int, pids.read_text().splitlines()))[previous_ids:]
                check(len(ids) == 2 and all(not alive(pid) for pid in ids),
                      f"integer timeout leaked process group: {[(pid, alive(pid)) for pid in ids]}")
                passed += 2
                previous_ids = len(pids.read_text().splitlines())
                rc, out, err, elapsed = run((request("orphan", 9) + "\n" +
                                           request("after", 13) + "\n").encode())
                expected = [
                    {"jsonrpc": "2.0", "id": 9, "result": {"method": "orphan"}},
                    {"jsonrpc": "2.0", "id": 13, "result": {"method": "after"}},
                ]
                check_json_outcome(rc, out, err, elapsed, expected,
                                   "orphan response or subsequent request failed")
                ids = list(map(int, pids.read_text().splitlines()))[previous_ids:]
                check(len(ids) == 1 and all(not alive(pid) for pid in ids),
                      f"orphan holding stdout survived: {[(pid, alive(pid)) for pid in ids]}")
                passed += 2
            # Retry success, init/stop counts, and timeout=0 path.
            state.write_text("0")
            data = (request("retry", 3) + "\n" + request("plain", 4) + "\n").encode()
            rc, out, _, _ = run(data, init=True)
            check(rc == 0 and out.count(b'"id":3') == 1 and out.count(b'"id":4') == 1,
                  "retry/init/stop or ordinary success failed")
            calls = log.read_text().splitlines()
            check(sum("init-fn" in x for x in calls) == 1 and sum("stop-fn" in x for x in calls) == 1,
                  "init/stop call count mismatch")
            check(sum('"method": "retry"' in x for x in calls) == 1,
                  "stateful retry request was replayed")
            # Init's first readiness attempt fails once; its retry, two request
            # probes and the stop probe succeed.  Stateful calls never retry.
            check(sum('"probe": "retry"' in x for x in calls) == 5,
                  "readiness retry / lifecycle probe counts mismatch")
            passed += 3
            # Exhausted socket retries stay bounded; non-socket errors are single-shot.
            before = len(calls)
            rc, out, _, _ = run((request("exhaust", 6) + "\n" + request("immediate", 7) + "\n" +
                                 request("notice") + "\n").encode())
            after_calls = log.read_text().splitlines()[before:]
            check(rc == 0 and b"Bridge synthetic error" in out and b'"id":7' in out,
                  "error classification output mismatch")
            check(sum('"probe": "exhaust"' in x for x in after_calls) == 4 and
                  sum('"method": "exhaust"' in x for x in after_calls) == 0 and
                  sum('"method": "immediate"' in x for x in after_calls) == 1 and
                  sum('"method": "notice"' in x for x in after_calls) == 1,
                  "retry exhaustion / immediate error / notification counts mismatch")
            passed += 2
            # Current phase deadlines are positive integers; legacy fractional
            # and disabled values must fail before even a readiness probe.
            for invalid in ("0.15", "0"):
                call_count = len(log.read_text().splitlines())
                rc, out, _, _ = run((request("plain", 5) + "\n").encode(), timeout_value=invalid)
                check(rc == 64 and not out and len(log.read_text().splitlines()) == call_count,
                      f"unsupported timeout {invalid!r} reached a client")
                passed += 1
            if args.backend == "perl":
                # Malformed phase deadlines fail before dispatching.  Removing
                # both legacy supervisors must not disable owned-runner custody.
                call_count = len(log.read_text().splitlines())
                rc, out, _, _ = run((request("plain", 10) + "\n").encode(), timeout_value="1e2")
                check(rc == 64 and not out
                      and len(log.read_text().splitlines()) == call_count,
                      "malformed timeout was dispatched")
                passed += 1
                perl_link = path_dir / "perl"
                perl_link.unlink()
                call_count = len(log.read_text().splitlines())
                previous_ids = len(pids.read_text().splitlines())
                rc, out, _, _ = run((request("hang", 11) + "\n" +
                                     request("after", 14) + "\n").encode())
                responses = [json.loads(line) for line in out.splitlines()]
                check(rc == 0 and responses[0]["error"]["data"] ==
                      {"phase": "dispatch", "dispatched": True,
                       "replayed": False, "emacsclientRc": 124} and
                      responses[1]["result"]["method"] == "after",
                      "owned runner failed without GNU timeout or Perl")
                ids = list(map(int, pids.read_text().splitlines()))[previous_ids:]
                check(len(ids) == 2 and all(not alive(pid) for pid in ids),
                      "missing legacy supervisors leaked timeout descendants")
                passed += 1
                call_count = len(log.read_text().splitlines())
                rc, out, _, _ = run((request("plain", 12) + "\n").encode(), timeout_value="0")
                check(rc == 64 and not out and len(log.read_text().splitlines()) == call_count,
                      "timeout=0 bypassed validation without legacy supervisors")
                passed += 1
    print(f"PASS {passed} checks ({args.backend} environment; owned runner; "
          f"max-request={max_request_duration:.3f}s; max-batch={max_batch_duration:.3f}s)")


if __name__ == "__main__":
    main()
