# Package lint profiles

Run `make lint-package` with Emacs and package-lint on the load path. If
package-lint is checked out separately, set `PACKAGE_LINT_DIR` to that directory.
Set `EMACS` to choose an Emacs executable. The runner does not install anything
and works independently of Eask. `make lint` runs this audit before the existing
Eask checkdoc audit.

The real `anvil.el` metadata is authoritative for the Emacs 28.2 core. Every
root `anvil*.el` module is audited, and warnings fail the command. The explicit
manifest in `scripts/package-lint-profiles.json` selects nine optional files for
an Emacs 29.1 profile derived from the same main file. Secondary dependency
headers cannot change either profile.

The eight optional services use builtin SQLite for their storage: longrun
store, harness telemetry, memory, memory bridge, memory observations, semantic
search, SQL tools, and worklogs. The ninth module, `anvil-builtin-backend.el`,
isolates builtin SQLite and tree-sitter calls behind delegating adapters.

Mixed modules retain their existing availability checks and alternative
backends: definition and org indexes, in-memory trajectories, state delegation,
session storage, syntax fallbacks, tree-sitter subprocesses, and TypeScript and
Python tools. They are audited against the core profile. Adapters do not replace
or redefine builtins, and resolve the current builtin on every call.

`tests/anvil-package-lint-test.el` includes negative controls: direct and
same-line Emacs-29-only calls must fail under the real core profile. A structural
guard checks both call heads and function references, while allowing quoted
symbols in availability probes. Passing this static
audit on a newer Emacs does not establish execution support on Emacs 28.2;
runtime compatibility must also be checked with that executable when available.
