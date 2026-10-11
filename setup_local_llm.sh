#!/usr/bin/env bash
#
# RECONSTRUCTION — inferred from launch_open_code_gui.sh, launch_open_code.sh,
# benchmark_profile.sh, and lib/{local_llm,server_session,opencode_session,
# gui_profile_catalog}.sh. Not the original file. Every step below is backed
# by a specific die()/check in those scripts EXCEPT where marked INFERRED or
# UNCONFIRMED — see the chat message this was attached to for the mapping.

set -euo pipefail
IFS=$'\n\t'
umask 077

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/local_llm.sh
source "$script_dir/lib/local_llm.sh"

usage() {
    cat >&2 <<'EOF'
Usage: setup_local_llm.sh [--check] [--data-root ABSOLUTE_PATH]

Installs/builds the toolchain pinned in site-config.json:
  - the "ml" Conda environment with PyQt5 (conda-forge, exact version)
  - llama.cpp built from the pinned commit with CUDA (cuda_architecture)
  - the opencode CLI (pinned version)  [UNCONFIRMED install mechanism]

--check verifies an existing install and exits nonzero on any mismatch,
without installing or building anything.
EOF
}

mode=install
data_root_arg=""
while (( $# )); do
    case "$1" in
        --check) mode=check; shift ;;
        --data-root) (( $# >= 2 )) || die "--data-root requires a value"; data_root_arg=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

# git/cmake: INFERRED (needed to build llama.cpp from a pinned commit).
# jq/curl/nvidia-smi: confirmed elsewhere in the repo.
# conda: INFERRED (nothing in the other scripts shells out to conda directly;
#   require_ml_environment only checks $CONDA_DEFAULT_ENV/$CONDA_PREFIX, so
#   env creation here assumes the conda CLI itself, which is a reasonable but
#   unconfirmed inference).
for command in git cmake jq curl tar sha256sum nvidia-smi conda; do require_command "$command"; done

load_site
resolve_data_root "$data_root_arg"

# --- 1. Conda "ml" environment + PyQt5 (conda-forge, exact version) -------
# Confirmed: configure_pyqt_runtime() in local_llm.sh requires
# $CONDA_PREFIX/plugins/platforms/libqxcb.so, which is the conda-forge Qt
# layout, not pip's bundled-Qt wheel layout — so this must install from
# conda-forge specifically.
if conda env list | awk '{print $1}' | grep -qx "$conda_environment"; then
    echo "Conda environment '$conda_environment' already exists."
elif [[ "$mode" == check ]]; then
    die "Conda environment '$conda_environment' does not exist"
else
    # Python version pin: UNCONFIRMED — nothing in the other scripts fixes it.
    conda create -y -n "$conda_environment" -c conda-forge python "pyqt=$pyqt_version"
fi

# conda's own activation hooks are not `set -u` clean — the CUDA toolkit's
# ~cuda-nvcc_activate.sh dereferences NVCC_PREPEND_FLAGS/NVCC_APPEND_FLAGS
# before setting them, which aborts the script under nounset. Relax nounset
# across activation only, then restore it.
# shellcheck disable=SC1091
set +u
source "$(conda info --base)/etc/profile.d/conda.sh"
conda activate "$conda_environment"
set -u
require_ml_environment "$conda_environment"

installed_pyqt=$(python -c 'from PyQt5.QtCore import PYQT_VERSION_STR; print(PYQT_VERSION_STR)' 2>/dev/null || true)
if [[ "$installed_pyqt" != "$pyqt_version" ]]; then
    [[ "$mode" == check ]] &&
        die "PyQt5 mismatch: expected $pyqt_version, found ${installed_pyqt:-not installed}"
    conda install -y -n "$conda_environment" -c conda-forge "pyqt=$pyqt_version"
fi
configure_pyqt_runtime  # dies here if libqxcb.so still isn't present post-install

# --- 2. llama.cpp, pinned commit, CUDA build -------------------------------
# Confirmed by resolve_data_root: llama_source_dir / llama_build_dir /
# llama_server_bin paths. Confirmed by site-config validation:
# tools.llama_cpp_commit (exact 40-hex commit) and tools.cuda_architecture.
# Repo URL below is INFERRED (ggml-org/llama.cpp is current upstream as of
# training data, but verify against whatever the real setup script clones).
llama_cpp_commit=$(jq -r .tools.llama_cpp_commit "$site_config")
cuda_arch=$(jq -r .tools.cuda_architecture "$site_config")

built_commit=""
[[ -d "$llama_source_dir/.git" ]] && built_commit=$(git -C "$llama_source_dir" rev-parse HEAD 2>/dev/null || true)

if [[ "$mode" == check ]]; then
    [[ -x "$llama_server_bin" ]] || die "llama-server is not built: $llama_server_bin"
    [[ "$built_commit" == "$llama_cpp_commit" ]] ||
        die "llama.cpp built at ${built_commit:-<none>}, expected $llama_cpp_commit"
elif [[ ! -x "$llama_server_bin" || "$built_commit" != "$llama_cpp_commit" ]]; then
    mkdir -p "$tools_root"
    if [[ ! -d "$llama_source_dir/.git" ]]; then
        git clone https://github.com/ggml-org/llama.cpp "$llama_source_dir"  # INFERRED URL
    fi
    git -C "$llama_source_dir" fetch origin "$llama_cpp_commit"
    git -C "$llama_source_dir" checkout "$llama_cpp_commit"
    # Flags INFERRED from a standard GGML_CUDA build; server_session.sh's
    # --fit/--kv-offload/--reasoning-* args require a build recent enough to
    # support them, which is presumably why the commit is pinned at all.
    cmake -S "$llama_source_dir" -B "$llama_build_dir" \
        -DCMAKE_BUILD_TYPE=Release -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES="$cuda_arch"
    cmake --build "$llama_build_dir" --config Release --target llama-server -j"$(nproc)"
fi
[[ -x "$llama_server_bin" ]] || die "llama-server build did not produce $llama_server_bin"
"$llama_server_bin" --version

nvidia-smi --query-gpu=name,memory.total,compute_cap --format=csv,noheader

# --- 3. opencode CLI, pinned version ---------------------------------------
# Confirmed: launch_open_code.sh requires `opencode` on PATH and runs
# `opencode --version`, which on 0.4.2 prints a bare "0.4.2".
# Installed from the upstream single-file release zip and pinned by sha256,
# mirroring how llama.cpp is pinned by commit: no JS runtime, no installer
# fetched at build time, no shell-rc rewriting. Note the repo moved orgs —
# sst/opencode now redirects to anomalyco/opencode.
# Linux CLI assets are .tar.gz (the .zip form existed only on older releases).
# The non-baseline glibc asset requires AVX2; use -baseline and/or -musl
# variants on hosts without AVX2 or without glibc.
opencode_version=$(jq -r .tools.opencode_version "$site_config")
opencode_sha256=$(jq -r .tools.opencode_sha256 "$site_config")
opencode_bin=${OPENCODE_BIN:-$HOME/.local/bin/opencode}
installed_opencode=""
if command -v opencode >/dev/null 2>&1; then
    installed_opencode=$(opencode --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
fi
if [[ "$installed_opencode" != "$opencode_version" ]]; then
    [[ "$mode" == check ]] &&
        die "opencode mismatch: expected $opencode_version, found ${installed_opencode:-not installed}"
    opencode_url="https://github.com/anomalyco/opencode/releases/download/v$opencode_version/opencode-linux-x64.tar.gz"
    opencode_tmp=$(mktemp -d)
    trap 'rm -rf "$opencode_tmp"' EXIT
    curl -fsSL "$opencode_url" -o "$opencode_tmp/opencode.tar.gz" ||
        die "failed to download opencode $opencode_version from $opencode_url"
    printf '%s  %s\n' "$opencode_sha256" "$opencode_tmp/opencode.tar.gz" | sha256sum -c --quiet ||
        die "opencode $opencode_version checksum mismatch against tools.opencode_sha256"
    tar -xzf "$opencode_tmp/opencode.tar.gz" -C "$opencode_tmp"
    mkdir -p "$(dirname "$opencode_bin")"
    install -m 755 "$opencode_tmp/opencode" "$opencode_bin"
    rm -rf "$opencode_tmp"
    trap - EXIT
    hash -r
    command -v opencode >/dev/null 2>&1 ||
        die "installed $opencode_bin but it is not on PATH — add $(dirname "$opencode_bin") to PATH"
    installed_opencode=$(opencode --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
    [[ "$installed_opencode" == "$opencode_version" ]] ||
        die "installed opencode reports ${installed_opencode:-nothing}, expected $opencode_version"
fi

echo "setup_local_llm.sh: environment ready (mode=$mode, data_root=$data_root)"