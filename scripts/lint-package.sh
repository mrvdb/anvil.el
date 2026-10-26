#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
args=(-Q --batch -L "$root" -L "$root/scripts")
if [[ -n ${PACKAGE_LINT_DIR:-} ]]; then
    args+=(-L "$PACKAGE_LINT_DIR")
fi
exec "${EMACS:-emacs}" "${args[@]}" -l "$root/scripts/anvil-package-lint.el" \
    -f anvil-package-lint-batch
