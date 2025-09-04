function bisect-tests
    # Check if test DLL argument is provided
    if test (count $argv) -eq 0
        echo "Usage: bisect-tests <test-dll-path>"
        echo "Example: bisect-tests MyTests.dll"
        return 1
    end

    set test_dll $argv[1]
    
    # Verify the test DLL exists
    if not test -f $test_dll
        echo "Error: Test DLL '$test_dll' not found"
        return 1
    end

    echo "Starting test bisection for: $test_dll"
    
    # Generate list of all test cases
    echo "Discovering test cases..."
    set temp_dir (mktemp -d)
    set all_tests_file "$temp_dir/all_tests.txt"
    
    # Use dotnet test with list-tests to get all test cases
    if not dotnet test $test_dll --list-tests --verbosity quiet | grep -E "^\s+" | sed 's/^\s*//' > $all_tests_file
        echo "Error: Failed to discover test cases from $test_dll"
        rm -rf $temp_dir
        return 1
    end
    
    set total_tests (wc -l < $all_tests_file)
    echo "Found $total_tests test cases"
    
    if test $total_tests -eq 0
        echo "No test cases found in the DLL"
        rm -rf $temp_dir
        return 1
    end
    
    # Start bisection process
    set current_tests_file "$temp_dir/current_tests.txt"
    cp $all_tests_file $current_tests_file
    
    set iteration 1
    set problematic_tests_file "$temp_dir/problematic_tests.txt"
    
    while test (wc -l < $current_tests_file) -gt 1
        set current_count (wc -l < $current_tests_file)
        echo ""
        echo "=== Iteration $iteration: Testing $current_count test cases ==="
        
        # Split current tests in half
        set half_count (math "ceil($current_count / 2)")
        set first_half_file "$temp_dir/first_half.txt"
        set second_half_file "$temp_dir/second_half.txt"
        
        head -n $half_count $current_tests_file > $first_half_file
        tail -n +(math "$half_count + 1") $current_tests_file > $second_half_file
        
        set first_half_count (wc -l < $first_half_file)
        set second_half_count (wc -l < $second_half_file)
        
        echo "Testing first half ($first_half_count tests)..."
        if _run_test_subset $test_dll $first_half_file
            echo "First half completed successfully"
            
            echo "Testing second half ($second_half_count tests)..."
            if _run_test_subset $test_dll $second_half_file
                echo "Second half also completed successfully"
                echo "Neither half caused stack overflow individually - the issue might be in the combination"
                break
            else
                echo "Stack overflow detected in second half"
                cp $second_half_file $current_tests_file
            end
        else
            echo "Stack overflow detected in first half"
            cp $first_half_file $current_tests_file
        end
        
        set iteration (math "$iteration + 1")
    end
    
    # Final result
    echo ""
    echo "=== BISECTION COMPLETE ==="
    set final_count (wc -l < $current_tests_file)
    
    if test $final_count -eq 1
        set problematic_test (cat $current_tests_file)
        echo "Found the problematic test case:"
        echo "  $problematic_test"
        
        echo ""
        echo "Verifying by running the single test..."
        if _run_test_subset $test_dll $current_tests_file
            echo "WARNING: Single test ran successfully - the issue might be related to test interaction"
        else
            echo "CONFIRMED: This test case causes a stack overflow"
        end
    else
        echo "Bisection stopped with $final_count remaining test cases:"
        cat $current_tests_file | sed 's/^/  /'
    end
    
    # Cleanup
    rm -rf $temp_dir
    
    echo ""
    echo "Bisection process completed."
end

function _run_test_subset
    set test_dll $argv[1]
    set tests_file $argv[2]
    
    # Create a filter string for dotnet test
    set filter_parts
    while read -l test_name
        if test -n "$test_name"
            set filter_parts $filter_parts "FullyQualifiedName=$test_name"
        end
    end < $tests_file
    
    if test (count $filter_parts) -eq 0
        echo "No tests to run"
        return 0
    end
    
    # Join filter parts with |
    set filter (string join "|" $filter_parts)
    
    # Run the tests and capture output
    set output_file (mktemp)
    set exit_code 0
    
    # Run dotnet test with timeout to prevent hanging on stack overflow
    # Use gtimeout if available (from coreutils), otherwise run without timeout
    if command -v gtimeout > /dev/null
        gtimeout 300 dotnet test $test_dll --filter "$filter" --verbosity normal --no-build --no-restore > $output_file 2>&1
        set exit_code $status
    else if command -v timeout > /dev/null
        timeout 300 dotnet test $test_dll --filter "$filter" --verbosity normal --no-build --no-restore > $output_file 2>&1
        set exit_code $status
    else
        # No timeout available - run without timeout but warn user
        echo "Warning: No timeout command available - tests may hang indefinitely on stack overflow"
        dotnet test $test_dll --filter "$filter" --verbosity normal --no-build --no-restore > $output_file 2>&1
        set exit_code $status
    end
    
    # Check for stack overflow indicators
    if grep -qi "stackoverflow\|stack overflow\|stackoverflowexception" $output_file
        echo "Stack overflow detected in test output"
        rm $output_file
        return 1
    end
    
    # Check if the process was killed by timeout (likely due to hang from stack overflow)
    if test $exit_code -eq 124
        echo "Tests timed out (likely due to stack overflow)"
        rm $output_file
        return 1
    end
    
    # Check if tests failed with non-zero exit code
    if test $exit_code -ne 0
        echo "Tests failed with exit code $exit_code"
        echo "Last few lines of output:"
        tail -10 $output_file
        rm $output_file
        return 1
    end
    
    rm $output_file
    return 0
end