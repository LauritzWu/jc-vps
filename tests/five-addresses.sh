#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT
source <(sed '/^command_name=/,$d' "$root/manager.sh")
template="$root/client-template.json"

ipv4=1.1.1.1
ipv6=2606:4700::1
ip() { [[ $* == "-6 route get $ipv6" ]]; }
preflight() { cert="$test_dir/test.crt"; }
ensure_unused() { :; }
ss() { :; }
reality_keys() { private=test-private; public=test-public; }
check() { jq -e 'type == "object"' "$1" >/dev/null; }
new_service() { mkdir -m 700 -- "$test_dir/$1"; }
cfg() { printf '%s/%s/config.json\n' "$test_dir" "$1"; }
private_put() { cat >"$1"; }
unit_file() { :; }
systemctl() { :; }
socket_ready() { :; }

for host in "$ipv4" "$ipv6"; do
    scratch="$test_dir/scratch-$host"
    mkdir "$scratch"
    five="five-$host"
    five_deploy example.com "$host" 443,8444,8445,8446,8447 12345678-1234-1234-1234-123456789abc
    dir="$test_dir/$five"
    listen=0.0.0.0
    uri_host=$host
    if [[ $host == "$ipv6" ]]; then listen=::; uri_host="[$host]"; fi
    jq -e --arg listen "$listen" '.inbounds | length == 5 and all(.[]; .listen == $listen)' "$dir/config.json" >/dev/null
    jq -e --arg host "$host" '[.outbounds[] | select(has("server"))] |
        length == 5 and all(.[]; .server == $host and .tls.server_name == "example.com")' "$dir/profiles/all.json" >/dev/null
    for endpoint in "vless 443" "hysteria2 8445" "tuic 8446" "anytls 8447"; do
        read -r scheme port <<<"$endpoint"
        grep -F "$scheme://" "$dir/profiles/links.txt" | grep -F "@$uri_host:$port?" >/dev/null
    done
    sed -n 's/^vmess:\/\///p' "$dir/profiles/links.txt" | base64 -d |
        jq -e --arg host "$host" '.add == $host and .sni == "example.com"' >/dev/null
    printf '%s configuration and links passed\n' "$host"
done

profiles="$test_dir/published"
mkdir -p "$profiles/five"
cp "$dir/profiles/"*.json "$dir/profiles/"*.sub "$profiles/five/"
auth_required() { :; }
put() { cat >"$1"; }
change_five_port reality 28443
grep -F "@[$ipv6]:28443?" "$dir/profiles/links.txt" >/dev/null
jq -e '.inbounds[0].listen_port == 28443 and .inbounds[1].listen_port == 8444' "$dir/config.json" >/dev/null
jq -e '.outbounds[] | select(.type == "vless") | .server_port == 28443' "$profiles/five/all.json" >/dev/null
base64 -d "$profiles/five/all.sub" | cmp - "$dir/profiles/links.txt"

rm -rf -- "$scratch/port"
change_five_port vmess 28444
sed -n 's/^vmess:\/\///p' "$dir/profiles/links.txt" | base64 -d |
    jq -e --arg host "$ipv6" '.port == "28444" and .add == $host' >/dev/null

rm -rf -- "$scratch/port"
before=$(sha256sum "$dir/config.json" "$dir/profiles/links.txt" "$profiles/five/all.json")
if (
    trap cleanup EXIT
    restart_managed() { [[ $(jq -r '.inbounds[2].listen_port' "$(cfg "$five")") == 8445 ]]; }
    change_five_port hy2 28445
) >"$test_dir/rollback.log" 2>&1; then
    echo 'Expected restart failure'
    exit 1
fi
grep -F '已恢复原监听端口和客户端配置' "$test_dir/rollback.log" >/dev/null || { cat "$test_dir/rollback.log"; exit 1; }
[[ $(sha256sum "$dir/config.json" "$dir/profiles/links.txt" "$profiles/five/all.json") == "$before" ]]
echo 'IPv6 URI, VMess, published profiles, and port rollback passed'

for bad in '[2606:4700::1]' '2606::::1' 'fe80::1' '::1'; do
    if (valid_node_address "$bad") >/dev/null 2>&1; then
        printf 'Accepted invalid node address %s\n' "$bad" >&2
        exit 1
    fi
done
