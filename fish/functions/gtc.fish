# gtc — Add a worktree that tracks a remote branch or a GitHub PR
# Usage:
#   gtc <path> <remote-branch> [local-branch] [--remote <name>]
#   gtc <path> --pr <number>   [local-branch] [--remote <name>]
# Examples:
#   gtc ../wt-feature feature/cool
#   gtc ../wt-pr123 --pr 123
#   gtc ../wt-pr123 --pr 123 my-branch-name --remote origin

function gtc --description "Create a git worktree from a remote branch or PR"
    # Configuration
    set -l DEFAULT_REMOTE "origin"
    set -l FETCH_TIMEOUT 30
    set -l DEFAULT_PR_PREFIX "pr-"
    
    argparse -n gtc 'h/help' 'r/remote=' 'p/pr=' 'n/dry-run' -- $argv
    or return 2

    if set -q _flag_help
        echo "Usage:"
        echo "  gtc <path> <remote-branch> [local-branch] [--remote <name>]"
        echo "  gtc <path> --pr <number>   [local-branch] [--remote <name>]"
        echo "  gtc <path> <pr-url-or-number> [local-branch] [--remote <name>]"
        echo ""
        echo "Options:"
        echo "  -r, --remote NAME    Remote name (default: $DEFAULT_REMOTE)"
        echo "  -p, --pr NUMBER      Explicitly treat as PR number"
        echo "  -n, --dry-run        Show what would be done without doing it"
        echo "  -h, --help           Show this help"
        return 0
    end

    # Validation and utility functions
    function __gtc_validate_environment
        # Ensure we are inside a git repo
        git rev-parse --git-dir >/dev/null 2>&1
        or begin
            echo "gtc: not inside a git repository" >&2
            return 1
        end
        
        # Check if we're in a bare repository
        set -l is_bare (git rev-parse --is-bare-repository 2>/dev/null)
        if test "$is_bare" = "true"
            echo "gtc: [DEBUG] Working with bare repository" >&2
        else
            echo "gtc: [DEBUG] Working with regular repository" >&2
            # Check if we're in a clean state (no ongoing merge/rebase/etc) - only for non-bare repos
            if test -f .git/MERGE_HEAD
                echo "gtc: repository has unfinished merge - resolve before creating worktree" >&2
                return 1
            end
            if test -f .git/rebase-apply/applying
                echo "gtc: repository has unfinished rebase - resolve before creating worktree" >&2
                return 1
            end
        end
        
        return 0
    end
    
    function __gtc_validate_path
        set -l path $argv[1]
        
        # Check if path already exists
        if test -e "$path"
            echo "gtc: path '$path' already exists" >&2
            return 1
        end
        
        # Check if parent directory exists and is writable
        set -l parent (dirname "$path")
        if not test -d "$parent"
            echo "gtc: parent directory '$parent' does not exist" >&2
            return 1
        end
        if not test -w "$parent"
            echo "gtc: parent directory '$parent' is not writable" >&2
            return 1
        end
        
        # Check if path would conflict with existing worktrees
        set -l existing_worktrees (git worktree list --porcelain | grep '^worktree ' | cut -d' ' -f2-)
        for wt in $existing_worktrees
            if test "$path" = "$wt"
                echo "gtc: worktree already exists at '$path'" >&2
                return 1
            end
        end
        
        return 0
    end
    
    function __gtc_detect_pr_number
        set -l input $argv[1]
        
        # Direct number
        if string match -r '^\d+$' -- $input >/dev/null
            echo $input
            return 0
        end
        
        # GitHub PR URL patterns
        if string match -r 'github\.com/[^/]+/[^/]+/pull/(\d+)' -- $input >/dev/null
            string replace -r '.*github\.com/[^/]+/[^/]+/pull/(\d+).*' '$1' -- $input
            return 0
        end
        
        return 1
    end
    
    function __gtc_cleanup_on_failure
        set -l worktree_path $argv[1]
        set -l remote_added $argv[2]
        
        if test -d "$worktree_path"
            echo "gtc: cleaning up failed worktree at '$worktree_path'" >&2
            git worktree remove "$worktree_path" --force 2>/dev/null
        end
        
        if test -n "$remote_added"
            echo "gtc: removing added remote '$remote_added'" >&2
            git remote remove "$remote_added" 2>/dev/null
        end
    end

    # Ensure we are inside a git repo and in a clean state
    __gtc_validate_environment
    or return $status

    # Require at least the worktree path
    if test (count $argv) -lt 1
        echo "Usage: gtc <path> <remote-branch>|--pr <number> [local-branch] [--remote <name>]" >&2
        return 1
    end

    set -l worktree_path $argv[1]
    set -l remote (set -q _flag_remote; and echo $_flag_remote; or echo $DEFAULT_REMOTE)

    # Validate the worktree path
    __gtc_validate_path "$worktree_path"
    or return $status

    if set -q _flag_dry_run
        echo "gtc: [DRY RUN] would create worktree at '$worktree_path'"
    end

    # Determine URL protocol style from origin (for adding fork remotes)
    set -l origin_url (git remote get-url origin 2>/dev/null)
    set -l use_ssh 0
    if string match -q 'git@github.com:*' -- $origin_url
        set use_ssh 1
    end

    # Helpers
    function __gtc_branch_exists --argument-names name
        git show-ref --verify --quiet "refs/heads/$name"
    end

    function __gtc_add_worktree --argument-names path local_branch upstream_ref
        if set -q _flag_dry_run
            echo "gtc: [DRY RUN] would create worktree:"
            echo "  Path: $path"
            echo "  Local branch: $local_branch"
            echo "  Upstream: $upstream_ref"
            return 0
        end
        
        echo "gtc: [DEBUG] Creating worktree at '$path' with branch '$local_branch'" >&2
        
        # Check if we're in a bare repository
        set -l is_bare (git rev-parse --is-bare-repository 2>/dev/null)
        
        if test "$is_bare" = "true"
            echo "gtc: [DEBUG] Bare repository: creating worktree directly from remote ref" >&2
            # In bare repos, create worktree directly from the remote reference
            git worktree add -b "$local_branch" "$path" "$upstream_ref"
            or begin
                __gtc_cleanup_on_failure "$path" ""
                return $status
            end
        else
            # Regular repository logic
            # If local branch exists, reuse it; else create it
            if __gtc_branch_exists $local_branch
                echo "gtc: [DEBUG] Local branch '$local_branch' exists, reusing it" >&2
                git worktree add "$path" "$local_branch"
                or begin
                    __gtc_cleanup_on_failure "$path" ""
                    return $status
                end
            else
                echo "gtc: [DEBUG] Creating new local branch '$local_branch'" >&2
                # Create worktree with new branch, but don't try to track yet
                git worktree add -b "$local_branch" "$path" "$upstream_ref"
                or begin
                    __gtc_cleanup_on_failure "$path" ""
                    return $status
                end
            end
        end
        
        # Set up tracking after worktree creation (works for both bare and non-bare)
        echo "gtc: [DEBUG] Setting up tracking: $local_branch -> $upstream_ref" >&2
        git -C "$path" branch --set-upstream-to="$upstream_ref" "$local_branch" 2>/dev/null
        or echo "gtc: [DEBUG] Warning: could not set up tracking (this may be normal for some remotes)" >&2
        
        return 0
    end

    # Auto-detect PR vs branch mode
    set -l pr_number ""
    set -l is_pr_mode 0
    
    # Check if --pr flag is explicitly set
    if set -q _flag_pr
        set pr_number $_flag_pr
        set is_pr_mode 1
    else if test (count $argv) -ge 2
        # Try to detect if second argument is a PR number or URL
        set pr_number (__gtc_detect_pr_number $argv[2])
        if test $status -eq 0
            set is_pr_mode 1
        end
    end

    # PR mode
    if test $is_pr_mode -eq 1
        if test -z "$pr_number"
            echo "gtc: --pr requires a number" >&2
            return 2
        end

        # Optional local branch name (use as-is)
        set -l local_branch
        if test (count $argv) -ge 3
            set local_branch $argv[3]
        else
            set local_branch "$DEFAULT_PR_PREFIX$pr_number"
        end

        echo "gtc: [DEBUG] Local branch name: '$local_branch'" >&2

        if not set -q _flag_dry_run
            type -q gh
            or begin
                echo "gtc: gh CLI not found (install from https://cli.github.com/)" >&2
                return 127
            end
            
            # Check if we're in a GitHub repository
            echo "gtc: [DEBUG] Checking repository context..." >&2
            set -l repo_info (gh repo view --json nameWithOwner --template '{{.nameWithOwner}}' 2>&1)
            set -l repo_status $status
            echo "gtc: [DEBUG] Current repository: $repo_info (status: $repo_status)" >&2
            
            if test $repo_status -ne 0
                echo "gtc: not in a GitHub repository or gh not authenticated" >&2
                echo "gtc: gh error: $repo_info" >&2
                return 1
            end
        end

        if set -q _flag_dry_run
            echo "gtc: [DRY RUN] would fetch PR #$pr_number and create branch '$local_branch'"
            return 0
        end

        # Get PR head info (branch + fork owner/name)
        echo "gtc: [DEBUG] Querying PR #$pr_number with gh..." >&2
        set -l head_line (gh pr view $pr_number --json headRefName,headRepository --template '{{.headRefName}}\t{{.headRepository.owner.login}}\t{{.headRepository.name}}' 2>&1)
        set -l gh_status $status
        echo "gtc: [DEBUG] gh command status: $gh_status" >&2
        echo "gtc: [DEBUG] gh command output (raw): '$head_line'" >&2
        echo "gtc: [DEBUG] gh command output (with quotes): \"$head_line\"" >&2
        
        if test $gh_status -ne 0 -o -z "$head_line"
            echo "gtc: failed to query PR $pr_number via gh (status: $gh_status)" >&2
            if test -n "$head_line"
                echo "gtc: gh error output: $head_line" >&2
            end
            return 1
        end
        set -l parts (string split '\\t' -- $head_line)
        set -l head_branch $parts[1]
        set -l head_owner  $parts[2]
        set -l head_repo   $parts[3]

        echo "gtc: [DEBUG] Parsed head_branch: '$head_branch'" >&2
        echo "gtc: [DEBUG] Parsed head_owner: '$head_owner'" >&2
        echo "gtc: [DEBUG] Parsed head_repo: '$head_repo'" >&2

        if test -z "$head_branch"
            echo "gtc: could not resolve PR head branch" >&2
            return 1
        end

        # Handle case where PR is from the same repository (not a fork)
        set -l remote_added ""
        set -l head_remote
        if test "$head_owner" = "<no value>" -o -z "$head_owner"
            echo "gtc: [DEBUG] PR is from the same repository, auto-detecting remote" >&2
            # Auto-detect which remote has this branch
            set head_remote ""
            for r in (git remote)
                echo "gtc: [DEBUG] Checking remote '$r' for branch '$head_branch'" >&2
                if git ls-remote --heads $r $head_branch >/dev/null 2>&1
                    echo "gtc: [DEBUG] Found branch '$head_branch' on remote '$r'" >&2
                    set head_remote $r
                    break
                else
                    echo "gtc: [DEBUG] Branch '$head_branch' not found on remote '$r'" >&2
                end
            end
            
            if test -z "$head_remote"
                echo "gtc: could not find branch '$head_branch' on any remote" >&2
                return 1
            end
            echo "gtc: [DEBUG] Using remote '$head_remote' for branch '$head_branch'" >&2
        else
            echo "gtc: [DEBUG] PR is from a fork: $head_owner/$head_repo" >&2
            # Determine or create a remote for the PR head repository
            set head_remote $head_owner
            git remote get-url $head_remote >/dev/null 2>&1
            or begin
                set -l url (begin
                    if test $use_ssh -eq 1
                        printf "git@github.com:%s/%s.git" "$head_owner" "$head_repo"
                    else
                        printf "https://github.com/%s/%s.git" "$head_owner" "$head_repo"
                    end
                end)
                git remote add $head_remote $url
                or begin
                    echo "gtc: failed to add remote '$head_remote' ($url)" >&2
                    return 1
                end
                set remote_added $head_remote
            end
        end

        # Fetch the PR head branch
        echo "gtc: [DEBUG] About to fetch '$head_remote' '$head_branch'" >&2
        git fetch $head_remote "$head_branch"
        or begin
            __gtc_cleanup_on_failure "$worktree_path" "$remote_added"
            return $status
        end

        # Create the worktree
        __gtc_add_worktree "$worktree_path" "$local_branch" "$head_remote/$head_branch"
        or begin
            __gtc_cleanup_on_failure "$worktree_path" "$remote_added"
            return $status
        end

        echo "gtc: worktree created at '$worktree_path' for PR #$pr_number ($head_remote/$head_branch -> $local_branch)"
        return 0
    end

    # Remote-branch mode
    if test (count $argv) -lt 2
        echo "Usage: gtc <path> <remote-branch> [local-branch] [--remote <name>]" >&2
        return 1
    end

    set -l remote_branch $argv[2]
    
    # Auto-detect the remote if not specified
    if not set -q _flag_remote
        echo "gtc: [DEBUG] Auto-detecting remote for branch '$remote_branch'" >&2
        echo "gtc: [DEBUG] Current remote is '$remote'" >&2
        # Check which remote has this branch
        for r in (git remote)
            echo "gtc: [DEBUG] Checking remote '$r' for branch '$remote_branch'" >&2
            if git ls-remote --heads $r $remote_branch >/dev/null 2>&1
                echo "gtc: [DEBUG] Found branch '$remote_branch' on remote '$r'" >&2
                set remote $r
                break
            else
                echo "gtc: [DEBUG] Branch '$remote_branch' not found on remote '$r'" >&2
            end
        end
        echo "gtc: [DEBUG] Final remote selected: '$remote'" >&2
    else
        echo "gtc: [DEBUG] Using explicitly specified remote: '$remote'" >&2
    end
    
    # Default local branch = basename of remote branch (after last '/'), use as-is
    set -l local_branch
    if test (count $argv) -ge 3
        set local_branch $argv[3]
    else
        set local_branch (string split '/' -- $remote_branch)[-1]
    end

    if set -q _flag_dry_run
        echo "gtc: [DRY RUN] would fetch $remote/$remote_branch and create branch '$local_branch'"
        return 0
    end

    echo "gtc: [DEBUG] About to fetch $remote/$remote_branch" >&2
    # Fetch the remote branch
    git fetch $remote "$remote_branch"
    or begin
        __gtc_cleanup_on_failure "$worktree_path" ""
        return $status
    end

    # Get the correct remote reference format
    set -l upstream_ref "$remote/$remote_branch"
    echo "gtc: [DEBUG] Checking if reference '$upstream_ref' exists" >&2
    
    # Check if we're in a bare repository
    set -l is_bare (git rev-parse --is-bare-repository 2>/dev/null)
    
    if test "$is_bare" = "true"
        echo "gtc: [DEBUG] Bare repository: using remote ref directly" >&2
        # In bare repos, we can use the remote reference directly
        if git show-ref --verify --quiet "refs/remotes/$upstream_ref"
            echo "gtc: [DEBUG] Found refs/remotes/$upstream_ref" >&2
            set upstream_ref "$remote/$remote_branch"
        else
            echo "gtc: [DEBUG] Remote ref not found, will use FETCH_HEAD" >&2
            set -l commit_sha (git rev-parse FETCH_HEAD 2>/dev/null)
            if test -n "$commit_sha"
                echo "gtc: [DEBUG] Using commit SHA from FETCH_HEAD: $commit_sha" >&2
                set upstream_ref "$commit_sha"
            else
                echo "gtc: [DEBUG] Could not get commit SHA from FETCH_HEAD" >&2
                return 1
            end
        end
    else
        # Regular repository logic
        # First try the standard remotes reference
        if git show-ref --verify --quiet "refs/remotes/$upstream_ref"
            echo "gtc: [DEBUG] Found refs/remotes/$upstream_ref" >&2
            set upstream_ref "$remote/$remote_branch"
        else
            echo "gtc: [DEBUG] refs/remotes/$upstream_ref not found, checking alternatives" >&2
            # Try to get the commit SHA from FETCH_HEAD and create a proper reference
            set -l commit_sha (git rev-parse FETCH_HEAD 2>/dev/null)
            if test -n "$commit_sha"
                echo "gtc: [DEBUG] Got commit SHA from FETCH_HEAD: $commit_sha" >&2
                # Update the remote reference manually
                git update-ref "refs/remotes/$upstream_ref" "$commit_sha"
                echo "gtc: [DEBUG] Created refs/remotes/$upstream_ref pointing to $commit_sha" >&2
            else
                echo "gtc: [DEBUG] Could not get commit SHA from FETCH_HEAD" >&2
                # Last resort: use the commit SHA directly
                set upstream_ref "$commit_sha"
            end
        end
    end
    echo "gtc: [DEBUG] Using upstream reference: '$upstream_ref'" >&2

    echo "gtc: [DEBUG] About to create worktree with upstream: $upstream_ref" >&2
    # Create the worktree
    __gtc_add_worktree "$worktree_path" "$local_branch" "$upstream_ref"
    or return $status

    echo "gtc: worktree created at '$worktree_path' ($remote/$remote_branch -> $local_branch)"
end