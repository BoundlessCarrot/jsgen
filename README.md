# jsgen

I realized I could do this much better with a bash script, which is exactly what I've done. See here:

```bash
#!/bin/bash
# This script needs to be run from the source directory!!

# Check if prettier is installed, install if not
if ! command -v prettier &> /dev/null; then
    echo "Installing prettier..."
    npm install -g prettier
fi

# Function to convert a markdown file to HTML
convert_file() {
    local file="$1"
    local rel_path="${file#masters/}"
    local output_dir="../$(dirname "$rel_path")"
    local filename="$(basename "$rel_path" .md)"
    
    # Create output directory if it doesn't exist
    mkdir -p "$output_dir"
    
    echo "Converting $file to HTML..."
    # Convert markdown to HTML and combine with header and footer
    cat header.html <(pandoc "$file" -f markdown -t html) footer.html > "$output_dir/$filename.html"
    
    # Format the HTML file using prettier
    echo "Formatting HTML..."
    prettier --write "$output_dir/$filename.html"
    
    echo "Saved to $output_dir/$filename.html"
}

# Find all markdown files recursively and convert them
find masters -type f -name "*.md" | while read -r file; do
    convert_file "$file"
done

echo "All files converted! Starting local web server..."
echo "Press Ctrl+C to stop the server"
cd "$HOME/projects/website-files/" && python3 -m http.server 8000


```
