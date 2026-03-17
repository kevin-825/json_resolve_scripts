#!/bin/bash


SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
source "${SCRIPT_DIR}/shell_exception_handling_core/exception_handling_core.sh"
set -euo pipefail
# ==============================================================================
# Script: resolve_json.sh
# Description: Purely in-memory JSON resolver orchestrator.
# ==============================================================================

INPUT_FILE=""
RESOLVER_SCRIPT="${SCRIPT_DIR}/resolver.sh"

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -i|--input) 
                INPUT_FILE="$2"
                shift 2 
                ;;
            -r|--resolver) 
                RESOLVER_SCRIPT="$2"
                shift 2 
                ;;
            *) 
                echo "Error: Unknown argument $1" >&2
                exit 1 
                ;;
        esac
    done
}

validate_args() {
    if [[ -z "$INPUT_FILE" ]] || [[ ! -f "$INPUT_FILE" ]]; then
        echo "Error: Input file (-i) is required and must exist." >&2
        exit 1
    fi
    if [[ -z "$RESOLVER_SCRIPT" ]] || [[ ! -x "$RESOLVER_SCRIPT" ]]; then
        echo "Error: Resolver script (-r) is required and must be executable." >&2
        exit 1
    fi
}

get_leaf_nodes() {
    local json_content="$1"
    local query='paths(scalars) as $p | ($p | map(if type == "number" then "[\(.)]" else . end) | join(".") | gsub("\\.\\["; "[")) + "|" + ($p | @json) + "|" + (getpath($p) | tostring)'
    
    # Pipe the raw string directly into jq
    printf "%s\n" "$json_content" | jq -r "$query"
}

needs_resolution() {
    local value="$1"
    if [[ "$value" =~ \$ ]]; then
        return 0
    else
        return 1
    fi
}

resolve_value() {
    local json_content="$1"
    local dot_path="$2"
    
    # Pass the purely in-memory JSON string as the first argument
    "$RESOLVER_SCRIPT" "$json_content" "$dot_path"
}

update_json_string() {
    local json_content="$1"
    local array_path="$2"
    local new_val="$3"
    
    # Execute jq against the string and output the new string
    printf "%s\n" "$json_content" | jq --argjson p "$array_path" --arg v "$new_val" 'setpath($p; $v)'
}

process_json_in_memory() {
    local current_json="$1"
    
    # Extract the structure once. We use the pipe separator as before.
    while IFS="|" read -r dot_path array_path original_value; do
        
        if needs_resolution "$original_value"; then
            local resolved_val
            
            # 1. Resolve using the LIVE string state
            resolved_val=$(resolve_value "$current_json" "$dot_path")
            
            # 2. Update the LIVE string state
            current_json=$(update_json_string "$current_json" "$array_path" "$resolved_val")
        fi
        
    done < <(get_leaf_nodes "$current_json")
    
    # Return the final modified JSON string
    printf "%s\n" "$current_json"
}

main() {
    parse_args "$@"
    validate_args
    
    # 1. Read the JSON file into a variable ONCE
    local initial_json
    initial_json=$(cat "$INPUT_FILE")
    
    # 2. Process everything strictly in memory
    local final_json
    final_json=$(process_json_in_memory "$initial_json")
    
    # 3. Output the fully resolved JSON object to stdout
    printf "%s\n" "$final_json"
}

main "$@"
