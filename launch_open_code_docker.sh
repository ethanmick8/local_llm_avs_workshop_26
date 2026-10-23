#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'
umask 077

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/local_llm.sh
source "$script_dir/lib/local_llm.sh"

usage() {
    cat >&2 <<'EOF'
Usage: launch_open_code_docker.sh --build
       launch_open_code_docker.sh [--build] [--check|--dry-run] [--workspace-id ID]
                                  [--data-root ABSOLUTE_PATH] <profile> <workdir>

Runs launch_open_code.sh inside the pinned container for the profile's
backend. No Conda environment is required on the host. CUDA profiles need
Docker with the NVIDIA Container Toolkit; CPU profiles (*-cpu) need only Docker
and are much slower.
--build rebuilds the image even if it already exists. A bare --build builds the
CUDA image, or the CPU image with LOCAL_LLM_BACKEND=cpu.
Operational overrides: REASONING_EFFORT=low|medium|high, LOCAL_LLM_PORT,
LOCAL_LLM_VERIFY_MODEL_HASH=1, LOCAL_LLM_GPU_DEVICE (CUDA only, default 0).
EOF
}

force_build=0
data_root_arg=""
launcher_args=()
positionals=()
while (( $# )); do
    case "$1" in
        --build) force_build=1; shift ;;
        --check|--dry-run) launcher_args+=("$1"); shift ;;
        --workspace-id) (( $# >= 2 )) || die "--workspace-id requires a value"; launcher_args+=("$1" "$2"); shift 2 ;;
        --data-root) (( $# >= 2 )) || die "--data-root requires a value"; data_root_arg=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        -*) die "unknown option: $1" ;;
        *) positionals+=("$1"); shift ;;
    esac
done
if (( ${#positionals[@]} == 0 && force_build == 1 && ${#launcher_args[@]} == 0 )) && [[ -z "$data_root_arg" ]]; then
    build_only=1
elif (( ${#positionals[@]} == 2 )); then
    build_only=0
else
    usage; exit 1
fi

for command in docker jq realpath id; do require_command "$command"; done
load_site
docker info >/dev/null 2>&1 ||
    die "cannot reach the Docker daemon; check that it is running and that you may use it (docker group or rootless Docker)"

jq -e '
  (.docker.cuda_version|test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) and
  (.docker.ubuntu_version|test("^[0-9]+\\.[0-9]+$")) and
  (.docker.image_repository|test("^[a-z0-9][a-z0-9._/-]*$"))
' "$site_config" >/dev/null || die "invalid docker section in site config: $site_config"

# The profile names its backend, which selects the image target. Full profile
# validation happens inside the container; this only picks the image.
if (( build_only == 1 )); then
    backend=${LOCAL_LLM_BACKEND:-cuda}
else
    [[ "${positionals[0]}" =~ ^[a-z0-9][a-z0-9-]+$ ]] || die "invalid profile ID: ${positionals[0]}"
    [[ -f "$script_dir/profiles/${positionals[0]}.json" ]] || die "unknown profile: ${positionals[0]}"
    backend=$(jq -r '.backend // empty' "$script_dir/profiles/${positionals[0]}.json")
    [[ -z "${LOCAL_LLM_BACKEND:-}" || "$LOCAL_LLM_BACKEND" == "$backend" ]] ||
        die "LOCAL_LLM_BACKEND=$LOCAL_LLM_BACKEND conflicts with profile backend: ${backend:-missing}"
fi
[[ "$backend" == cuda || "$backend" == cpu ]] || die "backend must be cuda or cpu: ${backend:-missing}"

llama_cpp_commit=$(jq -r .tools.llama_cpp_commit "$site_config")
opencode_version=$(jq -r .tools.opencode_version "$site_config")
cuda_version=$(jq -r .docker.cuda_version "$site_config")
image_tag="${llama_cpp_commit:0:12}-oc$opencode_version"
if [[ "$backend" == cuda ]]; then image_tag+="-cuda$cuda_version"; else image_tag+="-cpu"; fi
image="$(jq -r .docker.image_repository "$site_config"):$image_tag"

# Images built before backend selection existed carry no backend label; rebuild
# them rather than run a container whose backend the launcher cannot confirm.
image_backend=$(docker image inspect --format '{{index .Config.Labels "local-llm.backend"}}' "$image" 2>/dev/null || true)
if (( force_build == 1 )) || [[ "$image_backend" != "$backend" ]]; then
    echo "Building $image (llama.cpp $backend build; first build takes a while)..."
    docker build --target "$backend" \
        --build-arg "CUDA_VERSION=$cuda_version" \
        --build-arg "UBUNTU_VERSION=$(jq -r .docker.ubuntu_version "$site_config")" \
        --build-arg "LLAMA_CPP_COMMIT=$llama_cpp_commit" \
        --build-arg "CUDA_ARCHITECTURE=$(jq -r .tools.cuda_architecture "$site_config")" \
        --build-arg "OPENCODE_VERSION=$opencode_version" \
        --build-arg "OPENCODE_SHA256=$(jq -r .tools.opencode_sha256 "$site_config")" \
        --tag "$image" "$script_dir/docker"
fi
if (( build_only == 1 )); then echo "Image ready: $image"; exit 0; fi

resolve_data_root "$data_root_arg"
[[ -d "$data_root" ]] || die "data root does not exist: $data_root (create it and place models in $data_root/models)"
data_root=$(realpath -e "$data_root")
[[ -d "${positionals[1]}" ]] || die "workspace does not exist: ${positionals[1]}"
workdir=$(realpath -e "${positionals[1]}")

# Host paths are mounted at the same absolute path inside the container so
# workspace IDs, logs, and session data match host-native runs.
check_mount_path() {
    local label=$1 path=$2
    [[ "$path" != *,* && "$path" != *$'\n'* ]] || die "$label path must not contain commas or newlines: $path"
    case "$path" in
        /|/bin|/bin/*|/boot|/boot/*|/dev|/dev/*|/etc|/etc/*|/lib|/lib/*|/lib64|/lib64/*|/opt|/opt/local_llm|/opt/local_llm/*|/opt/llama.cpp|/opt/llama.cpp/*|/proc|/proc/*|/run|/run/*|/sbin|/sbin/*|/sys|/sys/*|/tmp|/usr|/usr/*|/var|/var/lib|/var/lib/*)
            die "$label path collides with container system paths: $path" ;;
    esac
}
check_mount_path "data root" "$data_root"
check_mount_path "workspace" "$workdir"

if [[ "$backend" == cuda ]]; then
    gpu_device=${LOCAL_LLM_GPU_DEVICE:-0}
    [[ "$gpu_device" =~ ^([0-9]+|GPU-[0-9a-fA-F-]+)$ ]] || die "LOCAL_LLM_GPU_DEVICE must be one GPU index or UUID"
fi

# Rootless Docker maps container root to the invoking user; rootful Docker
# needs the host UID/GID so generated files stay owned by the caller.
if docker info --format '{{json .SecurityOptions}}' 2>/dev/null | grep -q rootless; then
    container_user=0:0
else
    container_user="$(id -u):$(id -g)"
fi

docker_args=(
    run --rm --interactive --init
    --user "$container_user"
    --cap-drop ALL --security-opt no-new-privileges
    --env HOME=/tmp --env "TERM=${TERM:-xterm-256color}"
    --mount "type=bind,src=$script_dir,dst=/opt/local_llm,readonly"
    --mount "type=bind,src=$data_root,dst=$data_root"
    --workdir /opt/local_llm
)
# CPU containers get no GPU device at all.
[[ "$backend" != cuda ]] || docker_args+=(--gpus "device=$gpu_device")
[[ "$workdir" == "$data_root" || "$workdir" == "$data_root"/* ]] ||
    docker_args+=(--mount "type=bind,src=$workdir,dst=$workdir")
[[ -t 0 && -t 1 ]] && docker_args+=(--tty)
for variable in REASONING_EFFORT LOCAL_LLM_PORT LOCAL_LLM_VERIFY_MODEL_HASH COLORTERM LANG; do
    [[ -z "${!variable:-}" ]] || docker_args+=(--env "$variable=${!variable}")
done

exec docker "${docker_args[@]}" "$image" \
    /opt/local_llm/launch_open_code.sh "${launcher_args[@]}" --data-root "$data_root" \
    "${positionals[0]}" "$workdir"
