function fish_title \
    --description "Set title to current working directory" \
    --argument-names last_command

    # Configurable: how many characters to keep for each parent directory.
    # 0 = no shortening, default = 1 (Fish's usual behavior).
    set -l maxlen 1
    if set -q FISH_TITLE_DIR_LENGTH
        set maxlen $FISH_TITLE_DIR_LENGTH
    end

    # Produce a shortened path (respects ~ for $HOME)
    set -l current_folder (fish_prompt_pwd_dir_length=$maxlen prompt_pwd)

    echo $current_folder
end