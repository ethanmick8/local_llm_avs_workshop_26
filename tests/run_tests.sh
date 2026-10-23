#!/usr/bin/env bash
#
# Mocked checks for profile validation, backend selection, server arguments,
# the GUI catalog, and the Docker wrapper. No GPU, model, or Docker daemon is
# used: fake executables stand in, and model files are sparse files of the
# pinned size.

set -euo pipefail
IFS=$'\n\t'
umask 077

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/local-llm-tests.XXXXXXXX")
trap 'find "$scratch" -depth -delete' EXIT

failures=0
passes=0
pass() { passes=$((passes + 1)); echo "ok   $1"; }
fail() { failures=$((failures + 1)); echo "FAIL $1" >&2; [[ -z "${2:-}" ]] || printf '%s\n' "$2" | sed 's/^/     /' >&2; }
expect_success() {
    local name=$1 output; shift
    if output=$("$@" 2>&1); then pass "$name"; else fail "$name" "$output"; fi
}
expect_failure() {
    local name=$1 pattern=$2 output; shift 2
    if output=$("$@" 2>&1); then
        fail "$name (unexpectedly succeeded)" "$output"
    elif [[ "$output" == *"$pattern"* ]]; then
        pass "$name"
    else
        fail "$name (wrong error)" "$output"
    fi
}
expect_output() {
    local name=$1 output; shift 1
    local -a wanted=() unwanted=()
    while [[ "$1" != -- ]]; do
        if [[ "$1" == !* ]]; then unwanted+=("${1#!}"); else wanted+=("$1"); fi
        shift
    done
    shift
    if ! output=$("$@" 2>&1); then fail "$name (command failed)" "$output"; return; fi
    local item
    for item in "${wanted[@]}"; do
        [[ "$output" == *"$item"* ]] || { fail "$name (missing: $item)" "$output"; return; }
    done
    for item in "${unwanted[@]}"; do
        [[ "$output" != *"$item"* ]] || { fail "$name (unexpected: $item)" "$output"; return; }
    done
    pass "$name"
}

# --- fixtures ---------------------------------------------------------------
fake_bin="$scratch/bin"
data_root="$scratch/data"
workspace="$scratch/workspace"
mkdir -p "$fake_bin" "$data_root/models" "$workspace"
for tool in llama-server opencode nvidia-smi; do
    printf '#!/usr/bin/env bash\necho "fake %s $*"\n' "$tool" > "$fake_bin/$tool"
done
# The fake docker reports a reachable daemon and an existing image labeled with
# the backend its tag names (FAKE_IMAGE_BACKEND overrides the label), and prints
# build and run commands instead of executing them.
cat > "$fake_bin/docker" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
    info) exit 0 ;;
    image)
        if [[ -n "${FAKE_IMAGE_BACKEND+set}" ]]; then echo "$FAKE_IMAGE_BACKEND"
        elif [[ "${*: -1}" == *-cpu ]]; then echo cpu
        else echo cuda; fi
        exit 0 ;;
    build) echo "docker $*"; exit 0 ;;
    run) printf 'docker'; printf ' %s' "$@"; printf '\n'; exit 0 ;;
esac
exit 1
FAKE
chmod 755 "$fake_bin"/*
for profile in "$repo"/profiles/*.json; do
    model_file="$data_root/models/$(jq -r .gguf "$profile")"
    [[ -f "$model_file" ]] || truncate -s "$(jq -r .source.size_bytes "$profile")" "$model_file"
done

export PATH="$fake_bin:$PATH"
export CONDA_DEFAULT_ENV=ml CONDA_PREFIX="$scratch/conda"
export LLAMA_SERVER_BIN="$fake_bin/llama-server"
unset LOCAL_LLM_RUNTIME LOCAL_LLM_BACKEND LOCAL_LLM_PORT REASONING_EFFORT LOCAL_LLM_VERIFY_MODEL_HASH LOCAL_LLM_SITE_CONFIG

# Runs a snippet with the shared libraries sourced, as the launchers do.
with_lib() {
    (
        script_dir=$repo
        # shellcheck source=lib/local_llm.sh
        source "$repo/lib/local_llm.sh"
        # shellcheck source=lib/server_session.sh
        source "$repo/lib/server_session.sh"
        load_site
        resolve_data_root "$data_root"
        eval "$1"
    )
}

# --- profile validation -----------------------------------------------------
for profile in "$repo"/profiles/*.json; do
    id=$(basename "$profile" .json)
    expect_success "profile validates: $id" with_lib "load_profile $id"
done

mutate_cpu_profile() {
    local filter=$1 dir="$scratch/mutated"
    mkdir -p "$dir"
    jq "$filter" "$repo/profiles/gemma4-26b-a4b-q4-32k-cpu.json" > "$dir/profile.json"
    with_lib "validate_profile_file '$dir/profile.json'"
}
expect_failure "cpu profile rejects gpu_layers all" "invalid deployment profile" \
    mutate_cpu_profile '.llama.gpu_layers = "all"'
expect_failure "cpu profile rejects dense families" "invalid deployment profile" \
    mutate_cpu_profile '.family = "qwen3.8"'
expect_failure "cpu profile rejects fixed threads" "invalid deployment profile" \
    mutate_cpu_profile '.llama.threads = 16'
expect_failure "profile requires a known backend" "invalid deployment profile" \
    mutate_cpu_profile 'del(.backend)'

# --- backend resolution -----------------------------------------------------
expect_failure "host-native rejects cpu profile" "Docker-only" \
    with_lib "load_profile gemma4-26b-a4b-q4-32k-cpu; resolve_backend"
expect_failure "container rejects backend mismatch" "needs the cpu image" \
    with_lib "LOCAL_LLM_RUNTIME=container LOCAL_LLM_BACKEND=cuda; load_profile gemma4-26b-a4b-q4-32k-cpu; resolve_backend"
expect_output "cpu container uses cpu startup timeout" "timeout=180" -- \
    with_lib "LOCAL_LLM_RUNTIME=container LOCAL_LLM_BACKEND=cpu; load_profile gemma4-26b-a4b-q4-32k-cpu; resolve_backend; echo timeout=\$startup_timeout"

# --- server arguments -------------------------------------------------------
server_args_for() {
    with_lib "load_profile $1; resolve_reasoning_policy; print_sanitized_server_args"
}
expect_output "cuda server args" \
    "--n-gpu-layers all" "--kv-offload" "--threads 16" "--threads-batch 18" "--flash-attn on" \
    "!--device none" "!--no-kv-offload" -- \
    server_args_for gemma4-26b-a4b-q4-32k
expect_output "cpu server args" \
    "--device none" "--n-gpu-layers 0" "--no-kv-offload" "--flash-attn on" "--cache-type-k q8_0" \
    "!--threads" "!--n-gpu-layers all" -- \
    server_args_for gemma4-26b-a4b-q4-32k-cpu

# --- launcher ---------------------------------------------------------------
expect_output "launcher dry-run (cuda)" "Backend: cuda" "--n-gpu-layers all" "Dry run completed" -- \
    "$repo/launch_open_code.sh" --dry-run --data-root "$data_root" qwen38-27b-q4-32k "$workspace"
expect_failure "launcher refuses cpu profile host-native" "Docker-only" \
    "$repo/launch_open_code.sh" --dry-run --data-root "$data_root" gemma4-26b-a4b-q4-32k-cpu "$workspace"

# --- GUI catalog ------------------------------------------------------------
gui_catalog_ids() {
    with_lib "source '$repo/lib/gui_profile_catalog.sh'; build_gui_profile_catalog '$scratch/catalog.json'; jq -r '(.profiles[].profile_id), (.rejected[].file)' '$scratch/catalog.json'"
}
expect_output "gui catalog omits cpu profiles" "gemma4-26b-a4b-q4-32k" "qwen38-27b-q4-32k" "!-cpu" -- \
    gui_catalog_ids

# --- benchmark --------------------------------------------------------------
expect_failure "benchmark refuses cpu profile" "CUDA profiles only" \
    "$repo/benchmark_profile.sh" --data-root "$data_root" gemma4-26b-a4b-q4-32k-cpu

# --- Docker wrapper ---------------------------------------------------------
expect_output "docker wrapper (cuda)" "--gpus device=0" "-cuda12.8.1 /opt/local_llm/launch_open_code.sh" -- \
    "$repo/launch_open_code_docker.sh" --dry-run --data-root "$data_root" qwen38-27b-q4-32k "$workspace"
expect_output "docker wrapper (cpu)" "-cpu /opt/local_llm/launch_open_code.sh" "!--gpus" -- \
    "$repo/launch_open_code_docker.sh" --dry-run --data-root "$data_root" gemma4-26b-a4b-q4-32k-cpu "$workspace"
expect_output "docker wrapper reuses labeled image" "!docker build" -- \
    "$repo/launch_open_code_docker.sh" --dry-run --data-root "$data_root" qwen38-27b-q4-32k "$workspace"
expect_output "docker wrapper rebuilds unlabeled image" "docker build --target cuda" -- \
    env FAKE_IMAGE_BACKEND= "$repo/launch_open_code_docker.sh" --dry-run --data-root "$data_root" qwen38-27b-q4-32k "$workspace"
expect_output "docker build targets cpu" "docker build --target cpu" -- \
    env LOCAL_LLM_BACKEND=cpu "$repo/launch_open_code_docker.sh" --build
expect_output "docker build defaults to cuda" "docker build --target cuda" -- \
    "$repo/launch_open_code_docker.sh" --build
expect_failure "docker wrapper rejects conflicting backend" "conflicts with profile backend" \
    env LOCAL_LLM_BACKEND=cpu "$repo/launch_open_code_docker.sh" --dry-run --data-root "$data_root" qwen38-27b-q4-32k "$workspace"

echo
echo "$passes passed, $failures failed"
(( failures == 0 ))
