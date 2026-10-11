#!/usr/bin/env bash

# Build a GUI-safe catalog from local profiles that pass the shared profile and
# immutable OpenCode configuration checks. Callers must source local_llm.sh and
# set script_dir to the repository root first.

build_gui_profile_catalog() (
    local output=$1 profile_dir profile expected_id config_rel error scratch profiles_json rejected_json

    profile_dir=${LLM_PROFILE_DIR:-$script_dir/profiles}
    [[ -d "$profile_dir" ]] || die "profile directory not found: $profile_dir"
    scratch=$(mktemp -d "${TMPDIR:-/tmp}/local-llm-gui-catalog.XXXXXXXX")
    trap '[[ ! -d "$scratch" ]] || find "$scratch" -depth -delete' EXIT
    profiles_json="$scratch/profiles.ndjson"
    rejected_json="$scratch/rejected.ndjson"
    : > "$profiles_json"
    : > "$rejected_json"

    shopt -s nullglob
    local -a profile_files=("$profile_dir"/*.json)
    shopt -u nullglob
    (( ${#profile_files[@]} > 0 )) || {
        find "$scratch" -depth -delete
        die "no deployment profiles found in $profile_dir"
    }

    for profile in "${profile_files[@]}"; do
        expected_id=$(basename "$profile" .json)
        config_rel=$(jq -r '.opencode_config // empty' "$profile" 2>/dev/null || true)
        if error=$( {
            validate_profile_file "$profile" "$expected_id" &&
            [[ -n "$config_rel" && -f "$script_dir/$config_rel" ]] &&
            jq empty "$script_dir/$config_rel" >/dev/null &&
            validate_profile_config_match "$profile" "$script_dir/$config_rel"
        } 2>&1); then
            jq -c '
                {
                    profile_id: .id,
                    model: .model,
                    family: .family,
                    gguf: .gguf,
                    size_bytes: .source.size_bytes,
                    source_url: .source.url,
                    context: .limits.context,
                    output: .limits.output,
                    default_effort: .reasoning.default_effort,
                    reasoning_efforts: ["low", "medium", "high"]
                }
            ' "$profile" >> "$profiles_json"
        else
            [[ -n "$error" ]] || error="profile or immutable config validation failed"
            jq -cn --arg file "$(basename "$profile")" --arg error "$error" \
                '{file:$file,error:$error}' >> "$rejected_json"
        fi
    done

    jq -n --slurpfile profiles "$profiles_json" --slurpfile rejected "$rejected_json" \
        '{profiles:$profiles,rejected:$rejected}' > "$output"
    find "$scratch" -depth -delete
    jq -e '.profiles | length > 0' "$output" >/dev/null ||
        die "no valid deployment profiles are available for the GUI"
)
