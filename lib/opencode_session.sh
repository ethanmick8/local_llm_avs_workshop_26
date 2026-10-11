#!/usr/bin/env bash

prepare_opencode_overlay() {
    local key_reference
    opencode_overlay="$run_dir/config/opencode-overlay.json"
    key_reference="{file:$api_key_file}"
    jq -c --arg key "$key_reference" '
      {model,small_model,enabled_providers,compaction,permission,
       provider:{"llama-server":(.provider["llama-server"] | .options.apiKey=$key)}}
    ' "$opencode_config" > "$opencode_overlay"
    chmod 600 "$opencode_overlay"
}

run_opencode() {
    local overlay_content opencode_status
    prepare_opencode_overlay
    overlay_content=$(<"$opencode_overlay")
    mkdir -p "$workspace_root/data" "$workspace_root/state" "$workspace_root/config" "$data_root/shared/cache" "$run_dir/tmp"
    set +e
    XDG_DATA_HOME="$workspace_root/data" \
    XDG_STATE_HOME="$workspace_root/state" \
    XDG_CONFIG_HOME="$workspace_root/config" \
    XDG_CACHE_HOME="$data_root/shared/cache" \
    TMPDIR="$run_dir/tmp" \
    OPENCODE_CONFIG="$opencode_config" \
    OPENCODE_CONFIG_CONTENT="$overlay_content" \
    LLAMA_SERVER_BASE_URL="http://$server_host:$server_port/v1" \
        opencode "$workdir"
    opencode_status=$?
    set -e
    return "$opencode_status"
}
