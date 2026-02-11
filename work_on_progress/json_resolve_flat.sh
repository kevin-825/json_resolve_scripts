#!/bin/bash
set -e

# --- Configuration & Defaults ---
INPUT_FILE=""
DRY_RUN=false
VERBOSE=false
DEBUG=false

FLAT_JSON_DATA=""
RESOLVED_JSON_DATA=""

# --- Module: Logging ---
# Usage: log_info "message" or log_error "message"
# These all send to stderr (>&2) to avoid breaking JSON stdout capture.

log_info()    { printf "\e[34m[INFO]\e[0m  %s\n" "$1" >&2; }
log_warn()    { printf "\e[33m[WARN]\e[0m  %s\n" "$1" >&2; }
log_error()   { printf "\e[31m[ERROR]\e[0m %s\n" "$1" >&2; }

# Only prints if DEBUG=true
log_debug() {
    if [[ "$DEBUG" == "true" ]]; then
        printf "\e[35m[DEBUG]\e[0m %s\n" "$1" >&2
    fi
}

# --- Module: JSON Flattener ---
flatten_json() {
    local input_file="$1"
    [[ ! -f "$input_file" ]] && return 1

    FLAT_JSON_DATA=$(jq -r '
        [
          paths(scalars) as $p 
          | { 
              key: ($p | map(if type == "number" then "[\(.)]" else tostring end) | join(".")), 
              value: getpath($p) 
            }
        ] | from_entries
    ' "$input_file")

    export FLAT_JSON_DATA
}

# --- Config Module ---
UniqueMatchMode=true


# --- Module: expand_template_logic ---
# Description: Uses the shell's native parser to resolve:
#              1. Environment Variables ($VAR or ${VAR})
#              2. Command Substitution ($(cmd))
#              3. Arithmetic $((1+1))
# -------------------------------------
expand_template_logic() {
    local raw_content="$1"

    # Escape double quotes so they are treated as literal text 
    # and don't break the 'eval' boundary.
    local escaped_content="${raw_content//\"/\\\"}"

    # The 'eval echo' trick: Bash parses the string as if it 
    # were typed directly into the terminal.
    local expanded_result
    expanded_result=$(eval echo "\"$escaped_content\"")

    echo "$expanded_result"
}


# --- Logic Module: Find Absolute Key ---
# Searches FLAT_JSON_DATA for a key matching the shorthand name
# --- Logic Module ---
get_absolute_key() {
    local shorthand="$1"
    local matches=()

    # --- AUTOMATIC ESCAPING ---
    # We must escape [ and ] so the Regex treats them as literal text.
    # We use Bash-native replacement for speed.
    local escaped_shorthand="${shorthand//\[/\\\[}"
    escaped_shorthand="${escaped_shorthand//\]/\\\]}"
    
    # This regex is the "Brain". It ensures we match 'tags' in 'build.tags'
    # but NOT 'tags' in 'system_tags_backup'.
    local key_regex="(^|\.)${escaped_shorthand}$"
    #echo "[get_absolute_key] Searching for key '$shorthand' with regex '$key_regex'" >&2
    # 3. Loop through the keys we just extracted
    while read -r full_key; do
        if [[ "$full_key" =~ $key_regex ]]; then
            matches+=("$full_key")
        fi
    done < <(echo "$FLAT_JSON_DATA" | jq -r 'keys[]')

    local count=${#matches[@]}

    # Check for 0 matches or multiple matches (if UniqueMatchMode is true)
    if [[ $count -eq 0 ]] || [[ "$UniqueMatchMode" == "true" && $count -gt 1 ]]; then
        echo ""    # Variable gets nothing
        return 1  # Script gets told it failed
    fi

    echo "${matches[0]}" # Variable gets the full key (e.g., build.context)
    return 0             # Script gets told it succeeded
}

# --- Module: Flat Dictionary Resolver ---
resolve_flat_dictionary() {
    # --- Step 1: Get Pending ---
    PENDING_RESOLUTIONS=$(echo "$FLAT_JSON_DATA" | jq -r '
        to_entries 
        | map(select(.value | type == "string" and contains("$"))) 
        | from_entries
    ')
    if $DEBUG; then
        echo ">>> [DEBUG]  Data needs to be resolved:"
        echo "$PENDING_RESOLUTIONS" | jq .
    fi
    # --- Step 2.1: Internal Config Resolution ---

    #2.1.1 
# --- Step 2.1: Internal Config Resolution ---
    #local keys_flat=$(echo "$FLAT_JSON_DATA" | jq -r 'keys[]')

    while read -r key; do
        local regex='\$\{([^}]+)\}'
        local value=$(echo "$PENDING_RESOLUTIONS" | jq -r --arg k "$key" '.[$k]')
        
        while [[ "$value" =~ $regex ]]; do
            local nested_key="${BASH_REMATCH[1]}"
            #nested_key maynot be full flat key, it can be partial key, we need to find the full flat key in FLAT_JSON_DATA
            local nested_key_flat=$(get_absolute_key "$nested_key")
       
            if [[  -z "$nested_key_flat" ]]; then
                echo 0000
                log_error ">>> [Error] No absolute key found for '$nested_key' in FLAT_JSON_DATA"
                exit 1
            fi
            local replacement=$(echo "$FLAT_JSON_DATA" | jq -r --arg nkf "$nested_key_flat" '.[$nkf] // "null"')
            
            if [[ "$replacement" == "null" ]]; then
                log_error ">>> [Error] Reference '$nested_key' not found for key '$key' in FLAT_JSON_DATA"
                exit 1
            fi
            local escaped_key="${nested_key//\[/\\\[}"
            escaped_key="${escaped_key//\]/\\\]}"
            #echo "[end-1] before replace nestedkey:'$nested_key': escaped_key:$escaped_key replacement:$replacement" >&2
            value="${value//\$\{$escaped_key\}/$replacement}"
            #value=$(expand_template_logic "$value")
        done
        value=$(expand_template_logic "$value")
        PENDING_RESOLUTIONS=$(echo "$PENDING_RESOLUTIONS" | jq --arg k "$key" --arg v "$value" '.[$k] = $v')

    done < <(echo "$PENDING_RESOLUTIONS" | jq -r 'keys[]')


    if $DEBUG; then
        log_debug ">>> [DEBUG] PENDING_RESOLUTIONS after Internal reference Resolution:"
        echo "$PENDING_RESOLUTIONS" | jq .
    fi

    # --- Step 2.2: External/Cmd Resolution ---
    while read -r key; do
        local value=$(echo "$PENDING_RESOLUTIONS" | jq -r ".\"$key\"")
        if [[ "$value" == *\$* ]]; then
            value=$(echo "$value" | envsubst)
            if [[ "$value" == \$\(* ]]; then
                value=$(eval echo "$value")
            fi
            if [[ "$value" == *\$* ]]; then
                echo ">>> ERROR: Final resolution failed for key: $key (Result: $value)"
                exit 1
            fi
            PENDING_RESOLUTIONS=$(echo "$PENDING_RESOLUTIONS" | jq --arg k "$key" --arg v "$value" '.[$k] = $v')
        fi
    done < <(echo "$PENDING_RESOLUTIONS" | jq -r 'keys[]')

    if $DEBUG; then
        log_debug ">>> PENDING_RESOLUTIONS after full Resolution:"
        echo "$PENDING_RESOLUTIONS" | jq .
    fi
    # --- Step 3: Final Merge back to Original State ---
    local final_flat=$(echo "$FLAT_JSON_DATA $PENDING_RESOLUTIONS" | jq -s 'add')
    
    if $DEBUG; then
        log_debug ">>> Intermediary Flat Data:"
        echo "$final_flat" | jq .
    fi

    RESOLVED_JSON_DATA=$(echo "$final_flat" | jq -n '
        reduce (inputs | to_entries[]) as $item ({}; 
            (
                $item.key | split(".") | map(
                    if (type == "string" and test("^\\[.*\\]$")) then 
                        (sub("\\["; "") | sub("\\]"; "") | tonumber)
                    else 
                        . 
                    end
                )
            ) as $path 
            | setpath($path; $item.value)
        )
    ')

    export RESOLVED_JSON_DATA
}

# --- Argument Parsing & Main ---
usage() {
    echo "Usage: $0 [options] <json_file>"
    echo "Options:"
    echo "  -d, --debug     Print all intermediary objects (flat, pending, etc.)"
    echo "  -v, --verbose   Print the final resolved JSON object"
    echo "  --dry-run       Run logic without side effects"
    exit 1
}

parse_args() {
    if [[ $# -eq 0 ]]; then
        usage
    fi

    while [[ $# -gt 0 ]]; do
        case $1 in
            -d|--debug) 
                DEBUG=true
                shift 
                ;;
            -v|--verbose) 
                VERBOSE=true
                shift 
                ;;
            --dry-run) 
                DRY_RUN=true
                shift 
                ;;
            -*) 
                echo "Error: Unknown option '$1'"
                usage 
                ;;
            *) 
                INPUT_FILE="$1"
                shift 
                ;;
        esac
    done

    if [[ -z "$INPUT_FILE" ]]; then
        echo "Error: No JSON file specified"
        usage
    fi
}

main() {
    parse_args "$@"

    flatten_json "$INPUT_FILE"
    
    if [[ "$DEBUG" = true ]]; then
        log_debug ">>> [DEBUG] Initial Flat Data:"
        echo "$FLAT_JSON_DATA" | jq .
    fi

    resolve_flat_dictionary

    if [[ "$VERBOSE" = true ]] || [[ "$DEBUG" = true ]]; then
        log_debug ">>> JSON resolution complete."
        log_debug "###########################"
        echo "$RESOLVED_JSON_DATA" | jq .
        log_debug "###########################"
    else
        echo "$RESOLVED_JSON_DATA" | jq .
    fi
}

main "$@"
