if not functions -q fisher
    curl -sL https://raw.githubusercontent.com/jorgebucaran/fisher/HEAD/functions/fisher.fish | source
    and fisher update
end
