#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'
umask 077

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/local_llm.sh
source "$script_dir/lib/local_llm.sh"
# shellcheck source=lib/gui_profile_catalog.sh
source "$script_dir/lib/gui_profile_catalog.sh"

usage() { echo "Usage: launch_open_code_gui.sh" >&2; }
if (( $# != 0 )); then usage; exit 1; fi

for command in jq python realpath stat; do require_command "$command"; done
load_site
require_ml_environment "$conda_environment"
[[ -n "${DISPLAY:-}" ]] || die "DISPLAY is not set; start the launcher from a WSLg/X11-enabled terminal"
configure_pyqt_runtime
python -c 'from PyQt5.QtCore import PYQT_VERSION_STR; from PyQt5.QtWidgets import QApplication' >/dev/null 2>&1 ||
    die "PyQt5 is unavailable in the '$conda_environment' environment; run ./setup_local_llm.sh"
installed_pyqt=$(python -c 'from PyQt5.QtCore import PYQT_VERSION_STR; print(PYQT_VERSION_STR)')
[[ "$installed_pyqt" == "$pyqt_version" ]] ||
    die "PyQt5 version mismatch: expected $pyqt_version, found $installed_pyqt; run ./setup_local_llm.sh"
python -c 'from PyQt5.QtCore import QTimer; from PyQt5.QtWidgets import QApplication; app=QApplication([]); QTimer.singleShot(0, app.quit); app.exec_()' \
    >/dev/null 2>&1 || die "PyQt5 cannot connect to the WSLg/X11 display; check DISPLAY and run ./setup_local_llm.sh --check"

[[ -d "$PWD" ]] || die "calling directory is unavailable: $PWD"
initial_workspace=$(realpath -e "$PWD")
resolve_data_root ""

gui_state=$(mktemp -d "${TMPDIR:-/tmp}/local-llm-gui.XXXXXXXX")
chmod 700 "$gui_state"
catalog_file="$gui_state/catalog.json"
result_file="$gui_state/result.json"
initial_file="$gui_state/initial-selection.json"
cleanup_gui() {
    local status=$?
    trap - EXIT INT TERM HUP
    find "$gui_state" -depth -delete 2>/dev/null || true
    exit "$status"
}
trap cleanup_gui EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

build_gui_profile_catalog "$catalog_file"
chmod 600 "$catalog_file"
settings_dir="$data_root/gui"
settings_file="$settings_dir/last-selection.json"
if [[ -f "$settings_file" && ! -L "$settings_file" ]]; then
    saved_workspace=$(jq -r 'if (.workspace | type) == "string" then .workspace else "" end' "$settings_file" 2>/dev/null || true)
    if [[ "$saved_workspace" == /* && "$saved_workspace" != *$'\n'* && "$saved_workspace" != *$'\r'* && -d "$saved_workspace" ]]; then
        saved_workspace=$(realpath -e "$saved_workspace")
    else
        saved_workspace=$initial_workspace
    fi
    jq -c --arg workspace "$saved_workspace" '.workspace = $workspace' "$settings_file" \
        > "$initial_file" 2>/dev/null || true
    [[ ! -s "$initial_file" ]] || chmod 600 "$initial_file"
fi

set +e
python "$script_dir/gui/open_code_launcher.py" \
    --catalog "$catalog_file" \
    --result "$result_file" \
    --initial-workspace "$initial_workspace" \
    --default-profile muse-glimmer-30b-q4-32k \
    --initial-selection "$initial_file"
gui_status=$?
set -e
if (( gui_status == 10 )); then exit 0; fi
(( gui_status == 0 )) || die "GUI launcher exited with status $gui_status"
[[ -f "$result_file" && ! -L "$result_file" ]] || die "GUI completed without a launch selection"
[[ "$(stat -c %a "$result_file")" == 600 ]] || die "GUI result file permissions are not private"

jq -e '
    type == "object" and
    ((keys | sort) == ["profile_id","reasoning_effort","workspace"]) and
    (.profile_id | type == "string" and length > 0) and
    (.reasoning_effort == "low" or .reasoning_effort == "medium" or .reasoning_effort == "high") and
    (.workspace | type == "string" and startswith("/") and (contains("\n") | not) and (contains("\r") | not))
' "$result_file" >/dev/null || die "GUI returned an invalid launch selection"

profile_id=$(jq -r .profile_id "$result_file")
reasoning_effort=$(jq -r .reasoning_effort "$result_file")
workspace_raw=$(jq -r .workspace "$result_file")
jq -e --arg id "$profile_id" --arg effort "$reasoning_effort" '
    .profiles[] | select(.profile_id == $id) | (.reasoning_efforts | index($effort)) != null
' "$catalog_file" >/dev/null || die "GUI returned an unsupported profile or reasoning effort"
[[ -d "$workspace_raw" ]] || die "selected workspace does not exist: $workspace_raw"
workspace=$(realpath -e "$workspace_raw")

mkdir -p "$settings_dir"
chmod 700 "$data_root" "$settings_dir"
settings_tmp=$(mktemp "$settings_dir/.last-selection.json.XXXXXXXX")
jq -cS --arg workspace "$workspace" '.workspace = $workspace' "$result_file" > "$settings_tmp"
chmod 600 "$settings_tmp"
mv -f -- "$settings_tmp" "$settings_file"

trap - EXIT INT TERM HUP
find "$gui_state" -depth -delete
exec env REASONING_EFFORT="$reasoning_effort" \
    "$script_dir/launch_open_code.sh" "$profile_id" "$workspace"
