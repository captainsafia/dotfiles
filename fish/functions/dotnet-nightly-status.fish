function dotnet-nightly-status --description "Show latest .NET nightly SDK and related commits (Fish with --os/--arch)"
    # Configuration
    set -l DEFAULT_DOTNET_VERSION "10.0.1xx"
    set -l GITHUB_API_BASE "https://api.github.com"
    set -l DOTNET_API_BASE "https://aka.ms/dotnet"
    set -l MAX_RETRIES 3
    set -l RETRY_DELAY 2
    set -l API_TIMEOUT 20
    set -l CONNECT_TIMEOUT 10

    # Parse flags
    # Usage: dotnet-nightly-status [--os osx|linux|win] [--arch x64|arm64] [-h|--help]
    argparse -n dotnet-nightly-status 'h/help' 'o/os=' 'a/arch=' -- $argv
    if test $status -ne 0
        return 2
    end
    if set -q _flag_help
        echo "Usage: dotnet-nightly-status [--os osx|linux|win] [--arch x64|arm64]"
        return 0
    end

    # ---- Defaults (auto-detected) ----
    set -l def_os linux
    switch (uname -s)
        case Darwin
            set def_os osx
        case Linux
            set def_os linux
        case '*'
            set def_os linux
    end

    set -l def_arch x64
    switch (string lower -- (uname -m))
        case x86_64 amd64
            set def_arch x64
        case arm64 aarch64
            set def_arch arm64
    end

    # Apply flags (normalize & map synonyms)
    set -l os (string lower -- (set -q _flag_os; and echo $_flag_os; or echo $def_os))
    set -l arch (string lower -- (set -q _flag_arch; and echo $_flag_arch; or echo $def_arch))

    switch $os
        case osx mac macos darwin
            set os osx
        case linux
            set os linux
        case win windows windows-nt windowsnt
            set os win
        case '*'
            set_color red; echo "Unsupported --os '$os'. Allowed: osx, linux, win."; set_color normal
            return 2
    end

    switch $arch
        case x64 x86_64 amd64
            set arch x64
        case arm64 aarch64
            set arch arm64
        case '*'
            set_color red; echo "Unsupported --arch '$arch'. Allowed: x64, arm64."; set_color normal
            return 2
    end

    set -l DAILY_URL "$DOTNET_API_BASE/$DEFAULT_DOTNET_VERSION/daily/productCommit-$os-$arch.txt"

    # Curl defaults with improved retry and timeout handling
    set -l curl_common -fsSL --retry $MAX_RETRIES --retry-delay $RETRY_DELAY --max-time $API_TIMEOUT --connect-timeout $CONNECT_TIMEOUT

    # Helper function to validate JSON response
    function _is_valid_json
        set -l json_content $argv[1]
        if test -z "$json_content"
            return 1
        end
        if string match -q "*HTML*" -- $json_content; or string match -q "*<!DOCTYPE*" -- $json_content
            return 1
        end
        if string match -q "*{*" -- $json_content; or string match -q "*[*" -- $json_content
            return 0
        end
        return 1
    end

    # Helper function to format ISO date to human-readable format
    function _format_date
        set -l iso_date $argv[1]
        if test -z "$iso_date"; or test "$iso_date" = "null"
            echo "Unknown"
            return
        end
        
        # Try to use date command to format (works on macOS and Linux)
        if date -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso_date" "+%Y-%m-%d %H:%M UTC" 2>/dev/null
            return
        else if date -d "$iso_date" "+%Y-%m-%d %H:%M UTC" 2>/dev/null
            return
        else
            # Fallback: just clean up the ISO format
            echo (string replace -r 'T' ' ' -- $iso_date | string replace -r 'Z.*$' ' UTC')
        end
    end

    # Helper function for API calls with better error handling
    function _github_api_call
        set -l url $argv[1]
        set -l description $argv[2]
        
        set -l response (curl $curl_common $gh_headers "$url" 2>/dev/null)
        set -l curl_status $status
        
        if test $curl_status -ne 0
            set_color yellow
            echo "$description API call failed (curl exit code: $curl_status)"
            set_color normal
            return 1
        end
        
        if not _is_valid_json "$response"
            set_color yellow
            echo "$description returned invalid JSON response"
            set_color normal
            return 1
        end
        
        if string match -q "*Not Found*" -- $response; or string match -q "*rate limit*" -- $response
            set_color yellow
            if string match -q "*rate limit*" -- $response
                echo "$description failed: GitHub API rate limit exceeded"
            else
                echo "$description: Resource not found"
            end
            set_color normal
            return 1
        end
        
        echo "$response"
        return 0
    end

    set_color cyan; echo "Target: $os-$arch"; set_color normal
    set_color cyan; echo "Fetching nightly metadata…"; set_color normal
    set -l metadata (curl $curl_common "$DAILY_URL")
    if test $status -ne 0 -o -z "$metadata"
        set_color red; echo "Download failed."; set_color normal
        return 1
    end

    # Extract sdk_commit and sdk_version (tiny key=value file)
    set -l commit_sha (string match -r --groups-only 'sdk_commit="([^"]+)"' -- $metadata)[1]
    set -l sdk_version (string match -r --groups-only 'sdk_version="([^"]+)"' -- $metadata)[1]
    if test -z "$commit_sha"
        set_color red; echo "Could not parse commit SHA from metadata."; set_color normal
        return 1
    end

    set_color green; printf "Latest SDK version:"; set_color normal; printf "  %s\n" "$sdk_version"
    set_color green; printf "SDK commit SHA    :"; set_color normal; printf "  %s\n\n" "$commit_sha"

    # ---- dotnet/dotnet commit lookup ----
    set -l api_url "$GITHUB_API_BASE/repos/dotnet/dotnet/commits/$commit_sha"
    set -l gh_headers "-H" "Accept: application/vnd.github+json"
    if set -q GITHUB_TOKEN
        set gh_headers $gh_headers "-H" "Authorization: Bearer $GITHUB_TOKEN"
    end

    set_color cyan; echo "Fetching dotnet/dotnet commit info…"; set_color normal
    set -l commit_json (_github_api_call "$api_url" "dotnet/dotnet commit lookup")
    set -l api_success $status

    set -l commit_date ""
    set -l commit_msg  ""
    
    if test $api_success -eq 0
        if type -q jq
            set commit_date (printf "%s" "$commit_json" | jq -r '.commit.committer.date' 2>/dev/null)
            set commit_msg  (printf "%s" "$commit_json" | jq -r '(.commit.message | split("\n")[0])' 2>/dev/null)
        end
        if test -z "$commit_date"
            set commit_date (printf "%s" "$commit_json" | grep -o '"date":[[:space:]]*"[^"]*"'    | head -n1 | sed 's/.*"date":[[:space:]]*"\([^"]*\)".*/\1/')
            set commit_msg  (printf "%s" "$commit_json" | grep -o '"message":[[:space:]]*"[^"]*"' | head -n1 | sed 's/.*"message":[[:space:]]*"\([^"]*\)".*/\1/')
        end
        
        set commit_date (_format_date "$commit_date")
    else
        set commit_date "Unable to fetch"
        set commit_msg "Unable to fetch"
    end

    set_color green; printf "Commit date       :"; set_color normal; printf "  %s\n" "$commit_date"
    set_color green; printf "Commit message    :"; set_color normal; printf "  %s\n\n" "$commit_msg"

    # ---- ASP.NET Core commit via source-manifest.json ----
    set_color cyan; echo "Fetching source-manifest.json…"; set_color normal
    set -l manifest_url "https://raw.githubusercontent.com/dotnet/dotnet/$commit_sha/src/source-manifest.json"
    set -l manifest_json (curl $curl_common "$manifest_url" 2>/dev/null)
    if test $status -ne 0 -o -z "$manifest_json"
        set_color yellow; echo "Failed to fetch source-manifest.json - continuing without ASP.NET Core info"; set_color normal
        return 0
    end

    if not _is_valid_json "$manifest_json"
        set_color yellow; echo "Invalid source-manifest.json format - continuing without ASP.NET Core info"; set_color normal
        return 0
    end

    set -l aspnetcore_commit_sha ""
    if type -q jq
        set aspnetcore_commit_sha (printf "%s" "$manifest_json" | jq -r '.repositories[] | select(.path == "aspnetcore") | .commitSha' 2>/dev/null)
    end
    if test -z "$aspnetcore_commit_sha"
        set aspnetcore_commit_sha (printf "%s" "$manifest_json" | awk '
            /"path"[[:space:]]*:[[:space:]]*"aspnetcore"/ {found=1}
            found && /"commitSha"[[:space:]]*:/ {
                match($0, /"commitSha"[[:space:]]*:[[:space:]]*"([^"]*)"/, a);
                if (a[1]!="") { print a[1]; exit }
            }')
    end
    if test -z "$aspnetcore_commit_sha"
        set_color yellow; echo "Could not find ASP.NET Core commit in manifest - continuing without ASP.NET Core info"; set_color normal
        return 0
    end

    set_color green; printf "ASP.NET Core SHA  :"; set_color normal; printf "  %s\n\n" "$aspnetcore_commit_sha"

    set_color cyan; echo "Fetching ASP.NET Core commit info…"; set_color normal
    set -l asp_api "$GITHUB_API_BASE/repos/dotnet/aspnetcore/commits/$aspnetcore_commit_sha"
    set -l asp_json (_github_api_call "$asp_api" "ASP.NET Core commit lookup")
    set -l asp_api_success $status

    set -l asp_date ""
    set -l asp_msg  ""
    
    if test $asp_api_success -eq 0
        if type -q jq
            set asp_date (printf "%s" "$asp_json" | jq -r '.commit.committer.date' 2>/dev/null)
            set asp_msg  (printf "%s" "$asp_json" | jq -r '(.commit.message | split("\n")[0])' 2>/dev/null)
        end
        if test -z "$asp_date"
            set asp_date (printf "%s" "$asp_json" | grep -o '"date":[[:space:]]*"[^"]*"'    | head -n1 | sed 's/.*"date":[[:space:]]*"\([^"]*\)".*/\1/')
            set asp_msg  (printf "%s" "$asp_json" | grep -o '"message":[[:space:]]*"[^"]*"' | head -n1 | sed 's/.*"message":[[:space:]]*"\([^"]*\)".*/\1/')
        end
        
        set asp_date (_format_date "$asp_date")
    else
        set asp_date "Unable to fetch"
        set asp_msg "Unable to fetch"
    end

    set_color green; printf "ASP.NET Core date :"; set_color normal; printf "  %s\n" "$asp_date"
    set_color green; printf "ASP.NET Core msg  :"; set_color normal; printf "  %s\n" "$asp_msg"
end