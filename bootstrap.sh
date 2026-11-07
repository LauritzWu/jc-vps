#!/usr/bin/env bash
set -euo pipefail
umask 077

for dependency in curl python3; do
    if ! command -v "$dependency" >/dev/null; then
        printf '缺少依赖：%s\n' "$dependency" >&2
        exit 1
    fi
done

printf '%s\n' '正在下载 Lauritz Duo 程序与模板…'
source_url='https://raw.githubusercontent.com/LauritzWu/lauritz-duo/main'
dir=$(mktemp -d)
trap 'rm -f "$dir/lauritz-duo.py" "$dir/client-template.json"; rmdir "$dir"' EXIT
for file in lauritz-duo.py client-template.json; do
    curl -4 -fsSL --retry 2 --connect-timeout 8 --max-time 25 "$source_url/$file" -o "$dir/$file"
done
(cd "$dir" && sha256sum -c <<'SHA256'
947cd1930e3a8b8235dc48f4e20224080cf190fa2fc85dbf1df3f0b84afbe964  lauritz-duo.py
d96d8e1440c7b53ef47625820c77fe58c95a4ff0cef1f989d68c53ff099a7d7b  client-template.json
SHA256
)

duo() {
    python3 "$dir/lauritz-duo.py" "$@" </dev/tty
}

setup() {
    local domain answer
    read -r -p '请输入已解析到 VPS 的域名：' domain </dev/tty || return 1
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

deploy_when_ready() {
    local domain=$1 attempt
    printf '%s\n' '正在等待 Caddy 证书，最多约 90 秒…'
    for ((attempt=1; attempt<=15; attempt++)); do
        if curl -fsS --noproxy '*' --max-time 3 \
            --resolve "$domain:8443:127.0.0.1" "https://$domain:8443/" -o /dev/null; then
            duo deploy "$domain"
            return $?
        fi
        sleep 3
    done
    printf '%s\n' '证书暂未就绪。检查 DNS 和公网 TCP 80，查看 journalctl -u caddy -n 30 --no-pager。修好后选 5 续跑。' >&2
    return 1
}

while true; do
    printf '\n%s\n' 'Lauritz Duo 预览版' \
        '1. 检查现有服务' '2. 发布或更新 HTTPS 订阅' '3. 查看全部命令' \
        '4. 新 VPS：引导安装主备' '5. 继续部署（网站已配置）' '0. 退出'
    read -r -p '请选择：' choice </dev/tty || exit 1
    case "$choice" in
        1) duo status || true ;;
        2)
            read -r -p '请输入 VPS 公网 IPv4：' ip </dev/tty || exit 1
            duo publish "$ip" || true
            ;;
        3) duo --help ;;
        4) setup || printf '%s\n' '安装未完成，请查看上面的报错。' ;;
        5)
            read -r -p '请输入站点域名：' domain </dev/tty || exit 1
            deploy_when_ready "$domain" || true
            ;;
        0) exit 0 ;;
        *) printf '%s\n' '无效选项。' >&2 ;;
    esac
done
