#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only

jc_ui_theme() {
    local scope=$1
    ink='' muted='' accent='' sketch='' red='' terminal_reset=''
    if [[ -t 1 && "${TERM:-dumb}" != dumb && -z "${NO_COLOR:-}" ]]; then
        terminal_reset=$'\033[0m'
        ink=$'\033[37m'; accent=$'\033[33m'; red=$'\033[31m'
        if [[ ${JC_THEME:-dark} == light ]]; then ink=$'\033[30m'; fi
        muted=$ink; sketch=$ink
        if [[ ${COLORTERM:-} == truecolor || ${COLORTERM:-} == 24bit ]]; then
            if [[ ${JC_THEME:-dark} == light ]]; then
                ink=$'\033[38;2;41;39;35m'; muted=$'\033[38;2;111;102;91m'; accent=$'\033[38;2;162;84;62m'
                sketch=$'\033[38;2;130;105;83m'; red=$'\033[38;2;145;66;54m'
            else
                ink=$'\033[38;2;232;228;219m'; muted=$'\033[38;2;181;174;162m'; accent=$'\033[38;2;212;150;125m'
                sketch=$'\033[38;2;185;170;150m'; red=$'\033[38;2;224;160;143m'
            fi
        elif [[ $TERM == *256color* ]]; then
            if [[ ${JC_THEME:-dark} == light ]]; then
                ink=$'\033[38;5;235m'; muted=$'\033[38;5;241m'; accent=$'\033[38;5;131m'
                sketch=$'\033[38;5;101m'; red=$'\033[38;5;124m'
            else
                ink=$'\033[38;5;254m'; muted=$'\033[38;5;249m'; accent=$'\033[38;5;173m'
                sketch=$'\033[38;5;248m'; red=$'\033[38;5;174m'
            fi
        fi
    fi

    green=$ink; yellow=$muted; reset=$terminal_reset
    if [[ $scope == menu ]]; then reset+=$ink; fi
}

jc_confirm() {
    local answer
    while true; do
        printf '%s%s [Y/N]（回车默认 Y）：%s' "${muted:-}" "$1" "${reset:-}" >&2
        IFS= read -r answer || return 1
        case "$answer" in
            ''|[Yy]) return 0 ;;
            [Nn]) return 1 ;;
            *) printf '\n%s\n' '请输入 Y 或 N。' >&2 ;;
        esac
    done
}
