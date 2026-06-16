#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.build_app_env"

EXPANDER_REPO="${EXPANDER_GH_REPO:-Wayne-Richardson-Rheem/Expander-Releases}"
LOGFILE_REPO="${LOGFILE_XFR_GH_REPO:-Wayne-Richardson-Rheem/LogFileXfr-Releases}"
EXPANDER_TAG="${EXPANDER_RELEASE_TAG:-latest}"
LOGFILE_TAG="${LOGFILE_XFR_RELEASE_TAG:-latest}"
RUN_BUILD_TARGET=""

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --expander-repo <owner/repo>   Expander release repository
  --logfile-repo <owner/repo>    LogFileXfr release repository
  --expander-tag <tag|latest>    Expander release tag (default: latest)
  --logfile-tag <tag|latest>     LogFileXfr release tag (default: latest)
  --run-build <device>           Optional: run harden_pi.sh on device (e.g. /dev/sdX)
  --help                         Show this help

This script:
  1) installs prerequisite packages
  2) creates ~/Dev/Expander and ~/Dev/LogFileXfr
  3) writes environment exports to ${ENV_FILE}
  4) verifies release endpoints are reachable
  5) optionally runs harden_pi.sh with the configured env
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --expander-repo)
      EXPANDER_REPO="$2"
      shift 2
      ;;
    --logfile-repo)
      LOGFILE_REPO="$2"
      shift 2
      ;;
    --expander-tag)
      EXPANDER_TAG="$2"
      shift 2
      ;;
    --logfile-tag)
      LOGFILE_TAG="$2"
      shift 2
      ;;
    --run-build)
      RUN_BUILD_TARGET="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

echo "[INFO] Installing prerequisites..."
sudo apt update
sudo apt install -y curl python3 tar rsync coreutils

echo "[INFO] Preparing application directories..."
mkdir -p "$HOME/Dev/Expander" "$HOME/Dev/LogFileXfr"

echo "[INFO] Writing build environment file: ${ENV_FILE}"
cat > "$ENV_FILE" <<EOF
export FETCH_RELEASES=1
export EXPANDER_GH_REPO=${EXPANDER_REPO}
export LOGFILE_XFR_GH_REPO=${LOGFILE_REPO}
export EXPANDER_RELEASE_TAG=${EXPANDER_TAG}
export LOGFILE_XFR_RELEASE_TAG=${LOGFILE_TAG}
EOF

echo "[INFO] Verifying release endpoints..."
LOGFILE_LATEST_URL="https://raw.githubusercontent.com/${LOGFILE_REPO}/main/latest.txt"
if ! curl -fsSL "$LOGFILE_LATEST_URL" >/dev/null; then
  echo "[ERROR] Cannot fetch LogFileXfr latest.txt from ${LOGFILE_REPO}" >&2
  exit 1
fi

if [[ "$EXPANDER_TAG" == "latest" ]]; then
  EXPANDER_LATEST_URL="https://raw.githubusercontent.com/${EXPANDER_REPO}/main/latest.txt"
  if ! curl -fsSL "$EXPANDER_LATEST_URL" >/dev/null; then
    echo "[WARN] Cannot fetch Expander latest.txt from ${EXPANDER_REPO}" >&2
    echo "[WARN] Build will fail later unless repo/tag is corrected." >&2
  fi
fi

echo
echo "[INFO] Setup complete. Load env with:"
echo "       source ${ENV_FILE}"
echo
echo "[INFO] Then run build manually:"
echo "       cd ${SCRIPT_DIR}"
echo "       ./harden_pi.sh /dev/sdX"

if [[ -n "$RUN_BUILD_TARGET" ]]; then
  echo
  echo "[INFO] Running build now on target: ${RUN_BUILD_TARGET}"
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  cd "$SCRIPT_DIR"
  ./harden_pi.sh "$RUN_BUILD_TARGET"
fi
