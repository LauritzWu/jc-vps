#!/usr/bin/env bash
set -euo pipefail
umask 077

revision=${1:-main}
if (( $# > 1 )) || [[ $revision != main && ! $revision =~ ^[0-9a-f]{40}$ ]]; then
    printf '用法：bootstrap.sh [完整 Git 提交 SHA]\n' >&2
    exit 2
fi

if (( EUID != 0 )); then printf '请在 VPS 的 root 会话中运行。\n' >&2; exit 1; fi
for dependency in curl; do
    if ! command -v "$dependency" >/dev/null; then
        printf '缺少依赖：%s\n' "$dependency" >&2
        exit 1
    fi
done

printf '正在下载 JC 程序与模板（%s）…\n' "$revision"
source_url="https://raw.githubusercontent.com/LauritzWu/lauritz-duo/$revision"
dir=$(mktemp -d)
trap 'rm -f "$dir/manager.sh" "$dir/client-template.json"; rmdir "$dir"' EXIT
for file in manager.sh client-template.json; do
    curl -4 -fsSL --retry 2 --connect-timeout 8 --max-time 25 "$source_url/$file" -o "$dir/$file"
done
(cd "$dir" && sha256sum -c <<'SHA256'
598cd9b97bae918b7c7bd82972a15f7c49480dfa355ad50020c9756760adad18  manager.sh
d96d8e1440c7b53ef47625820c77fe58c95a4ff0cef1f989d68c53ff099a7d7b  client-template.json
SHA256
)

duo() {
    bash "$dir/manager.sh" "$@" </dev/tty
}
five_service=$(duo five-service)

pause_menu() {
    read -r -p '按回车返回菜单：' </dev/tty || true
}

certificate_ready() {
    curl -s --noproxy '*' --max-time 2 \
        --resolve "$1:8443:127.0.0.1" "https://$1:8443/" -o /dev/null
}

wait_for_certificate() {
    local domain=$1 started=$2 deadline=$((SECONDS + 90)) next_update=$((SECONDS + 15))
    local logs listeners
    if certificate_ready "$domain"; then
        echo 'Caddy 公信证书已就绪。'
        return 0
    fi
    listeners=$(ss -H -lnt '( sport = :80 )') || return 1
    if [[ -z $listeners ]]; then
        printf '%s%s%s\n' "$red" '本机 TCP 80 未监听，Caddy 无法处理 HTTP 签发验证。' "$reset" >&2
        return 1
    fi
    echo '正在等待 Caddy 公信证书（最多约 90 秒）…'
    while (( SECONDS < deadline )); do
        if ! systemctl is-active --quiet caddy; then break; fi
        if certificate_ready "$domain"; then
            echo 'Caddy 公信证书已就绪。'
            return 0
        fi
        if (( SECONDS >= next_update )); then
            printf '仍在等待 %s 的签发结果…\n' "$domain"
            next_update=$((SECONDS + 15))
        fi
        sleep 1
    done
    printf '%s%s%s\n' "$red" '证书暂未就绪。请核对域名 A/AAAA 记录和公网 TCP 80。修正后选 6 重试。' "$reset" >&2
    logs=$(journalctl -u caddy --since "@$started" --no-pager -o cat 2>/dev/null | grep -F -- "$domain" | tail -n 8 || true)
    if [[ -z $logs ]]; then
        logs=$(journalctl -u caddy -n 8 --no-pager -o cat 2>/dev/null || true)
    fi
    if [[ -n $logs ]]; then printf '\nCaddy 最近的日志\n%s\n' "$logs" >&2; fi
    return 1
}

quick_install() {
    local domain ip ports='' uuid version='' answer detected port protocol resolved started reality_target='' target_index
    local reality_targets=(aws.amazon.com www.microsoft.com www.cloudflare.com www.amazon.com dl.google.com www.samsung.com www.intel.com)
    local protocol_ports=() protocol_labels=('VLESS / REALITY (TCP)' 'VMess WS (TCP)' 'Hysteria 2 (UDP)' 'TUIC (UDP)' 'AnyTLS (TCP)')
    local selection port_mode index
    local transports=(tcp tcp udp udp tcp)
    if [[ -e /etc/$five_service/config.json || -e /etc/systemd/system/$five_service.service ]]; then
        echo '已检测到五协议配置。请到 2 管理服务，或到 3 查看节点与订阅。'
        return 0
    fi

    heading '一键安装 sing-box · 五协议'
    printf '%s\n' 'REALITY / VMess WS + TLS / Hysteria 2 / TUIC / AnyTLS' \
        '请将域名直接解析到 VPS，并在云防火墙放行 TCP 80 供 Caddy 签发或续期。' \
        '已有主备服务可继续运行。新五协议使用另外分配的端口。'
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
    option 1 '使用自己的域名作为 REALITY 目标'
    option 2 '从常用站点选择 REALITY 目标'
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
            printf 'REALITY 握手目标 %s:443 · REALITY SNI %s\n' "$reality_target" "$reality_target"
            echo 'REALITY 的目标和 SNI 已选好。接下来请输入你自己的域名，用于另外四个协议的 TLS 证书和 HTTPS 订阅。'
            ;;
        *) echo '无效选项。'; return 1 ;;
    esac
    detected=$(jq -r '.inbounds[0].tls.server_name // empty' /etc/sing-box-reality/config.json 2>/dev/null || true)
    read -r -p "站点域名${detected:+ [回车使用 $detected]}（0 返回）：" domain </dev/tty || return 1
    [[ $domain != 0 ]] || return 0
    domain=${domain:-$detected}
    [[ $domain =~ ^[a-z0-9][a-z0-9.-]*\.[a-z][a-z0-9-]*$ ]] || { echo '请输入有效的小写域名。'; return 1; }
    read -r -p 'VPS 公网 IPv4 或 IPv6（0 返回）：' ip </dev/tty || return 1
    [[ $ip != 0 ]] || return 0
    duo validate-install "$domain" "$ip" || return 1

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
            printf '  %s 已自动选定：%s%s%s\n' "$protocol" "$green" "$port" "$reset"
        fi
        protocol_ports+=("$port")
    done
    ports=$(IFS=,; printf '%s' "${protocol_ports[*]}")
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
    duo validate-install "$domain" "$ip" "$ports" "$uuid" || return 1
    printf '已确认 UUID：%s%s%s\n' "$green" "$uuid" "$reset"
    heading '5/5  确认安装'
    printf '域名 %s · 节点地址 %s\n' "$domain" "$ip"
    if [[ -n $reality_target ]]; then
        printf 'REALITY 目标 %s:443。HTTPS 订阅发布后使用自有域名的 TCP 8443。\n' "$reality_target"
    fi
    for protocol in "${!protocol_labels[@]}"; do
        port=${protocol_ports[protocol]}
        printf '  %s：%s%s%s\n' "${protocol_labels[protocol]}" "$yellow" "$port" "$reset"
    done
    echo '安装后按输出放行各节点端口，再进行客户端验收。'
    read -r -p "${yellow}开始安装？[Y/n，回车确认] $reset" answer </dev/tty || return 1
    [[ ${answer:-y} == [yY] ]] || return 0
    if ! certificate_ready "$domain"; then
        resolved=$(timeout 5 getent ahosts "$domain" | awk '$2 == "STREAM" && !seen[$1]++ {print $1}') || resolved=''
        if [[ -z $resolved ]]; then
            printf '%s域名 %s 尚未解析到可用地址。请检查 A/AAAA 记录后重试。%s\n' "$red" "$domain" "$reset" >&2
            return 1
        fi
        printf '当前 DNS 解析结果（应指向这台 VPS）\n%s\n' "$resolved"
    fi
    if [[ -n $version ]]; then
        duo packages --restart-managed --version "$version" || return 1
    elif [[ ! -x /usr/bin/sing-box ]] || ! command -v caddy >/dev/null; then
        duo packages || return 1
    fi
    if ! certificate_ready "$domain"; then
        started=$(date +%s)
        duo site "$domain" && wait_for_certificate "$domain" "$started" || return 1
    else
        echo 'Caddy 公信证书已就绪，继续安装。'
    fi
    local target_args=()
    if [[ -n $reality_target ]]; then target_args=(--reality-target "$reality_target"); fi
    duo five "$domain" "$ip" --ports "$ports" --uuid "$uuid" "${target_args[@]}" || return 1
    printf '\n%s五协议安装成功 · 本机监听已确认%s\n' "$green" "$reset"
    echo '请在云防火墙放行上面列出的 TCP/UDP 端口。外网验收通过后，在主菜单 2 启用开机启动。'
    option 1 '查看五条节点链接和二维码（含凭据）'
    option 2 '稍后在客户端与订阅菜单查看'
    choose 1
    if [[ $selection == 1 ]]; then duo five-share || return 1; fi
}

if [[ -t 1 && "${TERM:-dumb}" != dumb && -z "${NO_COLOR:-}" ]]; then
    accent=$'\033[1;36m'; green=$'\033[1;32m'; yellow=$'\033[1;33m'; red=$'\033[1;31m'; reset=$'\033[0m'
else
    accent=''; green=''; yellow=''; red=''; reset=''
fi

heading() { printf '\n%s%s%s\n' "$accent" "$1" "$reset"; }
option() { printf ' %s%s.%s %s%s%s\n' "$green" "$1" "$reset" "${3:-$accent}" "$2" "$reset"; }
choose() {
    read -r -p "${yellow}请选择 [默认 $1，0 返回]：$reset" selection </dev/tty || exit 1
    selection=${selection:-$1}
}

node_links() {
    local links link
    links=$(duo links) || return 1
    printf '%s每条链接及其二维码均含凭据，请勿截图或转发。%s\n' "$yellow" "$reset"
    while IFS= read -r link; do
        heading "${link##*#}"
        printf '%s%s%s\n' "$yellow" "$link" "$reset"
        if command -v qrencode >/dev/null; then
            printf '%s' "$link" | qrencode -t ANSIUTF8 -m 2 || return 1
        fi
    done <<< "$links"
    if ! command -v qrencode >/dev/null; then
        echo '需要终端二维码时，请在客户端子菜单选 5 安装 qrencode。'
    fi
}

client_menu() {
    while true; do
        heading '客户端配置与验收'
        option 1 '显示两条独立的导入链接和二维码'
        option 2 '导出 sing-box JSON（固定 IPv4）'
        option 3 '发布或更新 HTTPS 订阅'
        option 4 '查看客户端验收步骤'
        option 5 '安装终端二维码工具 qrencode'
        option 6 '查看五协议节点链接和二维码'
        option 7 '发布五协议单节点及聚合订阅'
        local default_option=4
        if [[ -s /etc/$five_service/profiles/links.txt ]]; then default_option=6; fi
        choose "$default_option"
        case "$selection" in
            0) return ;;
            1) node_links || echo '请先部署主备并确认配置文件存在。' ;;
            2|3)
                read -r -p '请输入 VPS 公网 IPv4（0 返回）：' ip </dev/tty || return
                [[ "$ip" == 0 ]] && continue
                if [[ "$selection" == 2 ]]; then
                    duo export "$ip" "$HOME/jc-client-$(date +%s).json" || true
                else
                    duo publish "$ip" || true
                fi ;;
            4) printf '%s\n' '在 v2rayN 从剪贴板导入两条链接，或把导出的 JSON 导入 sing-box。' \
                   '逐条选中节点并打开境外网页，再查询出口 IPv4。两条都应显示 VPS 的公网 IPv4。' \
                   '实测通过后，在「安装与部署」选 4 设置主备开机启动。' ;;
            5)
                read -r -p '用 APT 安装 qrencode？[Y/N] ' answer </dev/tty || return
                if [[ "$answer" == y || "$answer" == Y ]]; then
                    apt-get install -y qrencode || true
                fi ;;
            6) duo five-share || echo '请先完成五协议安装。' ;;
            7) duo five-share --publish || echo '发布未完成，请检查上方信息。' ;;
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

custom_menu() {
    while true; do
        heading '自定义规则与备用端口'
        option 1 '为 Hysteria 2 更新国内目的地拒绝规则'
        option 2 '为 REALITY 更新国内目的地拒绝规则'
        option 3 '设置 Hysteria 2 UDP 跳跃范围'
        choose 1
        case "$selection" in
            0) return ;;
            1|2)
                service=sing-box-hy2
                [[ "$selection" == 2 ]] && service=sing-box-reality
                read -r -p "短暂重启 $service，请确认 SSH 走另一条线路 [Y/N]：" answer </dev/tty || return
                if [[ "$answer" == y || "$answer" == Y ]]; then duo rules "$service" || true; fi ;;
            3)
                read -r -p '输入 UDP 起止端口，用空格分隔（0 返回）：' first last </dev/tty || return
                [[ "$first" == 0 ]] || duo hopping "$first" "$last" || true ;;
            *) echo '无效选项。' ;;
        esac
    done
}

install_shortcut() {
    local target=/usr/local/bin/jc temp
    if [[ -e "$target" || -L "$target" ]]; then
        if [[ -f "$target" && ! -L "$target" && -x "$target" ]] &&
            grep -qxF -e '# Managed by JC' -e '# Managed by Lauritz Duo' "$target"; then
            if grep -qxF "revision=$revision" "$target"; then
                echo 'jc 快捷命令已安装。'
                return 0
            fi
        else
            echo '发现其他程序使用 /usr/local/bin/jc，保留原文件。' >&2
            return 1
        fi
    fi
    temp=$(mktemp /usr/local/bin/.jc.XXXXXX) || return 1
    if ! {
        printf '%s\n' '#!/usr/bin/env bash' '# Managed by JC' 'set -eu' "revision=$revision"
        cat <<'DUOSH'
f=$(mktemp)
trap 'rm -f "$f"' EXIT
curl -4 -fsSL --connect-timeout 8 --max-time 25 "https://raw.githubusercontent.com/LauritzWu/lauritz-duo/$revision/bootstrap.sh" -o "$f"
bash "$f" "$revision"
DUOSH
    } > "$temp" || ! chmod 0755 "$temp" || ! mv -fT -- "$temp" "$target"; then
        rm -f -- "$temp"
        return 1
    fi
    printf 'jc 快捷命令已安装（%s）。\n' "$revision"
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
    install_shortcut || printf '%s\n' '快捷命令未安装，仍可继续使用本次菜单。' >&2
}

shortcut_menu() {
    local target=/usr/local/bin/jc
    while true; do
        heading '管理 JC 快捷命令'
        option 1 '安装 jc 快捷命令'
        option 2 '卸载 jc 快捷命令（节点服务继续运行）'
        choose 1
        case "$selection" in
            0) return ;;
            1) install_shortcut || true ;;
            2)
                if [[ ! -f "$target" || -L "$target" ]] || ! grep -qxF -e '# Managed by JC' -e '# Managed by Lauritz Duo' "$target"; then
                    echo '未发现由 JC 安装的快捷命令。'
                    continue
                fi
                read -r -p '卸载 jc 快捷命令？[Y/N] ' answer </dev/tty || return
                if [[ "$answer" == y || "$answer" == Y ]]; then
                    rm -f -- "$target" && echo '快捷命令已卸载。'
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
    local os ipv4 ipv6 region kernel active unit state names
    os=$(awk -F= '$1=="PRETTY_NAME" {print substr($0,index($0,"=")+1); exit}' /etc/os-release 2>/dev/null || true)
    os=${os#\"}; os=${os%\"}
    ipv4=$(ip -o -4 addr show scope global 2>/dev/null | awk '{sub(/\/.*/,"",$4); printf "%s%s", sep,$4; sep="  "}' || true)
    ipv6=$(ip -o -6 addr show scope global 2>/dev/null | awk '$0 !~ / tentative | dadfailed / {sub(/\/.*/,"",$4); printf "%s%s",sep,$4; sep="  "}' || true)
    region=''
    if [[ -r "$region_file" ]]; then IFS= read -r region < "$region_file" || true
    elif [[ -r "$legacy_region_file" ]]; then IFS= read -r region < "$legacy_region_file" || true; fi
    if [[ -z "$region" ]]; then region=$(detect_region "$ipv4 | $ipv6"); fi
    region=$(printf '%s' "$region" | tr -d '[:cntrl:]')
    kernel=''
    if [[ -x /usr/bin/sing-box ]]; then
        kernel=$(/usr/bin/sing-box version 2>/dev/null | sed -n '1p' || true)
        kernel=${kernel#sing-box version }
    fi
    names=(REALITY HY2 五协议)
    active=''
    local idx=0
    for unit in sing-box-reality sing-box-hy2 "$five_service"; do
        state='未运行'
        if systemctl is-active --quiet "$unit" 2>/dev/null; then state='运行中'; fi
        active+="${names[idx]} $state  "
        idx=$((idx+1))
    done
    heading 'VPS 概况'
    printf ' 主机  %s    系统  %s\n' "$(hostname)" "${os:-未知}"
    printf ' Linux %s    架构  %s    sing-box  %s\n' "$(uname -r)" "$(uname -m)" "${kernel:-未检测到}"
    printf ' IPv4  %s\n IPv6  %s\n' "${ipv4:-未检测到}" "${ipv6:-未检测到}"
    printf ' 地区  %s\n 服务  %s\n' "${region:-未能识别（系统工具可手动覆盖）}" "$active"
}

service_menu() {
    local selection answer
    while true; do
        heading '服务管理'
        option 1 '启动或恢复五协议服务'
        option 2 '五协议设为开机启动（客户端验收后）'
        option 3 '启动已有 REALITY / HY2 主备'
        option 4 '已有主备设为开机启动（客户端验收后）'
        choose 1
        case "$selection" in
            0) return ;;
            1) systemctl start "$five_service" && echo '五协议服务已启动。' ;;
            3) systemctl start sing-box-reality sing-box-hy2 && echo '现有主备已启动。' ;;
            2|4)
                local services=("$five_service")
                if [[ $selection == 4 ]]; then services=(sing-box-reality sing-box-hy2); fi
                read -r -p '客户端验收已经通过？[Y/N] ' answer </dev/tty || return
                if [[ $answer == y || $answer == Y ]]; then
                    local service ready=1
                    for service in "${services[@]}"; do
                        systemctl is-active --quiet "$service" || ready=0
                    done
                    if (( ready )); then systemctl enable "${services[@]}" || true
                    else echo '请先启动服务并完成外网验收。'; fi
                fi ;;
            *) echo '无效选项。' ;;
        esac
    done
}

network_menu() {
    while true; do
        heading '网络与防火墙'
        option 1 '监听端口与防火墙'
        option 2 '国内规则与 UDP 跳跃'
        choose 1
        case "$selection" in
            0) return ;;
            1) firewall_menu ;;
            2) custom_menu ;;
            *) echo '无效选项。' ;;
        esac
    done
}

tools_menu() {
    while true; do
        heading '系统工具'
        option 1 '查看或更新官方内核'
        option 2 '安装或卸载 jc 快捷命令'
        option 3 '手动覆盖服务器地区'
        option 4 '查看全部命令'
        option 5 '补齐快捷命令和基础组件'
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
            *) echo '无效选项。' ;;
        esac
    done
}

home_width() {
    local size rows columns
    size=$(stty size 2>/dev/null </dev/tty) || size=''
    read -r rows columns <<< "$size"
    columns=${columns:-${COLUMNS:-80}}
    [[ "$columns" =~ ^[1-9][0-9]{0,3}$ ]] || columns=80
    if (( columns > 104 )); then columns=104; fi
    printf '%s' "$columns"
}

home_rule() {
    local padding
    printf -v padding '%*s' "$1" ''
    printf '%s%s%s\n' "$accent" "${padding// /─}" "$reset"
}

home_banner() {
    printf '\n'
    home_rule "$1"
    printf '%s' "$accent"
    if (( $1 >= 78 )); then
        cat <<'SHEPHERD'
           /\                 /\
          /  \               /  \
         / /\ \_____________/ /\ \
        / /  \               /  \ \            ███████╗  ██████╗
       /_/    \             /    \_\      ██╔══██╗██║   ██║██╔═══██╗
       \       ●           ●       /      ██║  ██║██║   ██║██║   ██║
        \         _______         /            ╚══██╔═╝ ██╔════╝
         \       /       \       /                ██║   ██║
          \_____ \___▼___/ _____/            ██   ██║   ██║
                \___/ \___/
                                          JC
                                          GERMAN SHEPHERD EDITION
SHEPHERD
    elif (( $1 >= 48 )); then
        cat <<'SHEPHERD'
       /\       /\
      /  \_____/  \
     /  ●       ●  \
     \      ▼      /    JC
      \____/ \____/     German Shepherd Edition
SHEPHERD
    else
        printf '%s\n' '  /\___/\' ' ( ^ Y ^ )' '  JC'
    fi
    printf '%s' "$reset"
    home_rule "$1"
}

init_tools

while true; do
    width=$(home_width)
    home_banner "$width"
    heading '管理菜单'
    option 1 '服务状态'
    option 2 '服务管理'
    option 3 '客户端与订阅'
    option 4 '网络与防火墙'
    option 5 '系统工具'
    option 6 '一键安装 sing-box' "$green"
    option 7 '完整卸载 JC' "$red"
    option 0 '退出'
    home_rule "$width"
    vps_summary
    if [[ ! -s /etc/$five_service/config.json &&
        ! -s /etc/sing-box-reality/config.json && ! -s /etc/sing-box-hy2/config.json ]]; then
        printf '%s尚未部署 JC 节点，请先选择 6 安装。%s\n' "$yellow" "$reset"
    fi
    home_rule "$width"
    read -r -p "${yellow}请选择 [回车默认 1，0 退出]：$reset" selection </dev/tty || exit 1
    case "${selection:-1}" in
        1) duo status || true ;;
        2) service_menu ;;
        3) client_menu ;;
        4) network_menu ;;
        5) tools_menu ;;
        6)
            quick_install || echo '安装未完成，请查看上面的报错。'
            pause_menu ;;
        7)
            if duo uninstall; then
                printf '\n%s\n' '如需装回本次运行的版本，请复制下面两行。' "revision=$revision" \
                    's=$(curl -4fsSL -m 25 "https://raw.githubusercontent.com/LauritzWu/jc-vps/$revision/bootstrap.sh") && bash -c "$s" -- "$revision"'
                exit 0
            fi ;;
        0) exit 0 ;;
        *) printf '%s\n' '无效选项。' >&2 ;;
    esac
done
