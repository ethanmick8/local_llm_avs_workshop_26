# AGENTS.md

## Mission

This repository runs a pinned CUDA llama.cpp server and OpenCode locally on a
single RTX 3090 Linux host (native or WSL2), either from the `ml` Conda
environment or inside the pinned Docker image. A Docker-only CPU fallback image
exists for hosts without an NVIDIA GPU; it is explicitly slow and limited to the
Gemma MoE profile. It does not target Slurm,
Enroot, Windows-native execution, or remote cluster storage. Never restart,
shut down, update, or reconfigure WSL, Windows, or the Docker daemon from
repository automation.

## Supported interface

The launcher is profile-only:

```text
launch_open_code.sh [--check|--dry-run] [--workspace-id ID]
                    [--data-root ABSOLUTE_PATH] <profile> <workdir>
```

The optional local PyQt selector is started as `launch_open_code_gui.sh` with
no arguments. It may expose only validated profiles, workspace selection, and
profile-supported reasoning effort, and must hand off to the CLI launcher
rather than duplicate the server lifecycle.

The container path is `launch_open_code_docker.sh [--build] <launcher args>`.
It must stay a thin host wrapper: build the toolchain-only image from
`docker/Dockerfile` with every pin taken from `site-config.json`, bind-mount the
repository read-only and the data root and workspace at their host paths, and
run `launch_open_code.sh` inside the container. The image holds only
llama-server and OpenCode; it never contains models, keys, or repository
profiles. The profile's `backend` (`cuda` or `cpu`) selects the Dockerfile
target and image tag; the image bakes in `LOCAL_LLM_BACKEND` and the launcher
refuses a profile whose backend differs. The wrapper publishes no ports, exposes
exactly one GPU (`LOCAL_LLM_GPU_DEVICE`, default 0) for CUDA and no GPU for CPU,
and runs as the invoking user.

The checked-in profiles are authoritative. Context, output, compaction,
GPU layers, cache, batching, sampling, and reasoning policy belong in profiles
and exact OpenCode configs. Operational overrides are limited to data root,
workspace ID, port, reasoning effort, and opt-in model hash verification.

## Environment and setup

Host-native runs require the existing `ml` Conda environment to be active; do
not silently activate or recreate it. Inside the image, `LOCAL_LLM_RUNTIME=container`
replaces that check and is honored only when a container marker file exists.
`setup_local_llm.sh` may install pinned packages into
that environment using only `conda-forge` with
`--override-channels`. Do not accept default-channel terms, use sudo, install a
Windows driver, invoke `wsl.exe`, or restart WSL. Build llama.cpp from the exact
commit in `site-config.json` with CUDA and architecture 86. Install the exact
OpenCode and PyQt versions from the same config.

Models, tool checkouts/builds, credentials, runtime state, sessions, and logs
are generated under ignored `local_llm_data/` and must not be committed. Model
downloads remain an explicit user action. Profiles pin filename, byte size, and
SHA-256 and must link to their source.

## Runtime and security

Bind llama.cpp only to `127.0.0.1`. Each run uses a random 32-byte API key held
in mode-0600 files; never print or persist the value. Disable the llama.cpp Web
UI. Start OpenCode only after public health and authenticated model checks pass.
Stop only the child server PID owned by the launcher, using bounded TERM/KILL
cleanup. Keep workspace-scoped OpenCode data and shared cache separate from
run-scoped keys, overlays, temp files, and logs. Use umask `077` and mode `0700`.
Full data resets may remove only the known generated `shared`, `workspaces`,
`benchmarks`, `validations`, and `gui` directories after an exact preview and
confirmation. They must preserve `models`, `tools`, and unknown entries.

CUDA profiles assume one RTX 3090, one parallel slot, all layers on GPU, Q8 K/V
cache, Flash Attention, and no automatic fitting or CPU layer offload. CPU
profiles are Docker-only, limited to the `gemma4` family, and use
`gpu_layers: 0`, `--device none`, no KV offload, and `"auto"` threads so
llama.cpp sizes to the host; they keep Q8 K/V cache, Flash Attention, and the
same limits. Host-native runs, the GUI, and benchmarking are CUDA-only. Do not
add multimodal projectors, speculative draft models, partial CPU offload,
multiple GPUs, other GPU backends (e.g. Vulkan), or LAN binding without an
explicit design change and real VRAM validation.

## Development

Keep deployment and lifecycle implementation in Bash and JSON. The native GUI
selector is the only Python exception and must remain a thin, non-privileged
front end to `launch_open_code.sh`. Preserve strict mode, explicit quoting,
bounded waits, exact profile/config cross-checks, and cleanup traps. Tests must
mock GPU/model execution. Real model validation is opt-in through
`validate_profile.sh` and required when deployment behavior or fit changes.

Run before handoff:

```bash
for script in *.sh lib/*.sh tests/*.sh; do bash -n "$script"; done
for config in configs/*.json profiles/*.json schemas/*.json site-config.json; do jq empty "$config"; done
./tests/run_tests.sh
git diff --check
```

Inspect `git diff` and `git status`. Do not commit unless the owner explicitly
requests a commit. Always report edited, added, and removed files.
