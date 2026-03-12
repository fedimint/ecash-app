#!/usr/bin/env bash
#
# Translation/Localization Check Script
# Checks for common i18n issues in Flutter ARB files and Dart code
#
# Checks performed:
# 1. ARB JSON validation - Ensure translation files are valid JSON
# 2. Missing translations - Keys in one language missing from another
# 3. Placeholder mismatches - {placeholder} usage differs between languages
# 4. Unused keys - Translation keys not referenced in code (warning only)
# 5. Hardcoded strings - User-facing strings not using l10n

set -eo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Get script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

L10N_DIR="$PROJECT_ROOT/lib/l10n"
EN_ARB="$L10N_DIR/app_en.arb"
ES_ARB="$L10N_DIR/app_es.arb"
LIB_DIR="$PROJECT_ROOT/lib"

# Track if any blocking errors occurred
ERRORS=0
WARNINGS=0

print_check() {
    echo -e "${GREEN}✓${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
    ERRORS=$((ERRORS + 1))
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
    WARNINGS=$((WARNINGS + 1))
}

print_header() {
    echo ""
    echo "=== $1 ==="
}

# Check if required files exist
check_files_exist() {
    if [[ ! -f "$EN_ARB" ]]; then
        print_error "English ARB file not found: $EN_ARB"
        exit 1
    fi
    if [[ ! -f "$ES_ARB" ]]; then
        print_error "Spanish ARB file not found: $ES_ARB"
        exit 1
    fi
}

# Check 1: ARB JSON Validation
check_json_validity() {
    print_header "Check 1: ARB JSON Validation"
    
    local en_valid=true
    local es_valid=true
    
    if ! jq empty "$EN_ARB" 2>/dev/null; then
        print_error "app_en.arb is not valid JSON"
        en_valid=false
    fi
    
    if ! jq empty "$ES_ARB" 2>/dev/null; then
        print_error "app_es.arb is not valid JSON"
        es_valid=false
    fi
    
    if $en_valid && $es_valid; then
        print_check "Both ARB files are valid JSON"
    fi
}

# Extract translation keys from ARB file (excluding @@locale and @metadata keys)
get_translation_keys() {
    local arb_file="$1"
    jq -r 'keys[]' "$arb_file" | grep -v '^@@' | grep -v '^@' | sort
}

# Check 2: Missing Translations
check_missing_translations() {
    print_header "Check 2: Missing Translations"
    
    local en_keys es_keys
    en_keys=$(get_translation_keys "$EN_ARB")
    es_keys=$(get_translation_keys "$ES_ARB")
    
    local en_count es_count
    en_count=$(echo "$en_keys" | wc -l | tr -d ' ')
    es_count=$(echo "$es_keys" | wc -l | tr -d ' ')
    
    # Find keys in English but not in Spanish
    local missing_in_es
    missing_in_es=$(comm -23 <(echo "$en_keys") <(echo "$es_keys"))
    
    # Find keys in Spanish but not in English
    local missing_in_en
    missing_in_en=$(comm -13 <(echo "$en_keys") <(echo "$es_keys"))
    
    if [[ -n "$missing_in_es" ]]; then
        print_error "Keys in app_en.arb missing from app_es.arb:"
        echo "$missing_in_es" | while read -r key; do
            echo "   - $key"
        done
    else
        print_check "All English keys exist in Spanish ($en_count keys)"
    fi
    
    if [[ -n "$missing_in_en" ]]; then
        print_error "Keys in app_es.arb missing from app_en.arb:"
        echo "$missing_in_en" | while read -r key; do
            echo "   - $key"
        done
    else
        print_check "All Spanish keys exist in English ($es_count keys)"
    fi
}

# Extract placeholders from a string (e.g., {amount}, {count})
extract_placeholders() {
    echo "$1" | grep -oE '\{[a-zA-Z_][a-zA-Z0-9_]*\}' | sort -u || true
}

# Check 3: Placeholder Mismatches
check_placeholder_mismatches() {
    print_header "Check 3: Placeholder Consistency"
    
    local keys
    keys=$(get_translation_keys "$EN_ARB")
    
    local mismatch_found=false
    
    while read -r key; do
        [[ -z "$key" ]] && continue
        
        local en_value es_value
        en_value=$(jq -r --arg k "$key" '.[$k] // empty' "$EN_ARB")
        es_value=$(jq -r --arg k "$key" '.[$k] // empty' "$ES_ARB")
        
        # Skip if Spanish translation doesn't exist (caught by check 2)
        [[ -z "$es_value" ]] && continue
        
        local en_placeholders es_placeholders
        en_placeholders=$(extract_placeholders "$en_value")
        es_placeholders=$(extract_placeholders "$es_value")
        
        if [[ "$en_placeholders" != "$es_placeholders" ]]; then
            mismatch_found=true
            print_error "Placeholder mismatch for key '$key':"
            echo "   English:  $en_placeholders"
            echo "   Spanish:  $es_placeholders"
        fi
    done <<< "$keys"
    
    if ! $mismatch_found; then
        print_check "All placeholders match between languages"
    fi
}

# Check 4: Unused Translation Keys
check_unused_keys() {
    print_header "Check 4: Unused Translation Keys"
    
    local keys
    keys=$(get_translation_keys "$EN_ARB")
    
    # Get all l10n usages from code in one pass (much faster than per-key grep)
    local used_keys
    used_keys=$(grep -rhE "l10n\??\.[a-zA-Z_][a-zA-Z0-9_]*" "$LIB_DIR" --include="*.dart" 2>/dev/null | \
        grep -oE "l10n\??\.[a-zA-Z_][a-zA-Z0-9_]*" | \
        sed 's/l10n?\.//;s/l10n\.//' | \
        sort -u)
    
    local unused_keys=()
    
    while read -r key; do
        [[ -z "$key" ]] && continue
        
        # Check if key is in the used_keys list
        if ! echo "$used_keys" | grep -qx "$key"; then
            unused_keys+=("$key")
        fi
    done <<< "$keys"
    
    if [[ ${#unused_keys[@]} -gt 0 ]]; then
        print_warning "Found ${#unused_keys[@]} potentially unused translation keys:"
        for key in "${unused_keys[@]}"; do
            echo "   - $key"
        done
        echo "   (These may be used dynamically or in generated code)"
    else
        print_check "All translation keys appear to be used in code"
    fi
}

# Check 5: Hardcoded Strings
check_hardcoded_strings() {
    print_header "Check 5: Hardcoded User-Facing Strings"
    
    # We run multiple patterns to catch different cases
    local all_matches=""
    
    # Pattern 1: Direct widget/property usage
    # Matches: Text('String'), tooltip: 'String', message: 'String', etc.
    local pattern1='(Text\(|tooltip:|message:|hintText:|labelText:|title:)\s*['"'"'"][A-Z][a-zA-Z ]{4,}'
    
    # Pattern 2: Error assignments (common pattern for user-facing errors)
    # Matches: _error = 'String', error = 'String'
    local pattern2='_?error\s*=\s*['"'"'"][A-Z][a-zA-Z ]{4,}'
    
    # Pattern 3: Return statements with user-facing strings
    # Matches: return 'String' or return condition ? 'String' : 'String'
    # We look for returns with strings that look like UI text (capital letter, spaces, or hyphens)
    local pattern3='return\s+.*['"'"'"][A-Z][a-zA-Z -]+['"'"'"]'
    
    # Pattern 4: Standalone string literals that look like UI text (ternary expressions, etc.)
    # Matches lines with ? 'String' : or just standalone 'Capital String'
    # This catches multi-line ternaries where the string is on its own line
    local pattern4='^\s*[\?:]\s*['"'"'"][A-Z][a-zA-Z ]{3,}['"'"'"]'
    
    # Run all patterns and combine results
    local matches1 matches2 matches3 matches4
    
    matches1=$(grep -rn --include="*.dart" -E "$pattern1" "$LIB_DIR" 2>/dev/null || true)
    matches2=$(grep -rn --include="*.dart" -E "$pattern2" "$LIB_DIR" 2>/dev/null || true)
    matches3=$(grep -rn --include="*.dart" -E "$pattern3" "$LIB_DIR" 2>/dev/null || true)
    matches4=$(grep -rn --include="*.dart" -E "$pattern4" "$LIB_DIR" 2>/dev/null || true)
    
    # Combine all matches
    all_matches=$(echo -e "${matches1}\n${matches2}\n${matches3}\n${matches4}" | \
        grep -v "^$" | \
        grep -v "context\.l10n" | \
        grep -v "l10n\." | \
        grep -v "_test\.dart" | \
        grep -v "/generated/" | \
        grep -v "// i18n-ignore" | \
        sort -u || true)
    
    if [[ -n "$all_matches" ]]; then
        local count
        count=$(echo "$all_matches" | wc -l | tr -d ' ')
        print_error "Found $count hardcoded strings that may need translation:"
        echo "$all_matches" | while read -r line; do
            # Make path relative to project root
            echo "   ${line#$PROJECT_ROOT/}"
        done
        echo ""
        echo "   To fix: Use context.l10n.keyName instead of literal strings"
        echo "   To ignore: Add '// i18n-ignore' comment on the same line"
    else
        print_check "No obvious hardcoded user-facing strings found"
    fi
}

# Main
main() {
    echo "Checking translations..."
    echo "Project root: $PROJECT_ROOT"
    
    check_files_exist
    check_json_validity
    check_missing_translations
    check_placeholder_mismatches
    check_unused_keys
    check_hardcoded_strings
    
    echo ""
    echo "=== Summary ==="
    
    if [[ $ERRORS -gt 0 ]]; then
        echo -e "${RED}Translation check failed with $ERRORS error(s) and $WARNINGS warning(s)${NC}"
        echo "Please fix the errors above before committing."
        exit 1
    elif [[ $WARNINGS -gt 0 ]]; then
        echo -e "${YELLOW}Translation check passed with $WARNINGS warning(s)${NC}"
        exit 0
    else
        echo -e "${GREEN}All translation checks passed!${NC}"
        exit 0
    fi
}

main "$@"
