# dkde-term's shell integration for zsh (see .zshrc here): zsh found this
# folder through ZDOTDIR; read the user's own .zshenv as zsh would have.
() {
    local dir=${DKDE_USER_ZDOTDIR:-$HOME}
    [[ -f $dir/.zshenv ]] && ZDOTDIR=$dir source $dir/.zshenv
}
