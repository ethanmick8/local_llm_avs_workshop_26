# local_llm_avs_workshop_26

Run [OpenCode](https://github.com/anomalyco/opencode) against a local,
pinned CUDA [llama.cpp](https://github.com/ggml-org/llama.cpp) server on a
single 24 GB NVIDIA GPU (tuned for an RTX 3090). A much slower CPU-only
Docker fallback is available for machines without an NVIDIA GPU. The server
binds only to loopback, uses a fresh random API key per run, and is stopped
when OpenCode exits.

Model weights are **not** part of this repository; download them yourself
(see [Models](#models)).

## Profiles

| Profile | Model | GGUF size |
| --- | --- | --- |
| `gemma4-26b-a4b-q4-32k` | Gemma 4 26B-A4B IT Q4_0 | 14.6 GB |
| `muse-glimmer-30b-q4-32k` | Muse Glimmer 30B Q4_K_M | 16.8 GB |
| `qwen38-27b-q4-32k` | Qwen3.8 27B UD-Q4_K_M | 16.5 GB |
| `gemma4-26b-a4b-q4-32k-cpu` | Gemma 4 26B-A4B IT Q4_0, CPU only ([Option A2](#option-a2-docker-cpu-only-fallback)) | 14.6 GB (same file) |

All profiles use a 32k context, Q8 K/V cache, and Flash Attention. The GPU
profiles keep every layer on the GPU. Each one lives in `profiles/` with a
matching OpenCode config in `configs/`.

## Models

Each profile pins the GGUF filename, byte size, SHA-256, and download URL.
Put the files in `local_llm_data/models/`:

```bash
mkdir -p local_llm_data/models
jq -r '.source.url' profiles/qwen38-27b-q4-32k.json   # print the download URL
curl -L --fail -o local_llm_data/models/Qwen3.8-27B-UD-Q4_K_M.gguf "<url>"
```

Set `LOCAL_LLM_VERIFY_MODEL_HASH=1` on a launch to check the SHA-256.
Otherwise the launcher checks only the file size.

## Option A: Docker (recommended for sharing)

Requirements: an NVIDIA driver supporting CUDA 12.8, Docker, and the
[NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)
(`docker run --gpus` must work). You also need `jq` on the host. Conda is not
needed.

```bash
./launch_open_code_docker.sh --build                       # build the image once
./launch_open_code_docker.sh --check qwen38-27b-q4-32k ~/my-project
./launch_open_code_docker.sh qwen38-27b-q4-32k ~/my-project
```

The image contains only llama-server, built from the pinned commit for
`sm_86`, and the OpenCode binary, checked against its SHA-256. All pins come
from `site-config.json`, and the image tag changes when they do. At run time:

- The repository is mounted read-only, so profile and config edits apply
  without rebuilding.
- `local_llm_data/` and the workspace are mounted at their host paths.
  Sessions, logs, and workspace IDs are shared with host-native runs.
- No ports are published. llama-server listens on `127.0.0.1` inside the
  container only.
- The container runs as your user, with all capabilities dropped.

`LOCAL_LLM_GPU_DEVICE` selects the GPU index or UUID (default `0`).

## Option A2: Docker, CPU-only fallback

> **Performance warning.** CPU inference is far slower than the GPU path.
> On a 36-thread workstation it measured about 66 tokens/s of prompt
> processing and 14 tokens/s of generation. OpenCode sends a long system
> prompt, so expect **about 2 minutes before the first reply** in a fresh
> session on a fast desktop, and considerably longer on a laptop. Use it to try
> things out when no NVIDIA GPU is available, not for interactive work.

Requirements: x86-64 Linux (or WSL2) with Docker, `jq` on the host, and at
least **32 GB of RAM**. No GPU, NVIDIA driver, or Container Toolkit is needed.
Only the Gemma 4 26B-A4B profile is offered on CPU. It is a mixture-of-experts
model with about 4B active parameters per token, so it is the only one of the
three that is usable without a GPU. It uses the same GGUF file as the GPU
Gemma profile.

```bash
LOCAL_LLM_BACKEND=cpu ./launch_open_code_docker.sh --build   # build the CPU image once
./launch_open_code_docker.sh --check gemma4-26b-a4b-q4-32k-cpu ~/my-project
./launch_open_code_docker.sh gemma4-26b-a4b-q4-32k-cpu ~/my-project
```

The profile selects the image: `*-cpu` profiles run in the
`…-cpu` image, built with every x86-64 SIMD variant so llama.cpp picks the
best one for your CPU at run time. The container gets no GPU device. llama.cpp
chooses the thread count, startup may take up to
`server.cpu_startup_timeout_seconds` (180 s), and the OpenCode config allows
long waits for the first token. CPU profiles are Docker-only; the host-native
launcher, GUI, and benchmark refuse or hide them.

## Option B: host-native (Conda)

Requirements: Linux or WSL2, an NVIDIA driver, and an existing `ml` Conda
environment.

```bash
conda activate ml
./setup_local_llm.sh            # builds llama.cpp, installs OpenCode and PyQt
./launch_open_code.sh qwen38-27b-q4-32k ~/my-project
./launch_open_code_gui.sh       # optional PyQt profile/workspace picker
```

## Launcher options

```text
launch_open_code.sh [--check|--dry-run] [--workspace-id ID]
                    [--data-root ABSOLUTE_PATH] <profile> <workdir>
```

| Variable | Effect |
| --- | --- |
| `REASONING_EFFORT` | `low`, `medium`, or `high` (default `high`) |
| `LOCAL_LLM_PORT` | Loopback port (default `8081`) |
| `LOCAL_LLM_VERIFY_MODEL_HASH` | `1` to verify the model SHA-256 |

`benchmark_profile.sh <profile>` measures load time and generation speed
(host-native only).

## Data layout

Everything generated goes under `local_llm_data/`, which git ignores:

```text
local_llm_data/
  models/       GGUF files (you download these)
  tools/        host-native llama.cpp checkout and build
  shared/       shared OpenCode cache
  workspaces/   per-workspace OpenCode data and per-run logs
```
