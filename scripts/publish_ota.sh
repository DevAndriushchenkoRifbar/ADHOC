#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEFAULT_DROP_DIR="${REPO_ROOT}/drop"
WORKFLOW_FILE="publish-ota.yml"
BRANCH="main"
WATCH_RUN="true"

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
  --branch BRANCH       Workflow branch/ref (default: main)
  --no-watch            Do not watch GitHub Actions run
  -h, --help            Show this help

Examples:
  scripts/publish_ota.sh
  scripts/publish_ota.sh ./drop/COD.ipa
  scripts/publish_ota.sh ./drop/COD.ipa --tag v0.0.1 --branch main
EOF
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: required command not found: $cmd"
    exit 1
  fi
}

plist_read() {
  local plist_path="$1"
  local key="$2"
  /usr/libexec/PlistBuddy -c "Print :${key}" "$plist_path" 2>/dev/null || true
}

extract_info_plist() {
  local ipa_path="$1"
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  unzip -qq "$ipa_path" "Payload/*.app/Info.plist" -d "$tmp_dir"

  local plist_path
  plist_path="$(find "$tmp_dir/Payload" -name "Info.plist" -print -quit)"
  if [[ -z "$plist_path" ]]; then
    echo "Error: failed to find Info.plist inside IPA."
    rm -rf "$tmp_dir"
    exit 1
  fi

  echo "$tmp_dir|$plist_path"
}

pick_default_ipa() {
  local candidates=()
  shopt -s nullglob
  candidates=("${DEFAULT_DROP_DIR}"/*.ipa)
  shopt -u nullglob

  if [[ "${#candidates[@]}" -eq 0 ]]; then
    echo "Error: no .ipa files found in ${DEFAULT_DROP_DIR}"
    echo "Place one IPA into ${DEFAULT_DROP_DIR} or pass IPA_PATH explicitly."
    exit 1
  fi

  ls -t "${DEFAULT_DROP_DIR}"/*.ipa | head -n 1
}

extract_owner_repo() {
  local origin_url
  origin_url="$(git -C "$REPO_ROOT" config --get remote.origin.url || true)"
  if [[ -z "$origin_url" ]]; then
    echo "Error: git remote origin is not configured."
    exit 1
  fi

  local owner_repo
  if [[ "$origin_url" =~ ^git@github\.com:(.+)\.git$ ]]; then
    owner_repo="${BASH_REMATCH[1]}"
  elif [[ "$origin_url" =~ ^https://github\.com/(.+)\.git$ ]]; then
    owner_repo="${BASH_REMATCH[1]}"
  elif [[ "$origin_url" =~ ^https://github\.com/(.+)$ ]]; then
    owner_repo="${BASH_REMATCH[1]}"
  else
    echo "Error: unsupported GitHub remote format: $origin_url"
    exit 1
  fi

  echo "$owner_repo"
}

IPA_PATH=""
OVERRIDE_TAG=""
OVERRIDE_APP_NAME=""
OVERRIDE_BUNDLE_ID=""
OVERRIDE_VERSION=""
OVERRIDE_BUILD=""

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

require_cmd gh
require_cmd unzip
require_cmd python3

if ! gh auth status >/dev/null 2>&1; then
  echo "Error: GitHub CLI is not authenticated."
  echo "Run: gh auth login"
  exit 1
fi

if [[ -z "$IPA_PATH" ]]; then
  IPA_PATH="$(pick_default_ipa)"
fi

if [[ ! -f "$IPA_PATH" ]]; then
  echo "Error: IPA file not found: $IPA_PATH"
  exit 1
fi

extracted="$(extract_info_plist "$IPA_PATH")"
TMP_DIR="${extracted%%|*}"
INFO_PLIST="${extracted##*|}"
trap 'rm -rf "$TMP_DIR"' EXIT

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
  echo "Error: failed to resolve required metadata."
  echo "Resolved values:"
  echo "  app_name:        ${APP_NAME:-<empty>}"
  echo "  bundle_id:       ${BUNDLE_ID:-<empty>}"
  echo "  bundle_version:  ${BUNDLE_VERSION:-<empty>}"
  echo "  build_number:    ${BUILD_NUMBER:-<empty>}"
  exit 1
fi

if [[ -n "$OVERRIDE_TAG" ]]; then
  RELEASE_TAG="$OVERRIDE_TAG"
else
  RELEASE_TAG="v${BUNDLE_VERSION}-${BUILD_NUMBER}"
fi

IPA_ASSET_NAME="$(basename "$IPA_PATH")"
RELEASE_TITLE="${APP_NAME} ${BUNDLE_VERSION} (${BUILD_NUMBER})"
RELEASE_NOTES="Ad Hoc build ${BUNDLE_VERSION} (${BUILD_NUMBER})"

cd "$REPO_ROOT"
OWNER_REPO="$(extract_owner_repo)"
OWNER="${OWNER_REPO%%/*}"
REPO="${OWNER_REPO##*/}"

echo "Using IPA:           $IPA_PATH"
echo "App name:            $APP_NAME"
echo "Bundle ID:           $BUNDLE_ID"
echo "Version / Build:     $BUNDLE_VERSION ($BUILD_NUMBER)"
echo "Release tag:         $RELEASE_TAG"
echo "IPA asset name:      $IPA_ASSET_NAME"
echo

if gh release view "$RELEASE_TAG" >/dev/null 2>&1; then
  echo "Release exists. Uploading IPA asset with --clobber..."
  gh release upload "$RELEASE_TAG" "$IPA_PATH#$IPA_ASSET_NAME" --clobber
else
  echo "Release does not exist. Creating release and uploading IPA..."
  gh release create \
    "$RELEASE_TAG" \
    "$IPA_PATH#$IPA_ASSET_NAME" \
    --title "$RELEASE_TITLE" \
    --notes "$RELEASE_NOTES"
fi

echo "Triggering workflow: ${WORKFLOW_FILE}"
gh workflow run "$WORKFLOW_FILE" \
  --ref "$BRANCH" \
  -f app_name="$APP_NAME" \
  -f bundle_id="$BUNDLE_ID" \
  -f bundle_version="$BUNDLE_VERSION" \
  -f build_number="$BUILD_NUMBER" \
  -f release_tag="$RELEASE_TAG" \
  -f ipa_asset_name="$IPA_ASSET_NAME"

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

echo
echo "Workflow dispatched."
echo "Expected install page URL after success:"
echo "  ${INSTALL_PAGE_URL}"
echo "Predicted install URL format:"
echo "  ${INSTALL_URL}"

if [[ "$WATCH_RUN" == "true" ]]; then
  echo
  echo "Waiting for latest workflow run..."
  RUN_ID=""
  for _ in $(seq 1 20); do
    RUN_ID="$(gh run list --workflow "$WORKFLOW_FILE" --limit 1 --json databaseId --jq '.[0].databaseId' 2>/dev/null || true)"
    if [[ -n "$RUN_ID" && "$RUN_ID" != "null" ]]; then
      break
    fi
    sleep 3
  done

  if [[ -n "$RUN_ID" && "$RUN_ID" != "null" ]]; then
    gh run watch "$RUN_ID" || true
    RUN_URL="$(gh run view "$RUN_ID" --json url --jq '.url' 2>/dev/null || true)"
    if [[ -n "$RUN_URL" && "$RUN_URL" != "null" ]]; then
      echo "Run URL: ${RUN_URL}"
    fi
  else
    echo "Could not detect run ID automatically."
    echo "Open Actions tab and check latest run for ${WORKFLOW_FILE}."
  fi
fi
