#!/bin/bash
# Keep this compatible with the Bash 3.2 shipped with macOS.
set -eo pipefail

APP_NAME="NetworkPortEval"
BUNDLE_ID="com.networkporteval.desktop"
TEST_ROOT="${NETWORKPORTEVAL_UNINSTALL_TEST_ROOT:-}"
if [[ -n "$TEST_ROOT" ]]; then
  if [[ "$TEST_ROOT" != /* || ! -d "$TEST_ROOT" || -L "$TEST_ROOT" || ! -f "$TEST_ROOT/.networkporteval-uninstall-test-root" ]]; then
    echo "Test root must be an existing absolute, non-symlink directory with the uninstall-test sentinel." >&2
    exit 2
  fi
  TEST_ROOT="$(cd -L "$TEST_ROOT" && pwd -L)"
  HOME="$TEST_ROOT/home"
  APP_SEARCH_ROOTS=("$TEST_ROOT/Applications" "$HOME/Applications" "$HOME/Downloads" "$HOME/Desktop")
else
  APP_SEARCH_ROOTS=(/Applications "$HOME/Applications" "$HOME/Downloads" "$HOME/Desktop")
fi
SUPPORT_ROOT="$HOME/Library/Application Support"
APP_SUPPORT="$SUPPORT_ROOT/NetworkPortEval"
LEGACY_SUPPORT="$SUPPORT_ROOT/FluxCheck"
DEFAULT_REPORTS="$APP_SUPPORT/Reports"
PREFERENCES="$HOME/Library/Preferences/$BUNDLE_ID.plist"
SAVED_STATE="$HOME/Library/Saved Application State/$BUNDLE_ID.savedState"

APPLY=0
case "${1:-}" in
  "") ;;
  --apply) APPLY=1 ;;
  --help|-h)
    cat <<'EOF'
Usage: scripts/uninstall-macos.sh [--apply]

Without --apply, show what would be removed. With --apply, show the same
preview and require typing DELETE before removing NetworkPortEval app data
and matching app bundles found in standard install/download locations.

Custom report folders are listed separately. Only JSON files whose contents
match the NetworkPortEval report or folder-metadata format are eligible for
deletion there; other files and the folder itself are preserved. Recent
temporary email drafts are preserved.
EOF
    exit 0
    ;;
  *) echo "Unknown option: $1" >&2; exit 2 ;;
esac

declare -a TARGETS=()
declare -a CUSTOM_REPORTS=()
declare -a APP_BUNDLES=()
declare -a BYHOST_PREFS=()

add_if_present() {
  if [[ -e "$1" || -L "$1" ]]; then TARGETS+=("$1"); fi
}

add_if_present "$APP_SUPPORT"
add_if_present "$LEGACY_SUPPORT"
add_if_present "$PREFERENCES"
add_if_present "$SAVED_STATE"
add_if_present "$HOME/Library/Caches/$BUNDLE_ID"
add_if_present "$HOME/Library/Caches/$APP_NAME"
add_if_present "$HOME/Library/Containers/$BUNDLE_ID"

shopt -s nullglob
BYHOST_PREFS=("$HOME"/Library/Preferences/ByHost/"$BUNDLE_ID".*.plist)
for path in "${BYHOST_PREFS[@]}"; do add_if_present "$path"; done

# Find only bundles whose Info.plist has this app's exact bundle identifier.
for root in "${APP_SEARCH_ROOTS[@]}"; do
  [[ -d "$root" ]] || continue
  while IFS= read -r -d '' app; do
    bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null || true)
    if [[ "$bundle_id" == "$BUNDLE_ID" ]]; then APP_BUNDLES+=("$app"); fi
  done < <(find "$root" -maxdepth 5 -type d -name "$APP_NAME.app" -prune -print0 2>/dev/null)
done
for path in "${APP_BUNDLES[@]}"; do add_if_present "$path"; done

# Read a user-selected report folder before deleting the settings that remember it.
custom_reports=""
if [[ -f "$APP_SUPPORT/Settings/preferences.json" ]]; then
  custom_reports=$(python3 - "$APP_SUPPORT/Settings/preferences.json" <<'PY' 2>/dev/null || true
import json, sys
try:
    value = json.load(open(sys.argv[1], encoding="utf-8")).get("reportsFolder", "")
    if isinstance(value, str): print(value)
except Exception:
    pass
PY
)
fi
if [[ -z "$custom_reports" && -z "$TEST_ROOT" ]] && command -v defaults >/dev/null 2>&1; then
  custom_reports=$(defaults read "$BUNDLE_ID" reportsFolder 2>/dev/null || true)
fi
if [[ -n "$custom_reports" ]]; then
  custom_reports="${custom_reports/#\~/$HOME}"
  case "$custom_reports" in
    "$TEST_ROOT"/*) ;;
    *) if [[ -n "$TEST_ROOT" ]]; then
    echo "Skipping custom report folder outside the isolated test root." >&2
    custom_reports=""
    fi ;;
  esac
  if [[ "$custom_reports" != "$DEFAULT_REPORTS" && -d "$custom_reports" && ! -L "$custom_reports" ]]; then
    CUSTOM_REPORTS+=("$custom_reports")
  fi
fi

echo "NetworkPortEval full uninstall preview"
echo
if ((${#TARGETS[@]})); then
  echo "Will remove these app bundles and app-specific settings/data:"
  for path in "${TARGETS[@]}"; do printf '  %s\n' "$path"; done
else
  echo "No app bundle or standard app data was found in the checked locations."
fi
if ((${#CUSTOM_REPORTS[@]})); then
  echo
  echo "Custom report folder(s) found outside Application Support:"
  for path in "${CUSTOM_REPORTS[@]}"; do printf '  %s\n' "$path"; done
  echo "Only app-shaped report JSON files and folder metadata are eligible for deletion."
  echo "Other files and the custom folder itself will be preserved."
fi
echo
echo "Recent temporary email drafts are preserved. Remove old drafts manually if desired."

if (( ! APPLY )); then
  echo "Preview only. Run with --apply to continue to the confirmation prompt."
  exit 0
fi

echo
echo "This permanently deletes app settings, templates, schedules and reports in the listed NetworkPortEval/FluxCheck data folders."
read -r -p 'Type DELETE to continue: ' confirmation
if [[ "$confirmation" != "DELETE" ]]; then echo "Cancelled; nothing was removed."; exit 0; fi

# Do not race the app while it is writing templates, reports or preferences.
if [[ -z "$TEST_ROOT" ]] && pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  echo "$APP_NAME is still running. Quit the app, then run this script again; nothing was removed." >&2
  exit 1
fi

for path in "${TARGETS[@]}"; do
  # Refuse symlinks and paths outside the user's Library or the app search roots.
  if [[ -L "$path" ]]; then echo "Skipping symlink: $path"; continue; fi
  case "$path" in
    "$HOME/Library/"*|/Applications/*|"$HOME/Applications/"*|"$HOME/Downloads/"*|"$HOME/Desktop/"*|"$TEST_ROOT/Applications/"*)
      if ! rm -rf -- "$path"; then echo "Could not remove (move it to Trash manually if needed): $path"; fi
      ;;
    *) echo "Skipping unexpected path: $path" ;;
  esac
done

for folder in "${CUSTOM_REPORTS[@]}"; do
  [[ -d "$folder" && ! -L "$folder" ]] || continue
  while IFS= read -r -d '' file; do
    name=${file##*/}
    if [[ "$name" == "folders.json" ]] && python3 - "$file" <<'PY'
import json, sys, uuid
try:
    value = json.load(open(sys.argv[1], encoding="utf-8"))
    valid = isinstance(value, list) and all(
        isinstance(item, dict)
        and isinstance(item.get("id"), str)
        and isinstance(item.get("name"), str)
        and bool(item["name"].strip())
        and str(uuid.UUID(item["id"])).lower() == item["id"].lower()
        for item in value
    )
except (OSError, ValueError, TypeError):
    valid = False
sys.exit(0 if valid else 1)
PY
    then
      if [[ ! -L "$file" ]]; then rm -f -- "$file" || echo "Could not remove folder metadata: $file"; fi
    elif [[ "$name" =~ ^([[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12})\.json$ ]] && python3 - "$file" "${BASH_REMATCH[1]}" <<'PY'
import json, sys, uuid
try:
    expected_id = str(uuid.UUID(sys.argv[2]))
    value = json.load(open(sys.argv[1], encoding="utf-8"))
    valid = (
        isinstance(value, dict)
        and isinstance(value.get("id"), str)
        and str(uuid.UUID(value["id"])) == expected_id
        and isinstance(value.get("name"), str)
        and isinstance(value.get("flows"), list)
        and "createdAt" in value
    )
except (OSError, ValueError, TypeError):
    valid = False
sys.exit(0 if valid else 1)
PY
    then
      if [[ ! -L "$file" ]]; then rm -f -- "$file" || echo "Could not remove report file: $file"; fi
    fi
  done < <(find "$folder" -maxdepth 1 -type f -print0)
  rmdir "$folder" 2>/dev/null || true
done

if [[ -z "$TEST_ROOT" ]]; then defaults delete "$BUNDLE_ID" 2>/dev/null || true; fi
echo "NetworkPortEval app data removed. Empty the Trash if you moved any remaining app copies there."
