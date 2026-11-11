# dkde-term's shell integration for zsh. dkde-term points ZDOTDIR here; this
# puts the user's ZDOTDIR back, reads their .zshrc, then:
#  - marks where each prompt and command starts and ends (OSC 133), so
#    Ctrl+Shift+Up/Down jump between prompts;
#  - tells the terminal the current folder (OSC 7);
#  - when a command ran for 10 seconds or more, asks for a desktop
#    notification (OSC 777), shown only if you are looking elsewhere.
# Turn it off with shell-integration = false in the profile (term.toml).

if [[ -n $DKDE_USER_ZDOTDIR ]]; then
    ZDOTDIR=$DKDE_USER_ZDOTDIR
else
    unset ZDOTDIR
fi
unset DKDE_USER_ZDOTDIR
[[ -f ${ZDOTDIR:-$HOME}/.zshrc ]] && source ${ZDOTDIR:-$HOME}/.zshrc

if [[ -o interactive && -z $__dkde_integrated ]]; then
    __dkde_integrated=1
    autoload -Uz add-zsh-hook

    __dkde_preexec() {
        __dkde_t0=$SECONDS
        __dkde_cmd=${1//[$'\a\e']/}
        print -n '\e]133;C\a'
    }

    __dkde_precmd() {
        local st=$?
        if [[ -n $__dkde_t0 ]]; then
            print -n "\e]133;D;$st\a"
            local took=$(( SECONDS - __dkde_t0 ))
            (( took >= 10 )) && print -n "\e]777;notify;Command finished;$__dkde_cmd (${took}s, exit $st)\a"
            unset __dkde_t0
        fi
        local LC_ALL=C pwd_url=${PWD//\%/%25}
        pwd_url=${pwd_url// /%20}
        print -n "\e]7;file://$HOST$pwd_url\a"
        if [[ $PS1 != *'133;A'* ]]; then
            PS1=$'%{\e]133;A\a%}'$PS1$'%{\e]133;B\a%}'
        fi
    }

    add-zsh-hook preexec __dkde_preexec
    add-zsh-hook precmd __dkde_precmd
fi
