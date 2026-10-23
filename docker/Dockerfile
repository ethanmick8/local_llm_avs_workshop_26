# syntax=docker/dockerfile:1
#
# Toolchain-only images: pinned llama-server plus pinned OpenCode, in two final
# targets selected with --target:
#   cuda  CUDA llama-server for one NVIDIA GPU (primary path)
#   cpu   CPU-only llama-server fallback; no GPU runtime or device access
# Repository scripts, profiles, and configs are bind-mounted read-only by
# launch_open_code_docker.sh; models and runtime data stay on the host.
# Build through launch_open_code_docker.sh --build, which supplies every pin
# from site-config.json.

ARG CUDA_VERSION
ARG UBUNTU_VERSION

FROM docker.io/library/ubuntu:${UBUNTU_VERSION} AS llama-source
ARG LLAMA_CPP_COMMIT
RUN test -n "$LLAMA_CPP_COMMIT"
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates git && \
    rm -rf /var/lib/apt/lists/*
RUN git init -q /src/llama.cpp && \
    git -C /src/llama.cpp remote add origin https://github.com/ggml-org/llama.cpp && \
    git -C /src/llama.cpp fetch -q --depth 1 origin "$LLAMA_CPP_COMMIT" && \
    git -C /src/llama.cpp checkout -q --detach FETCH_HEAD && \
    test "$(git -C /src/llama.cpp rev-parse HEAD)" = "$LLAMA_CPP_COMMIT"

FROM docker.io/nvidia/cuda:${CUDA_VERSION}-devel-ubuntu${UBUNTU_VERSION} AS llama-build-cuda
ARG CUDA_ARCHITECTURE
RUN test -n "$CUDA_ARCHITECTURE"
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        build-essential ca-certificates cmake git && \
    rm -rf /var/lib/apt/lists/*
COPY --from=llama-source /src/llama.cpp /src/llama.cpp
# Static llama libraries keep the runtime stage to one binary. libcuda comes
# from the devel stubs here and from the NVIDIA container runtime at run time.
RUN cmake -S /src/llama.cpp -B /src/build \
        -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
        -DGGML_CUDA=ON -DGGML_NATIVE=OFF -DCMAKE_CUDA_ARCHITECTURES="$CUDA_ARCHITECTURE" \
        -DLLAMA_BUILD_UI=OFF -DLLAMA_OPENSSL=OFF \
        -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
        -DCMAKE_EXE_LINKER_FLAGS=-Wl,--allow-shlib-undefined && \
    cmake --build /src/build --config Release --target llama-server -j"$(nproc)"

FROM docker.io/library/ubuntu:${UBUNTU_VERSION} AS llama-build-cpu
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        build-essential ca-certificates cmake git && \
    rm -rf /var/lib/apt/lists/*
COPY --from=llama-source /src/llama.cpp /src/llama.cpp
# Every x86-64 CPU variant is built as a loadable backend; ggml picks the best
# one the host supports at run time, so the image is not tied to the build CPU.
RUN cmake -S /src/llama.cpp -B /src/build \
        -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON \
        -DGGML_NATIVE=OFF -DGGML_BACKEND_DL=ON -DGGML_CPU_ALL_VARIANTS=ON \
        -DLLAMA_BUILD_UI=OFF -DLLAMA_OPENSSL=OFF \
        -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF && \
    cmake --build /src/build --config Release -j"$(nproc)" && \
    mkdir -p /out && cp /src/build/bin/llama-server /out/ && \
    find /src/build -name '*.so*' -exec cp -P {} /out/ \;

FROM docker.io/library/ubuntu:${UBUNTU_VERSION} AS opencode-fetch
ARG OPENCODE_VERSION
ARG OPENCODE_SHA256
RUN test -n "$OPENCODE_VERSION" && test -n "$OPENCODE_SHA256"
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl && \
    rm -rf /var/lib/apt/lists/*
RUN curl -fsSL -o /tmp/opencode.tar.gz \
        "https://github.com/anomalyco/opencode/releases/download/v${OPENCODE_VERSION}/opencode-linux-x64.tar.gz" && \
    printf '%s  %s\n' "$OPENCODE_SHA256" /tmp/opencode.tar.gz | sha256sum -c --quiet - && \
    mkdir /tmp/opencode && tar -xzf /tmp/opencode.tar.gz -C /tmp/opencode && \
    install -D -m 755 /tmp/opencode/opencode /out/opencode

FROM docker.io/library/ubuntu:${UBUNTU_VERSION} AS cpu
ARG LLAMA_CPP_COMMIT
ARG OPENCODE_VERSION
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates curl git jq libgomp1 openssl ripgrep && \
    rm -rf /var/lib/apt/lists/*
# ggml loads backend libraries from the executable's directory.
COPY --from=llama-build-cpu /out/ /opt/llama.cpp/bin/
COPY --from=opencode-fetch /out/opencode /usr/local/bin/opencode
ENV LOCAL_LLM_RUNTIME=container \
    LOCAL_LLM_BACKEND=cpu \
    LLAMA_SERVER_BIN=/opt/llama.cpp/bin/llama-server \
    LD_LIBRARY_PATH=/opt/llama.cpp/bin
LABEL org.opencontainers.image.title="local-llm-opencode" \
      local-llm.backend="cpu" \
      local-llm.llama-cpp-commit="${LLAMA_CPP_COMMIT}" \
      local-llm.opencode-version="${OPENCODE_VERSION}"
WORKDIR /opt/local_llm

# Last stage, so a build without --target still produces the CUDA image.
FROM docker.io/nvidia/cuda:${CUDA_VERSION}-runtime-ubuntu${UBUNTU_VERSION} AS cuda
ARG LLAMA_CPP_COMMIT
ARG OPENCODE_VERSION
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates curl git jq libgomp1 openssl ripgrep && \
    rm -rf /var/lib/apt/lists/*
COPY --from=llama-build-cuda /src/build/bin/llama-server /opt/llama.cpp/bin/llama-server
COPY --from=opencode-fetch /out/opencode /usr/local/bin/opencode
ENV LOCAL_LLM_RUNTIME=container \
    LOCAL_LLM_BACKEND=cuda \
    LLAMA_SERVER_BIN=/opt/llama.cpp/bin/llama-server \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility
LABEL org.opencontainers.image.title="local-llm-opencode" \
      local-llm.backend="cuda" \
      local-llm.llama-cpp-commit="${LLAMA_CPP_COMMIT}" \
      local-llm.opencode-version="${OPENCODE_VERSION}"
WORKDIR /opt/local_llm
