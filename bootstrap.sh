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
source_url='https://raw.githubusercontent.com/LauritzWu/lauritz-duo/5134849d01497a877cb951295c737d733aeda818'
dir=$(mktemp -d)
trap 'rm -f "$dir/lauritz-duo.py" "$dir/client-template.json"; rmdir "$dir"' EXIT
for file in lauritz-duo.py client-template.json; do
    curl -4 -fsSL --connect-timeout 8 --max-time 25 "$source_url/$file" -o "$dir/$file"
done

printf '%s\n' 'Lauritz Duo 预览版' '1. 检查现有服务' '2. 发布或更新 HTTPS 订阅' '3. 查看全部命令' '4. 新 VPS：安装官方软件包并配置网站' '5. 新 VPS：证书就绪后部署双协议' '0. 退出'
read -r -p '请选择：' choice </dev/tty
case "$choice" in
    1) python3 "$dir/lauritz-duo.py" status </dev/tty ;;
    2)
        read -r -p '请输入 VPS 公网 IPv4：' ip </dev/tty
        python3 "$dir/lauritz-duo.py" publish "$ip" </dev/tty
        ;;
    3) python3 "$dir/lauritz-duo.py" --help ;;
    4)
        read -r -p '请输入已解析到 VPS 的域名：' domain </dev/tty
        python3 "$dir/lauritz-duo.py" packages </dev/tty
        python3 "$dir/lauritz-duo.py" site "$domain" </dev/tty
        ;;
    5)
        read -r -p '请输入已签发证书的域名：' domain </dev/tty
        python3 "$dir/lauritz-duo.py" deploy "$domain" </dev/tty
        ;;
    0) exit 0 ;;
    *) printf '%s\n' '无效选项。' >&2; exit 1 ;;
esac
