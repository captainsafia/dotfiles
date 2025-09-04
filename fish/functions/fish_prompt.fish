function fish_prompt --description "Percent-only prompt with changing color"
    set colors red green yellow blue magenta cyan \
               brred brgreen bryellow brblue brmagenta brcyan \
               white brwhite black brblack

    # Pick a random color from the list
    set color $colors[(math (random) % (count $colors) + 1)]

    set_color $color
    printf "%% "
    set_color normal
end