#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT

for scenario in unavailable install-failure start-failure success; do
    state="$test_dir/$scenario"
    mkdir "$state"
    if (
        source <(sed '/^command_name=/,$d' "$root/manager.sh")
        source "$root/lib/firewall.sh"
        scratch="$state/scratch"
        mkdir "$scratch"
        printf '1.14.4\n' >"$state/version"
        printf '%s\n' '{"inbounds":[{"type":"vless","listen_port":443},{"type":"hysteria2","listen_port":8445}]}' >"$state/config.json"
        trap cleanup EXIT

        cfg() { printf '%s/config.json\n' "$state"; }
        check() { [[ -f $1 ]]; }
        dpkg-query() {
            case "$1" in
                -W) cat "$state/version" ;;
                -S) printf 'sing-box: %s\n' "$core" ;;
            esac
        }
        dpkg-deb() {
            case "$3" in
                Package) printf 'sing-box\n' ;;
                Version) printf '1.14.4\n' ;;
            esac
        }
        apt-get() {
            case " $* " in
                *' -s install '*) [[ $scenario != unavailable ]] ;;
                *' download sing-box=1.14.4 '*) touch sing-box_1.14.4_amd64.deb ;;
                *' --reinstall '*)
                    [[ -f ${!#} ]] || return 1
                    printf '1.14.4\n' >"$state/version"
                    ;;
                *' sing-box=1.14.3 '*)
                    printf '1.14.3\n' >"$state/version"
                    [[ $scenario != install-failure ]]
                    ;;
                *) return 1 ;;
            esac
        }
        systemctl() {
            case "$1" in
                is-active) [[ $3 == "$five" ]] ;;
                restart)
                    [[ $2 == "$five" ]] || return 1
                    cat "$state/version" >>"$state/restarts"
                    ;;
            esac
        }
        socket_ready() {
            [[ $* == "$five 443/tcp 8445/udp" ]] &&
                [[ $scenario != start-failure || $(cat "$state/version") == 1.14.4 ]]
        }
        upgrade_managed --allow-downgrades sing-box=1.14.3
    ) >"$state/log" 2>&1; then
        code=0
    else
        code=$?
    fi
    case "$scenario" in
        unavailable)
            [[ $code == 1 && $(cat "$state/version") == 1.14.4 && ! -e $state/restarts ]]
            grep -q '无法安装目标版本' "$state/log"
            ;;
        install-failure|start-failure)
            [[ $code == 1 && $(cat "$state/version") == 1.14.4 ]]
            [[ $(tail -1 "$state/restarts") == 1.14.4 ]]
            grep -q '已恢复原 sing-box 版本' "$state/log"
            ;;
        success)
            [[ $code == 0 && $(cat "$state/version") == 1.14.3 ]]
            [[ $(cat "$state/restarts") == 1.14.3 ]]
            ;;
    esac
    printf '%s passed\n' "$scenario"
done
