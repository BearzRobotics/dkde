# dkde-term's shell integration for bash, read instead of ~/.bashrc (bash
# --rcfile). It reads the usual startup files first, then:
#  - marks where each prompt and command starts and ends (OSC 133), so
#    Ctrl+Shift+Up/Down jump between prompts;
#  - tells the terminal the current folder (OSC 7), for new tabs and splits;
#  - when a command ran for 10 seconds or more, asks for a desktop
#    notification (OSC 777), which dkde-term shows only if you are looking
#    at another window or tab.
# Turn it off with shell-integration = false in the profile (term.toml).

[ -f /etc/bash.bashrc ] && . /etc/bash.bashrc
[ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc"

# Only once, and only in an interactive shell.
if [[ $- == *i* && -z $__dkde_integrated ]]; then
    __dkde_integrated=1

    __dkde_urlencode() {
        local LC_ALL=C s=$1 out= c i
        for ((i = 0; i < ${#s}; i++)); do
            c=${s:i:1}
            case $c in
                [a-zA-Z0-9/._~-]) out+=$c ;;
                *) printf -v c '%%%02X' "'$c"; out+=$c ;;
            esac
        done
        printf '%s' "$out"
    }

    __dkde_prompt() {
        local status=$?
        if [[ -n $__dkde_t0 ]]; then
            printf '\e]133;D;%s\a' "$status"
            local took=$((SECONDS - __dkde_t0))
            if ((took >= 10)); then
                local cmd
                cmd=$(HISTTIMEFORMAT= builtin history 1)
                cmd=${cmd#*[0-9]  }
                printf '\e]777;notify;Command finished;%s (%ss, exit %s)\a' "${cmd//[$'\a\e']/}" "$took" "$status"
            fi
            unset __dkde_t0
        fi
        printf '\e]7;file://%s%s\a' "$HOSTNAME" "$(__dkde_urlencode "$PWD")"
        # Prompt marks around whatever prompt the user's setup made.
        if [[ $PS1 != *'133;A'* ]]; then
            PS1='\[\e]133;A\a\]'"$PS1"'\[\e]133;B\a\]'
        fi
        return $status
    }

    # PS0 is expanded just before a command runs; the arithmetic records the
    # start time in this shell (a command substitution would run elsewhere).
    PS0='${__dkde_unused:$((__dkde_t0 = SECONDS)):0}\e]133;C\a'"$PS0"
    if [[ $(declare -p PROMPT_COMMAND 2>/dev/null) == "declare -a"* ]]; then
        PROMPT_COMMAND=(__dkde_prompt "${PROMPT_COMMAND[@]}")
    else
        PROMPT_COMMAND="__dkde_prompt${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
    fi
fi
