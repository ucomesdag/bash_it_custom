# bash completion for odo                                  -*- shell-script -*-

__odo_debug()
{
    if [[ -n ${BASH_COMP_DEBUG_FILE:-} ]]; then
        echo "$*" >> "${BASH_COMP_DEBUG_FILE}"
    fi
}

# Homebrew on Macs have version 1.3 of bash-completion which doesn't include
# _init_completion. This is a very minimal version of that function.
__odo_init_completion()
{
    COMPREPLY=()
    _get_comp_words_by_ref "$@" cur prev words cword
}

__odo_index_of_word()
{
    local w word=$1
    shift
    index=0
    for w in "$@"; do
        [[ $w = "$word" ]] && return
        index=$((index+1))
    done
    index=-1
}

__odo_contains_word()
{
    local w word=$1; shift
    for w in "$@"; do
        [[ $w = "$word" ]] && return
    done
    return 1
}

__odo_handle_go_custom_completion()
{
    __odo_debug "${FUNCNAME[0]}: cur is ${cur}, words[*] is ${words[*]}, #words[@] is ${#words[@]}"

    local shellCompDirectiveError=1
    local shellCompDirectiveNoSpace=2
    local shellCompDirectiveNoFileComp=4
    local shellCompDirectiveFilterFileExt=8
    local shellCompDirectiveFilterDirs=16

    local out requestComp lastParam lastChar comp directive args

    # Prepare the command to request completions for the program.
    # Calling ${words[0]} instead of directly odo allows to handle aliases
    args=("${words[@]:1}")
    # Disable ActiveHelp which is not supported for bash completion v1
    requestComp="ODO_ACTIVE_HELP=0 ${words[0]} __completeNoDesc ${args[*]}"

    lastParam=${words[$((${#words[@]}-1))]}
    lastChar=${lastParam:$((${#lastParam}-1)):1}
    __odo_debug "${FUNCNAME[0]}: lastParam ${lastParam}, lastChar ${lastChar}"

    if [ -z "${cur}" ] && [ "${lastChar}" != "=" ]; then
        # If the last parameter is complete (there is a space following it)
        # We add an extra empty parameter so we can indicate this to the go method.
        __odo_debug "${FUNCNAME[0]}: Adding extra empty parameter"
        requestComp="${requestComp} \"\""
    fi

    __odo_debug "${FUNCNAME[0]}: calling ${requestComp}"
    # Use eval to handle any environment variables and such
    out=$(eval "${requestComp}" 2>/dev/null)

    # Extract the directive integer at the very end of the output following a colon (:)
    directive=${out##*:}
    # Remove the directive
    out=${out%:*}
    if [ "${directive}" = "${out}" ]; then
        # There is not directive specified
        directive=0
    fi
    __odo_debug "${FUNCNAME[0]}: the completion directive is: ${directive}"
    __odo_debug "${FUNCNAME[0]}: the completions are: ${out}"

    if [ $((directive & shellCompDirectiveError)) -ne 0 ]; then
        # Error code.  No completion.
        __odo_debug "${FUNCNAME[0]}: received error from custom completion go code"
        return
    else
        if [ $((directive & shellCompDirectiveNoSpace)) -ne 0 ]; then
            if [[ $(type -t compopt) = "builtin" ]]; then
                __odo_debug "${FUNCNAME[0]}: activating no space"
                compopt -o nospace
            fi
        fi
        if [ $((directive & shellCompDirectiveNoFileComp)) -ne 0 ]; then
            if [[ $(type -t compopt) = "builtin" ]]; then
                __odo_debug "${FUNCNAME[0]}: activating no file completion"
                compopt +o default
            fi
        fi
    fi

    if [ $((directive & shellCompDirectiveFilterFileExt)) -ne 0 ]; then
        # File extension filtering
        local fullFilter filter filteringCmd
        # Do not use quotes around the $out variable or else newline
        # characters will be kept.
        for filter in ${out}; do
            fullFilter+="$filter|"
        done

        filteringCmd="_filedir $fullFilter"
        __odo_debug "File filtering command: $filteringCmd"
        $filteringCmd
    elif [ $((directive & shellCompDirectiveFilterDirs)) -ne 0 ]; then
        # File completion for directories only
        local subdir
        # Use printf to strip any trailing newline
        subdir=$(printf "%s" "${out}")
        if [ -n "$subdir" ]; then
            __odo_debug "Listing directories in $subdir"
            __odo_handle_subdirs_in_dir_flag "$subdir"
        else
            __odo_debug "Listing directories in ."
            _filedir -d
        fi
    else
        while IFS='' read -r comp; do
            COMPREPLY+=("$comp")
        done < <(compgen -W "${out}" -- "$cur")
    fi
}

__odo_handle_reply()
{
    __odo_debug "${FUNCNAME[0]}"
    local comp
    case $cur in
        -*)
            if [[ $(type -t compopt) = "builtin" ]]; then
                compopt -o nospace
            fi
            local allflags
            if [ ${#must_have_one_flag[@]} -ne 0 ]; then
                allflags=("${must_have_one_flag[@]}")
            else
                allflags=("${flags[*]} ${two_word_flags[*]}")
            fi
            while IFS='' read -r comp; do
                COMPREPLY+=("$comp")
            done < <(compgen -W "${allflags[*]}" -- "$cur")
            if [[ $(type -t compopt) = "builtin" ]]; then
                [[ "${COMPREPLY[0]}" == *= ]] || compopt +o nospace
            fi

            # complete after --flag=abc
            if [[ $cur == *=* ]]; then
                if [[ $(type -t compopt) = "builtin" ]]; then
                    compopt +o nospace
                fi

                local index flag
                flag="${cur%=*}"
                __odo_index_of_word "${flag}" "${flags_with_completion[@]}"
                COMPREPLY=()
                if [[ ${index} -ge 0 ]]; then
                    PREFIX=""
                    cur="${cur#*=}"
                    ${flags_completion[${index}]}
                    if [ -n "${ZSH_VERSION:-}" ]; then
                        # zsh completion needs --flag= prefix
                        eval "COMPREPLY=( \"\${COMPREPLY[@]/#/${flag}=}\" )"
                    fi
                fi
            fi

            if [[ -z "${flag_parsing_disabled}" ]]; then
                # If flag parsing is enabled, we have completed the flags and can return.
                # If flag parsing is disabled, we may not know all (or any) of the flags, so we fallthrough
                # to possibly call handle_go_custom_completion.
                return 0;
            fi
            ;;
    esac

    # check if we are handling a flag with special work handling
    local index
    __odo_index_of_word "${prev}" "${flags_with_completion[@]}"
    if [[ ${index} -ge 0 ]]; then
        ${flags_completion[${index}]}
        return
    fi

    # we are parsing a flag and don't have a special handler, no completion
    if [[ ${cur} != "${words[cword]}" ]]; then
        return
    fi

    local completions
    completions=("${commands[@]}")
    if [[ ${#must_have_one_noun[@]} -ne 0 ]]; then
        completions+=("${must_have_one_noun[@]}")
    elif [[ -n "${has_completion_function}" ]]; then
        # if a go completion function is provided, defer to that function
        __odo_handle_go_custom_completion
    fi
    if [[ ${#must_have_one_flag[@]} -ne 0 ]]; then
        completions+=("${must_have_one_flag[@]}")
    fi
    while IFS='' read -r comp; do
        COMPREPLY+=("$comp")
    done < <(compgen -W "${completions[*]}" -- "$cur")

    if [[ ${#COMPREPLY[@]} -eq 0 && ${#noun_aliases[@]} -gt 0 && ${#must_have_one_noun[@]} -ne 0 ]]; then
        while IFS='' read -r comp; do
            COMPREPLY+=("$comp")
        done < <(compgen -W "${noun_aliases[*]}" -- "$cur")
    fi

    if [[ ${#COMPREPLY[@]} -eq 0 ]]; then
        if declare -F __odo_custom_func >/dev/null; then
            # try command name qualified custom func
            __odo_custom_func
        else
            # otherwise fall back to unqualified for compatibility
            declare -F __custom_func >/dev/null && __custom_func
        fi
    fi

    # available in bash-completion >= 2, not always present on macOS
    if declare -F __ltrim_colon_completions >/dev/null; then
        __ltrim_colon_completions "$cur"
    fi

    # If there is only 1 completion and it is a flag with an = it will be completed
    # but we don't want a space after the =
    if [[ "${#COMPREPLY[@]}" -eq "1" ]] && [[ $(type -t compopt) = "builtin" ]] && [[ "${COMPREPLY[0]}" == --*= ]]; then
       compopt -o nospace
    fi
}

# The arguments should be in the form "ext1|ext2|extn"
__odo_handle_filename_extension_flag()
{
    local ext="$1"
    _filedir "@(${ext})"
}

__odo_handle_subdirs_in_dir_flag()
{
    local dir="$1"
    pushd "${dir}" >/dev/null 2>&1 && _filedir -d && popd >/dev/null 2>&1 || return
}

__odo_handle_flag()
{
    __odo_debug "${FUNCNAME[0]}: c is $c words[c] is ${words[c]}"

    # if a command required a flag, and we found it, unset must_have_one_flag()
    local flagname=${words[c]}
    local flagvalue=""
    # if the word contained an =
    if [[ ${words[c]} == *"="* ]]; then
        flagvalue=${flagname#*=} # take in as flagvalue after the =
        flagname=${flagname%=*} # strip everything after the =
        flagname="${flagname}=" # but put the = back
    fi
    __odo_debug "${FUNCNAME[0]}: looking for ${flagname}"
    if __odo_contains_word "${flagname}" "${must_have_one_flag[@]}"; then
        must_have_one_flag=()
    fi

    # if you set a flag which only applies to this command, don't show subcommands
    if __odo_contains_word "${flagname}" "${local_nonpersistent_flags[@]}"; then
      commands=()
    fi

    # keep flag value with flagname as flaghash
    # flaghash variable is an associative array which is only supported in bash > 3.
    if [[ -z "${BASH_VERSION:-}" || "${BASH_VERSINFO[0]:-}" -gt 3 ]]; then
        if [ -n "${flagvalue}" ] ; then
            flaghash[${flagname}]=${flagvalue}
        elif [ -n "${words[ $((c+1)) ]}" ] ; then
            flaghash[${flagname}]=${words[ $((c+1)) ]}
        else
            flaghash[${flagname}]="true" # pad "true" for bool flag
        fi
    fi

    # skip the argument to a two word flag
    if [[ ${words[c]} != *"="* ]] && __odo_contains_word "${words[c]}" "${two_word_flags[@]}"; then
        __odo_debug "${FUNCNAME[0]}: found a flag ${words[c]}, skip the next argument"
        c=$((c+1))
        # if we are looking for a flags value, don't show commands
        if [[ $c -eq $cword ]]; then
            commands=()
        fi
    fi

    c=$((c+1))

}

__odo_handle_noun()
{
    __odo_debug "${FUNCNAME[0]}: c is $c words[c] is ${words[c]}"

    if __odo_contains_word "${words[c]}" "${must_have_one_noun[@]}"; then
        must_have_one_noun=()
    elif __odo_contains_word "${words[c]}" "${noun_aliases[@]}"; then
        must_have_one_noun=()
    fi

    nouns+=("${words[c]}")
    c=$((c+1))
}

__odo_handle_command()
{
    __odo_debug "${FUNCNAME[0]}: c is $c words[c] is ${words[c]}"

    local next_command
    if [[ -n ${last_command} ]]; then
        next_command="_${last_command}_${words[c]//:/__}"
    else
        if [[ $c -eq 0 ]]; then
            next_command="_odo_root_command"
        else
            next_command="_${words[c]//:/__}"
        fi
    fi
    c=$((c+1))
    __odo_debug "${FUNCNAME[0]}: looking for ${next_command}"
    declare -F "$next_command" >/dev/null && $next_command
}

__odo_handle_word()
{
    if [[ $c -ge $cword ]]; then
        __odo_handle_reply
        return
    fi
    __odo_debug "${FUNCNAME[0]}: c is $c words[c] is ${words[c]}"
    if [[ "${words[c]}" == -* ]]; then
        __odo_handle_flag
    elif __odo_contains_word "${words[c]}" "${commands[@]}"; then
        __odo_handle_command
    elif [[ $c -eq 0 ]]; then
        __odo_handle_command
    elif __odo_contains_word "${words[c]}" "${command_aliases[@]}"; then
        # aliashash variable is an associative array which is only supported in bash > 3.
        if [[ -z "${BASH_VERSION:-}" || "${BASH_VERSINFO[0]:-}" -gt 3 ]]; then
            words[c]=${aliashash[${words[c]}]}
            __odo_handle_command
        else
            __odo_handle_noun
        fi
    else
        __odo_handle_noun
    fi
    __odo_handle_word
}

_odo_add_binding()
{
    last_command="odo_add_binding"

    command_aliases=()

    commands=()

    flags=()
    two_word_flags=()
    local_nonpersistent_flags=()
    flags_with_completion=()
    flags_completion=()

    flags+=("--bind-as-files")
    local_nonpersistent_flags+=("--bind-as-files")
    flags+=("--name=")
    two_word_flags+=("--name")
    local_nonpersistent_flags+=("--name")
    local_nonpersistent_flags+=("--name=")
    flags+=("--naming-strategy=")
    two_word_flags+=("--naming-strategy")
    local_nonpersistent_flags+=("--naming-strategy")
    local_nonpersistent_flags+=("--naming-strategy=")
    flags+=("--service=")
    two_word_flags+=("--service")
    local_nonpersistent_flags+=("--service")
    local_nonpersistent_flags+=("--service=")
    flags+=("--service-namespace=")
    two_word_flags+=("--service-namespace")
    local_nonpersistent_flags+=("--service-namespace")
    local_nonpersistent_flags+=("--service-namespace=")
    flags+=("--workload=")
    two_word_flags+=("--workload")
    local_nonpersistent_flags+=("--workload")
    local_nonpersistent_flags+=("--workload=")
    flags+=("--o=")
    two_word_flags+=("--o")
    two_word_flags+=("-o")
    flags+=("--platform=")
    two_word_flags+=("--platform")
    flags+=("--v=")
    two_word_flags+=("--v")
    two_word_flags+=("-v")
    flags+=("--var=")
    two_word_flags+=("--var")
    flags+=("--var-file=")
    two_word_flags+=("--var-file")
    flags+=("--vmodule=")
    two_word_flags+=("--vmodule")

    must_have_one_flag=()
    must_have_one_noun=()
    noun_aliases=()
}

_odo_add()
{
    last_command="odo_add"

    command_aliases=()

    commands=()
    commands+=("binding")

    flags=()
    two_word_flags=()
    local_nonpersistent_flags=()
    flags_with_completion=()
    flags_completion=()

    flags+=("--o=")
    two_word_flags+=("--o")
    two_word_flags+=("-o")
    flags+=("--platform=")
    two_word_flags+=("--platform")
    flags+=("--v=")
    two_word_flags+=("--v")
    two_word_flags+=("-v")
    flags+=("--var=")
    two_word_flags+=("--var")
    flags+=("--var-file=")
    two_word_flags+=("--var-file")
    flags+=("--vmodule=")
    two_word_flags+=("--vmodule")

    must_have_one_flag=()
    must_have_one_noun=()
    noun_aliases=()
}

_odo_analyze()
{
    last_command="odo_analyze"

    command_aliases=()

    commands=()

    flags=()
    two_word_flags=()
    local_nonpersistent_flags=()
    flags_with_completion=()
    flags_completion=()

    flags+=("--o=")
    two_word_flags+=("--o")
    two_word_flags+=("-o")
    flags+=("--platform=")
    two_word_flags+=("--platform")
    flags+=("--v=")
    two_word_flags+=("--v")
    two_word_flags+=("-v")
    flags+=("--var=")
    two_word_flags+=("--var")
    flags+=("--var-file=")
    two_word_flags+=("--var-file")
    flags+=("--vmodule=")
    two_word_flags+=("--vmodule")

    must_have_one_flag=()
    must_have_one_noun=()
    noun_aliases=()
}

_odo_build-images()
{
    last_command="odo_build-images"

    command_aliases=()

    commands=()

    flags=()
    two_word_flags=()
    local_nonpersistent_flags=()
    flags_with_completion=()
    flags_completion=()

    flags+=("--push")
    local_nonpersistent_flags+=("--push")
    flags+=("--o=")
    two_word_flags+=("--o")
    two_word_flags+=("-o")
    flags+=("--platform=")
    two_word_flags+=("--platform")
    flags+=("--v=")
    two_word_flags+=("--v")
    two_word_flags+=("-v")
    flags+=("--var=")
    two_word_flags+=("--var")
    flags+=("--var-file=")
    two_word_flags+=("--var-file")
    flags+=("--vmodule=")
    two_word_flags+=("--vmodule")

    must_have_one_flag=()
    must_have_one_noun=()
    noun_aliases=()
}

_odo_completion()
{
    last_command="odo_completion"

    command_aliases=()

    commands=()

    flags=()
    two_word_flags=()
    local_nonpersistent_flags=()
    flags_with_completion=()
    flags_completion=()

    flags+=("--help")
    flags+=("-h")
    local_nonpersistent_flags+=("--help")
    local_nonpersistent_flags+=("-h")
    flags+=("--o=")
    two_word_flags+=("--o")
    two_word_flags+=("-o")
    flags+=("--platform=")
    two_word_flags+=("--platform")
    flags+=("--v=")
    two_word_flags+=("--v")
    two_word_flags+=("-v")
    flags+=("--var=")
    two_word_flags+=("--var")
    flags+=("--var-file=")
    two_word_flags+=("--var-file")
    flags+=("--vmodule=")
    two_word_flags+=("--vmodule")

    must_have_one_flag=()
    must_have_one_noun=()
    must_have_one_noun+=("bash")
    must_have_one_noun+=("fish")
    must_have_one_noun+=("powershell")
    must_have_one_noun+=("zsh")
    noun_aliases=()
}

_odo_create_namespace()
{
    last_command="odo_create_namespace"

    command_aliases=()

    commands=()

    flags=()
    two_word_flags=()
    local_nonpersistent_flags=()
    flags_with_completion=()
    flags_completion=()

    flags+=("--wait")
    flags+=("-w")
    local_nonpersistent_flags+=("--wait")
    local_nonpersistent_flags+=("-w")
    flags+=("--o=")
    two_word_flags+=("--o")
    two_word_flags+=("-o")
    flags+=("--platform=")
    two_word_flags+=("--platform")
    flags+=("--v=")
    two_word_flags+=("--v")
    two_word_flags+=("-v")
    flags+=("--var=")
    two_word_flags+=("--var")
    flags+=("--var-file=")
    two_word_flags+=("--var-file")
    flags+=("--vmodule=")
    two_word_flags+=("--vmodule")

    must_have_one_flag=()
    must_have_one_noun=()
    noun_aliases=()
}

_odo_create()
{
    last_command="odo_create"

    command_aliases=()

    commands=()
    commands+=("namespace")
    if [[ -z "${BASH_VERSION:-}" || "${BASH_VERSINFO[0]:-}" -gt 3 ]]; then
        command_aliases+=("project")
        aliashash["project"]="namespace"
    fi

    flags=()
    two_word_flags=()
    local_nonpersistent_flags=()
    flags_with_completion=()
    flags_completion=()

    flags+=("--o=")
    two_word_flags+=("--o")
    two_word_flags+=("-o")
    flags+=("--platform=")
    two_word_flags+=("--platform")
    flags+=("--v=")
    two_word_flags+=("--v")
    two_word_flags+=("-v")
    flags+=("--var=")
    two_word_flags+=("--var")
    flags+=("--var-file=")
    two_word_flags+=("--var-file")
    flags+=("--vmodule=")
    two_word_flags+=("--vmodule")

    must_have_one_flag=()
    must_have_one_noun=()
    noun_aliases=()
}

_odo_delete_component()
{
    last_command="odo_delete_component"

    command_aliases=()

    commands=()

    flags=()
    two_word_flags=()
    local_nonpersistent_flags=()
    flags_with_completion=()
    flags_completion=()

    flags+=("--files")
    local_nonpersistent_flags+=("--files")
    flags+=("--force")
    flags+=("-f")
    local_nonpersistent_flags+=("--force")
    local_nonpersistent_flags+=("-f")
    flags+=("--name=")
    two_word_flags+=("--name")
    local_nonpersistent_flags+=("--name")
    local_nonpersistent_flags+=("--name=")
    flags+=("--namespace=")
    two_word_flags+=("--namespace")
    local_nonpersistent_flags+=("--namespace")
    local_nonpersistent_flags+=("--namespace=")
    flags+=("--running-in=")
    two_word_flags+=("--running-in")
    local_nonpersistent_flags+=("--running-in")
    local_nonpersistent_flags+=("--running-in=")
    flags+=("--wait")
    flags+=("-w")
    local_nonpersistent_flags+=("--wait")
    local_nonpersistent_flags+=("-w")
    flags+=("--o=")
    two_word_flags+=("--o")
    two_word_flags+=("-o")
    flags+=("--platform=")
    two_word_flags+=("--platform")
    flags+=("--v=")
    two_word_flags+=("--v")
    two_word_flags+=("-v")
    flags+=("--var=")
    two_word_flags+=("--var")
    flags+=("--var-file=")
    two_word_flags+=("--var-file")
    flags+=("--vmodule=")
    two_word_flags+=("--vmodule")

    must_have_one_flag=()
    must_have_one_noun=()
    noun_aliases=()
}

_odo_delete_namespace()
{
    last_command="odo_delete_namespace"

    command_aliases=()

    commands=()

    flags=()
    two_word_flags=()
    local_nonpersistent_flags=()
    flags_with_completion=()
    flags_completion=()

    flags+=("--force")
    flags+=("-f")
    local_nonpersistent_flags+=("--force")
    local_nonpersistent_flags+=("-f")
    flags+=("--wait")
    flags+=("-w")
    local_nonpersistent_flags+=("--wait")
    local_nonpersistent_flags+=("-w")
    flags+=("--o=")
    two_word_flags+=("--o")
    two_word_flags+=("-o")
    flags+=("--platform=")
    two_word_flags+=("--platform")
    flags+=("--v=")
    two_word_flags+=("--v")
    two_word_flags+=("-v")
    flags+=("--var=")
    two_word_flags+=("--var")
    flags+=("--var-file=")
    two_word_flags+=("--var-file")
    flags+=("--vmodule=")
    two_word_flags+=("--vmodule")

    must_have_one_flag=()
    must_have_one_noun=()
    noun_aliases=()
}

_odo_delete()
{
    last_command="odo_delete"

    command_aliases=()

    commands=()
    commands+=("component")
    commands+=("namespace")
    if [[ -z "${BASH_VERSION:-}" || "${BASH_VERSINFO[0]:-}" -gt 3 ]]; then
        command_aliases+=("project")
        aliashash["project"]="namespace"
    fi

    flags=()
    two_word_flags=()
    local_nonpersistent_flags=()
    flags_with_completion=()
    flags_completion=()

    flags+=("--o=")
    two_word_flags+=("--o")
    two_word_flags+=("-o")
    flags+=("--platform=")
    two_word_flags+=("--platform")
    flags+=("--v=")
    two_word_flags+=("--v")
    two_word_flags+=("-v")
    flags+=("--var=")
    two_word_flags+=("--var")
    flags+=("--var-file=")
    two_word_flags+=("--var-file")
    flags+=("--vmodule=")
    two_word_flags+=("--vmodule")

    must_have_one_flag=()
    must_have_one_noun=()
    noun_aliases=()
}

_odo_deploy()
{
    last_command="odo_deploy"

    command_aliases=()

    commands=()

    flags=()
    two_word_flags=()
    local_nonpersistent_flags=()
    flags_with_completion=()
    flags_completion=()

    flags+=("--o=")
    two_word_flags+=("--o")
    two_word_flags+=("-o")
    flags+=("--platform=")
    two_word_flags+=("--platform")
    flags+=("--v=")
    two_word_flags+=("--v")
    two_word_flags+=("-v")
    flags+=("--var=")
    two_word_flags+=("--var")
    flags+=("--var-file=")
    two_word_flags+=("--var-file")
    flags+=("--vmodule=")
    two_word_flags+=("--vmodule")

    must_have_one_flag=()
    must_have_one_noun=()
    noun_aliases=()
}

_odo_describe_binding()
{
    last_command="odo_describe_binding"

    command_aliases=()

    commands=()

    flags=()
    two_word_flags=()
    local_nonpersistent_flags=()
    flags_with_completion=()
    flags_completion=()

    flags+=("--name=")
    two_word_flags+=("--name")
    local_nonpersistent_flags+=("--name")
    local_nonpersistent_flags+=("--name=")
    flags+=("--o=")
    two_word_flags+=("--o")
    two_word_flags+=("-o")
    flags+=("--platform=")
    two_word_flags+=("--platform")
    flags+=("--v=")
    two_word_flags+=("--v")
    two_word_flags+=("-v")
    flags+=("--var=")
    two_word_flags+=("--var")
    flags+=("--var-file=")
    two_word_flags+=("--var-file")
    flags+=("--vmodule=")
    two_word_flags+=("--vmodule")

    must_have_one_flag=()
    must_have_one_noun=()
    noun_aliases=()
}

_odo_describe_component()
{
    last_command="odo_describe_component"

    command_aliases=()

    commands=()

    flags=()
    two_word_flags=()
    local_nonpersistent_flags=()
    flags_with_completion=()
    flags_completion=()

    flags+=("--name=")
    two_word_flags+=("--name")
    local_nonpersistent_flags+=("--name")
    local_nonpersistent_flags+=("--name=")
    flags+=("--namespace=")
    two_word_flags+=("--namespace")
    local_nonpersistent_flags+=("--namespace")
    local_nonpersistent_flags+=("--namespace=")
    flags+=("--o=")
    two_word_flags+=("--o")
    two_word_flags+=("-o")
    flags+=("--platform=")
    two_word_flags+=("--platform")
    flags+=("--v=")
    two_word_flags+=("--v")
    two_word_flags+=("-v")
    flags+=("--var=")
    two_word_flags+=("--var")
    flags+=("--var-file=")
    two_word_flags+=("--var-file")
    flags+=("--vmodule=")
    two_word_flags+=("--vmodule")

    must_have_one_flag=()
    must_have_one_noun=()
    noun_aliases=()
}

_odo_describe()
{
    last_command="odo_describe"

    command_aliases=()

    commands=()
    commands+=("binding")
    commands+=("component")

    flags=()
    two_word_flags=()
    local_nonpersistent_flags=()
    flags_with_completion=()
    flags_completion=()

    flags+=("--o=")
    two_word_flags+=("--o")
    two_word_flags+=("-o")
    flags+=("--platform=")
    two_word_flags+=("--platform")
    flags+=("--v=")
    two_word_flags+=("--v")
    two_word_flags+=("-v")
    flags+=("--var=")
    two_word_flags+=("--var")
    flags+=("--var-file=")
    two_word_flags+=("--var-file")
    flags+=("--vmodule=")
    two_word_flags+=("--vmodule")

    must_have_one_flag=()
    must_have_one_noun=()
    noun_aliases=()
}

_odo_dev()
{
    last_command="odo_dev"

    command_aliases=()

    commands=()

    flags=()
    two_word_flags=()
    local_nonpersistent_flags=()
    flags_with_completion=()
    flags_completion=()

    flags+=("--address=")
    two_word_flags+=("--address")
    local_nonpersistent_flags+=("--address")
    local_nonpersistent_flags+=("--address=")
    flags+=("--api-server")
    local_nonpersistent_flags+=("--api-server")
    flags+=("--api-server-port=")
    two_word_flags+=("--api-server-port")
    local_nonpersistent_flags+=("--api-server-port")
    local_nonpersistent_flags+=("--api-server-port=")
    flags+=("--build-command=")
    two_word_flags+=("--build-command")
    local_nonpersistent_flags+=("--build-command")
    local_nonpersistent_flags+=("--build-command=")
    flags+=("--debug")
    local_nonpersistent_flags+=("--debug")
    flags+=("--forward-localhost")
    local_nonpersistent_flags+=("--forward-localhost")
    flags+=("--ignore-localhost")
    local_nonpersistent_flags+=("--ignore-localhost")
    flags+=("--logs")
    local_nonpersistent_flags+=("--logs")
    flags+=("--no-commands")
    local_nonpersistent_flags+=("--no-commands")
    flags+=("--no-watch")
    local_nonpersistent_flags+=("--no-watch")
    flags+=("--port-forward=")
    two_word_flags+=("--port-forward")
    local_nonpersistent_flags+=("--port-forward")
    local_nonpersistent_flags+=("--port-forward=")
    flags+=("--random-ports")
    local_nonpersistent_flags+=("--random-ports")
    flags+=("--run-command=")
    two_word_flags+=("--run-command")
    local_nonpersistent_flags+=("--run-command")
    local_nonpersistent_flags+=("--run-command=")
    flags+=("--sync-git-dir")
    local_nonpersistent_flags+=("--sync-git-dir")
    flags+=("--o=")
    two_word_flags+=("--o")
    two_word_flags+=("-o")
    flags+=("--platform=")
    two_word_flags+=("--platform")
    flags+=("--v=")
    two_word_flags+=("--v")
    two_word_flags+=("-v")
    flags+=("--var=")
    two_word_flags+=("--var")
    flags+=("--var-file=")
    two_word_flags+=("--var-file")
    flags+=("--vmodule=")
    two_word_flags+=("--vmodule")

    must_have_one_flag=()
    must_have_one_noun=()
    noun_aliases=()
}

_odo_help()
{
    last_command="odo_help"

    command_aliases=()

    commands=()

    flags=()
    two_word_flags=()
    local_nonpersistent_flags=()
    flags_with_completion=()
    flags_completion=()

    flags+=("--o=")
    two_word_flags+=("--o")
    two_word_flags+=("-o")
    flags+=("--platform=")
    two_word_flags+=("--platform")
    flags+=("--v=")
    two_word_flags+=("--v")
    two_word_flags+=("-v")
    flags+=("--var=")
    two_word_flags+=("--var")
    flags+=("--var-file=")
    two_word_flags+=("--var-file")
    flags+=("--vmodule=")
    two_word_flags+=("--vmodule")

    must_have_one_flag=()
    must_have_one_noun=()
    has_completion_function=1
    noun_aliases=()
}

_odo_init()
{
    last_command="odo_init"

    command_aliases=()

    commands=()

    flags=()
    two_word_flags=()
    local_nonpersistent_flags=()
    flags_with_completion=()
    flags_completion=()

    flags+=("--architecture=")
    two_word_flags+=("--architecture")
    local_nonpersistent_flags+=("--architecture")
    local_nonpersistent_flags+=("--architecture=")
    flags+=("--devfile=")
    two_word_flags+=("--devfile")
    local_nonpersistent_flags+=("--devfile")
    local_nonpersistent_flags+=("--devfile=")
    flags+=("--devfile-path=")
    two_word_flags+=("--devfile-path")
    local_nonpersistent_flags+=("--devfile-path")
    local_nonpersistent_flags+=("--devfile-path=")
    flags+=("--devfile-registry=")
    two_word_flags+=("--devfile-registry")
    local_nonpersistent_flags+=("--devfile-registry")
    local_nonpersistent_flags+=("--devfile-registry=")
    flags+=("--devfile-version=")
    two_word_flags+=("--devfile-version")
    local_nonpersistent_flags+=("--devfile-version")
    local_nonpersistent_flags+=("--devfile-version=")
    flags+=("--name=")
    two_word_flags+=("--name")
    local_nonpersistent_flags+=("--name")
    local_nonpersistent_flags+=("--name=")
    flags+=("--run-port=")
    two_word_flags+=("--run-port")
    local_nonpersistent_flags+=("--run-port")
    local_nonpersistent_flags+=("--run-port=")
    flags+=("--starter=")
    two_word_flags+=("--starter")
    local_nonpersistent_flags+=("--starter")
    local_nonpersistent_flags+=("--starter=")
    flags+=("--o=")
    two_word_flags+=("--o")
    two_word_flags+=("-o")
    flags+=("--platform=")
    two_word_flags+=("--platform")
    flags+=("--v=")
    two_word_flags+=("--v")
    two_word_flags+=("-v")
    flags+=("--var=")
    two_word_flags+=("--var")
    flags+=("--var-file=")
    two_word_flags+=("--var-file")
    flags+=("--vmodule=")
    two_word_flags+=("--vmodule")

    must_have_one_flag=()
    must_have_one_noun=()
    noun_aliases=()
}

_odo_list_binding()
{
    last_command="odo_list_binding"

    command_aliases=()

    commands=()

    flags=()
    two_word_flags=()
    local_nonpersistent_flags=()
    flags_with_completion=()
    flags_completion=()

    flags+=("--namespace=")
    two_word_flags+=("--namespace")
    local_nonpersistent_flags+=("--namespace")
    local_nonpersistent_flags+=("--namespace=")
    flags+=("--o=")
    two_word_flags+=("--o")
    two_word_flags+=("-o")
    flags+=("--platform=")
    two_word_flags+=("--platform")
    flags+=("--v=")
    two_word_flags+=("--v")
    two_word_flags+=("-v")
    flags+=("--var=")
    two_word_flags+=("--var")
    flags+=("--var-file=")
    two_word_flags+=("--var-file")
    flags+=("--vmodule=")
    two_word_flags+=("--vmodule")

    must_have_one_flag=()
    must_have_one_noun=()
    noun_aliases=()
}

_odo_list_component()
{
    last_command="odo_list_component"

    command_aliases=()

    commands=()

    flags=()
    two_word_flags=()
    local_nonpersistent_flags=()
    flags_with_completion=()
    flags_completion=()

    flags+=("--namespace=")
    two_word_flags+=("--namespace")
    local_nonpersistent_flags+=("--namespace")
    local_nonpersistent_flags+=("--namespace=")
    flags+=("--o=")
    two_word_flags+=("--o")
    two_word_flags+=("-o")
    flags+=("--platform=")
    two_word_flags+=("--platform")
    flags+=("--v=")
    two_word_flags+=("--v")
    two_word_flags+=("-v")
    flags+=("--var=")
    two_word_flags+=("--var")
    flags+=("--var-file=")
    two_word_flags+=("--var-file")
    flags+=("--vmodule=")
    two_word_flags+=("--vmodule")

    must_have_one_flag=()
    must_have_one_noun=()
    noun_aliases=()
}

_odo_list_namespace()
{
    last_command="odo_list_namespace"

    command_aliases=()

    commands=()

    flags=()
    two_word_flags=()
    local_nonpersistent_flags=()
    flags_with_completion=()
    flags_completion=()

    flags+=("--o=")
    two_word_flags+=("--o")
    two_word_flags+=("-o")
    flags+=("--platform=")
    two_word_flags+=("--platform")
    flags+=("--v=")
    two_word_flags+=("--v")
    two_word_flags+=("-v")
    flags+=("--var=")
    two_word_flags+=("--var")
    flags+=("--var-file=")
    two_word_flags+=("--var-file")
    flags+=("--vmodule=")
    two_word_flags+=("--vmodule")

    must_have_one_flag=()
    must_have_one_noun=()
    noun_aliases=()
}

_odo_list_services()
{
    last_command="odo_list_services"

    command_aliases=()

    commands=()

    flags=()
    two_word_flags=()
    local_nonpersistent_flags=()
    flags_with_completion=()
    flags_completion=()

    flags+=("--all-namespaces")
    flags+=("-A")
    local_nonpersistent_flags+=("--all-namespaces")
    local_nonpersistent_flags+=("-A")
    flags+=("--namespace=")
    two_word_flags+=("--namespace")
    two_word_flags+=("-n")
    local_nonpersistent_flags+=("--namespace")
    local_nonpersistent_flags+=("--namespace=")
    local_nonpersistent_flags+=("-n")
    flags+=("--o=")
    two_word_flags+=("--o")
    two_word_flags+=("-o")
    flags+=("--platform=")
    two_word_flags+=("--platform")
    flags+=("--v=")
    two_word_flags+=("--v")
    two_word_flags+=("-v")
    flags+=("--var=")
    two_word_flags+=("--var")
    flags+=("--var-file=")
    two_word_flags+=("--var-file")
    flags+=("--vmodule=")
    two_word_flags+=("--vmodule")

    must_have_one_flag=()
    must_have_one_noun=()
    noun_aliases=()
}

_odo_list()
{
    last_command="odo_list"

    command_aliases=()

    commands=()
    commands+=("binding")
    if [[ -z "${BASH_VERSION:-}" || "${BASH_VERSINFO[0]:-}" -gt 3 ]]; then
        command_aliases+=("bindings")
        aliashash["bindings"]="binding"
    fi
    commands+=("component")
    if [[ -z "${BASH_VERSION:-}" || "${BASH_VERSINFO[0]:-}" -gt 3 ]]; then
        command_aliases+=("components")
        aliashash["components"]="component"
    fi
    commands+=("namespace")
    if [[ -z "${BASH_VERSION:-}" || "${BASH_VERSINFO[0]:-}" -gt 3 ]]; then
        command_aliases+=("namespaces")
        aliashash["namespaces"]="namespace"
        command_aliases+=("project")
        aliashash["project"]="namespace"
        command_aliases+=("projects")
        aliashash["projects"]="namespace"
    fi
    commands+=("services")
    if [[ -z "${BASH_VERSION:-}" || "${BASH_VERSINFO[0]:-}" -gt 3 ]]; then
        command_aliases+=("service")
        aliashash["service"]="services"
    fi

    flags=()
    two_word_flags=()
    local_nonpersistent_flags=()
    flags_with_completion=()
    flags_completion=()

    flags+=("--namespace=")
    two_word_flags+=("--namespace")
    local_nonpersistent_flags+=("--namespace")
    local_nonpersistent_flags+=("--namespace=")
    flags+=("--o=")
    two_word_flags+=("--o")
    two_word_flags+=("-o")
    flags+=("--platform=")
    two_word_flags+=("--platform")
    flags+=("--v=")
    two_word_flags+=("--v")
    two_word_flags+=("-v")
    flags+=("--var=")
    two_word_flags+=("--var")
    flags+=("--var-file=")
    two_word_flags+=("--var-file")
    flags+=("--vmodule=")
    two_word_flags+=("--vmodule")

    must_have_one_flag=()
    must_have_one_noun=()
    noun_aliases=()
}

_odo_login()
{
    last_command="odo_login"

    command_aliases=()

    commands=()

    flags=()
    two_word_flags=()
    local_nonpersistent_flags=()
    flags_with_completion=()
    flags_completion=()

    flags+=("--certificate-authority=")
    two_word_flags+=("--certificate-authority")
    local_nonpersistent_flags+=("--certificate-authority")
    local_nonpersistent_flags+=("--certificate-authority=")
    flags+=("--insecure-skip-tls-verify")
    local_nonpersistent_flags+=("--insecure-skip-tls-verify")
    flags+=("--password=")
    two_word_flags+=("--password")
    two_word_flags+=("-p")
    local_nonpersistent_flags+=("--password")
    local_nonpersistent_flags+=("--password=")
    local_nonpersistent_flags+=("-p")
    flags+=("--server=")
    two_word_flags+=("--server")
    local_nonpersistent_flags+=("--server")
    local_nonpersistent_flags+=("--server=")
    flags+=("--token=")
    two_word_flags+=("--token")
    two_word_flags+=("-t")
    local_nonpersistent_flags+=("--token")
    local_nonpersistent_flags+=("--token=")
    local_nonpersistent_flags+=("-t")
    flags+=("--username=")
    two_word_flags+=("--username")
    two_word_flags+=("-u")
    local_nonpersistent_flags+=("--username")
    local_nonpersistent_flags+=("--username=")
    local_nonpersistent_flags+=("-u")
    flags+=("--o=")
    two_word_flags+=("--o")
    two_word_flags+=("-o")
    flags+=("--platform=")
    two_word_flags+=("--platform")
    flags+=("--v=")
    two_word_flags+=("--v")
    two_word_flags+=("-v")
    flags+=("--var=")
    two_word_flags+=("--var")
    flags+=("--var-file=")
    two_word_flags+=("--var-file")
    flags+=("--vmodule=")
    two_word_flags+=("--vmodule")

    must_have_one_flag=()
    must_have_one_noun=()
    noun_aliases=()
}

_odo_logout()
{
    last_command="odo_logout"

    command_aliases=()

    commands=()

    flags=()
    two_word_flags=()
    local_nonpersistent_flags=()
    flags_with_completion=()
    flags_completion=()

    flags+=("--o=")
    two_word_flags+=("--o")
    two_word_flags+=("-o")
    flags+=("--platform=")
    two_word_flags+=("--platform")
    flags+=("--v=")
    two_word_flags+=("--v")
    two_word_flags+=("-v")
    flags+=("--var=")
    two_word_flags+=("--var")
    flags+=("--var-file=")
    two_word_flags+=("--var-file")
    flags+=("--vmodule=")
    two_word_flags+=("--vmodule")

    must_have_one_flag=()
    must_have_one_noun=()
    noun_aliases=()
}

_odo_logs()
{
    last_command="odo_logs"

    command_aliases=()

    commands=()

    flags=()
    two_word_flags=()
    local_nonpersistent_flags=()
    flags_with_completion=()
    flags_completion=()

    flags+=("--deploy")
    local_nonpersistent_flags+=("--deploy")
    flags+=("--dev")
    local_nonpersistent_flags+=("--dev")
    flags+=("--follow")
    local_nonpersistent_flags+=("--follow")
    flags+=("--o=")
    two_word_flags+=("--o")
    two_word_flags+=("-o")
    flags+=("--platform=")
    two_word_flags+=("--platform")
    flags+=("--v=")
    two_word_flags+=("--v")
    two_word_flags+=("-v")
    flags+=("--var=")
    two_word_flags+=("--var")
    flags+=("--var-file=")
    two_word_flags+=("--var-file")
    flags+=("--vmodule=")
    two_word_flags+=("--vmodule")

    must_have_one_flag=()
    must_have_one_noun=()
    noun_aliases=()
}

_odo_preference_add_registry()
{
    last_command="odo_preference_add_registry"

    command_aliases=()

    commands=()

    flags=()
    two_word_flags=()
    local_nonpersistent_flags=()
    flags_with_completion=()
    flags_completion=()

    flags+=("--token=")
    two_word_flags+=("--token")
    local_nonpersistent_flags+=("--token")
    local_nonpersistent_flags+=("--token=")
    flags+=("--o=")
    two_word_flags+=("--o")
    two_word_flags+=("-o")
    flags+=("--platform=")
    two_word_flags+=("--platform")
    flags+=("--v=")
    two_word_flags+=("--v")
    two_word_flags+=("-v")
    flags+=("--var=")
    two_word_flags+=("--var")
    flags+=("--var-file=")
    two_word_flags+=("--var-file")
    flags+=("--vmodule=")
    two_word_flags+=("--vmodule")

    must_have_one_flag=()
    must_have_one_noun=()
    noun_aliases=()
}

_odo_preference_add()
{
    last_command="odo_preference_add"

    command_aliases=()

    commands=()
    commands+=("registry")

    flags=()
    two_word_flags=()
    local_nonpersistent_flags=()
    flags_with_completion=()
    flags_completion=()

    flags+=("--o=")
    two_word_flags+=("--o")
    two_word_flags+=("-o")
    flags+=("--platform=")
    two_word_flags+=("--platform")
    flags+=("--v=")
    two_word_flags+=("--v")
    two_word_flags+=("-v")
    flags+=("--var=")
    two_word_flags+=("--var")
    flags+=("--var-file=")
    two_word_flags+=("--var-file")
    flags+=("--vmodule=")
    two_word_flags+=("--vmodule")

    must_have_one_flag=()
    must_have_one_noun=()
    noun_aliases=()
}

_odo_preference_remove_registry()
{
    last_command="odo_preference_remove_registry"

    command_aliases=()

    commands=()

    flags=()
    two_word_flags=()
    local_nonpersistent_flags=()
    flags_with_completion=()
    flags_completion=()

    flags+=("--force")
    flags+=("-f")
    local_nonpersistent_flags+=("--force")
    local_nonpersistent_flags+=("-f")
    flags+=("--o=")
    two_word_flags+=("--o")
    two_word_flags+=("-o")
    flags+=("--platform=")
    two_word_flags+=("--platform")
    flags+=("--v=")
    two_word_flags+=("--v")
    two_word_flags+=("-v")
    flags+=("--var=")
    two_word_flags+=("--var")
    flags+=("--var-file=")
    two_word_flags+=("--var-file")
    flags+=("--vmodule=")
    two_word_flags+=("--vmodule")

    must_have_one_flag=()
    must_have_one_noun=()
    noun_aliases=()
}

_odo_preference_remove()
{
    last_command="odo_preference_remove"

    command_aliases=()

    commands=()
    commands+=("registry")

    flags=()
    two_word_flags=()
    local_nonpersistent_flags=()
    flags_with_completion=()
    flags_completion=()

    flags+=("--o=")
    two_word_flags+=("--o")
    two_word_flags+=("-o")
    flags+=("--platform=")
    two_word_flags+=("--platform")
    flags+=("--v=")
    two_word_flags+=("--v")
    two_word_flags+=("-v")
    flags+=("--var=")
    two_word_flags+=("--var")
    flags+=("--var-file=")
    two_word_flags+=("--var-file")
    flags+=("--vmodule=")
    two_word_flags+=("--vmodule")

    must_have_one_flag=()
    must_have_one_noun=()
    noun_aliases=()
}

_odo_preference_set()
{
    last_command="odo_preference_set"

    command_aliases=()

    commands=()

    flags=()
    two_word_flags=()
    local_nonpersistent_flags=()
    flags_with_completion=()
    flags_completion=()

    flags+=("--force")
    flags+=("-f")
    local_nonpersistent_flags+=("--force")
    local_nonpersistent_flags+=("-f")
    flags+=("--o=")
    two_word_flags+=("--o")
    two_word_flags+=("-o")
    flags+=("--platform=")
    two_word_flags+=("--platform")
    flags+=("--v=")
    two_word_flags+=("--v")
    two_word_flags+=("-v")
    flags+=("--var=")
    two_word_flags+=("--var")
    flags+=("--var-file=")
    two_word_flags+=("--var-file")
    flags+=("--vmodule=")
    two_word_flags+=("--vmodule")

    must_have_one_flag=()
    must_have_one_noun=()
    noun_aliases=()
}

_odo_preference_unset()
{
    last_command="odo_preference_unset"

    command_aliases=()

    commands=()

    flags=()
    two_word_flags=()
    local_nonpersistent_flags=()
    flags_with_completion=()
    flags_completion=()

    flags+=("--force")
    flags+=("-f")
    local_nonpersistent_flags+=("--force")
    local_nonpersistent_flags+=("-f")
    flags+=("--o=")
    two_word_flags+=("--o")
    two_word_flags+=("-o")
    flags+=("--platform=")
    two_word_flags+=("--platform")
    flags+=("--v=")
    two_word_flags+=("--v")
    two_word_flags+=("-v")
    flags+=("--var=")
    two_word_flags+=("--var")
    flags+=("--var-file=")
    two_word_flags+=("--var-file")
    flags+=("--vmodule=")
    two_word_flags+=("--vmodule")

    must_have_one_flag=()
    must_have_one_noun=()
    noun_aliases=()
}

_odo_preference_view()
{
    last_command="odo_preference_view"

    command_aliases=()

    commands=()

    flags=()
    two_word_flags=()
    local_nonpersistent_flags=()
    flags_with_completion=()
    flags_completion=()

    flags+=("--o=")
    two_word_flags+=("--o")
    two_word_flags+=("-o")
    flags+=("--platform=")
    two_word_flags+=("--platform")
    flags+=("--v=")
    two_word_flags+=("--v")
    two_word_flags+=("-v")
    flags+=("--var=")
    two_word_flags+=("--var")
    flags+=("--var-file=")
    two_word_flags+=("--var-file")
    flags+=("--vmodule=")
    two_word_flags+=("--vmodule")

    must_have_one_flag=()
    must_have_one_noun=()
    noun_aliases=()
}

_odo_preference()
{
    last_command="odo_preference"

    command_aliases=()

    commands=()
    commands+=("add")
    commands+=("remove")
    commands+=("set")
    commands+=("unset")
    commands+=("view")

    flags=()
    two_word_flags=()
    local_nonpersistent_flags=()
    flags_with_completion=()
    flags_completion=()

    flags+=("--o=")
    two_word_flags+=("--o")
    two_word_flags+=("-o")
    flags+=("--platform=")
    two_word_flags+=("--platform")
    flags+=("--v=")
    two_word_flags+=("--v")
    two_word_flags+=("-v")
    flags+=("--var=")
    two_word_flags+=("--var")
    flags+=("--var-file=")
    two_word_flags+=("--var-file")
    flags+=("--vmodule=")
    two_word_flags+=("--vmodule")

    must_have_one_flag=()
    must_have_one_noun=()
    noun_aliases=()
}

_odo_registry()
{
    last_command="odo_registry"

    command_aliases=()

    commands=()

    flags=()
    two_word_flags=()
    local_nonpersistent_flags=()
    flags_with_completion=()
    flags_completion=()

    flags+=("--details")
    local_nonpersistent_flags+=("--details")
    flags+=("--devfile=")
    two_word_flags+=("--devfile")
    local_nonpersistent_flags+=("--devfile")
    local_nonpersistent_flags+=("--devfile=")
    flags+=("--devfile-registry=")
    two_word_flags+=("--devfile-registry")
    local_nonpersistent_flags+=("--devfile-registry")
    local_nonpersistent_flags+=("--devfile-registry=")
    flags+=("--filter=")
    two_word_flags+=("--filter")
    local_nonpersistent_flags+=("--filter")
    local_nonpersistent_flags+=("--filter=")
    flags+=("--o=")
    two_word_flags+=("--o")
    two_word_flags+=("-o")
    flags+=("--platform=")
    two_word_flags+=("--platform")
    flags+=("--v=")
    two_word_flags+=("--v")
    two_word_flags+=("-v")
    flags+=("--var=")
    two_word_flags+=("--var")
    flags+=("--var-file=")
    two_word_flags+=("--var-file")
    flags+=("--vmodule=")
    two_word_flags+=("--vmodule")

    must_have_one_flag=()
    must_have_one_noun=()
    noun_aliases=()
}

_odo_remove_binding()
{
    last_command="odo_remove_binding"

    command_aliases=()

    commands=()

    flags=()
    two_word_flags=()
    local_nonpersistent_flags=()
    flags_with_completion=()
    flags_completion=()

    flags+=("--name=")
    two_word_flags+=("--name")
    local_nonpersistent_flags+=("--name")
    local_nonpersistent_flags+=("--name=")
    flags+=("--o=")
    two_word_flags+=("--o")
    two_word_flags+=("-o")
    flags+=("--platform=")
    two_word_flags+=("--platform")
    flags+=("--v=")
    two_word_flags+=("--v")
    two_word_flags+=("-v")
    flags+=("--var=")
    two_word_flags+=("--var")
    flags+=("--var-file=")
    two_word_flags+=("--var-file")
    flags+=("--vmodule=")
    two_word_flags+=("--vmodule")

    must_have_one_flag=()
    must_have_one_noun=()
    noun_aliases=()
}

_odo_remove()
{
    last_command="odo_remove"

    command_aliases=()

    commands=()
    commands+=("binding")

    flags=()
    two_word_flags=()
    local_nonpersistent_flags=()
    flags_with_completion=()
    flags_completion=()

    flags+=("--o=")
    two_word_flags+=("--o")
    two_word_flags+=("-o")
    flags+=("--platform=")
    two_word_flags+=("--platform")
    flags+=("--v=")
    two_word_flags+=("--v")
    two_word_flags+=("-v")
    flags+=("--var=")
    two_word_flags+=("--var")
    flags+=("--var-file=")
    two_word_flags+=("--var-file")
    flags+=("--vmodule=")
    two_word_flags+=("--vmodule")

    must_have_one_flag=()
    must_have_one_noun=()
    noun_aliases=()
}

_odo_run()
{
    last_command="odo_run"

    command_aliases=()

    commands=()

    flags=()
    two_word_flags=()
    local_nonpersistent_flags=()
    flags_with_completion=()
    flags_completion=()

    flags+=("--o=")
    two_word_flags+=("--o")
    two_word_flags+=("-o")
    flags+=("--platform=")
    two_word_flags+=("--platform")
    flags+=("--v=")
    two_word_flags+=("--v")
    two_word_flags+=("-v")
    flags+=("--var=")
    two_word_flags+=("--var")
    flags+=("--var-file=")
    two_word_flags+=("--var-file")
    flags+=("--vmodule=")
    two_word_flags+=("--vmodule")

    must_have_one_flag=()
    must_have_one_noun=()
    noun_aliases=()
}

_odo_set_namespace()
{
    last_command="odo_set_namespace"

    command_aliases=()

    commands=()

    flags=()
    two_word_flags=()
    local_nonpersistent_flags=()
    flags_with_completion=()
    flags_completion=()

    flags+=("--o=")
    two_word_flags+=("--o")
    two_word_flags+=("-o")
    flags+=("--platform=")
    two_word_flags+=("--platform")
    flags+=("--v=")
    two_word_flags+=("--v")
    two_word_flags+=("-v")
    flags+=("--var=")
    two_word_flags+=("--var")
    flags+=("--var-file=")
    two_word_flags+=("--var-file")
    flags+=("--vmodule=")
    two_word_flags+=("--vmodule")

    must_have_one_flag=()
    must_have_one_noun=()
    noun_aliases=()
}

_odo_set()
{
    last_command="odo_set"

    command_aliases=()

    commands=()
    commands+=("namespace")
    if [[ -z "${BASH_VERSION:-}" || "${BASH_VERSINFO[0]:-}" -gt 3 ]]; then
        command_aliases+=("project")
        aliashash["project"]="namespace"
    fi

    flags=()
    two_word_flags=()
    local_nonpersistent_flags=()
    flags_with_completion=()
    flags_completion=()

    flags+=("--o=")
    two_word_flags+=("--o")
    two_word_flags+=("-o")
    flags+=("--platform=")
    two_word_flags+=("--platform")
    flags+=("--v=")
    two_word_flags+=("--v")
    two_word_flags+=("-v")
    flags+=("--var=")
    two_word_flags+=("--var")
    flags+=("--var-file=")
    two_word_flags+=("--var-file")
    flags+=("--vmodule=")
    two_word_flags+=("--vmodule")

    must_have_one_flag=()
    must_have_one_noun=()
    noun_aliases=()
}

_odo_version()
{
    last_command="odo_version"

    command_aliases=()

    commands=()

    flags=()
    two_word_flags=()
    local_nonpersistent_flags=()
    flags_with_completion=()
    flags_completion=()

    flags+=("--client")
    local_nonpersistent_flags+=("--client")
    flags+=("--o=")
    two_word_flags+=("--o")
    two_word_flags+=("-o")
    flags+=("--platform=")
    two_word_flags+=("--platform")
    flags+=("--v=")
    two_word_flags+=("--v")
    two_word_flags+=("-v")
    flags+=("--var=")
    two_word_flags+=("--var")
    flags+=("--var-file=")
    two_word_flags+=("--var-file")
    flags+=("--vmodule=")
    two_word_flags+=("--vmodule")

    must_have_one_flag=()
    must_have_one_noun=()
    noun_aliases=()
}

_odo_root_command()
{
    last_command="odo"

    command_aliases=()

    commands=()
    commands+=("add")
    commands+=("analyze")
    commands+=("build-images")
    commands+=("completion")
    commands+=("create")
    commands+=("delete")
    commands+=("deploy")
    commands+=("describe")
    commands+=("dev")
    commands+=("help")
    commands+=("init")
    commands+=("list")
    commands+=("login")
    commands+=("logout")
    commands+=("logs")
    commands+=("preference")
    commands+=("registry")
    commands+=("remove")
    commands+=("run")
    commands+=("set")
    commands+=("version")

    flags=()
    two_word_flags=()
    local_nonpersistent_flags=()
    flags_with_completion=()
    flags_completion=()

    flags+=("--complete")
    local_nonpersistent_flags+=("--complete")
    flags+=("--o=")
    two_word_flags+=("--o")
    two_word_flags+=("-o")
    flags+=("--platform=")
    two_word_flags+=("--platform")
    flags+=("--uncomplete")
    local_nonpersistent_flags+=("--uncomplete")
    flags+=("--v=")
    two_word_flags+=("--v")
    two_word_flags+=("-v")
    flags+=("--var=")
    two_word_flags+=("--var")
    flags+=("--var-file=")
    two_word_flags+=("--var-file")
    flags+=("--vmodule=")
    two_word_flags+=("--vmodule")
    flags+=("--y")
    flags+=("-y")
    local_nonpersistent_flags+=("--y")
    local_nonpersistent_flags+=("-y")

    must_have_one_flag=()
    must_have_one_noun=()
    noun_aliases=()
}

__start_odo()
{
    local cur prev words cword split
    declare -A flaghash 2>/dev/null || :
    declare -A aliashash 2>/dev/null || :
    if declare -F _init_completion >/dev/null 2>&1; then
        _init_completion -s || return
    else
        __odo_init_completion -n "=" || return
    fi

    local c=0
    local flag_parsing_disabled=
    local flags=()
    local two_word_flags=()
    local local_nonpersistent_flags=()
    local flags_with_completion=()
    local flags_completion=()
    local commands=("odo")
    local command_aliases=()
    local must_have_one_flag=()
    local must_have_one_noun=()
    local has_completion_function=""
    local last_command=""
    local nouns=()
    local noun_aliases=()

    __odo_handle_word
}

if [[ $(type -t compopt) = "builtin" ]]; then
    complete -o default -F __start_odo odo
else
    complete -o default -o nospace -F __start_odo odo
fi

# ex: ts=4 sw=4 et filetype=sh
