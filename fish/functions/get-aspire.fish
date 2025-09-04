function get-aspire --description "Install custom Aspire CLI versions from PR builds or latest dev build"
    argparse -n get-aspire 'h/help' 'f/force' 'l/latest' 'b/branch=' -- $argv
    or return 2

    if set -q _flag_help
        echo "Usage: get-aspire [OPTIONS] [<pr-number>]"
        echo ""
        echo "Install custom Aspire CLI versions from PR builds or latest dev build"
        echo ""
        echo "Arguments:"
        echo "  <pr-number>    The PR number to install Aspire CLI from"
        echo ""
        echo "Options:"
        echo "  -l, --latest   Install the latest dev build from aspire.dev"
        echo "  -f, --force    Force download of the installation script (ignore cache)"
        echo "  -b, --branch   Specify the GitHub branch to download the script from (default: main)"
        echo "  -h, --help     Show this help message"
        echo ""
        echo "Examples:"
        echo "  get-aspire 1234"
        echo "  get-aspire --force 1234"
        echo "  get-aspire --latest"
        echo "  get-aspire --branch feature-branch 1234"
        return 0
    end

    # Handle --latest flag
    if set -q _flag_latest
        if test (count $argv) -gt 0
            echo "get-aspire: error: cannot specify PR number with --latest flag" >&2
            return 1
        end
        
        echo "get-aspire: installing latest dev build..." >&2
        curl -sSL https://aspire.dev/install.sh | bash -s -- -q dev
        set -l exit_code $status
        
        if test $exit_code -eq 0
            echo "get-aspire: latest dev build installed successfully" >&2
        else
            echo "get-aspire: installation failed with exit code $exit_code" >&2
        end
        
        return $exit_code
    end

    # Require PR number when not using --latest
    if test (count $argv) -ne 1
        echo "get-aspire: error: PR number required (or use --latest for dev build)" >&2
        echo "Usage: get-aspire <pr-number>" >&2
        echo "Try 'get-aspire --help' for more information." >&2
        return 1
    end

    set -l pr_number $argv[1]

    # Validate PR number is numeric
    if not string match -r '^\d+$' -- $pr_number >/dev/null
        echo "get-aspire: error: PR number must be numeric, got '$pr_number'" >&2
        return 1
    end

    # Set the branch (default to main if not specified)
    set -l branch "main"
    if set -q _flag_branch
        set branch $_flag_branch
        echo "get-aspire: using branch '$branch'" >&2
    end

    # Create a safe filename from the branch name by replacing problematic characters
    set -l safe_branch_name (string replace -a '/' '_' -- $branch | string replace -a ':' '_')

    # Setup cache directory and file paths
    set -l cache_dir "$HOME/.cache/aspire-cli"
    set -l script_file "$cache_dir/get-aspire-cli-pr-$safe_branch_name.sh"
    set -l timestamp_file "$cache_dir/last_updated_$safe_branch_name"
    set -l script_url "https://raw.githubusercontent.com/dotnet/aspire/$branch/eng/scripts/get-aspire-cli-pr.sh"
    
    # Create cache directory if it doesn't exist
    if not test -d "$cache_dir"
        mkdir -p "$cache_dir"
        or begin
            echo "get-aspire: error: failed to create cache directory '$cache_dir'" >&2
            return 1
        end
    end

    # Function to check if cache is stale (older than 7 days)
    function __get_aspire_cache_is_stale
        set -l timestamp_file $argv[1]
        set -l script_file $argv[2]
        
        # If either file doesn't exist, cache is stale
        if not test -f "$timestamp_file"; or not test -f "$script_file"
            return 0
        end
        
        # Get timestamp of last update (seconds since epoch)
        set -l last_updated (cat "$timestamp_file" 2>/dev/null)
        if test -z "$last_updated"
            return 0
        end
        
        # Get current timestamp
        set -l current_time (date +%s)
        
        # Calculate age in seconds (7 days = 604800 seconds)
        set -l age (math "$current_time - $last_updated")
        set -l week_seconds 604800
        
        # Return 0 (true) if cache is stale
        test $age -gt $week_seconds
    end

    # Function to download and cache the script
    function __get_aspire_update_cache
        set -l script_url $argv[1]
        set -l script_file $argv[2]
        set -l timestamp_file $argv[3]
        
        echo "get-aspire: downloading installation script..." >&2
        
        # Ensure the directory exists and is writable
        set -l cache_dir (dirname "$script_file")
        if not test -d "$cache_dir"
            mkdir -p "$cache_dir"
            or begin
                echo "get-aspire: error: failed to create cache directory '$cache_dir'" >&2
                return 1
            end
        end
        
        # Test if we can write to the cache directory
        if not test -w "$cache_dir"
            echo "get-aspire: error: cache directory '$cache_dir' is not writable" >&2
            return 1
        end
        
        # Download the script with better error handling
        if not curl -fsSL "$script_url" -o "$script_file"
            echo "get-aspire: error: failed to download script from '$script_url'" >&2
            echo "get-aspire: this could be due to:" >&2
            echo "  - The branch name '$branch' does not exist" >&2
            echo "  - Network connectivity issues" >&2
            echo "  - The script path does not exist in this branch" >&2
            return 1
        end
        
        # Verify the downloaded file is not empty
        if not test -s "$script_file"
            echo "get-aspire: error: downloaded script is empty" >&2
            rm -f "$script_file"
            return 1
        end
        
        # Make script executable
        chmod +x "$script_file"
        or begin
            echo "get-aspire: error: failed to make script executable" >&2
            return 1
        end
        
        # Update timestamp
        date +%s > "$timestamp_file"
        or begin
            echo "get-aspire: warning: failed to update cache timestamp" >&2
        end
        
        echo "get-aspire: script cached successfully" >&2
        return 0
    end

    # Check if we need to update the cache
    set -l need_update 0
    
    if set -q _flag_force
        echo "get-aspire: force flag specified, updating cache..." >&2
        set need_update 1
    else if __get_aspire_cache_is_stale "$timestamp_file" "$script_file"
        echo "get-aspire: cache is stale or missing, updating..." >&2
        set need_update 1
    else
        echo "get-aspire: using cached script" >&2
    end

    # Update cache if needed
    if test $need_update -eq 1
        __get_aspire_update_cache "$script_url" "$script_file" "$timestamp_file"
        or return $status
    end

    # Verify script exists before executing
    if not test -f "$script_file"
        echo "get-aspire: error: cached script not found at '$script_file'" >&2
        return 1
    end

    # Execute the cached script with the PR number
    echo "get-aspire: installing Aspire CLI from PR #$pr_number using branch '$branch'..." >&2
    bash "$script_file" "$pr_number"
    set -l exit_code $status
    
    if test $exit_code -eq 0
        echo "get-aspire: Aspire CLI from PR #$pr_number (branch: $branch) installed successfully" >&2
    else
        echo "get-aspire: installation failed with exit code $exit_code" >&2
    end
    
    return $exit_code
end
