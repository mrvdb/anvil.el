# Asynchronous worker health monitoring

Periodic health monitoring must not wait for an `emacsclient` child in the
hosting Emacs. A synchronous wait previously delayed unrelated clients by
approximately two seconds per unresponsive worker, every 30-second sweep.
Creating the child asynchronously did not make the surrounding wait asynchronous.

`anvil-worker--health-check` now launches a bounded sweep and returns. Process
sentinels handle completion; deadline timers handle probes that never answer.
At most two probes run concurrently, and the whole sweep shares
`anvil-worker-alive-check-timeout`. Repeated ticks coalesce with the current
sweep. A rotating starting point prevents two hung endpoints from permanently
excluding later workers. Never-demanded lazy workers remain cold.

Stopping, restarting, resetting the pool, or killing workers invalidates old
callbacks and releases probe children, buffers, and timers. Callback results
belong to the exact pool, worker, endpoint, and owned worker process captured
when the probe started. An obsolete callback cannot act on a replacement.
Busy workers retain dispatch-owned timeout and cleanup semantics. Recovery can
signal only an exact process object owned by this Emacs; a PID or an auth file
alone never authorizes termination.

The Windows auth-file check also rejects a PID reused by another executable,
or a process whose start time is newer than the auth file, when OS metadata is
available. Unknown metadata remains conservative.

Explicit synchronous dispatch probes retain their existing API and timeout.
The change applies to periodic background monitoring. It does not preempt
arbitrary synchronous Lisp or prove that every historical freeze has one cause.

Run the focused contracts and real client check from the repository root:

```sh
emacs -Q --batch -L . -L tests \
  -l tests/anvil-worker-health-async-test.el \
  -l tests/anvil-worker-test.el -l tests/anvil-worker-pool-test.el \
  -l tests/anvil-worker-health-live-test.el \
  -f ert-run-tests-batch-and-exit
```

The Python live test creates a private batch Emacs server and a private TCP
listener that never answers the Emacs protocol. It verifies a concurrent real
client, bounded overlap, cancellation, stale callbacks, and process cleanup.
Recovery launches are suppressed only inside that private test server. It does
not enable monitoring in the user's GUI. `--expect-blocked` records the old
behavior for comparison; the normal acceptance mode must fail on old source.

The standalone connection and GUI startup policy do not need to change. Users
who keep GUI Anvil disabled can continue doing so; that isolation is separate
from repairing background monitoring for users who enable it.
