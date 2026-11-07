#!/usr/bin/env bash
set -euo pipefail
umask 077

for dependency in curl python3; do
    if ! command -v "$dependency" >/dev/null; then
        printf '缺少依赖：%s\n' "$dependency" >&2
        exit 1
    fi
done

source_url='https://raw.githubusercontent.com/LauritzWu/lauritz-duo/5134849d01497a877cb951295c737d733aeda818'
dir=$(mktemp -d)
trap 'rm -f "$dir/lauritz-duo.py" "$dir/client-template.json"; rmdir "$dir"' EXIT
for file in lauritz-duo.py client-template.json; do
    curl -fsSL --connect-timeout 10 --max-time 40 "$source_url/$file" -o "$dir/$file"
done

printf '%s\n' 'Lauritz Duo 预览版' '1. 检查现有服务' '2. 发布或更新 HTTPS 订阅' '3. 查看全部命令' '0. 退出'
read -r -p '请选择：' choice </dev/tty
case "$choice" in
    1) python3 "$dir/lauritz-duo.py" status </dev/tty ;;
    2)
        read -r -p '请输入 VPS 公网 IPv4：' ip </dev/tty
        python3 "$dir/lauritz-duo.py" publish "$ip" </dev/tty
        ;;
    3) python3 "$dir/lauritz-duo.py" --help ;;
    0) exit 0 ;;
    *) printf '%s\n' '无效选项。' >&2; exit 1 ;;
esac
