#!/bin/bash
# Exercise the uninstall script only against a disposable, sentinel-protected fixture.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
UNINSTALL_SCRIPT="$ROOT_DIR/scripts/uninstall-macos.sh"
FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/networkporteval-uninstall-test.XXXXXX")"
FIXTURE="$(cd -L "$FIXTURE" && pwd -L)"
trap 'rm -rf -- "$FIXTURE"' EXIT

touch "$FIXTURE/.networkporteval-uninstall-test-root"

HOME_ROOT="$FIXTURE/home"
APP_SUPPORT="$HOME_ROOT/Library/Application Support/NetworkPortEval"
CUSTOM_REPORTS="$HOME_ROOT/Company/NetworkPortEval Reports"

mkdir -p \
  "$FIXTURE/Applications/NetworkPortEval.app/Contents" \
  "$HOME_ROOT/Applications/NetworkPortEval.app/Contents" \
  "$HOME_ROOT/Downloads/NetworkPortEval.app/Contents" \
  "$APP_SUPPORT/Settings" \
  "$APP_SUPPORT/Templates" \
  "$APP_SUPPORT/Reports" \
  "$HOME_ROOT/Library/Application Support/FluxCheck" \
  "$HOME_ROOT/Library/Preferences/ByHost" \
  "$HOME_ROOT/Library/Saved Application State/com.networkporteval.desktop.savedState" \
  "$HOME_ROOT/Library/Caches/com.networkporteval.desktop" \
  "$HOME_ROOT/Library/Caches/NetworkPortEval" \
  "$HOME_ROOT/Library/Containers/com.networkporteval.desktop" \
  "$CUSTOM_REPORTS"

python3 - "$FIXTURE" "$HOME_ROOT" "$CUSTOM_REPORTS" <<'PY'
import json
import pathlib
import plistlib
import sys

fixture = pathlib.Path(sys.argv[1])
home = pathlib.Path(sys.argv[2])
custom_reports = pathlib.Path(sys.argv[3])
bundle_id = "com.networkporteval.desktop"

for app in (
    fixture / "Applications/NetworkPortEval.app",
    home / "Applications/NetworkPortEval.app",
    home / "Downloads/NetworkPortEval.app",
):
    info = {
        "CFBundleIdentifier": bundle_id,
        "CFBundleName": "NetworkPortEval",
    }
    with (app / "Contents/Info.plist").open("wb") as stream:
        plistlib.dump(info, stream)

support = home / "Library/Application Support/NetworkPortEval"
(support / "Settings/preferences.json").write_text(
    json.dumps({"reportsFolder": str(custom_reports)}), encoding="utf-8"
)
(support / "Templates/templates.json").write_text("{}", encoding="utf-8")
(support / "Reports/report.json").write_text("{}", encoding="utf-8")
(custom_reports / "12345678-1234-abcd-9876-1234567890ab.json").write_text(json.dumps({
    "id": "12345678-1234-ABCD-9876-1234567890AB",
    "name": "Network report test",
    "createdAt": 813024000,
    "flows": [],
}), encoding="utf-8")
(custom_reports / "folders.json").write_text("[]", encoding="utf-8")
(custom_reports / "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.json").write_text(
    json.dumps({"id": "different-record", "name": "Personal note", "flows": []}),
    encoding="utf-8",
)
(custom_reports / "unrelated.txt").write_text("keep me", encoding="utf-8")
(custom_reports / "nested").mkdir()
(custom_reports / "nested/12345678-1234-abcd-9876-1234567890ab.json").write_text(
    "keep nested files", encoding="utf-8"
)
(home / "Library/Application Support/FluxCheck/legacy.json").write_text(
    "{}", encoding="utf-8"
)
(home / "Library/Preferences/com.networkporteval.desktop.plist").write_bytes(
    plistlib.dumps({"reportsFolder": str(custom_reports)})
)
(home / "Library/Preferences/ByHost/com.networkporteval.desktop.1234.plist").write_bytes(
    plistlib.dumps({"example": True})
)
PY

assert_absent() {
  if [[ -e "$1" || -L "$1" ]]; then
    echo "Expected path to be removed: $1" >&2
    exit 1
  fi
}

assert_present() {
  if [[ ! -e "$1" ]]; then
    echo "Expected path to be preserved: $1" >&2
    exit 1
  fi
}

CANCEL_ROOT="$FIXTURE/cancel-root"
CANCEL_HOME="$CANCEL_ROOT/home"
CANCEL_SUPPORT="$CANCEL_HOME/Library/Application Support/NetworkPortEval"
CANCEL_REPORTS="$CANCEL_HOME/Reports"
mkdir -p "$CANCEL_SUPPORT/Settings" "$CANCEL_REPORTS"
touch "$CANCEL_ROOT/.networkporteval-uninstall-test-root"
python3 - "$CANCEL_SUPPORT/Settings/preferences.json" "$CANCEL_REPORTS" <<'PY'
import json, pathlib, sys
pathlib.Path(sys.argv[1]).write_text(
    json.dumps({"reportsFolder": sys.argv[2]}), encoding="utf-8"
)
(pathlib.Path(sys.argv[2]) / "keep.txt").write_text("keep on cancel", encoding="utf-8")
PY
cancel_output="$(printf 'no\n' | NETWORKPORTEVAL_UNINSTALL_TEST_ROOT="$CANCEL_ROOT" \
  "$UNINSTALL_SCRIPT" --apply 2>&1)"
if [[ "$cancel_output" != *"Cancelled; nothing was removed."* ]]; then
  echo "Expected a non-DELETE confirmation to cancel uninstall." >&2
  exit 1
fi
assert_present "$CANCEL_SUPPORT/Settings/preferences.json"
assert_present "$CANCEL_REPORTS/keep.txt"

printf 'DELETE\n' | NETWORKPORTEVAL_UNINSTALL_TEST_ROOT="$FIXTURE" \
  "$UNINSTALL_SCRIPT" --apply >/dev/null

assert_absent "$APP_SUPPORT"
assert_absent "$HOME_ROOT/Library/Application Support/FluxCheck"
assert_absent "$HOME_ROOT/Library/Preferences/com.networkporteval.desktop.plist"
assert_absent "$HOME_ROOT/Library/Preferences/ByHost/com.networkporteval.desktop.1234.plist"
assert_absent "$HOME_ROOT/Library/Saved Application State/com.networkporteval.desktop.savedState"
assert_absent "$HOME_ROOT/Library/Caches/com.networkporteval.desktop"
assert_absent "$HOME_ROOT/Library/Caches/NetworkPortEval"
assert_absent "$HOME_ROOT/Library/Containers/com.networkporteval.desktop"
assert_absent "$FIXTURE/Applications/NetworkPortEval.app"
assert_absent "$HOME_ROOT/Applications/NetworkPortEval.app"
assert_absent "$HOME_ROOT/Downloads/NetworkPortEval.app"
assert_absent "$CUSTOM_REPORTS/12345678-1234-abcd-9876-1234567890ab.json"
assert_absent "$CUSTOM_REPORTS/folders.json"
assert_present "$CUSTOM_REPORTS/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.json"
assert_present "$CUSTOM_REPORTS/unrelated.txt"
assert_present "$CUSTOM_REPORTS/nested/12345678-1234-abcd-9876-1234567890ab.json"
assert_present "$CUSTOM_REPORTS"

MALFORMED_ROOT="$FIXTURE/malformed-root"
MALFORMED_HOME="$MALFORMED_ROOT/home"
MALFORMED_SUPPORT="$MALFORMED_HOME/Library/Application Support/NetworkPortEval"
MALFORMED_REPORTS="$MALFORMED_HOME/Company/Reports"
mkdir -p "$MALFORMED_ROOT"
touch "$MALFORMED_ROOT/.networkporteval-uninstall-test-root"
mkdir -p "$MALFORMED_SUPPORT/Settings" "$MALFORMED_REPORTS"
python3 - "$MALFORMED_SUPPORT/Settings/preferences.json" "$MALFORMED_REPORTS" <<'PY'
import json, pathlib, sys
pathlib.Path(sys.argv[1]).write_text(
    json.dumps({"reportsFolder": sys.argv[2]}), encoding="utf-8"
)
reports = pathlib.Path(sys.argv[2])
(reports / "folders.json").write_text('{"unrelated": true}', encoding="utf-8")
(reports / "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.json").write_text(
    json.dumps({"id": "not-a-report", "name": "Keep this"}), encoding="utf-8"
)
PY
printf 'DELETE\n' | NETWORKPORTEVAL_UNINSTALL_TEST_ROOT="$FIXTURE/malformed-root" \
  "$UNINSTALL_SCRIPT" --apply >/dev/null
assert_present "$MALFORMED_REPORTS/folders.json"
assert_present "$MALFORMED_REPORTS/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.json"

LINK_ROOT="$FIXTURE/link-root"
LINK_HOME="$LINK_ROOT/home"
LINK_SUPPORT="$LINK_HOME/Library/Application Support/NetworkPortEval"
LINK_TARGET="$LINK_HOME/Company/Reports"
mkdir -p "$LINK_SUPPORT/Settings" "$LINK_TARGET"
touch "$LINK_ROOT/.networkporteval-uninstall-test-root"
ln -s "$LINK_TARGET" "$LINK_HOME/Reports Link"
python3 - "$LINK_SUPPORT/Settings/preferences.json" "$LINK_HOME/Reports Link" "$LINK_TARGET" <<'PY'
import json, pathlib, sys
pathlib.Path(sys.argv[1]).write_text(
    json.dumps({"reportsFolder": sys.argv[2]}), encoding="utf-8"
)
(pathlib.Path(sys.argv[3]) / "12345678-1234-abcd-9876-1234567890ab.json").write_text(
    json.dumps({
        "id": "12345678-1234-abcd-9876-1234567890ab",
        "name": "Linked report",
        "createdAt": 813024000,
        "flows": [],
    }),
    encoding="utf-8",
)
PY
printf 'DELETE\n' | NETWORKPORTEVAL_UNINSTALL_TEST_ROOT="$LINK_ROOT" \
  "$UNINSTALL_SCRIPT" --apply >/dev/null
assert_present "$LINK_HOME/Reports Link"
assert_present "$LINK_TARGET/12345678-1234-abcd-9876-1234567890ab.json"

ESCAPE_ROOT="$FIXTURE/escape-root"
ESCAPE_HOME="$ESCAPE_ROOT/home"
OUTSIDE_REPORTS="$FIXTURE/outside-reports"
mkdir -p "$ESCAPE_HOME/Library/Application Support/NetworkPortEval/Settings" "$OUTSIDE_REPORTS"
touch "$ESCAPE_ROOT/.networkporteval-uninstall-test-root"
python3 - "$ESCAPE_HOME/Library/Application Support/NetworkPortEval/Settings/preferences.json" "$OUTSIDE_REPORTS" <<'PY'
import json, pathlib, sys
pathlib.Path(sys.argv[1]).write_text(
    json.dumps({"reportsFolder": sys.argv[2]}), encoding="utf-8"
)
report = pathlib.Path(sys.argv[2]) / "12345678-1234-abcd-9876-1234567890ab.json"
report.write_text(json.dumps({
    "id": "12345678-1234-abcd-9876-1234567890ab",
    "name": "Outside fixture report",
    "createdAt": 813024000,
    "flows": [],
}), encoding="utf-8")
PY
escape_output="$(printf 'DELETE\n' | NETWORKPORTEVAL_UNINSTALL_TEST_ROOT="$ESCAPE_ROOT" \
  "$UNINSTALL_SCRIPT" --apply 2>&1)"
if [[ "$escape_output" != *"Skipping custom report folder outside the isolated test root."* ]]; then
  echo "Expected the isolated mode to reject a custom folder outside its test root." >&2
  exit 1
fi
assert_present "$OUTSIDE_REPORTS/12345678-1234-abcd-9876-1234567890ab.json"

echo "Isolated uninstall self-test passed."
