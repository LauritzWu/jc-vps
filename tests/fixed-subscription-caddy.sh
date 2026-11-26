#!/usr/bin/env bash
set -euo pipefail
source <(sed '/^command_name=/,$d' manager.sh)

test_dir=$(mktemp -d)
server_pid=''
finish_test() {
    local status=$?
    if [[ -n $server_pid ]]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    if (( status != 0 )) && [[ -r $test_dir/caddy.log ]]; then
        cat "$test_dir/caddy.log" >&2
    fi
    rm -rf -- "$test_dir"
    return "$status"
}
trap finish_test EXIT

domain=node.example
loopback=127.0.0.1
secondary=198.51.100.2
prefix=/profiles/five
ip link set lo up
ip address add "$secondary/32" dev lo

caddyfile="$test_dir/Caddyfile"
scratch="$test_dir/scratch"
profiles="$test_dir/published"
export XDG_DATA_HOME="$test_dir/data" XDG_CONFIG_HOME="$test_dir/config"
export CURL_CA_BUNDLE="$test_dir/tls.crt"
mkdir -p "$scratch" "$test_dir/profiles"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1 \
    -subj "/CN=$domain" -addext "subjectAltName=DNS:$domain" \
    -keyout "$test_dir/tls.key" -out "$CURL_CA_BUNDLE" >"$test_dir/openssl.log" 2>&1

cat >"$caddyfile" <<CADDY
{
    auto_https disable_redirects
    admin 127.0.0.1:2019
}
$domain:8443 {
    bind 127.0.0.1
    tls "$CURL_CA_BUNDLE" "$test_dir/tls.key"
    respond "subscription fixture"
}
CADDY
cat >"$test_dir/config.json" <<JSON
{"inbounds":[
  {"type":"vless","listen_port":4443,"tls":{"reality":{"handshake":{"server":"127.0.0.1"}}}},
  {"type":"vmess","tls":{"server_name":"$domain"}}
]}
JSON
for label in "${kinds[@]}"; do
    printf '%s\n' "$label" >>"$test_dir/profiles/links.txt"
done
for label in "${kinds[@]}" all; do
    printf '{"fixture":"%s"}\n' "$label" >"$test_dir/profiles/$label.json"
    printf '%s\n' "$label" | base64 >"$test_dir/profiles/$label.sub"
done

# Use real Caddy, TLS, auth, listener checks, and profile writes. Simulate
# only sing-box's node data and the service manager and firewall calls.
cfg() { printf '%s/config.json' "$test_dir"; }
set_node_aliases() { aliases=("${kinds[@]}"); }
refresh_five_aliases() { :; }
show_qr() { print_link "$1"; }
fw_open() { [[ $1 == 8443/tcp && $2 == subscription ]]; }
fw_commit() { :; }
systemctl() {
    [[ $# == 2 && $1 == reload && $2 == caddy ]] || return 1
    caddy reload --config "$caddyfile" --adapter caddyfile
}
# The fixture runs as root. An extracted Caddy package has no installed
# service account, so its published files use group root in this case.
if ! getent group caddy >/dev/null; then
    profile_dir() { mkdir -p -m 750 -- "$1"; }
    chgrp() {
        if [[ $1 == caddy ]]; then shift; command chgrp root "$@"
        else command chgrp "$@"; fi
    }
fi

request() {
    local address=$1 path=$2
    shift 2
    curl --noproxy '*' -sS --connect-timeout 1 --max-time 4 \
        --resolve "$domain:8443:$address" "$@" "https://$domain:8443$path"
}

caddy run --config "$caddyfile" --adapter caddyfile >"$test_dir/caddy.log" 2>&1 &
server_pid=$!
for ((attempt=0; attempt<40; attempt++)); do
    if request "$loopback" / -f >/dev/null 2>&1; then break; fi
    kill -0 "$server_pid"
    sleep 0.2
done
request "$loopback" / -f >/dev/null
if request "$secondary" / >/dev/null 2>&1; then
    echo 'The Caddy listener was reachable on the secondary address before activation' >&2
    exit 1
fi

password=$(openssl rand -hex 16)
auth_checks() {
    local address=$1 ext code
    for ext in sub json; do
        code=$(request "$address" "$prefix/all.$ext" -o /dev/null -w '%{http_code}')
        [[ $code == 401 ]]
        code=$(request "$address" "$prefix/all.$ext" -u 'lax:wrong' -o /dev/null -w '%{http_code}')
        [[ $code == 401 ]]
        code=$(request "$address" "$prefix/all.$ext" -u "lax:$password" -o "$test_dir/download" -w '%{http_code}')
        [[ $code == 200 ]]
        cmp "$test_dir/download" "$test_dir/profiles/all.$ext"
    done
}

five_share --publish <<<"$password"$'\n'"$password" >"$test_dir/legacy"
auth_checks "$loopback"
grep -Fq "https://$domain:4443$prefix/all.sub" "$test_dir/legacy"

# Force a post-reload failure to exercise the reverse listener migration.
cp "$caddyfile" "$test_dir/loopback.Caddyfile"
if (
    trap cleanup EXIT
    fw_commit() { return 1; }
    fw_rollback() { :; }
    five_share --publish --fixed
) >"$test_dir/rollback"; then
    echo 'An unsuccessful firewall commit did not fail the publication' >&2
    exit 1
fi
cmp "$test_dir/loopback.Caddyfile" "$caddyfile"
auth_checks "$loopback"
if request "$secondary" / >/dev/null 2>&1; then
    echo 'The fixed listener remained reachable after rollback' >&2
    cat "$test_dir/rollback" >&2
    exit 1
fi
mkdir -p "$scratch"

five_share --publish --fixed >"$test_dir/fixed"
grep -Fq "https://$domain:8443$prefix/all.sub" "$test_dir/fixed"
grep -Fq "https://$domain:4443$prefix/all.sub" "$test_dir/fixed"
auth_checks "$loopback"
auth_checks "$secondary"

jq '.inbounds[0].listen_port = 5443' "$test_dir/config.json" >"$test_dir/changed.json"
mv "$test_dir/changed.json" "$test_dir/config.json"
five_share --publish >"$test_dir/refreshed"
grep -Fq "https://$domain:8443$prefix/all.sub" "$test_dir/refreshed"
grep -Fq "https://$domain:5443$prefix/all.sub" "$test_dir/refreshed"
auth_checks "$loopback"
auth_checks "$secondary"

echo 'Real Caddy TLS: 401 for missing/wrong credentials, 200 for correct credentials before and after activation'
