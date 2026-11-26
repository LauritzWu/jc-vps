#!/usr/bin/env bash
set -euo pipefail
source <(sed '/^command_name=/,$d' manager.sh)

test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT
caddyfile="$test_dir/caddy"
scratch="$test_dir/scratch"
profiles="$test_dir/published"
mkdir -p "$scratch" "$test_dir/profiles"
cat >"$caddyfile" <<'CADDY'
other.example:8443 {
    bind 127.0.0.1
}
node.example:8443 {
    bind 127.0.0.1
    handle_path /profiles/five/* {
        basic_auth {
            lax hash
        }
    }
}
CADDY
cat >"$test_dir/config.json" <<'JSON'
{"inbounds":[
  {"type":"vless","listen_port":4443,"tls":{"reality":{"handshake":{"server":"127.0.0.1"}}}},
  {"type":"vmess","tls":{"server_name":"node.example"}}
]}
JSON
for label in "${kinds[@]}" all; do
    printf '%s\n' "$label" >>"$test_dir/profiles/links.txt"
    for ext in json sub; do
        printf '%s\n' "$label" >"$test_dir/profiles/$label.$ext"
    done
done
sed -i '$d' "$test_dir/profiles/links.txt"

cfg() { printf '%s/config.json' "$test_dir"; }
set_node_aliases() { aliases=("${kinds[@]}"); }
refresh_five_aliases() { :; }
show_qr() { print_link "$1"; }
auth_required() { [[ $1 == node.example && $2 == /profiles/five/* ]]; }
caddy_port_available() { [[ $1 == 8443 ]]; }
ss() { printf '%s\n' 'LISTEN 0 4096 *:8443 *:* users:(("caddy",pid=1,fd=2))'; }
fw_open() { [[ $1 == 8443/tcp && $2 == subscription ]] && touch "$test_dir/fw-open"; }
fw_commit() { [[ -f $test_dir/fw-open ]]; }
reload_site() { cp "$1" "$caddyfile"; }
profile_dir() { mkdir -p "$1"; }
put() { cat >"$1"; }

five_share --publish >"$test_dir/legacy"
grep -Fq 'https://node.example:4443/profiles/five/all.sub' "$test_dir/legacy"
[[ ! -e $test_dir/fw-open ]]
if fixed_subscription_block "$(site_block node.example)"; then exit 1; fi

five_share --publish --fixed >"$test_dir/fixed"
grep -Fq 'https://node.example:8443/profiles/five/all.sub' "$test_dir/fixed"
grep -Fq 'https://node.example:4443/profiles/five/all.sub' "$test_dir/fixed"
fixed_subscription_block "$(site_block node.example)"
grep -Fq 'bind 127.0.0.1' <<<"$(site_block other.example)"

jq '.inbounds[0].listen_port = 5443' "$test_dir/config.json" >"$test_dir/changed.json"
mv "$test_dir/changed.json" "$test_dir/config.json"
five_share --publish >"$test_dir/refreshed"
grep -Fq 'https://node.example:8443/profiles/five/all.sub' "$test_dir/refreshed"
grep -Fq 'https://node.example:5443/profiles/five/all.sub' "$test_dir/refreshed"
if grep -Fq 'https://node.example:4443/' "$test_dir/refreshed"; then exit 1; fi

sed -i '/^node\.example:8443 {/a\    bind 192.0.2.1' "$caddyfile"
cp "$caddyfile" "$test_dir/custom"
rm "$test_dir/fw-open"
if (five_share --publish --fixed); then exit 1; fi
cmp "$test_dir/custom" "$caddyfile"
[[ ! -e $test_dir/fw-open ]]

echo 'Fixed subscription migration, URL stability and custom bind protection passed'
