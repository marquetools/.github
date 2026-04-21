#!/usr/bin/env bash
# run.sh — Process a list of files through strip-ansi and emit GitHub Actions outputs.
#
# Environment variables consumed (all set from action.yml inputs):
#   INPUT_FILES          — newline- or space-separated file paths
#   INPUT_ON_THREAT      — fail | strip | warn
#   INPUT_PRESET         — dumb | color | sanitize | tmux | xterm | full
#   INPUT_UNICODE_MAP    — space-separated --unicode-map tokens (e.g. "@ascii-normalize math-latin")
#   INPUT_NO_UNICODE_MAP — space-separated --no-unicode-map tokens
#
# Outputs written to $GITHUB_OUTPUT:
#   results              — JSON array of {file, status, output}
#   threat-detected      — true | false
#   files-with-threats   — newline-separated file paths

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

ON_THREAT="${INPUT_ON_THREAT:-fail}"
PRESET="${INPUT_PRESET:-sanitize}"
UNICODE_MAP="${INPUT_UNICODE_MAP:-@ascii-normalize}"
NO_UNICODE_MAP="${INPUT_NO_UNICODE_MAP:-}"

# Use RUNNER_TEMP when available (GitHub-hosted runners); fall back to /tmp.
WORK_DIR="${RUNNER_TEMP:-/tmp}/strip-ansi-$$"
mkdir -p "${WORK_DIR}"

# Maximum bytes of file content to include in the results JSON per file.
MAX_OUTPUT_BYTES=51200

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log()  { echo "[strip-ansi] $*"; }
warn() { echo "::warning::${*}"; }

# Validate the on-threat input.
case "${ON_THREAT}" in
  fail|strip|warn) ;;
  *) echo "::error::Invalid on-threat value '${ON_THREAT}'. Must be fail, strip, or warn."; exit 1 ;;
esac

# Validate the preset input.
case "${PRESET}" in
  dumb|color|sanitize|tmux|xterm|full) ;;
  *) echo "::error::Invalid preset '${PRESET}'. Must be one of: dumb, color, sanitize, tmux, xterm, full."; exit 1 ;;
esac

# Build the flag array for strip-ansi.
# We always pass --check-threats so threats are detected regardless of on-threat value.
# When on-threat=strip we additionally pass --on-threat=strip so the binary strips them.
build_flags() {
  FLAGS=()
  FLAGS+=("--preset" "${PRESET}")
  FLAGS+=("--check-threats")

  if [ "${ON_THREAT}" = "strip" ]; then
    FLAGS+=("--on-threat=strip")
  fi

  if [ -n "${UNICODE_MAP}" ]; then
    for token in ${UNICODE_MAP}; do
      FLAGS+=("--unicode-map" "${token}")
    done
  fi

  if [ -n "${NO_UNICODE_MAP}" ]; then
    for token in ${NO_UNICODE_MAP}; do
      FLAGS+=("--no-unicode-map" "${token}")
    done
  fi
}

# JSON-encode a string using Python (available on all GitHub-hosted runners).
json_string() {
  python3 -c "import sys, json; print(json.dumps(sys.argv[1]), end='')" "$1"
}

# Read a file and JSON-encode its contents, truncating at MAX_OUTPUT_BYTES.
json_file_content() {
  local path="$1"
  python3 - "${path}" "${MAX_OUTPUT_BYTES}" <<'PYEOF'
import sys, json
path, limit = sys.argv[1], int(sys.argv[2])
with open(path, 'rb') as f:
    data = f.read(limit)
text = data.decode('utf-8', errors='replace')
print(json.dumps(text), end='')
PYEOF
}

# ---------------------------------------------------------------------------
# Parse file list
#
# Primary delimiter: newline. This preserves file paths that contain spaces.
# For convenience, a single-line input with no newlines is treated as a
# space-separated list — but note that file paths with spaces are not
# supported in that fallback form. Use newline-separated inputs when paths
# may contain spaces (the standard output of actions/changed-files).
# ---------------------------------------------------------------------------

_raw_input="${INPUT_FILES}"
# If the input contains no newlines, treat spaces as delimiters (simple one-liner form).
if ! printf '%s' "${_raw_input}" | grep -q $'\n'; then
  _raw_input="$(printf '%s' "${_raw_input}" | tr ' ' '\n')"
fi

mapfile -t FILES < <(printf '%s\n' "${_raw_input}" | sed '/^[[:space:]]*$/d')

if [ "${#FILES[@]}" -eq 0 ]; then
  echo "::error::No files provided to the strip-ansi action (input 'files' is empty)."
  exit 1
fi

log "Scanning ${#FILES[@]} file(s) with preset=${PRESET}, on-threat=${ON_THREAT}"

# ---------------------------------------------------------------------------
# Per-file processing
# ---------------------------------------------------------------------------

build_flags

THREAT_DETECTED=false
FILES_WITH_THREATS=""
RESULTS_JSON="["
FIRST_ENTRY=true

for file in "${FILES[@]}"; do
  if [ ! -f "${file}" ]; then
    warn "File not found, skipping: ${file}"
    continue
  fi

  out_file="${WORK_DIR}/$(basename "${file}").stripped"
  exit_code=0

  strip-ansi "${FLAGS[@]}" < "${file}" > "${out_file}" 2>/tmp/strip-ansi-stderr-$$ || exit_code=$?
  stderr_out="$(cat /tmp/strip-ansi-stderr-$$ 2>/dev/null || true)"
  rm -f /tmp/strip-ansi-stderr-$$

  # Determine status from exit code.
  # Exit 77 means the binary detected echoback attack vectors.
  # Exit 0 means clean (or stripped, if --on-threat=strip was passed).
  status="clean"
  output_path="${out_file}"

  if [ "${exit_code}" -eq 77 ]; then
    THREAT_DETECTED=true
    FILES_WITH_THREATS+="${file}"$'\n'
    status="threat"

    if [ "${ON_THREAT}" = "warn" ]; then
      echo "::warning file=${file}::Echoback attack vector detected in ${file}"
    fi

    # When on-threat=fail we do not expose the (unstripped) output.
    [ "${ON_THREAT}" = "fail" ] && output_path=""

  elif [ "${exit_code}" -eq 0 ]; then
    # Detect whether any bytes were actually changed.
    if ! diff -q "${file}" "${out_file}" &>/dev/null; then
      status="stripped"
    fi

  else
    # Unexpected exit code — surface the error and abort.
    [ -n "${stderr_out}" ] && echo "::error::strip-ansi stderr: ${stderr_out}"
    echo "::error file=${file}::strip-ansi exited with unexpected code ${exit_code} for ${file}"
    exit "${exit_code}"
  fi

  log "${file}: ${status}"
  [ -n "${stderr_out}" ] && log "  stderr: ${stderr_out}"

  # Build the output content JSON value.
  if [ -n "${output_path}" ] && [ -f "${output_path}" ]; then
    out_json="$(json_file_content "${output_path}")"
  else
    out_json='""'
  fi

  file_json="$(json_string "${file}")"
  entry="{\"file\":${file_json},\"status\":\"${status}\",\"output\":${out_json}}"

  if [ "${FIRST_ENTRY}" = "true" ]; then
    FIRST_ENTRY=false
  else
    RESULTS_JSON+=","
  fi
  RESULTS_JSON+="${entry}"
done

RESULTS_JSON+="]"

# ---------------------------------------------------------------------------
# Emit outputs to GITHUB_OUTPUT
# ---------------------------------------------------------------------------

{
  echo "results=${RESULTS_JSON}"
  echo "threat-detected=${THREAT_DETECTED}"
  printf 'files-with-threats<<_STRIP_ANSI_EOF\n%s_STRIP_ANSI_EOF\n' "${FILES_WITH_THREATS}"
} >> "${GITHUB_OUTPUT}"

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

rm -rf "${WORK_DIR}"

log "Done. threat-detected=${THREAT_DETECTED}"
