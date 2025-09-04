function prune-worktree --description "Prune git worktrees that can be removed"
    # Parse arguments
    set -l dry_run false
    set -l verbose false
    
    for arg in $argv
        switch $arg
            case --dry-run -n
                set dry_run true
            case --verbose -v
                set verbose true
            case --help -h
                echo "Usage: prune-worktree [OPTIONS]"
                echo ""
                echo "Prune git worktrees that can be safely removed"
                echo ""
                echo "Options:"
                echo "  --dry-run, -n    Show what would be pruned without actually doing it"
                echo "  --verbose, -v    Show verbose output"
                echo "  --help, -h       Show this help message"
                return 0
            case '*'
                echo "Unknown option: $arg" >&2
                echo "Use --help for usage information" >&2
                return 1
        end
    end
    
    # Check if we're in a git repository
    if not git rev-parse --git-dir >/dev/null 2>&1
        echo "Error: Not in a git repository" >&2
        return 1
    end
    
    # Get the main branch name (try main, master, then default)
    set -l main_branch
    if git show-ref --verify --quiet refs/heads/main
        set main_branch main
    else if git show-ref --verify --quiet refs/heads/master
        set main_branch master
    else
        # Get the default branch from remote
        set main_branch (git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
        if test -z "$main_branch"
            set main_branch main  # fallback
        end
    end
    
    # Also get the remote main branch reference
    set -l remote_main_branch "origin/$main_branch"
    
    if test $verbose = true
        echo "Using '$main_branch' as the main branch"
        if git show-ref --verify --quiet "refs/remotes/$remote_main_branch"
            echo "Found remote branch '$remote_main_branch'"
        else
            echo "Remote branch '$remote_main_branch' not found, will only check local merges"
        end
    end
    
    # Fetch latest changes to ensure we have up-to-date remote refs
    if test $verbose = true
        echo "Fetching latest changes from remote..."
    end
    git fetch origin --prune --quiet 2>/dev/null
    
    # Get list of worktrees that can be pruned (missing directories)
    set -l prune_output (git worktree prune --dry-run 2>&1)
    
    # Get list of worktrees with merged branches
    set -l merged_worktrees
    set -l worktree_list (git worktree list --porcelain)
    set -l current_worktree_path ""
    set -l current_branch ""
    
    # Get list of branches merged to local main
    set -l merged_to_local_main
    if git show-ref --verify --quiet "refs/heads/$main_branch"
        set merged_to_local_main (git branch --merged $main_branch --format='%(refname:short)' | grep -v "^$main_branch\$")
    end
    
    # Get list of branches merged to remote main (after fetch)
    set -l merged_to_remote_main
    if git show-ref --verify --quiet "refs/remotes/$remote_main_branch"
        set merged_to_remote_main (git branch --merged $remote_main_branch --format='%(refname:short)' | grep -v "^$main_branch\$")
    end
    
    # Get list of all local branches to check against remote main individually
    set -l all_local_branches (git branch --format='%(refname:short)' | grep -v "^$main_branch\$")
    set -l merged_via_remote
    
    # Check each local branch to see if it's been merged via remote commits
    if git show-ref --verify --quiet "refs/remotes/$remote_main_branch"
        for branch in $all_local_branches
            # Skip if already found in previous checks
            if not contains $branch $merged_to_local_main; and not contains $branch $merged_to_remote_main
                # Check if the branch's commits are all present in remote main
                set -l branch_commits (git rev-list $branch --not $remote_main_branch 2>/dev/null)
                if test -z "$branch_commits"
                    # All commits from this branch are in remote main
                    set merged_via_remote $merged_via_remote $branch
                else
                    # Additional check: see if branch content matches something in remote main
                    # This catches squash merges and rebased commits
                    set -l branch_tree (git rev-parse "$branch^{tree}" 2>/dev/null)
                    if test -n "$branch_tree"
                        # Look for commits in remote main with the same tree (content)
                        set -l matching_commits (git log $remote_main_branch --format="%H %T" --since="3 months ago" | grep "$branch_tree" | head -1)
                        if test -n "$matching_commits"
                            set merged_via_remote $merged_via_remote $branch
                        end
                    end
                end
            end
        end
    end
    
    # Get list of branches merged to integration branches
    set -l merged_to_integration
    for integration_branch in develop development staging
        if git show-ref --verify --quiet "refs/heads/$integration_branch"
            set -l merged_branches (git branch --merged $integration_branch --format='%(refname:short)' | grep -v "^$main_branch\$" | grep -v "^$integration_branch\$")
            set merged_to_integration $merged_to_integration $merged_branches
        end
        
        if git show-ref --verify --quiet "refs/remotes/origin/$integration_branch"
            set -l merged_branches (git branch --merged "origin/$integration_branch" --format='%(refname:short)' | grep -v "^$main_branch\$" | grep -v "^$integration_branch\$")
            set merged_to_integration $merged_to_integration $merged_branches
        end
    end
    
    # Combine all merged branches and remove duplicates
    set -l all_merged_branches $merged_to_local_main $merged_to_remote_main $merged_via_remote $merged_to_integration
    set all_merged_branches (printf '%s\n' $all_merged_branches | sort -u)
    
    if test $verbose = true -a (count $all_merged_branches) -gt 0
        echo "Found merged branches: "(string join ", " $all_merged_branches)
        if test (count $merged_via_remote) -gt 0
            echo "Branches merged via remote (squash/rebase): "(string join ", " $merged_via_remote)
        end
    end
    
    for line in $worktree_list
        if string match -q "worktree *" $line
            set current_worktree_path (string replace "worktree " "" $line)
        else if string match -q "branch *" $line
            set current_branch (string replace "branch refs/heads/" "" $line)
            
            # Skip if this is the main branch or current branch
            if test "$current_branch" != "$main_branch" -a "$current_branch" != (git branch --show-current)
                set -l merge_reason ""
                
                # Check if this branch is in our list of merged branches
                if contains $current_branch $all_merged_branches
                    # Determine why it's merged for better reporting
                    if contains $current_branch $merged_to_local_main
                        set merge_reason "merged to local $main_branch"
                    else if contains $current_branch $merged_to_remote_main
                        set merge_reason "merged to remote $remote_main_branch"
                    else if contains $current_branch $merged_via_remote
                        set merge_reason "merged to remote $remote_main_branch (squash/rebase)"
                    else if contains $current_branch $merged_to_integration
                        # Find which integration branch it was merged to
                        for integration_branch in develop development staging
                            if git show-ref --verify --quiet "refs/heads/$integration_branch"
                                set -l integration_merged (git branch --merged $integration_branch --format='%(refname:short)')
                                if contains $current_branch $integration_merged
                                    set merge_reason "merged to $integration_branch"
                                    break
                                end
                            end
                            
                            if git show-ref --verify --quiet "refs/remotes/origin/$integration_branch"
                                set -l integration_merged (git branch --merged "origin/$integration_branch" --format='%(refname:short)')
                                if contains $current_branch $integration_merged
                                    set merge_reason "merged to remote origin/$integration_branch"
                                    break
                                end
                            end
                        end
                    end
                    
                    # If we still don't have a reason, provide a generic one
                    if test -z "$merge_reason"
                        set merge_reason "merged"
                    end
                    
                    set merged_worktrees $merged_worktrees "$current_worktree_path (branch: $current_branch - $merge_reason)"
                else
                    # Additional check for branches that might have been deleted remotely after merging
                    set -l remote_branch_exists (git show-ref --verify --quiet "refs/remotes/origin/$current_branch"; echo $status)
                    if test $remote_branch_exists -ne 0
                        # Remote branch doesn't exist, check if local branch is fully contained in remote main
                        if git show-ref --verify --quiet "refs/remotes/$remote_main_branch"
                            if git merge-base --is-ancestor $current_branch $remote_main_branch 2>/dev/null
                                set -l merge_base (git merge-base $current_branch $remote_main_branch)
                                set -l branch_commit (git rev-parse $current_branch)
                                if test "$merge_base" = "$branch_commit"
                                    set merged_worktrees $merged_worktrees "$current_worktree_path (branch: $current_branch - merged to remote $remote_main_branch, remote branch deleted)"
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    
    # Combine all items to be pruned
    set -l all_prune_items
    if test -n "$prune_output"
        set all_prune_items $all_prune_items $prune_output
    end
    if test (count $merged_worktrees) -gt 0
        set all_prune_items $all_prune_items $merged_worktrees
    end
    
    if test (count $all_prune_items) -eq 0
        if test $verbose = true
            echo "No worktrees need pruning"
        end
        return 0
    end
    
    # Show what will be pruned
    if test $dry_run = true
        echo "The following worktrees would be pruned:"
        if test -n "$prune_output"
            echo "Stale worktrees (missing directories):"
            echo "$prune_output"
        end
        if test (count $merged_worktrees) -gt 0
            echo "Worktrees with merged branches:"
            for worktree in $merged_worktrees
                echo "  $worktree"
            end
        end
        return 0
    end
    
    # Show what's being pruned if verbose
    if test $verbose = true
        echo "Pruning the following worktrees:"
        if test -n "$prune_output"
            echo "Stale worktrees (missing directories):"
            echo "$prune_output"
        end
        if test (count $merged_worktrees) -gt 0
            echo "Worktrees with merged branches:"
            for worktree in $merged_worktrees
                echo "  $worktree"
            end
        end
    end
    
    set -l success true
    
    # First prune the standard stale worktrees
    if test -n "$prune_output"
        if not git worktree prune
            echo "Error: Failed to prune stale worktrees" >&2
            set success false
        end
    end
    
    # Then remove worktrees with merged branches
    if test (count $merged_worktrees) -gt 0
        for worktree_info in $merged_worktrees
            # Extract the path (everything before " (branch:")
            set -l worktree_path (string split " (branch:" $worktree_info)[1]
            if test -d "$worktree_path"
                if not git worktree remove "$worktree_path" --force
                    echo "Error: Failed to remove worktree: $worktree_path" >&2
                    set success false
                else if test $verbose = true
                    # Extract just the branch name and reason for verbose output
                    set -l branch_info (string split " (branch:" $worktree_info)[2]
                    set -l branch_name (string split " - " $branch_info)[1]
                    echo "Removed worktree: $worktree_path (branch: $branch_name)"
                end
            end
        end
    end
    
    if test $success = true -a $verbose = true
        echo "Successfully pruned worktrees"
    else if test $success = false
        return 1
    end
end