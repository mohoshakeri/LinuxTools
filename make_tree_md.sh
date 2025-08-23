#!/bin/bash

# Project Documentation Generator
# Usage: ./generate_project_doc.sh [OPTIONS]
# Options:
#   --dir=<directory>     Directory to scan (default: current directory)
#   --includes=<patterns> Comma-separated list of include patterns (default: all files)
#   --excludes=<patterns> Comma-separated list of exclude patterns (default: none)
#   --output=<filename>   Output markdown file (default: project_documentation.md)
#   --help               Show this help message

# Default values
DIR="."
INCLUDES=""
EXCLUDES=""
OUTPUT="project_documentation.md"

# Function to show help
show_help() {
    cat << EOF
Project Documentation Generator

Usage: $0 [OPTIONS]

Options:
    --dir=<directory>     Directory to scan (default: current directory)
    --includes=<patterns> Comma-separated list of include patterns (default: all files)
                         Examples: "*.py,*.js,*.md" or "src/**/*.java"
    --excludes=<patterns> Comma-separated list of exclude patterns (default: none)
                         Examples: "node_modules/**,*.log,dist/**"
    --output=<filename>   Output markdown file (default: project_documentation.md)
    --help               Show this help message

Examples:
    $0 --dir=./my-project --excludes="node_modules/**,*.log"
    $0 --includes="*.py,*.js" --excludes="__pycache__/**,*.pyc"
    $0 --dir=./src --includes="**/*.java" --output=java_docs.md
EOF
}

# Parse command line arguments
for arg in "$@"; do
    case $arg in
        --dir=*)
            DIR="${arg#*=}"
            shift
            ;;
        --includes=*)
            INCLUDES="${arg#*=}"
            shift
            ;;
        --excludes=*)
            EXCLUDES="${arg#*=}"
            shift
            ;;
        --output=*)
            OUTPUT="${arg#*=}"
            shift
            ;;
        --help)
            show_help
            exit 0
            ;;
        *)
            echo "Unknown option: $arg"
            show_help
            exit 1
            ;;
    esac
done

# Function to check if file matches pattern
matches_pattern() {
    local file="$1"
    local pattern="$2"

    # Convert gitignore-style pattern to shell glob
    case "$pattern" in
        **/*)
            # Handle ** patterns
            shopt -s globstar
            [[ "$file" == $pattern ]]
            ;;
        */*)
            # Handle directory patterns
            [[ "$file" == $pattern ]]
            ;;
        .*)
            # Handle dot files
            [[ "$file" == *$pattern ]]
            ;;
        *.*)
            # Handle extension patterns
            [[ "$file" == $pattern ]]
            ;;
        *)
            # Handle simple patterns
            [[ "$file" == *$pattern* ]]
            ;;
    esac
}

# Function to check if file should be included
should_include_file() {
    local file="$1"
    local relative_path="${file#$DIR/}"

    # Remove leading ./
    relative_path="${relative_path#./}"

    # Check excludes first
    if [[ -n "$EXCLUDES" ]]; then
        IFS=',' read -ra EXCLUDE_PATTERNS <<< "$EXCLUDES"
        for pattern in "${EXCLUDE_PATTERNS[@]}"; do
            pattern=$(echo "$pattern" | xargs) # trim whitespace
            if matches_pattern "$relative_path" "$pattern"; then
                return 1
            fi
        done
    fi

    # Check includes
    if [[ -n "$INCLUDES" ]]; then
        IFS=',' read -ra INCLUDE_PATTERNS <<< "$INCLUDES"
        for pattern in "${INCLUDE_PATTERNS[@]}"; do
            pattern=$(echo "$pattern" | xargs) # trim whitespace
            if matches_pattern "$relative_path" "$pattern"; then
                return 0
            fi
        done
        return 1
    fi

    # Default: include all files (except binary files)
    if file "$file" | grep -q "text\|empty"; then
        return 0
    else
        return 1
    fi
}

# Function to generate tree structure
generate_tree() {
    local current_dir="$1"
    local prefix="$2"
    local is_last="$3"

    local files=()
    local dirs=()

    # Separate files and directories
    while IFS= read -r -d '' item; do
        if [[ -d "$item" ]]; then
            dirs+=("$item")
        elif [[ -f "$item" ]] && should_include_file "$item"; then
            files+=("$item")
        fi
    done < <(find "$current_dir" -maxdepth 1 -not -path "$current_dir" -print0 2>/dev/null | sort -z)

    # Print directories first
    local total_items=$((${#dirs[@]} + ${#files[@]}))
    local item_count=0

    for dir in "${dirs[@]}"; do
        ((item_count++))
        local dir_name=$(basename "$dir")
        local is_last_item=$((item_count == total_items))

        if [[ $is_last_item -eq 1 ]]; then
            echo "${prefix}└── ${dir_name}/"
            generate_tree "$dir" "${prefix}    " 1
        else
            echo "${prefix}├── ${dir_name}/"
            generate_tree "$dir" "${prefix}│   " 0
        fi
    done

    # Print files
    for file in "${files[@]}"; do
        ((item_count++))
        local file_name=$(basename "$file")
        local is_last_item=$((item_count == total_items))

        if [[ $is_last_item -eq 1 ]]; then
            echo "${prefix}└── ${file_name}"
        else
            echo "${prefix}├── ${file_name}"
        fi
    done
}

# Function to get all valid files recursively
get_all_files() {
    local search_dir="$1"
    local files=()

    while IFS= read -r -d '' file; do
        if should_include_file "$file"; then
            files+=("$file")
        fi
    done < <(find "$search_dir" -type f -print0 2>/dev/null | sort -z)

    printf '%s\n' "${files[@]}"
}

# Main execution
echo "🔄 Generating project documentation..."
echo "📂 Directory: $DIR"
echo "📝 Output: $OUTPUT"

# Check if directory exists
if [[ ! -d "$DIR" ]]; then
    echo "❌ Error: Directory '$DIR' does not exist!"
    exit 1
fi

# Create output file
cat > "$OUTPUT" << EOF
# 📋 Project Documentation

Generated on: $(date '+%Y-%m-%d %H:%M:%S')
Directory: \`$(realpath "$DIR")\`
$(if [[ -n "$INCLUDES" ]]; then echo "Includes: \`$INCLUDES\`"; fi)
$(if [[ -n "$EXCLUDES" ]]; then echo "Excludes: \`$EXCLUDES\`"; fi)

---

## 🌳 1. PROJECT TREE

\`\`\`
$(basename "$(realpath "$DIR")")/
$(generate_tree "$DIR" "" 1)
\`\`\`

---

## 📄 2. FILE CONTENTS

EOF

# Get all files and add their contents
file_counter=0
while IFS= read -r file; do
    if [[ -n "$file" ]]; then
        ((file_counter++))
        relative_path="${file#$DIR/}"
        relative_path="${relative_path#./}"

        echo "### 📄 File $file_counter: \`$relative_path\`" >> "$OUTPUT"
        echo "" >> "$OUTPUT"

        # Check if file is readable and not binary
        if [[ -r "$file" ]] && file "$file" | grep -q "text\|empty"; then
            # Get file extension for syntax highlighting
            extension="${file##*.}"
            case "$extension" in
                py) lang="python" ;;
                js) lang="javascript" ;;
                ts) lang="typescript" ;;
                java) lang="java" ;;
                cpp|cc|cxx) lang="cpp" ;;
                c) lang="c" ;;
                h|hpp) lang="c" ;;
                sh) lang="bash" ;;
                html) lang="html" ;;
                css) lang="css" ;;
                json) lang="json" ;;
                xml) lang="xml" ;;
                yml|yaml) lang="yaml" ;;
                md) lang="markdown" ;;
                sql) lang="sql" ;;
                php) lang="php" ;;
                rb) lang="ruby" ;;
                go) lang="go" ;;
                rs) lang="rust" ;;
                *) lang="text" ;;
            esac

            echo "\`\`\`$lang" >> "$OUTPUT"
            cat "$file" >> "$OUTPUT" 2>/dev/null || echo "[Error: Could not read file]" >> "$OUTPUT"
            echo "" >> "$OUTPUT"
            echo "\`\`\`" >> "$OUTPUT"
        else
            echo "\`\`\`" >> "$OUTPUT"
            echo "[Binary file or unreadable content]" >> "$OUTPUT"
            echo "\`\`\`" >> "$OUTPUT"
        fi

        echo "" >> "$OUTPUT"
        echo "---" >> "$OUTPUT"
        echo "" >> "$OUTPUT"
    fi
done < <(get_all_files "$DIR")

# Add footer
cat >> "$OUTPUT" << EOF

## ✨ Summary

- **Total Files Documented:** $file_counter
- **Generated:** $(date '+%Y-%m-%d %H:%M:%S')
- **Tool:** Project Documentation Generator

---

*This documentation was automatically generated. Please review the content before use.*
EOF

echo "✅ Documentation generated successfully!"
echo "📄 Output file: $OUTPUT"
echo "📊 Total files documented: $file_counter"