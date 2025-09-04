function castgif --description "Record a command with asciinema and convert the cast to a GIF"
    argparse -n castgif 'h/help' -- $argv
    or return 2

    if set -q _flag_help
        echo "Usage: castgif [OPTIONS] <command> [output_name]"
        echo ""
        echo "Record a command with asciinema and convert the cast to a GIF"
        echo ""
        echo "Arguments:"
        echo "  <command>      The command to record (must be quoted if it contains spaces)"
        echo "  [output_name]  Optional name for the output file (default: timestamp)"
        echo ""
        echo "Options:"
        echo "  -h, --help     Show this help message"
        echo ""
        echo "Examples:"
        echo "  castgif \"ls -la\""
        echo "  castgif \"git status\" my_demo"
        echo "  castgif \"npm test\" test_output"
        echo ""
        echo "Dependencies:"
        echo "  - asciinema: Terminal session recorder"
        echo "  - agg: Asciinema GIF Generator"
        echo ""
        echo "Output:"
        echo "  GIF files are saved to: ~/Pictures/Screenshots/terminal/"
        return 0
    end

    set -l cmd  $argv[1]
    set -l name $argv[2]

    if test -z "$cmd"
        echo "castgif: error: missing command to record" >&2
        echo "Usage: castgif <command> [output_name]" >&2
        echo "Try 'castgif --help' for more information." >&2
        return 1
    end

    # Dependencies
    for bin in asciinema agg
        if not command -v $bin >/dev/null 2>&1
            echo "castgif: missing dependency: $bin"
            echo "castgif: please install $bin and ensure it's in your PATH"
            return 127
        end
    end

    # Default name is a timestamp
    if test -z "$name"
        set name (date "+%Y%m%d_%H%M%S")
    end

    set -l out_dir "$HOME/Pictures/Screenshots/terminal"
    mkdir -p "$out_dir"
    if test $status -ne 0
        echo "castgif: could not create output directory $out_dir"
        return 1
    end

    # Check available disk space (require at least 100MB free)
    set -l available_space (df -m "$out_dir" | tail -1 | awk '{print $4}')
    if test "$available_space" -lt 100
        echo "castgif: insufficient disk space in $out_dir (need at least 100MB)"
        return 1
    end

    # Temporary directory for the cast
    set -l tmp_dir (mktemp -d)
    if test $status -ne 0 -o -z "$tmp_dir"
        echo "castgif: failed to create temporary directory"
        return 1
    end

    # Check available space in temp directory too
    set -l tmp_available_space (df -m "$tmp_dir" | tail -1 | awk '{print $4}')
    if test "$tmp_available_space" -lt 50
        echo "castgif: insufficient disk space in temporary directory (need at least 50MB)"
        rm -rf "$tmp_dir"
        return 1
    end

    # Setup cleanup function and trap for interruptions
    function cleanup_castgif
        if test -n "$tmp_dir" -a -d "$tmp_dir"
            rm -rf "$tmp_dir"
        end
    end

    # Setup signal handlers for cleanup
    trap cleanup_castgif INT TERM

    set -l cast_file "$tmp_dir/$name.cast"
    set -l gif_file  "$out_dir/$name.gif"

    echo "Recording with asciinema..."
    # --quiet suppresses prompts; -c runs the provided command
    asciinema rec --quiet -c "$cmd" "$cast_file"
    if test $status -ne 0
        echo "castgif: asciinema recording failed"
        cleanup_castgif
        return 1
    end

    echo "Converting cast to GIF..."
    # agg: Asciinema GIF Generator (https://github.com/asciinema/agg)
    agg "$cast_file" "$gif_file" --renderer fontdue
    if test $status -ne 0
        echo "castgif: agg conversion failed"
        cleanup_castgif
        return 1
    end

    echo "GIF saved to: $gif_file"
    cleanup_castgif
end