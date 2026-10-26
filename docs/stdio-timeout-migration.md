# Stdio bridge timeout settings

The emacsclient bridge `anvil-stdio.sh` uses separately bounded phases.
Replace legacy `ANVIL_EMACSCLIENT_TIMEOUT` settings with the appropriate
phase setting below. The legacy variable no longer controls this bridge.

| Variable | Default and maximum seconds |
| --- | ---: |
| `ANVIL_EMACSCLIENT_PROBE_TIMEOUT` | 5 |
| `ANVIL_EMACSCLIENT_READINESS_TIMEOUT` | 20 |
| `ANVIL_EMACSCLIENT_STARTUP_DISPATCH_TIMEOUT` | 20 |
| `ANVIL_EMACSCLIENT_DISPATCH_TIMEOUT` | 150 |
| `ANVIL_EMACSCLIENT_KILL_AFTER_TIMEOUT` | 1 |
| `ANVIL_MCP_REQUEST_PARSE_TIMEOUT` | 10 |
| `ANVIL_MCP_FRAME_READ_TIMEOUT` | 10 |
| `ANVIL_MCP_RUNNER_CONTROL_TIMEOUT` | 10 |

Values must be positive decimal integers without leading zeroes, within
the listed maximum. Zero, fractional values and larger values fail before
dispatch. Settings can shorten the package's bounds; they cannot disable
them or enlarge them.

For example, `ANVIL_EMACSCLIENT_DISPATCH_TIMEOUT=30` lowers the response
deadline. A timeout does not prove that a stateful operation did not run:
inspect its outcome before retrying. Only readiness probes are retried;
stateful request dispatch is not replayed.

The bridge uses its owned READY/ACK runner for process custody and cleanup.
The timeout contract tests exercise environments with GNU timeout present
and with only Perl present; these are environment compatibility profiles,
not alternate execution backends.
