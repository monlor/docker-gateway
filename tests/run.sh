#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)

bash "${SCRIPT_DIR}/test-log-levels.sh"
bash "${SCRIPT_DIR}/test-config-log-generation.sh"
bash "${SCRIPT_DIR}/test-manager-warning.sh"

printf 'All tests passed.\n'
