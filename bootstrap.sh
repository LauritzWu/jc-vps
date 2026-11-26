#!/usr/bin/env bash
set -euo pipefail
umask 077

installed=false
action=''
if [[ ${1:-} == --installed ]]; then
    installed=true
    shift
    action=${1:-}
    if (( $# > 1 )) || [[ -n $action && $action != --check && $action != --rollback ]]; then
        printf '用法：jc [--rollback]\n' >&2
        exit 2
    fi
    dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
    IFS= read -r revision <"$dir/revision"
else
    revision=${1:-main}
    if (( $# > 1 )); then
        printf '用法：bootstrap.sh [完整 Git 提交 SHA]\n' >&2
        exit 2
    fi
fi
if [[ $revision != main && ! $revision =~ ^[0-9a-f]{40}$ ]]; then
    printf '用法：bootstrap.sh [完整 Git 提交 SHA]\n' >&2
    exit 2
fi

if (( EUID != 0 )); then printf '请在 VPS 的 root 会话中运行。\n' >&2; exit 1; fi

if ! $installed; then
    if ! command -v curl >/dev/null; then
        printf '缺少依赖：curl\n' >&2
        exit 1
    fi
    printf '正在下载 JC 程序与模板（%s）…\n' "$revision"
    source_url="https://raw.githubusercontent.com/LauritzWu/jc-vps/$revision"
    dir=$(mktemp -d)
    trap 'rm -rf -- "$dir"' EXIT
    mkdir "$dir/lib"
    for file in manager.sh client-template.json lib/firewall.sh lib/launcher.sh; do
        curl -4 -fsSL --retry 2 --connect-timeout 8 --max-time 25 "$source_url/$file" -o "$dir/$file"
    done
    if [[ -f ${BASH_SOURCE[0]:-} ]]; then
        cp -- "${BASH_SOURCE[0]}" "$dir/bootstrap.sh"
    else
        curl -4 -fsSL --retry 2 --connect-timeout 8 --max-time 25 "$source_url/bootstrap.sh" -o "$dir/bootstrap.sh"
    fi
    printf '%s\n' "$revision" >"$dir/revision"
fi
(cd "$dir" && sha256sum --status --strict -c <<'SHA256'
9ed7a0de648bc25cefadbd1bd19c8fed0b970fa5d3b5753ea21a99ece8280612  manager.sh
d96d8e1440c7b53ef47625820c77fe58c95a4ff0cef1f989d68c53ff099a7d7b  client-template.json
6dc765ad0e22eeeeed7d8edda757b79ab6cd67a4756970762a2ccb6c1f7fab42  lib/firewall.sh
d1c7f57d69da15af90ef773dbcab1b3dd2fb89f70c42675a89d9c73575a3ea04  lib/launcher.sh
SHA256
) || { printf 'JC 程序校验失败，请重新安装该版本。\n' >&2; exit 1; }
if [[ $action == --check ]]; then exit 0; fi
source "$dir/lib/launcher.sh"
if [[ $action == --rollback ]]; then
    jc_switch_bundle --rollback
    exit
fi
source "$dir/lib/firewall.sh"

duo() {
    bash "$dir/manager.sh" "$@" </dev/tty
}
five_service=$(bash "$dir/manager.sh" five-service)

pause_menu() {
    read -r -p '按回车返回菜单：' </dev/tty || true
}

choose_preset_name() {
    local -n chosen_name=$1
    local selection i
    shift
    local candidates=("$@")
    for i in "${!candidates[@]}"; do option "$((i + 1))" "${candidates[i]}"; done
    choose 1
    [[ $selection =~ ^[1-9]$ ]] && (( selection <= ${#candidates[@]} )) || return 1
    chosen_name=${candidates[selection-1]}
}

choose_preset_reality() {
    local -n target=$1
    local selection candidate i preferred='' auto=false
    shift
    if [[ ${1:-} == --auto ]]; then auto=true; shift; fi
    local candidates=("$@")
    if ! $auto; then
        heading 'VLESS · REALITY 握手目标'
        for i in "${!candidates[@]}"; do option "$((i + 1))" "${candidates[i]}"; done
        option 9 '自动探测可用目标'
        while true; do
            choose 9
            case "$selection" in
                0) return 1 ;;
                9) preferred=''; break ;;
                [1-8]) preferred=${candidates[selection-1]}; break ;;
                *) echo '无效选项。' ;;
            esac
        done
    fi
    if [[ -n $preferred ]]; then
        if duo reality-probe "$preferred"; then
            target=$preferred
            return 0
        fi
        printf '%s 未通过探测，自动尝试其他目标。\n' "$preferred"
    fi
    for candidate in "${candidates[@]}"; do
        [[ $candidate != "$preferred" ]] || continue
        printf '正在探测 %s…\n' "$candidate"
        if duo reality-probe "$candidate"; then
            target=$candidate
            return 0
        fi
    done
    echo '候选站点均未通过探测。请检查 VPS 出站 TCP 443 和 DNS。'
    return 2
}

five_deployed() {
    [[ -e /etc/$five_service/config.json || -e /etc/systemd/system/$five_service.service ]]
}

quick_install() {
    local domain ip ports='' uuid version='' answer port protocol resolved reality_target='' target_index candidate
    local mode=1 reality_sni='' preset_names='' preset_name automatic=false
    local reality_args=()
    local preset_values=() package_args=()
    local reality_targets=(aws.amazon.com www.microsoft.com www.cloudflare.com www.amazon.com dl.google.com www.samsung.com www.intel.com)
    local protocol_ports=() protocol_labels=('VLESS / REALITY (TCP)' 'VMess WS (TCP)' 'Hysteria 2 (UDP)' 'TUIC (UDP)' 'AnyTLS (TCP)')
    local selection port_mode index
    local transports=(tcp tcp udp udp tcp)
    if five_deployed; then
        echo '已检测到五协议配置。请到 4 管理服务，或到 5 查看节点与订阅。'
        return 0
    fi

    heading '一键安装 sing-box · 五协议'
    printf '%s\n' 'REALITY / VMess WS + TLS / Hysteria 2 / TUIC / AnyTLS' \
        '公信证书模式需要将站点域名解析到 VPS，并放行公网 TCP 80。'
    heading '1/5  官方内核'
    option 1 '使用已安装的官方内核；新机安装 APT 稳定版'
        option 2 '指定官方 APT 版本（运行中的 JC 服务会短暂重启）'
    choose 1
    case "$selection" in
        0) return 0 ;;
        1) ;;
        2)
            apt-cache madison sing-box || true
            read -r -p '完整 APT 版本号（0 返回）：' version </dev/tty || return 1
            [[ $version != 0 ]] || return 0
            [[ $version =~ ^[0-9][0-9A-Za-z.+:~\-]*$ ]] || { echo '版本号格式无效。'; return 1; } ;;
        *) echo '无效选项。'; return 1 ;;
    esac
    heading '2/5  域名和证书'
    option 1 '自有域名与公信证书'
    option 2 '无自有域名 · 全自动自签'
    choose 1
    case "$selection" in
        0) return 0 ;;
        1|2) mode=$selection ;;
        *) echo '无效选项。'; return 1 ;;
    esac
    if [[ $mode == 2 ]]; then
        domain=-
        package_args=(--no-caddy)
        option 1 '全自动（优先 IPv4，失败时尝试 IPv6）'
        option 2 '高级调整（手动填写 IPv4 / IPv6，按协议选站点）'
        choose 1
        case "$selection" in
            0) return 0 ;;
            1)
                automatic=true
                reality_args=(--auto)
                ip=$(duo detect-address 4 2>/dev/null) || ip=$(duo detect-address 6 2>/dev/null) ||
                    { echo '无法自动检测公网 IP，请返回模式二并选择高级调整。'; return 1; }
                preset_values=(www.bing.com www.bing.com www.bing.com www.bing.com)
                ;;
            2) ;;
            *) echo '无效选项。'; return 1 ;;
        esac
        choose_preset_reality reality_target "${reality_args[@]}" apple.com "${reality_targets[@]}" || {
            [[ $? == 1 ]] && return 0
            return 1
        }
        if ! $automatic; then
            printf '已选 REALITY 目标与 SNI：%s\n' "$reality_target"
            for protocol in 'VMess WS Host' 'Hysteria 2 SNI' 'TUIC SNI' 'AnyTLS SNI'; do
                heading "$protocol"
                choose_preset_name preset_name www.bing.com www.microsoft.com www.cloudflare.com www.amazon.com || return 0
                preset_values+=("$preset_name")
            done
        fi
        preset_names=$(IFS=,; printf '%s' "${preset_values[*]}")
    else
        heading 'REALITY 握手目标'
        option 1 '使用自己的域名作为 REALITY 目标'
        option 2 '从常用站点手动选择 REALITY 目标'
        option 3 '自动探测并选择常用 REALITY 目标'
        option 4 '手动输入其他 REALITY 目标域名'
        choose 1
        case "$selection" in
            0) return 0 ;;
            1) ;;
            2)
                heading 'REALITY 握手目标'
                for target_index in "${!reality_targets[@]}"; do
                    option "$((target_index + 1))" "${reality_targets[target_index]}"
                done
                choose 0
                case "$selection" in
                    0) return 0 ;;
                    [1-7]) reality_target=${reality_targets[selection-1]} ;;
                    *) echo '无效选项。'; return 1 ;;
                esac
                ;;
            3)
                echo '正在从 VPS 探测候选站点的 TLS 1.3 和 HTTP/2…'
                for candidate in "${reality_targets[@]}"; do
                    if duo reality-probe "$candidate"; then
                        reality_target=$candidate
                        break
                    fi
                done
                [[ -n $reality_target ]] || { echo '暂未找到可用目标，请重试或手动选择。'; return 1; }
                ;;
            4)
                read -r -p 'REALITY 目标域名（0 返回）：' reality_target </dev/tty || return 1
                [[ $reality_target != 0 ]] || return 0
                read -r -p "REALITY SNI（回车使用 $reality_target，0 返回）：" reality_sni </dev/tty || return 1
                [[ $reality_sni != 0 ]] || return 0
                duo reality-probe "$reality_target" "${reality_sni:-$reality_target}" ||
                    { echo '目标未通过 TLS 1.3 和 HTTP/2 检查。'; return 1; }
                ;;
            *) echo '无效选项。'; return 1 ;;
        esac
        if [[ -n $reality_target ]]; then
            printf 'REALITY 握手目标 %s:443 · REALITY SNI %s\n' "$reality_target" "${reality_sni:-$reality_target}"
            echo '请填写自己的站点域名，用于另外四个协议的 TLS 证书和 HTTPS 订阅。'
        fi
        read -r -p '自己的站点域名（0 返回）：' domain </dev/tty || return 1
        [[ $domain != 0 ]] || return 0
        [[ $domain =~ ^[a-z0-9][a-z0-9.-]*\.[a-z][a-z0-9-]*$ ]] || { echo '请输入有效的小写域名。'; return 1; }
        if [[ $domain == "$reality_target" ]]; then
            echo '站点域名和外部目标相同，请选择选项 1 使用本机 REALITY 目标。'
            return 1
        fi
    fi
    port_mode=1
    if ! $automatic; then
        read -r -p 'VPS 公网 IPv4 或 IPv6（0 返回）：' ip </dev/tty || return 1
        [[ $ip != 0 ]] || return 0
        heading '3/5  五协议端口'
        option 1 '自动选择五个可用端口'
        option 2 '手动指定五个端口'
        choose 1
        case "$selection" in
            0) return 0 ;;
            1|2) port_mode=$selection ;;
            *) echo '无效选项。'; return 1 ;;
        esac
        if [[ $port_mode == 2 ]]; then
            echo '每项回车自动选择 10000–65535 内的可用端口，输入 0 返回。'
        fi
    fi
    duo validate-install "$domain" "$ip" || return 1
    for index in "${!protocol_labels[@]}"; do
        protocol=${protocol_labels[index]}
        port=''
        if [[ $port_mode == 2 ]]; then
            while true; do
                read -r -p "$yellow$protocol 端口：$reset" port </dev/tty || return 1
                [[ $port != 0 ]] || return 0
                [[ -n $port ]] || break
                if [[ $port =~ ^[1-9][0-9]{0,4}$ ]] && (( port <= 65535 )); then
                    if [[ " ${protocol_ports[*]} " != *" $port "* ]]; then break; fi
                    echo '这个端口已填写，请换一个。'
                else
                    echo '请输入 1–65535，或按回车自动选择。'
                fi
            done
        fi
        if [[ -z $port ]]; then
            port=$(duo pick-port "${transports[index]}" "${protocol_ports[@]}") || return 1
            if ! $automatic; then printf '  %s 已自动选定：%s%s%s\n' "$protocol" "$green" "$port" "$reset"; fi
        fi
        protocol_ports+=("$port")
    done
    ports=$(IFS=,; printf '%s' "${protocol_ports[*]}")
    if $automatic; then
        read -r uuid </proc/sys/kernel/random/uuid || return 1
    else
        heading '4/5  节点凭据'
        option 1 '自动生成 UUID（回车默认）'
        option 2 '自定义 UUID'
        choose 1
        case "$selection" in
            0) return 0 ;;
            1) read -r uuid </proc/sys/kernel/random/uuid || return 1 ;;
            2)
                read -r -p "${yellow}请输入 UUID（0 返回）：$reset" uuid </dev/tty || return 1
                [[ $uuid != 0 ]] || return 0
                [[ -n $uuid ]] || { echo 'UUID 不能为空。'; return 1; } ;;
            *) echo '无效选项。'; return 1 ;;
        esac
    fi
    duo validate-install "$domain" "$ip" "$ports" "$uuid" || return 1
    printf '已确认 UUID：%s%s%s\n' "$green" "$uuid" "$reset"
    heading '5/5  确认安装'
    if [[ $mode == 2 ]]; then
        printf '无自有域名 · 节点地址 %s\nREALITY %s:443 · SNI %s\n' "$ip" "$reality_target" "$reality_target"
        printf 'VMess WS Host %s\nHysteria 2 SNI %s\nTUIC SNI %s\nAnyTLS SNI %s\n' "${preset_values[@]}"
        echo 'VMess WS 不启用 TLS。后三个协议使用公钥固定，请导入 sing-box JSON。'
    else
        printf '站点域名 %s · 节点地址 %s\n' "$domain" "$ip"
        if [[ -n $reality_target ]]; then
            printf 'REALITY %s:443 · SNI %s。HTTPS 订阅使用自有域名 TCP 8443。\n' \
                "$reality_target" "${reality_sni:-$reality_target}"
        fi
    fi
    for protocol in "${!protocol_labels[@]}"; do
        port=${protocol_ports[protocol]}
        printf '  %s：%s%s%s\n' "${protocol_labels[protocol]}" "$yellow" "$port" "$reset"
    done
    duo firewall-status || return 1
    option 1 '智能管理本机 UFW（默认）'
    option 2 '手动管理防火墙'
    choose 1
    local JC_FIREWALL_MODE=smart
    case "$selection" in
        1) ;;
        2) JC_FIREWALL_MODE=manual ;;
        *) return 0 ;;
    esac
    export JC_FIREWALL_MODE
    read -r -p "${yellow}开始安装？[Y/n，回车确认] $reset" answer </dev/tty || return 1
    [[ ${answer:-y} == [yY] ]] || return 0
    if [[ $mode == 1 ]] && ! certificate_ready "$domain"; then
        resolved=$(timeout 5 getent ahosts "$domain" | awk '$2 == "STREAM" && !seen[$1]++ {print $1}') || resolved=''
        if [[ -z $resolved ]]; then
            printf '%s域名 %s 尚未解析到可用地址。请检查 A/AAAA 记录后重试。%s\n' "$red" "$domain" "$reset" >&2
            return 1
        fi
        printf '当前 DNS 解析结果（应指向这台 VPS）\n%s\n' "$resolved"
    fi
    if [[ -n $version ]]; then
        duo packages "${package_args[@]}" --restart-managed --version "$version" || return 1
    elif [[ ! -x /usr/bin/sing-box ]] || { [[ $mode == 1 ]] && ! command -v caddy >/dev/null; }; then
        duo packages "${package_args[@]}" || return 1
    fi
    local target_args=()
    if [[ -n $reality_target ]]; then target_args=(--reality-target "$reality_target"); fi
    if [[ -n $reality_sni ]]; then target_args+=(--reality-sni "$reality_sni"); fi
    if [[ $mode == 2 ]]; then target_args+=(--preset-names "$preset_names"); fi
    if [[ $mode == 1 ]]; then target_args+=(--prepare-site yes); fi
    duo five "$domain" "$ip" --ports "$ports" --uuid "$uuid" "${target_args[@]}" || return 1
    printf '\n%s五协议安装成功 · 本机监听已确认 · 已启用开机自启%s\n' "$green" "$reset"
    echo '请在云防火墙放行上面列出的 TCP/UDP 端口，再从客户端逐条验证。'
    if [[ $mode == 2 ]]; then
        option 1 '生成 v2rayN 兼容链接和二维码（需确认）'
        option 2 '查看普通链接和公钥固定 JSON'
        option 3 '稍后查看'
        choose 1
        case "$selection" in
            1) duo five-share --v2rayn || return 1 ;;
            2) duo five-share || return 1 ;;
        esac
    else
        option 1 '查看节点链接和配置文件（含凭据）'
        option 2 '稍后在客户端与订阅菜单查看'
        choose 1
        if [[ $selection == 1 ]]; then duo five-share || return 1; fi
    fi
}

accent='' ink='' muted='' sketch='' green='' yellow='' red='' reset=''
if [[ -t 1 && "${TERM:-dumb}" != dumb && -z "${NO_COLOR:-}" ]]; then
    accent=$'\033[1;33m'; ink=$'\033[37m'; muted=$ink; sketch=$'\033[33m'
    green=$'\033[32m'; yellow=$'\033[33m'; red=$'\033[31m'; reset=$'\033[0m'
    if [[ ${COLORTERM:-} == truecolor || ${COLORTERM:-} == 24bit ]]; then
        if [[ ${JC_THEME:-dark} == light ]]; then
            accent=$'\033[1;38;2;128;85;46m'; ink=$'\033[38;2;52;42;33m'; muted=$'\033[38;2;101;90;80m'
            sketch=$'\033[38;2;125;88;57m'; green=$'\033[38;2;58;97;64m'
            yellow=$'\033[38;2;132;85;19m'; red=$'\033[38;2;152;63;55m'
        else
            accent=$'\033[1;38;2;232;192;141m'; ink=$'\033[38;2;237;226;209m'; muted=$'\033[38;2;182;173;160m'
            sketch=$'\033[38;2;215;183;143m'; green=$'\033[38;2;169;199;160m'
            yellow=$'\033[38;2;233;190;117m'; red=$'\033[38;2;236;163;152m'
        fi
    elif [[ $TERM == *256color* ]]; then
        if [[ ${JC_THEME:-dark} == light ]]; then
            accent=$'\033[1;38;5;94m'; ink=$'\033[38;5;235m'; muted=$'\033[38;5;240m'
            sketch=$'\033[38;5;94m'; green=$'\033[38;5;22m'; yellow=$'\033[38;5;94m'; red=$'\033[38;5;124m'
        else
            accent=$'\033[1;38;5;223m'; ink=$'\033[38;5;255m'; muted=$'\033[38;5;250m'
            sketch=$'\033[38;5;180m'; green=$'\033[38;5;150m'; yellow=$'\033[38;5;222m'; red=$'\033[38;5;174m'
        fi
    elif [[ ${JC_THEME:-dark} == light ]]; then
        ink=$'\033[30m'
        muted=$ink
    fi
fi

heading() { printf '\n%s%s%s\n' "$accent" "$1" "$reset"; }
option() { printf ' %s%s%s  %s%s%s\n' "$accent" "$1" "$reset" "${3:-$ink}" "$2" "$reset"; }
choose() {
    read -r -p "${yellow}请选择 [默认 $1，0 返回]：$reset" selection </dev/tty || exit 1
    selection=${selection:-$1}
}

address_menu() {
    local selection address
    heading '刷新节点地址'
    option 1 '检测公网 IPv4'
    option 2 '检测公网 IPv6'
    option 3 '手动输入公网地址'
    choose 0
    case "$selection" in
        0) return ;;
        1) address=--ipv4 ;;
        2) address=--ipv6 ;;
        3)
            read -r -p '公网 IPv4 或 IPv6（0 返回）：' address </dev/tty || return
            [[ $address != 0 ]] || return ;;
        *) echo '无效选项。'; return ;;
    esac
    duo five-address "$address" || true
}

client_menu() {
    local default_option
    while true; do
        heading '客户端与订阅'
        option 1 '查看节点链接和配置文件'
        option 2 '发布五协议单节点及聚合订阅'
        option 3 '查看五协议客户端验收步骤'
        option 4 '刷新节点地址（IPv4 / IPv6）'
        if [[ -s /etc/$five_service/local-tls.crt ]]; then
            option 5 'v2rayN 兼容链接与二维码（自签模式）'
        elif [[ -s /etc/$five_service/config.json ]]; then
            option 6 '启用固定 HTTPS 订阅入口（TCP 8443）'
        fi
        default_option=3
        if [[ -s /etc/$five_service/profiles/links.txt ]]; then default_option=1; fi
        choose "$default_option"
        case "$selection" in
            0) return ;;
            1) duo five-share || echo '请先完成五协议安装。' ;;
            2) duo five-share --publish || echo '发布未完成，请检查上方信息。' ;;
            3) printf '%s\n' '导入五协议节点链接，或将 sing-box JSON 导入客户端。' \
                   '逐条切换为活动节点并打开网页，确认连接和出口地址。' ;;
            4) address_menu ;;
            5) duo five-share --v2rayn || true ;;
            6) duo five-share --publish --fixed || echo '固定入口未启用，请检查上方信息。' ;;
            *) echo '无效选项。' ;;
        esac
    done
}

firewall_menu() {
    while true; do
        heading '本机与云防火墙'
        option 1 '查看本机监听和 UFW 状态'
        option 2 '向已启用的 UFW 添加 TCP 80/443、UDP 443'
        option 3 '按协议指定单个端口或端口范围'
        option 4 '放开全部本机入站（需明确确认）'
        choose 1
        case "$selection" in
            0) return ;;
            3|4)
                if ! command -v ufw >/dev/null || ! LC_ALL=C ufw status | grep -q '^Status: active'; then
                    echo '需要已启用的 UFW。云防火墙请在服务商后台配置。'
                    continue
                fi
                if [[ "$selection" == 4 ]]; then
                    read -r -p '所有监听服务都将暴露。输入 OPEN-ALL 确认：' answer </dev/tty || return
                    if [[ "$answer" == OPEN-ALL ]]; then
                        ufw insert 1 allow in from any comment 'JC open all' || true
                    fi
                else
                    read -r -p '端口和协议（如 8444/tcp 或 20000:20009/udp，0 返回）：' rule </dev/tty || return
                    if [[ "$rule" =~ ^[0-9]{1,5}(:[0-9]{1,5})?/(tcp|udp)$ ]]; then ufw allow "$rule" || true; fi
                fi ;;
            1)
                duo firewall-status || true
                ss -lntup '( sport = :22 or sport = :80 or sport = :443 or sport = :8443 )' || true
                if command -v ufw >/dev/null; then LC_ALL=C ufw status verbose || true; fi
                echo '云防火墙请在服务商后台放行相同端口。' ;;
            2)
                if ! command -v ufw >/dev/null || ! LC_ALL=C ufw status | grep -q '^Status: active'; then
                    echo '未发现正在运行的 UFW。请按实际防火墙和云平台配置处理。'
                    continue
                fi
                read -r -p '添加三条入站规则？[Y/N] ' answer </dev/tty || return
                if [[ "$answer" == y || "$answer" == Y ]]; then
                    ufw allow 80/tcp && ufw allow 443/tcp && ufw allow 443/udp && LC_ALL=C ufw status || true
                fi ;;
            *) echo '无效选项。' ;;
        esac
    done
}

core_menu() {
    while true; do
        heading '官方 sing-box 内核'
        option 1 '刷新并查看已安装版本和 APT 候选版本'
        option 2 '安装或升级官方稳定版'
        option 3 '安装指定的官方 APT 版本'
        choose 1
        case "$selection" in
            0) return ;;
            1) apt-get -o Acquire::ForceIPv4=true update && apt-cache policy sing-box || true ;;
            3)
                apt-cache madison sing-box || true
                read -r -p '输入完整版本号（0 返回）：' version </dev/tty || return
                [[ "$version" == 0 || -z "$version" ]] && continue
                read -r -p '切换版本并重启运行中的 JC 服务（连接会短暂中断）？[Y/N] ' answer </dev/tty || return
                if [[ "$answer" == y || "$answer" == Y ]]; then duo packages --restart-managed --version "$version" || true; fi ;;
            2)
                read -r -p '安装或升级 APT 稳定版（运行中的 JC 服务会短暂重启）？[Y/N] ' answer </dev/tty || return
                if [[ "$answer" == y || "$answer" == Y ]]; then
                    duo packages --restart-managed || true
                fi ;;
            *) echo '无效选项。' ;;
        esac
    done
}

install_shortcut() {
    local alias_path=/usr/local/bin/JC
    jc_install_launcher "$dir" "$installed" || return 1
    if [[ -L $alias_path && $(readlink -- "$alias_path") == jc ]]; then
        return 0
    fi
    if [[ -e $alias_path || -L $alias_path ]]; then
        printf '发现其他程序使用 %s，保留原文件。可继续使用 jc。\n' "$alias_path" >&2
        return 1
    fi
    ln -sT -- jc "$alias_path" || return 1
    echo 'JC 快捷命令已安装。'
}

init_tools() {
    local missing=() pair package tool
    for pair in jq:jq qrencode:qrencode openssl:openssl iproute2:ss util-linux:flock; do
        package=${pair%:*}; tool=${pair#*:}
        command -v "$tool" >/dev/null || missing+=("$package")
    done
    if (( ${#missing[@]} )); then
        apt-get -o Acquire::ForceIPv4=true update &&
            apt-get -o Acquire::ForceIPv4=true install -y "${missing[@]}" || return 1
    fi
    install_shortcut || printf '%s\n' '快捷命令安装未全部完成，仍可继续使用本次菜单。' >&2
}

shortcut_menu() {
    local target=/usr/local/bin/jc alias_path=/usr/local/bin/JC answer
    local shortcuts=()
    while true; do
        heading '管理 JC 快捷命令'
        option 1 '安装 jc / JC 快捷命令'
        option 2 '卸载 jc / JC 快捷命令（节点服务继续运行）'
        choose 1
        case "$selection" in
            0) return ;;
            1) install_shortcut || true ;;
            2)
                shortcuts=()
                if [[ -L $alias_path && $(readlink -- "$alias_path") == jc ]]; then
                    shortcuts+=("$alias_path")
                fi
                if [[ -f $target && ! -L $target ]] &&
                    grep -qxF -e '# Managed by JC' -e '# Managed by Lauritz Duo' "$target"; then
                    shortcuts+=("$target")
                fi
                if (( ! ${#shortcuts[@]} )); then
                    echo '未发现由 JC 安装的快捷命令。'
                    continue
                fi
                read -r -p '卸载 jc / JC 快捷命令？[Y/N] ' answer </dev/tty || return
                if [[ $answer == [yY] ]]; then
                    rm -f -- "${shortcuts[@]}" && echo '快捷命令已卸载。'
                fi ;;
            *) echo '无效选项。' ;;
        esac
    done
}


region_file="${XDG_CONFIG_HOME:-$HOME/.config}/jc/region"
legacy_region_file="${XDG_CONFIG_HOME:-$HOME/.config}/lauritz-duo/region"

set_region() {
    local value
    read -r -p '服务器地区（例如 Los Angeles, US；auto 恢复自动；0 返回）：' value </dev/tty || return
    [[ "$value" != 0 && -n "$value" ]] || return 0
    if [[ "$value" == auto ]]; then
        rm -f -- "$region_file" "${region_file}.auto" "$legacy_region_file"
        return
    fi
    if [[ "$value" =~ [[:cntrl:]] || ${#value} -gt 100 ]]; then
        echo '请输入不超过 100 字的地区名称。'
        return 1
    fi
    mkdir -p "$(dirname "$region_file")" && printf '%s\n' "$value" > "$region_file"
}

detect_region() {
    local cache="${region_file}.auto" key=$1 now stamp cached_key cached_value payload value
    now=$(date +%s)
    if [[ -r "$cache" ]]; then
        { IFS= read -r stamp; IFS= read -r cached_key; IFS= read -r cached_value; } < "$cache" || true
        if [[ "${stamp:-}" =~ ^[0-9]{1,12}$ && "${cached_key:-}" == "$key" ]] &&
            (( now >= stamp && now - stamp < 86400 )); then
            printf '%s' "${cached_value:-}"
            return
        fi
    fi
    payload=$(curl --noproxy '*' -4 -fsS --connect-timeout 2 --max-time 3 https://ipwho.is/ 2>/dev/null) ||
        payload=$(curl --noproxy '*' -6 -fsS --connect-timeout 2 --max-time 3 https://ipwho.is/ 2>/dev/null) || payload=''
    value=$(jq -er '
        select(.success == true) |
        [.city, .region, .country, .connection.isp] |
        reduce (.[] | strings | select(length > 0)) as $part
          ([]; if index($part) == null then . + [$part] else . end) |
        join(", ")
    ' <<<"$payload" 2>/dev/null) || value=''
    value=$(printf '%s' "$value" | tr -d '[:cntrl:]' | cut -c1-160)
    mkdir -p "$(dirname "$cache")" &&
        printf '%s\n%s\n%s\n' "$now" "$key" "$value" > "$cache" || true
    printf '%s' "$value"
}

vps_summary() {
    local mode=$1 os ipv4 ipv6 region kernel state autostart state_color
    os=$(awk -F= '$1=="PRETTY_NAME" {print substr($0,index($0,"=")+1); exit}' /etc/os-release 2>/dev/null || true)
    os=${os#\"}; os=${os%\"}
    state='未安装'
    state_color=''
    autostart=''
    if systemctl is-active --quiet "$five_service" 2>/dev/null; then
        state='运行中'
        state_color=$green
    elif [[ -s /etc/$five_service/config.json ]]; then
        state='未运行'
        state_color=$yellow
    fi
    if [[ $state != 未安装 ]]; then
        autostart=' · 开机自启未启用'
        if systemctl is-enabled --quiet "$five_service" 2>/dev/null; then autostart=' · 开机自启'; fi
    fi

    if [[ $mode == brief ]]; then
        printf ' %s%s%s\n' "$muted" "${os:-系统未知}" "$reset"
        printf ' %ssing-box     %s%s%s%s%s\n' "$ink" "${state_color:-$ink}" "$state" "$muted" "$autostart" "$reset"
        return
    fi

    region=''
    if [[ -r "$region_file" ]]; then IFS= read -r region < "$region_file" || true
    elif [[ -r "$legacy_region_file" ]]; then IFS= read -r region < "$legacy_region_file" || true; fi
    ipv4=$(ip -o -4 addr show scope global 2>/dev/null | awk '{sub(/\/.*/,"",$4); printf "%s%s", sep,$4; sep="  "}' || true)
    ipv6=$(ip -o -6 addr show scope global 2>/dev/null | awk '$0 !~ / tentative | dadfailed / {sub(/\/.*/,"",$4); printf "%s%s",sep,$4; sep="  "}' || true)
    if [[ -z "$region" ]]; then region=$(detect_region "$ipv4 | $ipv6"); fi
    region=$(printf '%s' "$region" | tr -d '[:cntrl:]')
    kernel=''
    if [[ -x /usr/bin/sing-box ]]; then
        kernel=$(/usr/bin/sing-box version 2>/dev/null | sed -n '1p' || true)
        kernel=${kernel#sing-box version }
    fi
    heading 'VPS 概况'
    printf ' 主机  %s    系统  %s\n' "$(hostname)" "${os:-未知}"
    printf ' Linux %s    架构  %s    sing-box  %s\n' "$(uname -r)" "$(uname -m)" "${kernel:-未检测到}"
    printf ' IPv4  %s\n IPv6  %s\n' "${ipv4:-未检测到}" "${ipv6:-未检测到}"
    printf ' 地区  %s\n 服务  五协议 %s%s%s%s\n' "${region:-未能识别（系统工具可手动覆盖）}" \
        "$state_color" "$state" "$reset" "$autostart"
}

status_menu() {
    local selection
    while true; do
        heading '服务状态'
        option 1 '查看服务状态和本机监听'
        option 2 '查看五协议最近 50 条运行日志'
        option 3 '实时跟随五协议日志（Ctrl+C 返回）'
        choose 1
        case "$selection" in
            0) return ;;
            1)
                vps_summary detail
                if [[ -s /etc/$five_service/config.json ]]; then
                    heading '五协议节点 · 配置端口'
                    duo five-summary || true
                fi
                heading '本机监听'
                duo status || true
                pause_menu ;;
            2) journalctl -u "$five_service.service" -n 50 --no-pager || true ;;
            3)
                trap ':' INT
                journalctl -u "$five_service.service" -n 20 --no-pager -f || true
                trap - INT ;;
            *) echo '无效选项。' ;;
        esac
    done
}

service_menu() {
    local selection answer kind port
    local port_kinds=(reality vmess hy2 tuic anytls)
    while true; do
        heading '服务管理'
        option 1 '启动或恢复五协议服务'
        option 2 '启用五协议开机自启（已有部署）'
        option 3 '更换单个五协议节点的端口'
        choose 1
        case "$selection" in
            0) return ;;
            1) systemctl start "$five_service" && echo '五协议服务已启动。' ;;
            3)
                heading '选择要换端口的协议'
                option 1 'REALITY (TCP)'
                option 2 'VMess WS (TCP)'
                option 3 'Hysteria 2 (UDP)'
                option 4 'TUIC (UDP)'
                option 5 'AnyTLS (TCP)'
                choose 0
                [[ $selection == [1-5] ]] || continue
                kind=${port_kinds[selection-1]}
                read -r -p '新端口（0 返回）：' port </dev/tty || return
                [[ $port != 0 ]] || continue
                printf '请先在云防火墙放行新端口。应用时五协议服务会短暂重启。\n'
                read -r -p '确认切换端口？[y/N] ' answer </dev/tty || return
                if [[ $answer == [yY] ]]; then duo five-port "$kind" "$port" || true; fi ;;
            2)
                read -r -p '启用五协议开机自启？[y/N] ' answer </dev/tty || return
                if [[ $answer == [yY] ]]; then
                    if systemctl is-active --quiet "$five_service"; then
                        systemctl enable "$five_service" && echo '已启用五协议开机自启。'
                    else echo '请先启动五协议服务。'; fi
                fi ;;
            *) echo '无效选项。' ;;
        esac
    done
}

tools_menu() {
    local selection answer
    while true; do
        heading '系统工具'
        option 1 '查看或更新官方内核'
        option 2 '安装或卸载 jc / JC 快捷命令'
        option 3 '手动覆盖服务器地区'
        option 4 '查看全部命令'
        option 5 '补齐快捷命令和基础组件'
        option 6 '完整卸载 sing-box 和 JC' "$red"
        choose 1
        case "$selection" in
            0) return ;;
            1) core_menu ;;
            2) shortcut_menu ;;
            3) set_region || true ;;
            4) duo --help ;;
            5)
                read -r -p '补齐快捷命令和缺失的基础组件？[Y/N] ' answer </dev/tty || return
                if [[ "$answer" == y || "$answer" == Y ]]; then init_tools || true; fi ;;
            6)
                if duo uninstall; then
                    printf '\n%s\n' '如需装回本次运行的版本，请复制下面两行。' "revision=$revision" \
                        's=$(curl -4fsSL -m 25 "https://raw.githubusercontent.com/LauritzWu/jc-vps/$revision/bootstrap.sh") && bash -c "$s" -- "$revision"'
                    exit 0
                fi ;;
            *) echo '无效选项。' ;;
        esac
    done
}

home_width() {
    local size rows columns
    size=$(stty size 2>/dev/null </dev/tty) || size=''
    read -r rows columns <<< "$size"
    [[ "$columns" =~ ^[1-9][0-9]{0,3}$ ]] || columns=${COLUMNS:-80}
    [[ "$columns" =~ ^[1-9][0-9]{0,3}$ ]] || columns=80
    if (( columns > 104 )); then columns=104; fi
    printf '%s' "$columns"
}

home_portrait() {
    case $1 in
        wide)
            cat <<'SHEPHERD'
               ⢠⣶⣄
              ⢠⢯⣿⣿⡄
             ⢠⣟⣾⡟⣿⣷  ⣴⣿
            ⢠⡟⣼⣿⡇⢹⣿⣀⡼⣽⣿
           ⢠⣿⡇⣿⣿⠇⢀⣿⣿⣷⣿⢿
          ⢰⣿⡗⡿⡞⣿⣇⢼⣿⣷⣇⣩⣟⣤⣀
         ⢀⣟⣿⣷⣧⣤⣼⠿⠛⣿⢋⣾⢿⣿⠛⠉⠳⢦⡀
        ⣠⣿⡇⢹⣿⡏⢿⣿⣷⣴⢟⣾⣧⠔⠓⣁⣔⣿⣷⢼⡆
       ⣠⣿⠿⣿⡀⢹⣷⢪⣿⣿⠟⣾⣿⣿⣷⢾⣟⠻⢿⣿⣷⣑⠤⣀
      ⣨⡿⠑⠁⠘⢱⣠⡿⠛⣿⣡⡾⠛⠉   ⠙⠷⠆⠉⣿⣏⣓⣶⣭⣔⣤⣄
     ⢀⣿⣷⣴⢂⣤⠾⠉⣴⣞⠿⠁  ⠚  ⣤⣄⣀⣴⣾⣿⣿⣿⣿⣿⣿⣿⣏⣽⣶
    ⢀⣽⣿⣟⣏⣿⡗  ⣥⢀  ⢀ ⡀ ⠚⠻⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡿⠇
   ⣠⣿⣿⣿⣿⣿⣾⣅⠄ ⢹⢇ ⠈⠙⠿⠟⢛⣿⣾⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⠟⠁
  ⠐⣻⢏⢉⣩⡝⠛⢿⣿⣤⡄ ⠙⠿⣷⡄   ⣰⣿⣿⠟⠛⠛⠋⠉⠉⠙⠉⠉
 ⢀⣼⣿⠟⠟⠋   ⠙⢿⣷⣿⣄⣄⠠⡙⢷⡀⢀⠿⠃⣿⠆
  ⡼⣋⣀⣤⢄⣀ ⠁⠁ ⠁⠙⠻⣿⣷⣿⠂ ⢠⢇ ⣸⣷
  ⠜⠉⠋⠑⠻⠷⠟⠷⣶⣤⠄  ⠈⠙⢿⣇⢠⢀⠁⢠⣿⠇
          ⠉⠉⠙⠛⠶⠷⣦⡁⠙⠻⣦⡀⣼⡇
                 ⠉   ⠁⠏
SHEPHERD
            ;;
        medium)
            cat <<'SHEPHERD'
            ⢠⣶⡄
           ⢠⢷⣿⣿⡀  ⣀
          ⢠⢿⣿⠟⣿⡇⢀⣾⣿
         ⢠⣿⣿⣿⡇⢹⣷⣿⣿⣿
        ⢰⣿⢿⣾⣿⣇⣾⣿⣿⣛⣿⣄
       ⢰⣟⣿⣽⣤⣼⡿⢻⡟⣽⠿⣿⠋⢙⡦⡀
      ⢠⣿⣇⢿⣿⢹⣿⣷⡿⣽⣿⣆⢉⣴⣿⣿⡞⡇
     ⢴⡿⠻⢷ ⢿⣵⣿⢟⣵⡿⠟⠟⠛⢮⣝⠿⣿⣮⣖⡤⢄⡀
    ⢰⣟⣅⡄⢀⡵⢟⣠⣿⠟⠁⢀⠄ ⢀⠈⢁⣤⣿⣷⣷⣿⣿⣿⡷⢦⡄
   ⢀⣿⣿⣟⣽⡍ ⢘⠁⠁    ⠴⢿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⠃
  ⣠⣿⣿⣿⣿⣼⣅ ⢐⢟⢀⠐⠟⠟⠓⣷⣾⣿⣿⣿⣿⣿⣿⣿⣿⣿⠟⠁
 ⠐⣿⣣⣭⡕⠉⠻⣿⣶⢀⠈⠛⢷⣄  ⣰⣿⣿⠉⠉⠉⠉⠉⠉⠁
 ⢞⡿⠛⠁ ⠐⢄⠌⠛⢿⣧⣦⣔⣝⠃ ⡏⠁⣿⡀
 ⢈⠶⠾⢫⣶⣤⣄⣄  ⠈⠛⢿⣷⢀⠐⠗⢀⣿⠃
        ⠛⠛⠶⠤⢤⣄⠙⠷⣇ ⣸⡇
             ⠈⠑  ⠑⠇⠁
SHEPHERD
            ;;
        compact)
            cat <<'SHEPHERD'
         ⣴⣦
        ⣰⣿⣿⡆⢀⣴
       ⣼⣿⣿⢸⣧⣾⣿
      ⣴⣟⠿⢿⣼⣿⣏⣿⣄⡀
     ⣼⡿⣿⢿⣿⣭⣧⣏⠿⢁⣼⣇⡄
    ⣼⠿⡇⢹⣾⣿⢿⡿⠿⠾⣝⡻⢷⣕⣄⢀
   ⣸⣧⣄⡤⢟⣵⠟⠉⠠ ⣠⣈⣥⣾⣿⣿⣿⣿⣗⡄
  ⣴⣿⣿⣿⠁ ⡤ ⢤⣤⣤⣝⣿⣿⣿⣿⣿⣿⣿⡟⠁
 ⢸⣏⣩⠟⠻⣧⣄⡙⠷⣄ ⢈⣿⣿⠛⠛⠛⠛⠋⠁
⠐⡿⣋⡁⡀⠐⠌⠛⠷⣶⣾⠁⢐⠁⣿
 ⠈⠉⠙⠛⠓⠶⢤⣀⣈⠻⣴⡈⢰⡟
         ⠉⠓ ⠙⠘⠁
SHEPHERD
            ;;
    esac
}

home_overview() {
    local health line
    vps_summary brief
    if [[ -s /etc/$five_service/config.json ]] && health=$(duo five-summary --brief); then
        while IFS= read -r line; do
            printf '%s%s%s\n' "$ink" "$line" "$reset"
        done <<<"$health"
    fi
}

home_banner() {
    local LC_ALL=C.UTF-8
    local width=$1 style art_width index row slot start
    local portrait=() title=() overview=()
    printf '\n'
    if [[ ${JC_BANNER:-} == plain ]] || (( width < 28 )); then
        printf ' %sJC%s · VPS 管理\n' "$accent" "$reset"
        heading '运行概况'
        home_overview
        return
    fi

    if (( width >= 84 )); then
        style=wide art_width=38
    elif (( width >= 54 )); then
        style=medium art_width=31
    else
        style=compact art_width=23
    fi
    mapfile -t portrait < <(home_portrait "$style")
    if (( width >= 66 )); then
        title=(
            "$accent  █████   ██████$reset"
            "$accent     ██  ██$reset"
            "$accent     ██  ██$reset"
            "$accent ██  ██  ██$reset"
            "$accent  ████    ██████$reset"
            ''
            "$accent  JC · VPS 管理$reset"
            "$muted  GERMAN SHEPHERD EDITION$reset"
        )
    elif (( width >= 43 )); then
        title=("$accent"'JC · VPS 管理'"$reset")
    fi
    if (( width >= 78 )); then
        mapfile -t overview < <(home_overview)
        title+=('' "$accent"'  运行概况'"$reset" "${overview[@]}")
    fi

    start=$(( (${#portrait[@]} - ${#title[@]}) / 2 ))
    for index in "${!portrait[@]}"; do
        row=${portrait[index]}
        slot=$((index - start))
        if (( slot >= 0 && slot < ${#title[@]} )) && [[ -n ${title[slot]} ]]; then
            printf ' %s%s%s%*s%s\n' "$sketch" "$row" "$reset" \
                "$((art_width + 4 - ${#row}))" '' "${title[slot]}"
        else
            printf ' %s%s%s\n' "$sketch" "$row" "$reset"
        fi
    done
    if (( ${#title[@]} == 0 )); then
        printf '\n %sJC%s · VPS 管理\n' "$accent" "$reset"
    fi
    if (( width < 78 )); then
        heading '运行概况'
        home_overview
    fi
}

home_pair() {
    local width=$1 left=$2 left_text=$3 right=$4 right_text=$5
    if (( width >= 80 )); then
        local LC_ALL=C.UTF-8
        # The labels in the left column contain only CJK characters.
        printf ' %s%s%s  %s%s%s%*s%s%s%s  %s%s%s\n' "$accent" "$left" "$reset" "$ink" "$left_text" "$reset" \
            "$((24 - 2 * ${#left_text}))" '' "$accent" "$right" "$reset" "$ink" "$right_text" "$reset"
    else
        option "$left" "$left_text"
        option "$right" "$right_text"
    fi
}

home_menu() {
    local width=$1 deployed=$2
    heading '管理菜单'
    if ! $deployed; then option 1 '一键安装 sing-box' "$green"; fi
    home_pair "$width" 3 '服务状态' 4 '服务管理'
    home_pair "$width" 5 '客户端与订阅' 6 '网络与防火墙'
    home_pair "$width" 7 '系统工具' 0 '退出'
    printf '\n'
}

if ! $installed; then init_tools; fi

while true; do
    width=$(home_width)
    home_banner "$width"
    deployed=false
    if five_deployed; then deployed=true; fi
    home_menu "$width" "$deployed"
    if $deployed; then
        while true; do
            read -r -p "${accent}输入菜单编号（0 退出）：$reset" selection </dev/tty || exit 1
            [[ -n $selection ]] && break
        done
    else
        read -r -p "${accent}请选择 [回车默认 1 安装，0 退出]：$reset" selection </dev/tty || exit 1
        selection=${selection:-1}
    fi
    case "$selection" in
        1)
            quick_install || echo '安装未完成，请查看上面的报错。'
            pause_menu ;;
        2) printf '%s\n' '完整卸载已移至「系统工具 → 6 完整卸载」。'; tools_menu ;;
        3) status_menu ;;
        4) service_menu ;;
        5) client_menu ;;
        6) firewall_menu ;;
        7) tools_menu ;;
        0) exit 0 ;;
        *) printf '%s\n' '无效选项。' >&2 ;;
    esac
done
