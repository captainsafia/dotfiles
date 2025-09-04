#!/usr/bin/env fish

function cleanup-rgs --description "Remove Azure resource groups from a subscription"
    # Check if Azure CLI is installed
    if not command -q az
        echo "❌ Azure CLI is not installed. Please install it first."
        return 1
    end

    # Check if user is logged in
    if not az account show >/dev/null 2>&1
        echo "❌ Not logged into Azure CLI. Please run 'az login' first."
        return 1
    end

    echo "🔍 Fetching Azure subscriptions..."
    
    # Get all subscriptions
    set -l subs_json (az account list --output json 2>/dev/null)
    if test $status -ne 0
        echo "❌ Failed to fetch subscriptions."
        return 1
    end
    
    # Parse subscription data
    set -l sub_names (echo $subs_json | jq -r '.[] | "\(.name) (\(.id))"')
    set -l sub_ids (echo $subs_json | jq -r '.[].id')
    
    if test (count $sub_names) -eq 0
        echo "❌ No subscriptions found."
        return 1
    end
    
    # Add cancel option
    set -a sub_names "Cancel"
    
    # Let user select subscription
    echo
    echo "Select an Azure subscription:"
    for i in (seq (count $sub_names))
        echo "  $i) $sub_names[$i]"
    end
    
    echo -n "Enter selection [1-"(count $sub_names)"]: "
    read -l selection
    
    # Validate selection
    if not string match -qr '^\d+$' $selection
        echo "❌ Invalid selection."
        return 1
    end
    
    if test $selection -lt 1 -o $selection -gt (count $sub_names)
        echo "❌ Selection out of range."
        return 1
    end
    
    # Check if user cancelled
    if test $selection -eq (count $sub_names)
        echo "❌ Aborted by user."
        return 0
    end
    
    set -l selected_sub_id $sub_ids[$selection]
    set -l selected_sub_name (echo $sub_names[$selection] | sed 's/ (.*//')
    
    echo "🔍 Scanning subscription $selected_sub_name..."
    
    # Set the subscription context
    az account set --subscription $selected_sub_id >/dev/null 2>&1
    if test $status -ne 0
        echo "❌ Failed to set subscription context."
        return 1
    end
    
    # Get all resource groups
    set -l rgs_json (az group list --output json 2>/dev/null)
    if test $status -ne 0
        echo "❌ Failed to fetch resource groups."
        return 1
    end
    
    set -l rg_names (echo $rgs_json | jq -r '.[].name' | sort -f)
    
    if test (count $rg_names) -eq 0
        echo "✔ No resource groups found."
        return 0
    end
    
    echo
    echo "Select resource groups to delete ("(count $rg_names)" found):"
    echo "(Enter space-separated numbers, or 'all' for all, or 'cancel' to abort)"
    
    for i in (seq (count $rg_names))
        echo "  $i) $rg_names[$i]"
    end
    
    echo -n "Enter selection: "
    read -l rg_selection
    
    # Handle special cases
    if test "$rg_selection" = "cancel"
        echo "❌ Aborted by user."
        return 0
    end
    
    set -l selected_rg_names
    
    if string match -q "all" "$rg_selection"
        set selected_rg_names $rg_names
    else
        # Parse space-separated numbers
        for num in (string split ' ' $rg_selection)
            if string match -qr '^\d+$' $num
                if test $num -ge 1 -a $num -le (count $rg_names)
                    set -a selected_rg_names $rg_names[$num]
                else
                    echo "❌ Number $num is out of range."
                    return 1
                end
            else
                echo "❌ Invalid selection: $num"
                return 1
            end
        end
    end
    
    if test (count $selected_rg_names) -eq 0
        echo "❌ Aborted – nothing selected."
        return 0
    end
    
    # Display selected resource groups
    echo
    echo "Selected resource groups:"
    for rg in $selected_rg_names
        echo "  • $rg"
    end
    
    # Confirmation
    echo
    set -l rg_count (count $selected_rg_names)
    echo -n "Delete $rg_count resource group(s) shown above? [y/N]: "
    read -l confirm
    
    if not string match -qi 'y*' $confirm
        echo "❌ Aborted – nothing deleted."
        return 0
    end
    
    # Delete resource groups
    echo
    echo "🗑  Deleting resource groups..."
    
    set -l success_count 0
    set -l failed_rgs
    
    for rg in $selected_rg_names
        echo -n "  Deleting $rg... "
        
        # Delete resource group (no-wait for faster execution)
        if az group delete --name $rg --yes --no-wait >/dev/null 2>&1
            echo "✓ deletion started"
            set success_count (math $success_count + 1)
        else
            echo "✗ failed"
            set -a failed_rgs $rg
        end
    end
    
    echo
    if test $success_count -gt 0
        echo "✅ Initiated deletion of $success_count resource group(s)."
        echo "Note: Deletions are running asynchronously. Use 'az group list' to check status."
        echo
        echo "Deleted resource groups:"
        for rg in $selected_rg_names
            if not contains $rg $failed_rgs
                echo "  • $rg"
            end
        end
    end
    
    if test (count $failed_rgs) -gt 0
        echo
        echo "❌ Failed to delete:"
        for rg in $failed_rgs
            echo "  • $rg"
        end
        return 1
    end
    
    echo
    echo "✅ Cleanup completed."
end
