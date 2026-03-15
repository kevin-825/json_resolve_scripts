#!/bin/bash
# ==============================================================================
# MODULE: generic_resolver.sh
# DESCRIPTION: Generic JSON/Env/Shell Resolver.
# ==============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- SOURCE DEPENDENCIES USING ABSOLUTE PATHS ---
source "${SCRIPT_DIR}/shell_exception_handling_core/exception_handling_core.sh"

# --- 1. REGEX PATTERNS ---
#RE_JSON_TEMPLATE='\$\{([^}]+)\}' 
export RE_JSON_TEMPLATE='\$\{((?:[^{}]|(?R))*)\}'
RE_SHELL_COMMAND='\$\(([^)]+)\)'
RE_ENV_VARIABLE='\$([a-zA-Z_][a-zA-Z0-9_]*)'
regex_join_pattern='\$\{(.*)\.join\(['\''"]([^'\''"]*)['\''"]\)\}'
# --- 2. STATE TRACKING ---
declare -A VISITED_KEYS
declare -a STACK_ORDER
# --- 2. INTERNAL RESOLUTION MODULES ---

log_info()    { printf "\e[34m[INFO]\e[0m  %s\n" "$1" >&2; }
log_warn()    { printf "\e[33m[WARN]\e[0m  %s\n" "$1" >&2; }
log_error()   { printf "\e[31m[ERROR]\e[0m %s\n" "$1" >&2; }

# Only prints if DEBUG=true
log_debug() {
    if [[ "$DEBUG" == "true" ]]; then
        printf "\e[35m[DEBUG]\e[0m %s\n" "$1" >&2
    fi
}

_resolve_from_json() {
    local json_file="$1"
    local json_key_template="$2" 
    local -n output_reference=$3
    local json_key_template_captured="$4"
    log_debug "json_key_template: $json_key_template"
    # Strip ${ and } to get the path
    local search_path="$json_key_template_captured"

    log_debug "search_path: $search_path "
    mapfile -t BASH_REMATCH < <(perl -nle 'if (/$ENV{RE_JSON_TEMPLATE}/) { print "$&\n$1"; exit }' <<< "$search_path")
    if [[ ${#BASH_REMATCH[@]} -gt 0 && -n "${BASH_REMATCH[1]}" ]]; then
        local sub_template="${BASH_REMATCH[0]}"
        local extracted_path="${BASH_REMATCH[1]}"
        local resolved_sub_value
        log_debug "Found nested template: $sub_template extracted_path: $extracted_path in value of key: $json_key_template. Resolving..."
        _resolve_from_json "$json_file" "$sub_template" "resolved_sub_value" "$extracted_path"
        [[ $? -ne 0 ]] && throw_exception "PARENT_RESOLUTION_FAILURE" 1 "Failed to resolve nested template: $sub_template in key: $fixed_key"
        search_path="${search_path//"$sub_template"/"$resolved_sub_value"}"
        json_key_template="${json_key_template//"$sub_template"/"$resolved_sub_value"}"
        log_debug "#########resolved_sub_value: $resolved_sub_value search_path: $search_path json_key_template: $json_key_template" >&2
        #output_reference="$resolved_sub_value"
    fi
    log_debug "updated search_path: $search_path "
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
        throw_exception "RESOLVE_JSON_KEY_MISSING" 6 "$json_key_template" "$json_file" "found_value" "fixed_key"
    fi
    log_debug "fixed_key: $fixed_key"
    log_debug "found_value: $found_value"
    # 1. Check & Lock right here in the engine
    if [[ -n "${VISITED_KEYS[$fixed_key]}" ]]; then
        throw_exception "CIRCULAR_DEPENDENCY" 12 "$fixed_key"
    fi
    VISITED_KEYS["$fixed_key"]=1
    STACK_ORDER+=("$fixed_key") # PUSH to ordered stack

    output_reference="$found_value"
    mapfile -t BASH_REMATCH < <(perl -nle 'if (/$ENV{RE_JSON_TEMPLATE}/) { print "$&\n$1"; exit }' <<< "$found_value")
    if [[ ${#BASH_REMATCH[@]} -gt 0 && -n "${BASH_REMATCH[1]}" ]]; then
        local sub_template="${BASH_REMATCH[0]}"
        local extracted_path="${BASH_REMATCH[1]}"
        local resolved_sub_value
        log_debug "Found nested template: $sub_template extracted_path: $extracted_path in value of key: $fixed_key. Resolving..."
        _resolve_from_json "$json_file" "$sub_template" "resolved_sub_value" "$extracted_path"
        [[ $? -ne 0 ]] && throw_exception "PARENT_RESOLUTION_FAILURE" 1 "Failed to resolve nested template: $sub_template in key: $fixed_key"
        output_reference="${output_reference//"$sub_template"/"$resolved_sub_value"}"
    fi
    unset VISITED_KEYS["$fixed_key"]
    unset 'STACK_ORDER[${#STACK_ORDER[@]}-1]' # POP from ordered stack
    log_debug "Final resolved value for key: $json_key_template is: $output_reference" >&2
    return 0
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
        mapfile -t BASH_REMATCH < <(perl -nle 'if (/$ENV{RE_JSON_TEMPLATE}/) { print "$&\n$1"; exit }' <<< "$current_line")
        if [[ ${#BASH_REMATCH[@]} -gt 0 && -n "${BASH_REMATCH[1]}" ]]; then
            local template_found="${BASH_REMATCH[0]}"
            local captured="${BASH_REMATCH[1]}"

            log_debug "Found JSON template: $template_found in line: $current_line. Resolving..." >&2
            local resolved_text=""
            _resolve_from_json "$json_file" "$template_found" "resolved_text" "$captured"
            
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
    
    log_info "Resolving path: $key_path"

    local raw_json_output
    local jq_exit_code=0
    raw_json_output=$(jq -r ".$key_path" "$json_file" 2>/dev/null) || jq_exit_code=$?
    local resolved_value=""
    local fixed_key=""
    log_debug "Initial jq output for key_path: $key_path is: $raw_json_output with exit code: ${jq_exit_code}"
    if [[ "$raw_json_output" == "null" || -z "$raw_json_output" || $jq_exit_code != 0 ]]; then
        log_debug "Initial jq resolution failed for key_path: $key_path in file: $json_file. Attempting to resolve missing key..."
        throw_exception "RESOLVE_JSON_KEY_MISSING" 9 "$key_path" "$json_file" "resolved_value" "fixed_key"
        raw_json_output="$resolved_value"
    fi

    while IFS= read -r line; do
        resolve_single_line "$json_file" "$line"
    done <<< "$raw_json_output"
}

json_array_join() {
    local failed_key="${HANDLER_ARGS[0]}"
    local json_file="${HANDLER_ARGS[1]}"
    local json_path
    local separator="$3"
    local target_var_name="${HANDLER_ARGS[2]}"

    if [[ "$failed_key" =~ $regex_join_pattern ]]; then
        separator="${BASH_REMATCH[2]}"
        json_path="${BASH_REMATCH[1]}"
        log_debug "failed_key: $failed_key separator:"-$separator-" "
    fi
    separator="${separator#[\'\"]}"
    separator="${separator%[\'\"]}"
    separator="${separator//[$'\n'$'\r'$'\t']/}"
    log_debug "Attempting to resolve .join() for failed_key:$failed_key json_path:$json_path separator: '$separator'"
    # Get array content - flattened to one line by JQ
    local raw_array_content
    raw_array_content=$(jq -r ".$json_path | if type == \"array\" then .[] else empty end" "$json_file" 2>/dev/null)

    if [[ -z "$raw_array_content" ]]; then
        log_debug "No array content found at path: $json_path for .join() in key: $failed_key"
        printf -v "$target_var_name" "" # Set to empty string if no content
        return 0
    fi

    # Join into one big string by appending and stripping the first separator
    local flattened_output=""
    while IFS= read -r element; do
        [[ -z "$element" ]] && continue
        flattened_output="${flattened_output}${separator}${element}"
    done <<< "$raw_array_content"

    # Strip the leading separator
    flattened_output="${flattened_output#"$separator"}"
    log_debug "Joined array content for key: $failed_key is: $flattened_output"

    printf -v "$target_var_name" "%s" "$flattened_output"
}

resolve_key_missing_handler() { 
    local missing_key_template="${HANDLER_ARGS[0]}"
    local json_file="${HANDLER_ARGS[1]}"
    local -n target_var_name="${HANDLER_ARGS[2]}"
    local -n __fixed_key_ref=${HANDLER_ARGS[3]}
    log_debug "[resolve_key_missing_handler] resolving missing_key_template:$missing_key_template"


    mapfile -t BASH_REMATCH < <(perl -nle 'if (/$ENV{RE_JSON_TEMPLATE}/) { print "$&\n$1"; exit }' <<< "$missing_key_template")
    local missing_key="${BASH_REMATCH[1]}"
    

    if [[ "$missing_key_template" =~ $RE_SHELL_COMMAND ]]; then
        local template_found="${BASH_REMATCH[0]}"
        local resolved_text
        resolved_text=$(_resolve_subshell "$template_found") || exit $?
        $target_var_name="${missing_key_template//"$template_found"/"$resolved_text"}"
        return 0
    fi

    if [[ "$missing_key_template" =~ $RE_ENV_VARIABLE ]]; then
        local template_found="${BASH_REMATCH[0]}"
        local resolved_text
        resolved_text=$(_resolve_env_var "$template_found") || exit $?
        $target_var_name="${missing_key_template//"$template_found"/"$resolved_text"}"
        return 0
    fi
    
    local regex_join_pattern='\$\{(.*)\.join\(('.*')\)\}'
    
    if [[ "$missing_key_template" =~ $regex_join_pattern ]]; then
        #__fixed_key_ref="${missing_key%%.join*}"
        separator="${BASH_REMATCH[2]}"
        __fixed_key_ref=${BASH_REMATCH[1]}
        json_array_join $missing_key $__fixed_key_ref $separator
        return 0
    fi

    local tmp_found_value=$( eval echo "$missing_key_template")
    if [[ -n "$tmp_found_value" ]]; then
        log_debug "Direct evaluation of template yielded: $tmp_found_value. Using it as found_value."
        target_var_name="$tmp_found_value"
        return 0
    fi

    log_error "unable to resolve missing key: $missing_key in $json_file"
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