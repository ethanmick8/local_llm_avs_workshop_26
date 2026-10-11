#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'
umask 077

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/local_llm.sh
source "$script_dir/lib/local_llm.sh"
# shellcheck source=lib/server_session.sh
source "$script_dir/lib/server_session.sh"
# shellcheck source=lib/opencode_session.sh
source "$script_dir/lib/opencode_session.sh"

usage() {
    cat >&2 <<'EOF'
Usage: launch_open_code.sh [--check|--dry-run] [--workspace-id ID]
                           [--data-root ABSOLUTE_PATH] <profile> <workdir>

Activate the ml Conda environment first. Operational overrides:
REASONING_EFFORT=low|medium|high, LOCAL_LLM_PORT, LOCAL_LLM_VERIFY_MODEL_HASH=1.
EOF
}

mode=run
workspace_id_arg=""
data_root_arg=""
positionals=()
while (( $# )); do
    case "$1" in
        --check) [[ "$mode" == run ]] || die "choose only one of --check and --dry-run"; mode=check; shift ;;
        --dry-run) [[ "$mode" == run ]] || die "choose only one of --check and --dry-run"; mode=dry-run; shift ;;
        --workspace-id) (( $# >= 2 )) || die "--workspace-id requires a value"; workspace_id_arg=$2; shift 2 ;;
        --data-root) (( $# >= 2 )) || die "--data-root requires a value"; data_root_arg=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        -*) die "unknown option: $1" ;;
        *) positionals+=("$1"); shift ;;
    esac
done
(( ${#positionals[@]} == 2 )) || { usage; exit 1; }

for command in jq curl openssl sha256sum realpath nvidia-smi; do require_command "$command"; done
load_site
require_ml_environment "$conda_environment"
resolve_data_root "$data_root_arg"
load_profile "${positionals[0]}"
resolve_reasoning_policy
requested_workdir=${positionals[1]}
[[ -d "$requested_workdir" ]] || die "workspace does not exist: $requested_workdir"
workdir=$(realpath -e "$requested_workdir")
derive_workspace_id "$workdir" "$workspace_id_arg"

[[ -x "$llama_server_bin" ]] || die "llama-server is not installed: run ./setup_local_llm.sh"
require_command opencode
verify_model_file

echo "Profile: $profile_id"
echo "Model: $model_file"
echo "Workspace: $workdir"
echo "Workspace ID: $workspace_id"
echo "Reasoning effort: $reasoning_effort"

if [[ "$mode" == check ]]; then
    "$llama_server_bin" --version >/dev/null
    opencode --version >/dev/null
    nvidia-smi --query-gpu=name,memory.total --format=csv,noheader
    echo "Launch preflight completed; no server was started."
    exit 0
fi

if [[ "$mode" == dry-run ]]; then
    print_sanitized_server_args
    echo "OpenCode config: $opencode_config"
    echo "Data root: $data_root"
    echo "Dry run completed; no key or runtime directory was created."
    exit 0
fi

new_run_id
create_private_tree
run_metadata="$run_dir/run.json"
jq -n --arg run_id "$run_id" --arg profile "$profile_id" --arg workspace_id "$workspace_id" \
    --arg workdir "$workdir" --arg started_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{run_id:$run_id,profile:$profile,workspace_id:$workspace_id,workdir:$workdir,started_at:$started_at,transport:"authenticated-localhost"}' > "$run_metadata"
chmod 600 "$run_metadata"

cleanup() {
    local status=$?
    trap - EXIT INT TERM HUP
    stop_server
    if [[ -n "${run_dir:-}" && -d "$run_dir" ]]; then
        find "$run_dir/secrets" "$run_dir/config" "$run_dir/tmp" -type f -delete 2>/dev/null || true
        rmdir "$run_dir/secrets" "$run_dir/config" "$run_dir/tmp" 2>/dev/null || true
        find "$run_dir" -maxdepth 1 -type f -name 'server.pid' -delete
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

start_server
echo "Logs: $run_dir/logs"
echo "Starting OpenCode; exiting OpenCode will stop llama-server."
run_opencode
echo "OpenCode exited successfully. Logs and workspace-scoped session data were retained."
