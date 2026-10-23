#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

die() { echo "Error: $*" >&2; exit 1; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }
require_integer() { [[ "$2" =~ ^[0-9]+$ ]] || die "$1 must be a nonnegative integer"; }

require_ml_environment() {
    local expected=${1:-ml}
    # The pinned container image replaces the Conda environment; only trust
    # that marker when actually running inside a container.
    if [[ "${LOCAL_LLM_RUNTIME:-}" == container ]]; then
        [[ -f /.dockerenv || -f /run/.containerenv ]] ||
            die "LOCAL_LLM_RUNTIME=container is only valid inside the local-llm container image"
        return 0
    fi
    [[ "${CONDA_DEFAULT_ENV:-}" == "$expected" && -n "${CONDA_PREFIX:-}" ]] ||
        die "activate the '$expected' Conda environment first: conda activate $expected"
}

configure_pyqt_runtime() {
    local platform_plugin="$CONDA_PREFIX/plugins/platforms/libqxcb.so"
    [[ -f "$platform_plugin" ]] ||
        die "Conda Qt xcb platform plugin is missing: $platform_plugin; run ./setup_local_llm.sh"
    QT_PLUGIN_PATH="$CONDA_PREFIX/plugins"
    export QT_PLUGIN_PATH
    # The conda Qt ships only the xcb platform plugin, so pin the platform
    # explicitly: on a Wayland session Qt otherwise auto-selects "wayland",
    # logs "Could not find the Qt platform plugin" and only then falls back.
    # An explicit caller override still wins.
    QT_QPA_PLATFORM=${QT_QPA_PLATFORM:-xcb}
    export QT_QPA_PLATFORM
}

load_site() {
    site_config=${LOCAL_LLM_SITE_CONFIG:-$script_dir/site-config.json}
    [[ -f "$site_config" ]] || die "site config not found: $site_config"
    jq -e '
      .conda_environment == "ml" and .data_root != "" and
      .server.host == "127.0.0.1" and (.server.port|type) == "number" and
      (.server.cpu_startup_timeout_seconds|type) == "number" and
      (.tools.llama_cpp_commit|test("^[0-9a-f]{40}$")) and
      (.tools.opencode_version|test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) and
      (.tools.opencode_sha256|test("^[0-9a-f]{64}$")) and
      .tools.pyqt_version == "5.15.11" and
      .tools.cuda_architecture == "86"
    ' "$site_config" >/dev/null || die "invalid site config: $site_config"
    conda_environment=$(jq -r .conda_environment "$site_config")
    server_host=$(jq -r .server.host "$site_config")
    server_port=${LOCAL_LLM_PORT:-$(jq -r .server.port "$site_config")}
    require_integer LOCAL_LLM_PORT "$server_port"
    (( server_port >= 1024 && server_port <= 65535 )) || die "LOCAL_LLM_PORT must be between 1024 and 65535"
    startup_timeout=$(jq -r .server.startup_timeout_seconds "$site_config")
    shutdown_timeout=$(jq -r .server.shutdown_timeout_seconds "$site_config")
    cpu_startup_timeout=$(jq -r .server.cpu_startup_timeout_seconds "$site_config")
    pyqt_version=$(jq -r .tools.pyqt_version "$site_config")
}

resolve_data_root() {
    local requested=${1:-}
    if [[ -z "$requested" ]]; then
        requested=$(jq -r .data_root "$site_config")
        [[ "$requested" == /* ]] || requested="$script_dir/$requested"
    fi
    [[ "$requested" == /* ]] || die "data-root overrides must be absolute: $requested"
    data_root=$(realpath -m "$requested")
    model_root="$data_root/models"
    tools_root="$data_root/tools"
    llama_source_dir="$tools_root/llama.cpp"
    llama_build_dir="$llama_source_dir/build-local"
    llama_server_bin=${LLAMA_SERVER_BIN:-$llama_build_dir/bin/llama-server}
}

validate_profile_file() {
    local file=$1 expected=${2:-}
    jq -e --arg expected "$expected" '
      (if $expected == "" then true else .id == $expected end) and
      (.id|test("^[a-z0-9][a-z0-9-]+$")) and
      (.family == "gemma4" or .family == "muse-glimmer" or .family == "qwen3.8") and
      (.gguf|test("^[^/]+\\.gguf$")) and
      (.source.sha256|test("^[0-9a-f]{64}$")) and (.source.size_bytes > 0) and
      (.opencode_config|test("^configs/[^/]+\\.json$")) and
      .limits == {context:32768,output:8192,compaction_reserved:8192,preserve_recent_tokens:4096,tail_turns:2} and
      .llama.parallel == 1 and
      (if .backend == "cuda" then
         .llama.gpu_layers == "all" and .llama.threads == 16 and .llama.threads_batch == 18
       elif .backend == "cpu" then
         .family == "gemma4" and .llama.gpu_layers == 0 and
         .llama.threads == "auto" and .llama.threads_batch == "auto"
       else false end) and
      .llama.flash_attention == "on" and .llama.cache_type_k == "q8_0" and .llama.cache_type_v == "q8_0" and
      .llama.batch_size == 2048 and .llama.ubatch_size == 512 and
      (.reasoning.default_effort == "high") and
      (.reasoning.mode == "gemma-budget" or .reasoning.mode == "muse-strength" or .reasoning.mode == "qwen-effort")
    ' "$file" >/dev/null || die "invalid deployment profile: $file"
}

validate_profile_config_match() {
    local profile=$1 config=$2 model full_model
    model=$(jq -r .model "$profile")
    full_model="llama-server/$model"
    jq -e --arg model "$model" --arg full "$full_model" --slurpfile p "$profile" '
      .model == $full and .small_model == $full and .enabled_providers == ["llama-server"] and
      .compaction.reserved == $p[0].limits.compaction_reserved and
      .compaction.preserve_recent_tokens == $p[0].limits.preserve_recent_tokens and
      .compaction.tail_turns == $p[0].limits.tail_turns and
      .provider["llama-server"].models[$model].limit.context == $p[0].limits.context and
      .provider["llama-server"].models[$model].limit.output == $p[0].limits.output
    ' "$config" >/dev/null || die "OpenCode config does not match profile: $config"
}

load_profile() {
    profile_id=$1
    [[ "$profile_id" =~ ^[a-z0-9][a-z0-9-]+$ ]] || die "invalid profile ID: $profile_id"
    profile_file="$script_dir/profiles/$profile_id.json"
    [[ -f "$profile_file" ]] || die "unknown profile: $profile_id"
    validate_profile_file "$profile_file" "$profile_id"
    backend=$(jq -r .backend "$profile_file")
    model=$(jq -r .model "$profile_file")
    gguf=$(jq -r .gguf "$profile_file")
    model_file="$model_root/$gguf"
    opencode_config="$script_dir/$(jq -r .opencode_config "$profile_file")"
    [[ -f "$opencode_config" ]] || die "OpenCode config not found: $opencode_config"
    validate_profile_config_match "$profile_file" "$opencode_config"
}

# CPU profiles run only inside the CPU image; the container's baked-in backend
# must match the profile so a CUDA image never silently runs a CPU profile.
resolve_backend() {
    if [[ "${LOCAL_LLM_RUNTIME:-}" == container ]]; then
        [[ "${LOCAL_LLM_BACKEND:-}" == "$backend" ]] ||
            die "profile $profile_id needs the $backend image, but this container provides ${LOCAL_LLM_BACKEND:-an unknown backend}"
    else
        [[ "$backend" == cuda ]] ||
            die "$backend profiles are Docker-only: launch_open_code_docker.sh $profile_id <workdir>"
    fi
    [[ "$backend" != cpu ]] || startup_timeout=$cpu_startup_timeout
}

require_backend_commands() {
    [[ "$backend" != cuda ]] || require_command nvidia-smi
}

print_backend_hardware() {
    case "$backend" in
        cuda) nvidia-smi --query-gpu=name,memory.total --format=csv,noheader ;;
        cpu) echo "CPU threads: $(nproc); memory: $(awk '/^MemTotal:/ {printf "%.1f GiB", $2/1048576}' /proc/meminfo)" ;;
    esac
}

print_cpu_disclaimer() {
    [[ "$backend" == cpu ]] || return 0
    cat >&2 <<'EOF'
CPU mode: expect roughly 10-15 tokens/s generation and several minutes before
the first reply on a fresh session while the prompt is processed (about 2
minutes on a fast desktop, longer on laptops). Needs at least 32 GB RAM.
Use a CUDA profile on an NVIDIA GPU for interactive speed.
EOF
}

resolve_reasoning_policy() {
    reasoning_effort=${REASONING_EFFORT:-$(jq -r .reasoning.default_effort "$profile_file")}
    [[ "$reasoning_effort" =~ ^(low|medium|high)$ ]] || die "REASONING_EFFORT must be low, medium, or high"
    reasoning_mode=$(jq -r .reasoning.mode "$profile_file")
}

verify_model_file() {
    local expected_size actual_size
    [[ -f "$model_file" ]] || die "model not found: $model_file (download: $(jq -r .source.url "$profile_file"))"
    expected_size=$(jq -r .source.size_bytes "$profile_file")
    actual_size=$(stat -c %s "$model_file")
    [[ "$actual_size" == "$expected_size" ]] || die "model size mismatch for $model_file: expected $expected_size bytes, found $actual_size"
    [[ "${LOCAL_LLM_VERIFY_MODEL_HASH:-0}" =~ ^[01]$ ]] ||
        die "LOCAL_LLM_VERIFY_MODEL_HASH must be 0 or 1"
    if [[ "${LOCAL_LLM_VERIFY_MODEL_HASH:-0}" == 1 ]]; then
        echo "Verifying model SHA-256..."
        printf '%s  %s\n' "$(jq -r .source.sha256 "$profile_file")" "$model_file" | sha256sum --check --status || die "model SHA-256 mismatch: $model_file"
    else
        echo "Model size verified; SHA-256 verification skipped (set LOCAL_LLM_VERIFY_MODEL_HASH=1 to enable)."
    fi
}

derive_workspace_id() {
    local path=$1 explicit=${2:-} digest
    if [[ -n "$explicit" ]]; then
        [[ "$explicit" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$ ]] || die "invalid workspace ID"
        workspace_id=$explicit
    else
        digest=$(printf '%s' "$path" | sha256sum | cut -c1-12)
        workspace_id="$(basename "$path" | tr -cs 'A-Za-z0-9._-' '-' | cut -c1-40)-$digest"
    fi
}

new_run_id() { run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$-$RANDOM"; }

create_private_tree() {
    workspace_root="$data_root/workspaces/$workspace_id"
    run_dir="$workspace_root/runs/$run_id"
    mkdir -p "$model_root" "$tools_root" "$data_root/shared/cache" \
        "$workspace_root/data" "$workspace_root/state" "$workspace_root/config" \
        "$run_dir/logs" "$run_dir/secrets" "$run_dir/config" "$run_dir/tmp"
    chmod 700 "$data_root" "$model_root" "$tools_root" "$data_root/shared" "$data_root/shared/cache" \
        "$data_root/workspaces" "$workspace_root" "$workspace_root/data" "$workspace_root/state" \
        "$workspace_root/config" "$workspace_root/runs" "$run_dir" "$run_dir/logs" "$run_dir/secrets" "$run_dir/config" "$run_dir/tmp"
}

print_profile_summary() {
    jq '{id,backend,model,gguf,limits,llama,sampling,reasoning}' "$profile_file"
}
