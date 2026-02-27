#!/bin/bash
# ==============================================================================
# MODULE: generic_resolver.sh
# DESCRIPTION: Generic JSON/Env/Shell Resolver.
# ==============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- SOURCE DEPENDENCIES USING ABSOLUTE PATHS ---
source "${SCRIPT_DIR}/shell_exception_handling_core/exception_handling_core.sh"

# --- 1. REGEX PATTERNS ---
RE_JSON_TEMPLATE='\$\{([^}]+)\}' 
RE_SHELL_COMMAND='\$\(([^)]+)\)'
RE_ENV_VARIABLE='\$([a-zA-Z_][a-zA-Z0-9_]*)'
# --- 2. STATE TRACKING ---
declare -A VISITED_KEYS
declare -a STACK_ORDER
# --- 2. INTERNAL RESOLUTION MODULES ---

_resolve_from_json() {
    local json_file="$1"
    local json_key_template="$2" 
    local -n output_reference=$3

    # Strip ${ and } to get the path
    local search_path="${json_key_template#\${}"
    search_path="${search_path%\}}"

    local found_value
    found_value=$(jq -e -r "
        [   paths(scalars) as \$p 
            | \$p 
            | map(tostring) 
            | join(\".\") 
            | select(endswith(\"$search_path\")) 
        ] as \$matches 
        | if (\$matches | length > 0) then getpath(\$matches[0] | split(\".\")) else null end
    " "$json_file" 2>/dev/null) || found_value="null"
    local fixed_key="$search_path"
    if [[ "$found_value" == "null" || -z "$found_value" ]]; then
        throw_exception "RESOLVE_JSON_KEY_MISSING" 6 "$search_path" "$json_file" "found_value" "fixed_key"
    fi

    # 1. Check & Lock right here in the engine
    if [[ -n "${VISITED_KEYS[$fixed_key]}" ]]; then
        throw_exception "CIRCULAR_DEPENDENCY" 12 "$fixed_key"
    fi
    VISITED_KEYS["$fixed_key"]=1
    STACK_ORDER+=("$fixed_key") # PUSH to ordered stack

    output_reference="$found_value"

    if [[ "$found_value" =~ $RE_JSON_TEMPLATE ]]; then
        local sub_template="${BASH_REMATCH[0]}"
        local resolved_sub_value
        _resolve_from_json "$json_file" "$sub_template" "resolved_sub_value"
        [[ $? -ne 0 ]] && throw_exception "PARENT_RESOLUTION_FAILURE" 1 "Failed to resolve nested template: $sub_template in key: $fixed_key"
        output_reference="${output_reference//"$sub_template"/"$resolved_sub_value"}"
    fi
    unset VISITED_KEYS["$fixed_key"]
    unset 'STACK_ORDER[${#STACK_ORDER[@]}-1]' # POP from ordered stack
}

_resolve_subshell() {
    local shell_template="$1"
    if [[ "$shell_template" =~ $RE_SHELL_COMMAND ]]; then
        local command="${BASH_REMATCH[1]}"
        local command_output=$(eval "$command")
        [[ $? -ne 0 ]] && throw_exception "RESOLVE_SHELL_FAIL" 7 "$command"
        echo "$command_output"
    fi
}

_resolve_env_var() {
    local env_template="$1"
    if [[ "$env_template" =~ $RE_ENV_VARIABLE ]]; then
        local env_name="${BASH_REMATCH[1]}"
        local env_value="${!env_name}"
        [[ -z "$env_value" ]] && throw_exception "RESOLVE_ENV_MISSING" 8 "$env_name"
        echo "$env_value"
    fi
}

# --- 3. THE GENERIC ENGINE ---

resolve_single_line() {
    local json_file="$1"
    local current_line="$2"

    while [[ "$current_line" =~ \$ ]]; do
        local line_before_change="$current_line"

        if [[ "$current_line" =~ $RE_JSON_TEMPLATE ]]; then
            local template_found="${BASH_REMATCH[0]}"

            
            local resolved_text=""
            _resolve_from_json "$json_file" "$template_found" "resolved_text"
            
            if [[ $? -ne 0 ]]; then
                throw_exception "PARENT_RESOLUTION_FAILURE" 1 "Subshell failed: $template_found"
            fi
            
            current_line="${current_line//"$template_found"/"$resolved_text"}"
            #echo "[resolve_single_line] current_line: $current_line resolved: $resolved_text" >&2
            continue 
        fi

        if [[ "$current_line" =~ $RE_SHELL_COMMAND ]]; then
            local template_found="${BASH_REMATCH[0]}"
            local resolved_text
            resolved_text=$(_resolve_subshell "$template_found") || exit $?
            current_line="${current_line//"$template_found"/"$resolved_text"}"
            continue
        fi

        if [[ "$current_line" =~ $RE_ENV_VARIABLE ]]; then
            local template_found="${BASH_REMATCH[0]}"
            local resolved_text
            resolved_text=$(_resolve_env_var "$template_found") || exit $?
            current_line="${current_line//"$template_found"/"$resolved_text"}"
            continue
        fi

        [[ "$line_before_change" == "$current_line" ]] && break
    done

    echo "$current_line"
}

resolve_value() {
    local json_file="$1"
    local key_path="$2"
    
    echo "[INFO] Resolving path: $key_path" >&2

    local raw_json_output
    raw_json_output=$(jq -r ".$key_path" "$json_file" 2>/dev/null)
    
    [[ "$raw_json_output" == "null" || -z "$raw_json_output" ]] && \
        throw_exception "RESOLVE_KEY_NOT_FOUND" 9 "$key_path"

    while IFS= read -r line; do
        resolve_single_line "$json_file" "$line"
    done <<< "$raw_json_output"
}

json_array_join() {
    local failed_key="${HANDLER_ARGS[0]}"
    local json_file="${HANDLER_ARGS[1]}"
    local target_var_name="${HANDLER_ARGS[2]}"

    # Extract path and arguments
    local json_path="${failed_key%%.join*}"
    local function_args="${failed_key#*(}"
    function_args="${function_args%)}"
    
    # Simplified Clean: Strip quotes and control characters
    local separator="${function_args#[\'\"]}"
    separator="${separator%[\'\"]}"
    separator="${separator//[$'\n'$'\r'$'\t']/}"

    # Get array content - flattened to one line by JQ
    local raw_array_content
    raw_array_content=$(jq -r ".$json_path | if type == \"array\" then .[] else empty end" "$json_file" 2>/dev/null)

    [[ -z "$raw_array_content" ]] && return 1

    # Join into one big string by appending and stripping the first separator
    local flattened_output=""
    while IFS= read -r element; do
        [[ -z "$element" ]] && continue
        flattened_output="${flattened_output}${separator}${element}"
    done <<< "$raw_array_content"

    # Strip the leading separator
    flattened_output="${flattened_output#"$separator"}"

    printf -v "$target_var_name" "%s" "$flattened_output"
}

resolve_key_missing_handler() {
    local missing_key="${HANDLER_ARGS[0]}"
    local json_file="${HANDLER_ARGS[1]}"
    local -n __fixed_key_ref=${HANDLER_ARGS[3]}
    
    local regex_join_pattern='\.join\('.*'\)'
    if [[ "$missing_key" =~ $regex_join_pattern ]]; then
        __fixed_key_ref="${missing_key%%.join*}"
        json_array_join
        return 0
    fi
    echo "unable to resolve missing key: $missing_key in $json_file" >&2
    exit 1
}

circular_dependency_handler() {
    local looped_key="${HANDLER_ARGS[0]}"
    
    echo "------------------------------------------------" >&2
    echo "🚨 ERROR: CIRCULAR DEPENDENCY DETECTED" >&2
    echo "The key '\${$looped_key}' creates a loop." >&2
    echo "------------------------------------------------" >&2
    echo "Resolution Path (Order of discovery):" >&2
    
    # Iterate through the indexed array for guaranteed order
    local i=1
    for key in "${STACK_ORDER[@]}"; do
        echo "  $i. \${$key}" >&2
        ((i++))
    done
    
    # Finally, show the key that tried to point back
    echo "  >> \${$looped_key} (BACK-REFERENCE)" >&2
    
    echo "------------------------------------------------" >&2
    exit 12
}

register_handler "CIRCULAR_DEPENDENCY" "circular_dependency_handler"

register_handler "RESOLVE_JSON_KEY_MISSING" "resolve_key_missing_handler" 

# --- 4. MAIN ---
main() {
    [[ $# -lt 2 ]] && { echo "Usage: $0 <json_file> <key_path>" >&2; exit 1; }
    resolve_value "$1" "$2"
}

main "$@"