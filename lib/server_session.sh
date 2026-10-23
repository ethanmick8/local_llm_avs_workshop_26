#!/usr/bin/env bash

server_pid=""
api_key_file=""
curl_config=""

build_server_args() {
    local key_path=$1 budget threads threads_batch
    server_args=(
        "$llama_server_bin"
        --model "$model_file" --alias "$model"
        --host "$server_host" --port "$server_port"
        --api-key-file "$key_path" --no-webui --jinja
        --parallel "$(jq -r .llama.parallel "$profile_file")"
        --ctx-size "$(jq -r .limits.context "$profile_file")"
    )
    # "auto" leaves thread selection to llama.cpp, which sizes it to the host.
    threads=$(jq -r .llama.threads "$profile_file")
    threads_batch=$(jq -r .llama.threads_batch "$profile_file")
    [[ "$threads" == auto ]] || server_args+=(--threads "$threads")
    [[ "$threads_batch" == auto ]] || server_args+=(--threads-batch "$threads_batch")
    case "$backend" in
        cuda) server_args+=(--fit off --n-gpu-layers all --kv-offload) ;;
        cpu) server_args+=(--fit off --device none --n-gpu-layers 0 --no-kv-offload) ;;
    esac
    server_args+=(
        --batch-size "$(jq -r .llama.batch_size "$profile_file")"
        --ubatch-size "$(jq -r .llama.ubatch_size "$profile_file")"
        --flash-attn on
        --cache-type-k "$(jq -r .llama.cache_type_k "$profile_file")"
        --cache-type-v "$(jq -r .llama.cache_type_v "$profile_file")"
        --cache-prompt --metrics --log-timestamps
        --temp "$(jq -r .sampling.temperature "$profile_file")"
        --top-k "$(jq -r .sampling.top_k "$profile_file")"
        --top-p "$(jq -r .sampling.top_p "$profile_file")"
        --min-p "$(jq -r .sampling.min_p "$profile_file")"
        --presence-penalty "$(jq -r .sampling.presence_penalty "$profile_file")"
        --repeat-penalty "$(jq -r .sampling.repeat_penalty "$profile_file")"
    )
    case "$reasoning_mode" in
        gemma-budget)
            budget=$(jq -r --arg e "$reasoning_effort" '.reasoning.budgets[$e]' "$profile_file")
            server_args+=(--reasoning-budget "$budget")
            ;;
        muse-strength)
            server_args+=(--chat-template-kwargs "{\"reasoning_strength\":\"$reasoning_effort\"}")
            ;;
        qwen-effort)
            server_args+=(--reasoning-effort "$reasoning_effort")
            ;;
    esac
}

print_sanitized_server_args() {
    build_server_args '<private-key-file>'
    printf 'llama-server command:'
    printf ' %q' "${server_args[@]}"
    printf '\n'
}

generate_api_key() {
    api_key_file="$run_dir/secrets/llama-api-key"
    curl_config="$run_dir/secrets/curl.conf"
    openssl rand -hex 32 > "$api_key_file"
    chmod 600 "$api_key_file"
    {
        echo 'silent'
        echo 'show-error'
        echo 'fail'
        printf 'header = "Authorization: Bearer %s"\n' "$(<"$api_key_file")"
    } > "$curl_config"
    chmod 600 "$curl_config"
}

start_server() {
    local base_url="http://$server_host:$server_port"
    if curl --silent --fail --max-time 1 "$base_url/health" >/dev/null 2>&1; then
        die "port $server_port is already serving HTTP; set LOCAL_LLM_PORT to an unused port"
    fi
    [[ -x "$llama_server_bin" ]] || die "llama-server is not installed: run ./setup_local_llm.sh"
    generate_api_key
    build_server_args "$api_key_file"
    server_log="$run_dir/logs/llama-server.log"
    "${server_args[@]}" >"$server_log" 2>&1 &
    server_pid=$!
    printf '%s\n' "$server_pid" > "$run_dir/server.pid"
    wait_for_server
}

wait_for_server() {
    local base_url="http://$server_host:$server_port" deadline=$((SECONDS + startup_timeout))
    while (( SECONDS < deadline )); do
        kill -0 "$server_pid" 2>/dev/null || {
            echo "llama-server exited during startup; log: $server_log" >&2
            tail -n 80 "$server_log" >&2 || true
            return 1
        }
        if curl --silent --fail --max-time 2 "$base_url/health" >/dev/null 2>&1 &&
           curl --config "$curl_config" --max-time 5 "$base_url/v1/models" | jq -e --arg model "$model" '.data[]? | select(.id == $model)' >/dev/null; then
            echo "llama-server ready at $base_url (authenticated model: $model)"
            return 0
        fi
        sleep 1
    done
    echo "llama-server did not become ready within ${startup_timeout}s; log: $server_log" >&2
    tail -n 80 "$server_log" >&2 || true
    return 1
}

stop_server() {
    local deadline
    [[ -n "${server_pid:-}" ]] || return 0
    kill -0 "$server_pid" 2>/dev/null || { wait "$server_pid" 2>/dev/null || true; server_pid=""; return 0; }
    kill -TERM "$server_pid" 2>/dev/null || true
    deadline=$((SECONDS + shutdown_timeout))
    while kill -0 "$server_pid" 2>/dev/null && (( SECONDS < deadline )); do sleep 1; done
    if kill -0 "$server_pid" 2>/dev/null; then kill -KILL "$server_pid" 2>/dev/null || true; fi
    wait "$server_pid" 2>/dev/null || true
    server_pid=""
}
