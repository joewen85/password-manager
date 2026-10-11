#!/usr/bin/env bash
set -euo pipefail

# Centralized Harmony/DevEco environment bootstrap for command-line scripts.
# Override with env vars when needed:
#   DEVECO_APP_PATH, HARMONY_COMMAND_LINK_HOME

DEVECO_APP_PATH="${DEVECO_APP_PATH:-/Applications/DevEco-Studio.app}"
HARMONY_COMMAND_LINK_HOME="${HARMONY_COMMAND_LINK_HOME:-/Users/joe/Tools/harmony-dev}"

# shellcheck disable=SC2034
DEVECO_CONTENTS="${DEVECO_APP_PATH}/Contents"

prepend_path() {
  local target="$1"
  if [[ -d "$target" && ":$PATH:" != *":$target:"* ]]; then
    PATH="$target:$PATH"
  fi
}

prepend_path "${HARMONY_COMMAND_LINK_HOME}/bin"
prepend_path "${HARMONY_COMMAND_LINK_HOME}/sdk/default/openharmony/toolchains"
prepend_path "${DEVECO_CONTENTS}/bin"

if [[ -z "${JAVA_HOME:-}" ]]; then
  if [[ -x "${DEVECO_CONTENTS}/jbr/Contents/Home/bin/java" ]]; then
    JAVA_HOME="${DEVECO_CONTENTS}/jbr/Contents/Home"
  elif [[ -x "${DEVECO_CONTENTS}/jbr/Home/bin/java" ]]; then
    JAVA_HOME="${DEVECO_CONTENTS}/jbr/Home"
  fi
fi

export DEVECO_APP_PATH
export HARMONY_COMMAND_LINK_HOME
export DEVECO_CONTENTS
export JAVA_HOME
export PATH
