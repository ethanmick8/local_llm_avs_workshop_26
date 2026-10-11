# syntax=docker/dockerfile:1
#
# Toolchain-only image: pinned llama-server (CUDA) plus pinned OpenCode.
# Repository scripts, profiles, and configs are bind-mounted read-only by
# launch_open_code_docker.sh; models and runtime data stay on the host.
# Build through launch_open_code_docker.sh --build, which supplies every pin
# from site-config.json.

ARG CUDA_VERSION
ARG UBUNTU_VERSION

FROM docker.io/nvidia/cuda:${CUDA_VERSION}-devel-ubuntu${UBUNTU_VERSION} AS llama-build
ARG LLAMA_CPP_COMMIT
ARG CUDA_ARCHITECTURE
RUN test -n "$LLAMA_CPP_COMMIT" && test -n "$CUDA_ARCHITECTURE"
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        build-essential ca-certificates cmake git && \
    rm -rf /var/lib/apt/lists/*
RUN git init -q /src/llama.cpp && \
    git -C /src/llama.cpp remote add origin https://github.com/ggml-org/llama.cpp && \
    git -C /src/llama.cpp fetch -q --depth 1 origin "$LLAMA_CPP_COMMIT" && \
    git -C /src/llama.cpp checkout -q --detach FETCH_HEAD && \
    test "$(git -C /src/llama.cpp rev-parse HEAD)" = "$LLAMA_CPP_COMMIT"
# Static llama libraries keep the runtime stage to one binary. libcuda comes
# from the devel stubs here and from the NVIDIA container runtime at run time.
RUN cmake -S /src/llama.cpp -B /src/build \
        -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
        -DGGML_CUDA=ON -DGGML_NATIVE=OFF -DCMAKE_CUDA_ARCHITECTURES="$CUDA_ARCHITECTURE" \
        -DLLAMA_BUILD_UI=OFF -DLLAMA_OPENSSL=OFF \
        -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
        -DCMAKE_EXE_LINKER_FLAGS=-Wl,--allow-shlib-undefined && \
    cmake --build /src/build --config Release --target llama-server -j"$(nproc)"

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

FROM docker.io/nvidia/cuda:${CUDA_VERSION}-runtime-ubuntu${UBUNTU_VERSION}
ARG LLAMA_CPP_COMMIT
ARG OPENCODE_VERSION
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates curl git jq libgomp1 openssl ripgrep && \
    rm -rf /var/lib/apt/lists/*
COPY --from=llama-build /src/build/bin/llama-server /opt/llama.cpp/bin/llama-server
COPY --from=opencode-fetch /out/opencode /usr/local/bin/opencode
ENV LOCAL_LLM_RUNTIME=container \
    LLAMA_SERVER_BIN=/opt/llama.cpp/bin/llama-server \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility
LABEL org.opencontainers.image.title="local-llm-opencode" \
      local-llm.llama-cpp-commit="${LLAMA_CPP_COMMIT}" \
      local-llm.opencode-version="${OPENCODE_VERSION}"
WORKDIR /opt/local_llm
