#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT
source <(sed '/^command_name=/,$d' "$root/manager.sh")
template="$root/client-template.json"
export XDG_CONFIG_HOME="$test_dir/settings"
mkdir -p "$XDG_CONFIG_HOME/jc"
printf '0\nkey\nFrankfurt, Hesse, Germany\n' >"$XDG_CONFIG_HOME/jc/region.auto"

ipv4=1.1.1.1
ipv6=2606:4700::1
ip() { [[ $* == "-6 route get $ipv6" || $* == "-6 route get 2606:4700::2" ]]; }
timeout() {
    [[ $* == *'s_client -connect www.microsoft.com:443'* ]] || return 1
    printf 'ALPN protocol: h2\n'
}
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
    grep -F '#VLESS-REALITY-Frankfurt' "$dir/profiles/links.txt" >/dev/null
    jq -e '.outbounds[0].default == "VLESS-REALITY-Frankfurt" and
        .outbounds[1].tag == "VLESS-REALITY-Frankfurt" and .outbounds[0].outbounds[4] == "AnyTLS-Frankfurt"' \
        "$dir/profiles/all.json" >/dev/null
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
if (change_five_address 1.0.0.1 <<<y) >/dev/null 2>&1; then
    echo 'Accepted an IPv4 address on the IPv6 listener' >&2
    exit 1
fi
change_five_address 2606:4700::2 <<<n
[[ $(sha256sum "$dir/config.json" "$dir/profiles/links.txt" "$profiles/five/all.json") == "$before" ]]
(
    scratch=$(mktemp -d "$test_dir/address.XXXXXX")
    trap cleanup EXIT
    curl() { printf '%s\n' '{"success":true,"ip":"2606:4700::2"}'; }
    change_five_address --ipv6 <<<y
)
grep -F '@[2606:4700::2]:28443?' "$dir/profiles/links.txt" >/dev/null
sed -n 's/^vmess:\/\///p' "$dir/profiles/links.txt" | base64 -d |
    jq -e '.add == "2606:4700::2" and .port == "28444" and .sni == "example.com"' >/dev/null
jq -e '[.outbounds[] | select(has("server_port"))] |
    length == 5 and all(.[]; .server == "2606:4700::2")' "$profiles/five/all.json" >/dev/null
base64 -d "$profiles/five/all.sub" | cmp - "$dir/profiles/links.txt"
[[ $(sha256sum "$dir/config.json") == "$(head -n1 <<<"$before")" ]]
caddyfile="$test_dir/Caddyfile"
cat >"$caddyfile" <<'CADDY'
example.com:8443 {
    handle_path /profiles/five/* {
        file_server
    }
}
CADDY
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=example.com \
    -keyout "$test_dir/test.key" -out "$test_dir/test.crt" >/dev/null 2>&1
summary=$(five_summary)
grep -Eq 'REALITY +TCP 28443 +SNI: example\.com' <<<"$summary"
grep -Eq 'VMess WS +TCP 28444' <<<"$summary"
grep -Eq 'Hysteria 2 +UDP 8445' <<<"$summary"
grep -F '距到期约' <<<"$summary" >/dev/null
grep -F '已发布 · TCP 28443' <<<"$summary" >/dev/null
if grep -Eq '12345678-1234-1234-1234-123456789abc|test-private|vless://' <<<"$summary"; then
    echo 'Node overview exposed credentials' >&2
    exit 1
fi
printf 'New York\n' >"$XDG_CONFIG_HOME/jc/region"
scratch="$test_dir/scratch-external"
mkdir "$scratch"
five=five-external
five_deploy example.com "$ipv4" 443,8444,8445,8446,8447 12345678-1234-1234-1234-123456789abc www.microsoft.com
dir="$test_dir/$five"
jq -e '
    .inbounds[0].tls.server_name == "www.microsoft.com" and
    .inbounds[0].tls.reality.handshake == {server:"www.microsoft.com",server_port:443} and
    all(.inbounds[1:][]; .tls.server_name == "example.com")
' "$dir/config.json" >/dev/null
jq -e '
    all(.outbounds[] | select(has("server"));
        .tls.server_name == (if .type == "vless" then "www.microsoft.com" else "example.com" end))
' "$dir/profiles/all.json" >/dev/null
grep -F 'sni=www.microsoft.com&' "$dir/profiles/links.txt" | grep -F 'vless://' >/dev/null
if (five_deploy example.com "$ipv4" 8443,8444,8445,8446,8447 12345678-1234-1234-1234-123456789abc www.microsoft.com) >/dev/null 2>&1; then
    echo 'Accepted TCP 8443 as a node port in external REALITY mode' >&2
    exit 1
fi

grep -F '#VLESS-REALITY-New%20York' "$dir/profiles/links.txt" >/dev/null
summary=$(five_summary)
grep -Eq 'REALITY +TCP 443 +SNI: www\.microsoft\.com' <<<"$summary"
grep -F '已发布 · TCP 8443' <<<"$summary" >/dev/null
rm -- "$profiles/five/all.sub"
grep -F '未发布' <<<"$(five_summary)" >/dev/null

scratch="$test_dir/scratch-preset"
mkdir "$scratch"
five=five-preset
dpkg-query() { :; }
five_deploy - "$ipv4" 8443,8444,8445,8446,8447 12345678-1234-1234-1234-123456789abc \
    www.microsoft.com www.bing.com,www.bing.com,www.amazon.com,www.cloudflare.com
dir="$test_dir/$five"
pin=$(openssl x509 -in "$dir/local-tls.crt" -pubkey -noout | openssl pkey -pubin -outform der |
    openssl dgst -sha256 -binary | openssl enc -base64)
jq -e --arg pin "$pin" '
    (.outbounds[] | select(.type=="vmess") | .transport.headers.Host == "www.bing.com" and (.tls | not)) and
    ([.outbounds[] | select(.type=="hysteria2" or .type=="tuic" or .type=="anytls") | .tls.server_name] ==
        ["www.bing.com","www.amazon.com","www.cloudflare.com"]) and
    all(.outbounds[] | select(.type=="hysteria2" or .type=="tuic" or .type=="anytls");
        .tls.certificate_public_key_sha256 == [$pin] and (.tls.insecure | not))
' "$dir/profiles/all.json" >/dev/null
sed -n 's/^vmess:\/\///p' "$dir/profiles/links.txt" | base64 -d |
    jq -e '.host == "www.bing.com" and .tls == ""' >/dev/null
if (five_share --publish) >/dev/null 2>&1; then
    echo 'Preset mode offered HTTPS publication without a certificate domain' >&2
    exit 1
fi

show_qr() { printf 'QR %s\n' "$1"; }
output=$(five_share)
[[ $(grep -c '^QR ' <<<"$output") == 5 ]]
[[ $(grep -cE '^(vless|vmess|hysteria2|tuic|anytls)://' <<<"$output") == 5 ]]
for label in "${kinds[@]}" all; do
    grep -F "$dir/profiles/$label.json" <<<"$output" >/dev/null
done
grep -F "$dir/local-tls.crt" <<<"$output" >/dev/null

links_before=$(sha256sum "$dir/profiles/links.txt" "$dir/profiles/all.json")
cancelled=$(five_share --v2rayn <<<n)
[[ $cancelled != *'QR '* ]]
output=$(five_share --v2rayn <<<y)
fingerprint=$(openssl x509 -in "$dir/local-tls.crt" -outform DER | sha256sum | cut -d' ' -f1)
[[ $(grep -c '^QR ' <<<"$output") == 5 ]]
grep -Eq "^hysteria2://.*&pinSHA256=$fingerprint#" <<<"$output"
grep -Eq '^tuic://.*&allow_insecure=1#' <<<"$output"
grep -Eq '^anytls://.*&insecure=1#' <<<"$output"
[[ $(sha256sum "$dir/profiles/links.txt" "$dir/profiles/all.json") == "$links_before" ]]

for bad in '[2606:4700::1]' '2606::::1' 'fe80::1' '::1'; do
    if (valid_node_address "$bad") >/dev/null 2>&1; then
        printf 'Accepted invalid node address %s\n' "$bad" >&2
        exit 1
    fi
done

(
    source <(sed -n '/^choose_preset_reality()/,/^quick_install()/ { /^quick_install()/d; p; }' "$root/bootstrap.sh")
    heading() { :; }
    option() { :; }
    choices=(1 9)
    choose() {
        [[ $1 == 9 ]]
        selection=${choices[0]}
        choices=("${choices[@]:1}")
    }
    duo() { [[ $1 == reality-probe && $2 == aws.amazon.com ]]; }
    result=''
    choose_preset_reality result apple.com aws.amazon.com
    [[ $result == aws.amazon.com && ${#choices[@]} == 0 ]]
)
