# Bootstrap Fisher + Pure once for new Monolith users.

set -l marker "$HOME/.config/fish/.monolith-fisher-bootstrapped"

if not test -f "$marker"
    if type -q curl
        curl -sL https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish | source

        fisher install jorgebucaran/fisher
        fisher install pure-fish/pure

        touch "$marker"
    end
end
