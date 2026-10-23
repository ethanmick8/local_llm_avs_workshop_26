#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'
umask 077

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$script_dir/lib/local_llm.sh"
source "$script_dir/lib/server_session.sh"

usage() { echo "Usage: benchmark_profile.sh [--repeats N] [--max-tokens N] [--data-root ABSOLUTE_PATH] <profile>" >&2; }
repeats=3
max_tokens=256
data_root_arg=""
while (( $# )); do
    case "$1" in
        --repeats) repeats=$2; shift 2 ;;
        --max-tokens) max_tokens=$2; shift 2 ;;
        --data-root) data_root_arg=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        -*) die "unknown option: $1" ;;
        *) [[ -z "${profile_arg:-}" ]] || die "only one profile may be supplied"; profile_arg=$1; shift ;;
    esac
done
[[ -n "${profile_arg:-}" ]] || { usage; exit 1; }
require_integer --repeats "$repeats"; require_integer --max-tokens "$max_tokens"
(( repeats > 0 && max_tokens > 0 )) || die "repeat and token counts must be positive"

for command in jq curl openssl sha256sum realpath nvidia-smi; do require_command "$command"; done
load_site
require_ml_environment "$conda_environment"
resolve_data_root "$data_root_arg"
load_profile "$profile_arg"
[[ "$backend" == cuda ]] || die "benchmark_profile.sh supports CUDA profiles only: $profile_id is $backend"
resolve_reasoning_policy
verify_model_file
workdir="$data_root/benchmarks/$profile_id"
mkdir -p "$workdir"
chmod 700 "$data_root" "$data_root/benchmarks" "$workdir"
derive_workspace_id "$workdir" "benchmark-$profile_id"
new_run_id
create_private_tree

cleanup() {
    local status=$?
    trap - EXIT INT TERM HUP
    stop_server
    find "$run_dir/secrets" "$run_dir/config" "$run_dir/tmp" -type f -delete 2>/dev/null || true
    rmdir "$run_dir/secrets" "$run_dir/config" "$run_dir/tmp" 2>/dev/null || true
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

started=$SECONDS
start_server
load_seconds=$((SECONDS - started))
results="$run_dir/benchmark.jsonl"
for ((i=1; i<=repeats; i++)); do
    response="$run_dir/response-$i.json"
    timing=$(curl --config "$curl_config" --max-time 900 -H 'Content-Type: application/json' \
        --output "$response" --write-out '%{time_starttransfer} %{time_total}' \
        --data-binary "$(jq -nc --arg model "$model" --argjson n "$max_tokens" '{model:$model,messages:[{role:"user",content:"Write a concise explanation of how a hash table handles collisions."}],max_tokens:$n,seed:42}')" \
        "http://$server_host:$server_port/v1/chat/completions")
    IFS=' ' read -r ttft wall <<< "$timing"
    jq -c --argjson repeat "$i" --arg ttft "$ttft" --arg wall "$wall" \
        --argjson load_seconds "$load_seconds" '{repeat:$repeat,load_seconds:$load_seconds,time_to_first_response_seconds:($ttft|tonumber),wall_seconds:($wall|tonumber),usage:.usage,timings:.timings}' \
        "$response" >> "$results"
done
nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu --format=csv,noheader > "$run_dir/gpu.csv"
jq -s '{runs:length,average_wall_seconds:(map(.wall_seconds)|add/length),average_predicted_tokens_per_second:(map(.timings.predicted_per_second // 0)|add/length)}' "$results"
echo "Benchmark results: $run_dir"
