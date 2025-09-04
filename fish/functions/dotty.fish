# dotty — per-project .NET installer/activator for the current shell
# Usage:
#   dotty [--version <10|10.0|10.0.1xx|9|9.0|Current|LTS|STS>] [--runtime [aspnetcore|dotnet]] [--activate]
#   dotty --help
#
# Examples:
#   dotty --version 9                       # install 9.x SDK
#   dotty --version 10 --runtime            # install ASP.NET Core 10.x runtime (default)
#   dotty --version 10 --runtime dotnet     # install base 10.x runtime
#   dotty --version 10 --runtime aspnetcore # install ASP.NET Core 10.x runtime
#   dotty                                   # install SDK for version in global.json, or "STS" channel
#   dotty --activate                        # activate existing .NET installation in ./.dotnet
#
# Version Detection:
#   1. Reads SDK version from global.json if present
#   2. Uses --version flag if provided (overrides global.json)
#   3. Defaults to "STS" channel if neither is specified
#
# Installs under: $PWD/.dotnet
# Activates by setting: DOTNET_ROOT and prepending to PATH
# Deactivate with: dotty-deactivate   (or `deactivate` if not already defined)

function dotty --description "Install and activate a local .NET SDK/runtime under ./.dotnet"
    # ---- Parse flags -------------------------------------------------------
    # --version accepts channel-like values (10, 10.0, 10.0.1xx, 9, 9.0, Current, LTS, STS)
    # --runtime switches from SDK install to runtime-only install. Optionally takes a value:
    #   - aspnetcore (default): Installs ASP.NET Core runtime
    #   - dotnet: Installs base .NET runtime only
    # --activate activates existing installation without downloading
    argparse -n dotty 'h/help' 'v/version=' 'r/runtime=?' 'a/activate' -- $argv
    if test $status -ne 0
        return 2
    end
    if set -q _flag_help
        echo "Usage: dotty [--version <10|10.0|10.0.1xx|9|9.0|Current|LTS|STS>] [--runtime[=aspnetcore|dotnet]] [--activate]"
        echo ""
        echo "Options:"
        echo "  --version   Specify .NET version/channel to install"
        echo "  --runtime   Install runtime only (not SDK). Optional values:"
        echo "              --runtime (defaults to aspnetcore) - ASP.NET Core runtime"
        echo "              --runtime=dotnet - Base .NET runtime only"
        echo "              --runtime=aspnetcore - ASP.NET Core runtime (explicit)"
        echo "  --activate  Activate existing .NET installation in ./.dotnet"
        echo ""
        echo "Examples:"
        echo "  dotty --version 9                       # install 9.x SDK"
        echo "  dotty --version 10 --runtime            # install ASP.NET Core 10.x runtime"
        echo "  dotty --version 10 --runtime=dotnet     # install base 10.x runtime"
        echo "  dotty --version 10 --runtime=aspnetcore # install ASP.NET Core 10.x runtime"
        echo "  dotty                                   # install SDK for version in global.json, or STS"
        echo "  dotty --activate                        # activate existing installation"
        return 0
    end

    # ---- Determine channel from --version (defaults to STS) ---------------
    set -l channel
    
    # Check for global.json file first
    if test -f global.json
        set -l json_version (jq -r '.sdk.version // empty' global.json 2>/dev/null)
        if test -n "$json_version"
            echo "dotty: found global.json specifying SDK version $json_version"
            set channel "$json_version"
        end
    end
    
    # Override with command line flag if provided
    if set -q _flag_version
        set channel $_flag_version
    end
    
    # Default to STS if no version specified
    if test -z "$channel"
        set channel STS
    end
    
    set channel (string trim -- $channel)

    # Normalize common shorthand like "10" -> "10.0", "9" -> "9.0"
    switch (string lower -- $channel)
        case 10
            set channel 10.0
        case 9
            set channel 9.0
        case current
            # Map deprecated "Current" to "STS"
            set channel STS
        case lts sts
            # capitalize for dotnet-install convention
            set channel (string upper -- $channel)
        case '*'
            # leave as-is if user passed e.g. 10.0.1xx or 9.0
    end

    # ---- Resolve target OS & installer script ------------------------------
    set -l uname_s (uname -s)
    set -l is_posix 1
    switch $uname_s
        case Darwin Linux
            set is_posix 1
        case '*'
            # Attempt Windows (PowerShell) if not POSIX
            set is_posix 0
    end

    set -l install_dir (pwd)/.dotnet
    
    # ---- Handle --activate flag -------------------------------------------
    if set -q _flag_activate
        # Check if installation exists
        if not test -d "$install_dir"
            echo "dotty: no .NET installation found in $install_dir" >&2
            echo "dotty: run 'dotty' without --activate to install first" >&2
            return 1
        end
        
        if not test -x "$install_dir/dotnet"
            echo "dotty: .NET installation found but dotnet binary is missing or not executable" >&2
            echo "dotty: try reinstalling with 'dotty' without --activate" >&2
            return 1
        end
        
        echo "dotty: activating existing .NET installation in $install_dir"
        # Skip to activation section
        set -l install_status 0
    else
        # Normal installation flow
        mkdir -p "$install_dir"
        if test $status -ne 0
            echo "dotty: failed to create $install_dir" >&2
            return 1
        end

        # ---- Download dotnet-install (with caching) ----------------------------
        set -l script  # Declare script variable at function scope
        set -l script_url  # Declare script_url variable at function scope
        
        # Use a cache directory for the install scripts
        set -l cache_dir "$HOME/.cache/dotty"
        mkdir -p "$cache_dir"
        
        if test $is_posix -eq 1
            set script "$cache_dir/dotnet-install.sh"
            set script_url "https://dot.net/v1/dotnet-install.sh"
        else
            set script "$cache_dir/dotnet-install.ps1"
            set script_url "https://dot.net/v1/dotnet-install.ps1"
        end
        
        # Download script if it doesn't exist or is older than 7 days
        set -l download_script 0
        if not test -f "$script"
            set download_script 1
            echo "dotty: downloading install script to cache..."
        else if test (find "$script" -mtime +7 2>/dev/null | wc -l) -gt 0
            set download_script 1
            echo "dotty: updating cached install script (older than 7 days)..."
        end
        
        if test $download_script -eq 1
            curl -fsSL --retry 2 --retry-delay 1 --connect-timeout 5 --max-time 60 "$script_url" -o "$script"
            if test $status -ne 0
                echo "dotty: failed to download $script_url" >&2
                rm -f "$script"
                return 1
            end
            if test $is_posix -eq 1
                chmod +x "$script"
            end
        end

        # ---- Install SDK or runtime -------------------------------------------
        set -l install_status 0
        
        # Determine if we should use --version or --channel parameter
        set -l version_param "--channel"
        set -l version_value "$channel"
        
        # Use --version for specific version numbers (e.g., 9.0.303), --channel for release channels (e.g., STS, LTS, 9.0)
        if string match -q -r '^\d+\.\d+\.\d+' "$channel"
            set version_param "--version"
        end
        
        if set -q _flag_runtime
            # Determine runtime type - default to aspnetcore if no value specified
            set -l runtime_type "aspnetcore"
            if test -n "$_flag_runtime"
                set runtime_type "$_flag_runtime"
            end
            
            # Validate runtime type
            switch "$runtime_type"
                case aspnetcore dotnet
                    # Valid runtime types
                case '*'
                    echo "dotty: invalid runtime type '$runtime_type'. Use 'aspnetcore' or 'dotnet'" >&2
                    return 1
            end
            
            echo "dotty: installing $runtime_type runtime..."
            
            # Runtime-only install
            if test $is_posix -eq 1
                bass "bash '$script' --install-dir '$install_dir' $version_param '$version_value' --runtime '$runtime_type' --skip-non-versioned-files"
                set install_status $status
            else
                # Prefer pwsh, fallback to Windows PowerShell
                if type -q pwsh
                    pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$script" --InstallDir "$install_dir" $version_param "$version_value" --Runtime "$runtime_type" --SkipNonVersionedFiles
                else if type -q powershell.exe
                    powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$script" --InstallDir "$install_dir" $version_param "$version_value" --Runtime "$runtime_type" --SkipNonVersionedFiles
                else
                    echo "dotty: neither pwsh nor powershell.exe found" >&2
                    set install_status 1
                end
                test $install_status -eq 0; or set install_status $status
            end
        else
            # SDK install
            if test $is_posix -eq 1
                bass "bash '$script' --install-dir '$install_dir' $version_param '$version_value' --skip-non-versioned-files"
                set install_status $status
            else
                if type -q pwsh
                    pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$script" --InstallDir "$install_dir" $version_param "$version_value" --SkipNonVersionedFiles
                else if type -q powershell.exe
                    powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$script" --InstallDir "$install_dir" $version_param "$version_value" --SkipNonVersionedFiles
                else
                    echo "dotty: neither pwsh nor powershell.exe found" >&2
                    set install_status 1
                end
                test $install_status -eq 0; or set install_status $status
            end
        end

        # No cleanup needed - script is cached for reuse

        if test $install_status -ne 0
            echo "dotty: installation failed" >&2
            return $install_status
        end
    end

    # ---- Activate this install in current shell ----------------------------
    # Backup only on first activation
    if not set -q __dotty_active
        set -g __dotty_prev_path $PATH
        if set -q DOTNET_ROOT
            set -g __dotty_prev_dotnet_root $DOTNET_ROOT
        else
            set -g __dotty_prev_dotnet_root ""
        end
    end

    set -gx DOTNET_ROOT "$install_dir"

    # Prepend to PATH if not already first
    if test "$PATH[1]" != "$install_dir"
        set -gx PATH "$install_dir" $PATH
    end

    set -gx __dotty_install_dir "$install_dir"
    set -gx __dotty_active 1

    # Show result
    if test -x "$install_dir/dotnet"
        echo "dotty: activated DOTNET_ROOT=$DOTNET_ROOT"
        "$install_dir/dotnet" --info | head -n 5
    else
        echo "dotty: warning: dotnet binary not found in $install_dir/bin" >&2
    end

    # Define deactivation helper if missing in this session
    if not functions -q dotty-deactivate
        functions -e deactivate 2>/dev/null >/dev/null
        function dotty-deactivate --description "Deactivate .NET installed by dotty in this shell"
            if not set -q __dotty_active
                echo "dotty: nothing to deactivate"
                return 0
            end

            # Restore PATH and DOTNET_ROOT from backups
            if set -q __dotty_prev_path
                set -gx PATH $__dotty_prev_path
            else
                # Fallback: remove the install dir from PATH if present
                set -l newpath
                for p in $PATH
                    if test "$p" != "$__dotty_install_dir"
                        set newpath $newpath $p
                    end
                end
                set -gx PATH $newpath
            end

            if test -n "$__dotty_prev_dotnet_root"
                set -gx DOTNET_ROOT "$__dotty_prev_dotnet_root"
            else
                set -e DOTNET_ROOT
            end

            # Unset dotty state
            set -e __dotty_prev_path
            set -e __dotty_prev_dotnet_root
            set -e __dotty_install_dir
            set -e __dotty_active

            echo "dotty: deactivated"
        end

        # Provide a convenient `deactivate` shim if that name isn't already in use
        if not functions -q deactivate
            function deactivate --description "Alias: dotty-deactivate"
                dotty-deactivate
            end
        end
    end
end