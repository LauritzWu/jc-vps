#!/usr/bin/env bash
set -euo pipefail
umask 077

if (( EUID != 0 )); then printf '请在 VPS 的 root 会话中运行。\n' >&2; exit 1; fi
for dependency in curl; do
    if ! command -v "$dependency" >/dev/null; then
        printf '缺少依赖：%s\n' "$dependency" >&2
        exit 1
    fi
done

printf '%s\n' '正在下载 Lauritz Duo 程序与模板…'
source_url='https://raw.githubusercontent.com/LauritzWu/lauritz-duo/main'
dir=$(mktemp -d)
trap 'rm -f "$dir/manager.sh" "$dir/client-template.json"; rmdir "$dir"' EXIT
for file in manager.sh client-template.json; do
    curl -4 -fsSL --retry 2 --connect-timeout 8 --max-time 25 "$source_url/$file" -o "$dir/$file"
done
(cd "$dir" && sha256sum -c <<'SHA256'
9656067b15800237ae05527d52e0240ebbe122afdec91a27bddec05a2dd2508b  manager.sh
d96d8e1440c7b53ef47625820c77fe58c95a4ff0cef1f989d68c53ff099a7d7b  client-template.json
SHA256
)

duo() {
    bash "$dir/manager.sh" "$@" </dev/tty
}

setup() {
    local domain answer
    read -r -p '请输入已解析到 VPS 的域名（0 返回）：' domain </dev/tty || return 1
    [[ "$domain" == 0 ]] && return 0
    if [[ ! "$domain" =~ ^[a-z0-9][a-z0-9.-]*\.[a-z][a-z0-9-]*$ ]]; then
        printf '%s\n' '请输入有效的小写域名。' >&2
        return 1
    fi
    printf '%s\n' '需要公网 TCP 80 用于签发证书，TCP/UDP 443 用于主备连接。'
    read -r -p '开始安装并配置站点？[y/N] ' answer </dev/tty || return 1
    [[ "$answer" == y || "$answer" == Y ]] || return 0
    duo packages || return 1
    duo site "$domain" || return 1
    deploy_when_ready "$domain"
}

quick_install() {
    local answer
    if [[ -f /etc/sing-box-reality/config.json && -f /etc/sing-box-hy2/config.json ]]; then
        read -r -p '检测到主备配置，安装官方软件包并启动现有主备？[y/N] ' answer </dev/tty || return 1
        [[ "$answer" == y || "$answer" == Y ]] || return 0
        duo packages && systemctl start sing-box-reality sing-box-hy2
    else
        setup
    fi
}

deploy_when_ready() {
    local domain=$1 attempt
    printf '%s\n' '正在等待 Caddy 证书，最多约 90 秒…'
    for ((attempt=1; attempt<=15; attempt++)); do
        if curl -fs --noproxy '*' --max-time 3 \
            --resolve "$domain:8443:127.0.0.1" "https://$domain:8443/" -o /dev/null; then
            duo deploy "$domain"
            return $?
        fi
        sleep 3
    done
    printf '%s\n' '证书暂未就绪。检查 DNS 和公网 TCP 80，查看 journalctl -u caddy -n 30 --no-pager。修好后在「安装与部署」选 2 续跑。' >&2
    return 1
}


if [[ -t 1 && "${TERM:-dumb}" != dumb && -z "${NO_COLOR:-}" ]]; then
    accent=$'\033[1;36m'; green=$'\033[1;32m'; reset=$'\033[0m'
else
    accent=''; green=''; reset=''
fi

heading() { printf '\n%s%s%s\n' "$accent" "$1" "$reset"; }
option() { printf ' %s%s.%s %s\n' "$green" "$1" "$reset" "$2"; }
choose() {
    read -r -p "请选择 [默认 $1，0 返回]：" selection </dev/tty || exit 1
    selection=${selection:-$1}
}

node_links() {
    local links link
    links=$(duo links) || return 1
    printf '%s\n' '每条链接及其二维码均含凭据，请勿截图或转发。'
    while IFS= read -r link; do
        heading "${link##*#}"
        printf '%s\n' "$link"
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
        choose 4
        case "$selection" in
            0) return ;;
            1) node_links || echo '请先部署主备并确认配置文件存在。' ;;
            2|3)
                read -r -p '请输入 VPS 公网 IPv4（0 返回）：' ip </dev/tty || return
                [[ "$ip" == 0 ]] && continue
                if [[ "$selection" == 2 ]]; then
                    duo export "$ip" "$HOME/lauritz-duo-client-$(date +%s).json" || true
                else
                    duo publish "$ip" || true
                fi ;;
            4) printf '%s\n' '在 v2rayN 从剪贴板导入两条链接，或把导出的 JSON 导入 sing-box。' \
                   '逐条选中节点并打开境外网页，再查询出口 IPv4。两条都应显示 VPS 的公网 IPv4。' \
                   '实测通过后，在「安装与部署」选 4 设置主备开机启动。' ;;
            5)
                read -r -p '用 APT 安装 qrencode？[y/N] ' answer </dev/tty || return
                if [[ "$answer" == y || "$answer" == Y ]]; then
                    apt-get install -y qrencode || true
                fi ;;
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
                        ufw insert 1 allow in from any comment 'Lauritz Duo open all' || true
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
                read -r -p '添加三条入站规则？[y/N] ' answer </dev/tty || return
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
                read -r -p '安装该版本（可能降级），确认？[y/N] ' answer </dev/tty || return
                if [[ "$answer" == y || "$answer" == Y ]]; then duo packages --version "$version" || true; fi ;;
            2)
                read -r -p '安装或升级 APT 稳定版？[y/N] ' answer </dev/tty || return
                if [[ "$answer" == y || "$answer" == Y ]]; then
                    duo packages || true
                    echo '已有服务请在备用线路可用时分别重启并复测，以加载新程序。'
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
                read -r -p "短暂重启 $service，请确认 SSH 走另一条线路 [y/N]：" answer </dev/tty || return
                if [[ "$answer" == y || "$answer" == Y ]]; then duo rules "$service" || true; fi ;;
            3)
                read -r -p '输入 UDP 起止端口，用空格分隔（0 返回）：' first last </dev/tty || return
                [[ "$first" == 0 ]] || duo hopping "$first" "$last" || true ;;
            *) echo '无效选项。' ;;
        esac
    done
}

install_shortcut() {
    local target=/usr/local/bin/duo temp
    if [[ -e "$target" || -L "$target" ]]; then
        if [[ -f "$target" && ! -L "$target" && -x "$target" ]] &&
            grep -qxF '# Managed by Lauritz Duo' "$target"; then
            echo 'duo 快捷命令已安装。'
            return 0
        fi
        echo '发现其他程序使用 /usr/local/bin/duo，保留原文件。' >&2
        return 1
    fi
    temp=$(mktemp) || return 1
    cat > "$temp" <<'DUOSH'
#!/usr/bin/env bash
# Managed by Lauritz Duo
set -eu
f=$(mktemp)
trap 'rm -f "$f"' EXIT
curl -4 -fsSL --connect-timeout 8 --max-time 25 https://raw.githubusercontent.com/LauritzWu/lauritz-duo/main/bootstrap.sh -o "$f"
bash "$f"
DUOSH
    if ! install -m 0755 "$temp" "$target"; then
        rm -f -- "$temp"
        return 1
    fi
    rm -f -- "$temp"
    echo 'duo 快捷命令已安装。'
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
    local target=/usr/local/bin/duo
    while true; do
        heading '管理 Lauritz Duo 快捷命令'
        option 1 '安装 duo 快捷命令'
        option 2 '卸载 duo 快捷命令（主备服务继续运行）'
        choose 1
        case "$selection" in
            0) return ;;
            1) install_shortcut || true ;;
            2)
                if [[ ! -f "$target" || -L "$target" ]] || ! grep -qxF '# Managed by Lauritz Duo' "$target"; then
                    echo '未发现由 Lauritz Duo 安装的快捷命令。'
                    continue
                fi
                read -r -p '卸载 duo 快捷命令？[y/N] ' answer </dev/tty || return
                if [[ "$answer" == y || "$answer" == Y ]]; then
                    rm -f -- "$target" && echo '快捷命令已卸载。'
                fi ;;
            *) echo '无效选项。' ;;
        esac
    done
}


five_menu() {
    local domain ip mode ports id
    while true; do
        heading '五协议部署与分享'
        option 1 '创建独立的五协议服务'
        option 2 '显示五条节点链接及独立二维码'
        option 3 '发布单节点与聚合 HTTPS 订阅'
        choose 2
        case "$selection" in
            0) return ;;
            1)
                read -r -p '站点域名（已签发证书，0 返回）：' domain </dev/tty || return
                [[ "$domain" == 0 ]] && continue
                read -r -p 'VPS 公网 IPv4（0 返回）：' ip </dev/tty || return
                [[ "$ip" == 0 ]] && continue
                option 1 '随机选五个未被监听的端口'
                option 2 '按 REALITY,VMess,HY2,TUIC,AnyTLS 指定五个端口'
                choose 1
                mode=$selection; ports=''
                case "$mode" in
                    0) continue ;;
                    1) ;;
                    2) read -r -p '五个端口，用英文逗号隔开（0 返回）：' ports </dev/tty || return
                       [[ "$ports" == 0 || -z "$ports" ]] && continue ;;
                    *) continue ;;
                esac
                read -r -p 'UUID（回车自动生成，0 返回）：' id </dev/tty || return
                [[ "$id" == 0 ]] && continue
                duo five "$domain" "$ip" --ports "$ports" --uuid "$id" || true ;;
            2) duo five-share || true ;;
            3) duo five-share --publish || true ;;
            *) echo '无效选项。' ;;
        esac
    done
}

region_file="${XDG_CONFIG_HOME:-$HOME/.config}/lauritz-duo/region"

set_region() {
    local value
    read -r -p '服务器地区（例如 Los Angeles, US；auto 恢复自动；0 返回）：' value </dev/tty || return
    [[ "$value" != 0 && -n "$value" ]] || return 0
    if [[ "$value" == auto ]]; then rm -f -- "$region_file" "${region_file}.auto"; return; fi
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
    if [[ -r "$region_file" ]]; then IFS= read -r region < "$region_file" || true; fi
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
    for unit in sing-box-reality sing-box-hy2 sing-box-lauritz-five; do
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

deploy_menu() {
    local domain answer
    while true; do
        heading '安装与部署'
        option 1 '新 VPS：引导安装主备'
        option 2 '继续部署（网站已配置）'
        option 3 '五协议部署与分享'
        option 4 '主备开机启动（客户端验收后）'
        choose 1
        case "$selection" in
            0) return ;;
            1) setup || echo '安装未完成，请查看上面的报错。' ;;
            2)
                read -r -p '请输入站点域名（0 返回）：' domain </dev/tty || return
                [[ "$domain" == 0 ]] || deploy_when_ready "$domain" || true ;;
            3) five_menu ;;
            4)
                read -r -p '两条线路已通过客户端验收？[y/N] ' answer </dev/tty || return
                if [[ "$answer" == y || "$answer" == Y ]]; then
                    systemctl is-active --quiet sing-box-reality &&
                        systemctl is-active --quiet sing-box-hy2 &&
                        systemctl enable sing-box-reality sing-box-hy2 || echo '请先确认主备都在运行。'
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
        option 2 '安装或卸载 duo 快捷命令'
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
                read -r -p '补齐快捷命令和缺失的基础组件？[y/N] ' answer </dev/tty || return
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
        / /  \               /  \ \       ██████╗ ██╗   ██╗ ██████╗
       /_/    \             /    \_\      ██╔══██╗██║   ██║██╔═══██╗
       \       ●           ●       /      ██║  ██║██║   ██║██║   ██║
        \         _______         /       ██║  ██║██║   ██║██║   ██║
         \       /       \       /        ██████╔╝╚██████╔╝╚██████╔╝
          \_____ \___▼___/ _____/         ╚═════╝  ╚═════╝  ╚═════╝
                \___/ \___/
                                          LAURITZ DUO
                                          GERMAN SHEPHERD EDITION
SHEPHERD
    elif (( $1 >= 48 )); then
        cat <<'SHEPHERD'
       /\       /\
      /  \_____/  \
     /  ●       ●  \
     \      ▼      /    LAURITZ DUO
      \____/ \____/     German Shepherd Edition
SHEPHERD
    else
        printf '%s\n' '  /\___/\' ' ( ^ Y ^ )' '  LAURITZ DUO'
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
    option 2 '安装与部署'
    option 3 '客户端与订阅'
    option 4 '网络与防火墙'
    option 5 '系统工具'
    option 6 '一键安装 sing-box'
    option 7 '完整卸载 Lauritz Duo'
    option 0 '退出'
    home_rule "$width"
    vps_summary
    home_rule "$width"
    read -r -p '请选择 [回车默认 1，0 退出]：' selection </dev/tty || exit 1
    case "${selection:-1}" in
        1) duo status || true ;;
        2) deploy_menu ;;
        3) client_menu ;;
        4) network_menu ;;
        5) tools_menu ;;
        6) quick_install || echo '安装未完成，请查看上面的报错。' ;;
        7) if duo uninstall; then exit 0; fi ;;
        0) exit 0 ;;
        *) printf '%s\n' '无效选项。' >&2 ;;
    esac
done
