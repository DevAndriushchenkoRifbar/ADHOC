#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEFAULT_DROP_DIR="${REPO_ROOT}/drop"
WORKFLOW_FILE="publish-ota.yml"
BRANCH="main"
WATCH_RUN="true"
EXPECTED_BUNDLE_ID="com.codxxx.COD"
LOG_DIR="${REPO_ROOT}/logs"
LOG_FILE=""
LOG_PIPE_DIR=""
LOG_PIPE=""
TEE_PID=""
TMP_DIR=""
INFO_PLIST=""

timestamp() {
  date +"%Y-%m-%d %H:%M:%S"
}

log() {
  printf '[%s] %s\n' "$(timestamp)" "$*" >&2
}

fail() {
  log "Error: $*"
  exit 1
}

cleanup() {
  local exit_code="$?"
  set +x
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    rm -rf "$TMP_DIR"
  fi
  if [[ -n "$LOG_PIPE" && -p "$LOG_PIPE" ]]; then
    rm -f "$LOG_PIPE"
  fi
  if [[ -n "$LOG_PIPE_DIR" && -d "$LOG_PIPE_DIR" ]]; then
    rm -rf "$LOG_PIPE_DIR"
  fi
  return "$exit_code"
}

setup_logging() {
  mkdir -p "$LOG_DIR" || fail "failed to create log directory ${LOG_DIR}"
  LOG_FILE="${LOG_DIR}/publish_ota_$(date +%Y%m%d_%H%M%S).log"
  LOG_PIPE_DIR="$(mktemp -d)" || fail "failed to create temporary log directory"
  LOG_PIPE="${LOG_PIPE_DIR}/stream"
  mkfifo "$LOG_PIPE" || fail "failed to create log pipe"
  tee -a "$LOG_FILE" < "$LOG_PIPE" &
  TEE_PID="$!"
  exec > "$LOG_PIPE" 2>&1
  export PS4='+ [$(date "+%Y-%m-%d %H:%M:%S")] ${BASH_SOURCE##*/}:${LINENO}: '
  set -x
  log "Logging to ${LOG_FILE}"
}

resolve_ipa_path() {
  local raw_path="$1"
  if [[ -z "$raw_path" ]]; then
    return 0
  fi

  if [[ "$raw_path" == /* ]]; then
    printf '%s\n' "$raw_path"
    return 0
  fi

  if [[ -f "$raw_path" ]]; then
    printf '%s\n' "$(cd "$(dirname "$raw_path")" && pwd)/$(basename "$raw_path")"
    return 0
  fi

  if [[ -f "${REPO_ROOT}/${raw_path}" ]]; then
    printf '%s\n' "${REPO_ROOT}/${raw_path}"
    return 0
  fi

  printf '%s\n' "$raw_path"
}

usage() {
  cat <<'EOF'
Usage:
  scripts/publish_ota.sh [IPA_PATH] [options]

Behavior:
  - If IPA_PATH is omitted, script picks the newest *.ipa from ./drop/
  - Extracts app metadata from IPA Info.plist
  - Creates or updates GitHub Release with IPA asset
  - Triggers workflow_dispatch for publish-ota.yml

Options:
  --tag TAG             Release tag (default: v<version>-<build>)
  --app-name NAME       Override app display name
  --bundle-id ID        Override bundle identifier
  --version VERSION     Override marketing version
  --build BUILD         Override build number
  --notes TEXT          Human-readable release notes shown on install page
  --notes-file PATH     Read release notes from text file
  --branch BRANCH       Workflow branch/ref (default: main)
  --no-watch            Do not watch GitHub Actions run
  -h, --help            Show this help

Examples:
  scripts/publish_ota.sh
  scripts/publish_ota.sh ./drop/COD.ipa
  scripts/publish_ota.sh ./drop/COD.ipa --notes "Fixed login and improved sync"
  scripts/publish_ota.sh ./drop/COD.ipa --tag v0.0.1 --branch main
EOF
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    fail "required command not found: $cmd"
  fi
  log "Found required command: $cmd"
}

plist_read() {
  local plist_path="$1"
  local key="$2"
  /usr/libexec/PlistBuddy -c "Print :${key}" "$plist_path" 2>/dev/null || true
}

extract_info_plist() {
  local ipa_path="$1"
  TMP_DIR="$(mktemp -d)" || fail "failed to create temporary directory"
  log "Extracting Info.plist from ${ipa_path} into ${TMP_DIR}"
  unzip -q "$ipa_path" "Payload/*.app/Info.plist" -d "$TMP_DIR" || fail "failed to extract Info.plist from ${ipa_path}"

  local plist_path
  plist_path="$(find "$TMP_DIR/Payload" -name "Info.plist" -print -quit)"
  if [[ -z "$plist_path" ]]; then
    log "Error: failed to find Info.plist inside IPA."
    rm -rf "$TMP_DIR"
    TMP_DIR=""
    exit 1
  fi

  log "Resolved Info.plist: ${plist_path}"
  INFO_PLIST="$plist_path"
}

pick_default_ipa() {
  local candidates=()
  shopt -s nullglob
  candidates=("${DEFAULT_DROP_DIR}"/*.ipa)
  shopt -u nullglob

  if [[ "${#candidates[@]}" -eq 0 ]]; then
    fail "no .ipa files found in ${DEFAULT_DROP_DIR}. Place one IPA there or pass IPA_PATH explicitly."
  fi

  ls -t "${DEFAULT_DROP_DIR}"/*.ipa | head -n 1
}

extract_owner_repo() {
  local origin_url
  origin_url="$(git -C "$REPO_ROOT" config --get remote.origin.url || true)"
  if [[ -z "$origin_url" ]]; then
    fail "git remote origin is not configured."
  fi

  local owner_repo
  if [[ "$origin_url" =~ ^git@github\.com:(.+)\.git$ ]]; then
    owner_repo="${BASH_REMATCH[1]}"
  elif [[ "$origin_url" =~ ^https://[^@/]+@github\.com/(.+)\.git$ ]]; then
    owner_repo="${BASH_REMATCH[1]}"
  elif [[ "$origin_url" =~ ^https://github\.com/(.+)\.git$ ]]; then
    owner_repo="${BASH_REMATCH[1]}"
  elif [[ "$origin_url" =~ ^https://github\.com/(.+)$ ]]; then
    owner_repo="${BASH_REMATCH[1]}"
  else
    fail "unsupported GitHub remote format: $origin_url"
  fi

  log "Resolved GitHub remote: ${owner_repo}"
  echo "$owner_repo"
}

trap cleanup EXIT

IPA_PATH=""
OVERRIDE_TAG=""
OVERRIDE_APP_NAME=""
OVERRIDE_BUNDLE_ID=""
OVERRIDE_VERSION=""
OVERRIDE_BUILD=""
OVERRIDE_NOTES=""
OVERRIDE_NOTES_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      OVERRIDE_TAG="$2"
      shift 2
      ;;
    --app-name)
      OVERRIDE_APP_NAME="$2"
      shift 2
      ;;
    --bundle-id)
      OVERRIDE_BUNDLE_ID="$2"
      shift 2
      ;;
    --version)
      OVERRIDE_VERSION="$2"
      shift 2
      ;;
    --build)
      OVERRIDE_BUILD="$2"
      shift 2
      ;;
    --notes)
      OVERRIDE_NOTES="$2"
      shift 2
      ;;
    --notes-file)
      OVERRIDE_NOTES_FILE="$2"
      shift 2
      ;;
    --branch)
      BRANCH="$2"
      shift 2
      ;;
    --no-watch)
      WATCH_RUN="false"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
    *)
      if [[ -n "$IPA_PATH" ]]; then
        echo "Error: multiple IPA paths provided."
        exit 1
      fi
      IPA_PATH="$1"
      shift
      ;;
  esac
done

if [[ -n "$OVERRIDE_NOTES" && -n "$OVERRIDE_NOTES_FILE" ]]; then
  fail "use either --notes or --notes-file, not both"
fi

setup_logging
log "Starting OTA publish script from ${PWD}"

require_cmd gh
require_cmd unzip
require_cmd python3

if ! gh auth status >/dev/null 2>&1; then
  fail "GitHub CLI is not authenticated. Run: gh auth login"
fi
log "GitHub CLI authentication is valid"

if [[ -z "$IPA_PATH" ]]; then
  log "IPA path was not provided explicitly, searching in ${DEFAULT_DROP_DIR}"
  IPA_PATH="$(pick_default_ipa)"
fi
IPA_PATH="$(resolve_ipa_path "$IPA_PATH")"
log "Resolved IPA path: ${IPA_PATH}"

if [[ ! -f "$IPA_PATH" ]]; then
  fail "IPA file not found: $IPA_PATH"
fi

extract_info_plist "$IPA_PATH"
log "Temporary extraction directory: ${TMP_DIR}"

BUNDLE_ID="$(plist_read "$INFO_PLIST" "CFBundleIdentifier")"
BUNDLE_VERSION="$(plist_read "$INFO_PLIST" "CFBundleShortVersionString")"
BUILD_NUMBER="$(plist_read "$INFO_PLIST" "CFBundleVersion")"
APP_NAME="$(plist_read "$INFO_PLIST" "CFBundleDisplayName")"
if [[ -z "$APP_NAME" ]]; then
  APP_NAME="$(plist_read "$INFO_PLIST" "CFBundleName")"
fi

if [[ -n "$OVERRIDE_BUNDLE_ID" ]]; then BUNDLE_ID="$OVERRIDE_BUNDLE_ID"; fi
if [[ -n "$OVERRIDE_VERSION" ]]; then BUNDLE_VERSION="$OVERRIDE_VERSION"; fi
if [[ -n "$OVERRIDE_BUILD" ]]; then BUILD_NUMBER="$OVERRIDE_BUILD"; fi
if [[ -n "$OVERRIDE_APP_NAME" ]]; then APP_NAME="$OVERRIDE_APP_NAME"; fi

if [[ -z "$BUNDLE_ID" || -z "$BUNDLE_VERSION" || -z "$BUILD_NUMBER" || -z "$APP_NAME" ]]; then
  log "Resolved values:"
  log "  app_name:        ${APP_NAME:-<empty>}"
  log "  bundle_id:       ${BUNDLE_ID:-<empty>}"
  log "  bundle_version:  ${BUNDLE_VERSION:-<empty>}"
  log "  build_number:    ${BUILD_NUMBER:-<empty>}"
  fail "failed to resolve required metadata"
fi

if [[ "$BUNDLE_ID" != "$EXPECTED_BUNDLE_ID" ]]; then
  fail "unexpected bundle identifier: ${BUNDLE_ID}. Expected: ${EXPECTED_BUNDLE_ID}"
fi

if [[ -n "$OVERRIDE_TAG" ]]; then
  RELEASE_TAG="$OVERRIDE_TAG"
else
  RELEASE_TAG="v${BUNDLE_VERSION}-${BUILD_NUMBER}"
fi

PAGE_RELEASE_NOTES=""
if [[ -n "$OVERRIDE_NOTES_FILE" ]]; then
  NOTES_PATH="$(resolve_ipa_path "$OVERRIDE_NOTES_FILE")"
  if [[ ! -f "$NOTES_PATH" ]]; then
    fail "release notes file not found: ${NOTES_PATH}"
  fi
  PAGE_RELEASE_NOTES="$(<"$NOTES_PATH")"
elif [[ -n "$OVERRIDE_NOTES" ]]; then
  PAGE_RELEASE_NOTES="$OVERRIDE_NOTES"
fi

IPA_ASSET_NAME="$(basename "$IPA_PATH")"
RELEASE_TITLE="${APP_NAME} ${BUNDLE_VERSION} (${BUILD_NUMBER})"
RELEASE_NOTES="Ad Hoc build ${BUNDLE_VERSION} (${BUILD_NUMBER})"
if [[ -n "$PAGE_RELEASE_NOTES" ]]; then
  RELEASE_NOTES="$PAGE_RELEASE_NOTES"
fi

RELEASE_NOTES_B64=""
if [[ -n "$PAGE_RELEASE_NOTES" ]]; then
  RELEASE_NOTES_B64="$(
    PAGE_RELEASE_NOTES="$PAGE_RELEASE_NOTES" python3 - <<'PY'
import base64
import os

print(base64.b64encode(os.environ["PAGE_RELEASE_NOTES"].encode("utf-8")).decode("ascii"))
PY
  )"
fi

cd "$REPO_ROOT" || fail "failed to enter repository root ${REPO_ROOT}"
OWNER_REPO="$(extract_owner_repo)" || fail "failed to resolve GitHub owner/repo from remote origin"
OWNER="${OWNER_REPO%%/*}"
REPO="${OWNER_REPO##*/}"

log "Using IPA:           $IPA_PATH"
log "App name:            $APP_NAME"
log "Bundle ID:           $BUNDLE_ID"
log "Version / Build:     $BUNDLE_VERSION ($BUILD_NUMBER)"
log "Release tag:         $RELEASE_TAG"
log "IPA asset name:      $IPA_ASSET_NAME"
if [[ -n "$PAGE_RELEASE_NOTES" ]]; then
  log "Release notes:       attached"
else
  log "Release notes:       not provided"
fi

if gh release view "$RELEASE_TAG" >/dev/null 2>&1; then
  log "Release ${RELEASE_TAG} exists. Uploading IPA asset with --clobber."
  gh release upload "$RELEASE_TAG" "$IPA_PATH#$IPA_ASSET_NAME" --clobber || fail "failed to upload IPA to release ${RELEASE_TAG}"
else
  log "Release ${RELEASE_TAG} does not exist. Creating release and uploading IPA."
  gh release create \
    "$RELEASE_TAG" \
    "$IPA_PATH#$IPA_ASSET_NAME" \
    --title "$RELEASE_TITLE" \
    --notes "$RELEASE_NOTES" || fail "failed to create release ${RELEASE_TAG}"
fi

log "Triggering workflow: ${WORKFLOW_FILE}"
workflow_args=(
  --ref "$BRANCH"
  -f "app_name=$APP_NAME"
  -f "bundle_id=$BUNDLE_ID"
  -f "bundle_version=$BUNDLE_VERSION"
  -f "build_number=$BUILD_NUMBER"
  -f "release_tag=$RELEASE_TAG"
  -f "ipa_asset_name=$IPA_ASSET_NAME"
)

if [[ -n "$RELEASE_NOTES_B64" ]]; then
  workflow_args+=(-f "release_notes_b64=$RELEASE_NOTES_B64")
fi

gh workflow run "$WORKFLOW_FILE" "${workflow_args[@]}" || fail "failed to trigger workflow ${WORKFLOW_FILE}"

MANIFEST_URL="https://github.com/${OWNER}/${REPO}/releases/download/${RELEASE_TAG}/manifest.plist"
ENCODED_MANIFEST_URL="$(
python3 - <<PY
import urllib.parse
print(urllib.parse.quote("${MANIFEST_URL}", safe=""))
PY
)"
INSTALL_URL="itms-services://?action=download-manifest&url=${ENCODED_MANIFEST_URL}"
if [[ "$REPO" == "${OWNER}.github.io" ]]; then
  INSTALL_PAGE_URL="https://${OWNER}.github.io"
else
  INSTALL_PAGE_URL="https://${OWNER}.github.io/${REPO}"
fi

log "Workflow dispatched."
log "Expected install page URL after success: ${INSTALL_PAGE_URL}"
log "Predicted install URL format: ${INSTALL_URL}"

if [[ "$WATCH_RUN" == "true" ]]; then
  log "Waiting for latest workflow run."
  RUN_ID=""
  for _ in $(seq 1 20); do
    RUN_ID="$(gh run list --workflow "$WORKFLOW_FILE" --limit 1 --json databaseId --jq '.[0].databaseId' 2>/dev/null || true)"
    if [[ -n "$RUN_ID" && "$RUN_ID" != "null" ]]; then
      break
    fi
    sleep 3
  done

  if [[ -n "$RUN_ID" && "$RUN_ID" != "null" ]]; then
    log "Detected run ID: ${RUN_ID}"
    gh run watch "$RUN_ID" || true
    RUN_URL="$(gh run view "$RUN_ID" --json url --jq '.url' 2>/dev/null || true)"
    if [[ -n "$RUN_URL" && "$RUN_URL" != "null" ]]; then
      log "Run URL: ${RUN_URL}"
    fi
  else
    log "Could not detect run ID automatically."
    log "Open Actions tab and check latest run for ${WORKFLOW_FILE}."
  fi
fi

log "Completed successfully. Full log: ${LOG_FILE}"
