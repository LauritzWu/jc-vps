#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
source <(sed '/^command_name=/,$d' "$root/manager.sh")
source "$root/lib/firewall.sh"

fw_dir="$tmp/firewall"
fw_ufw_config="$tmp/ufw"
caddyfile="$tmp/Caddyfile"
rules="$tmp/rules"
mutations="$tmp/mutations"
scratch="$tmp/scratch"
mkdir "$scratch"
touch "$rules" "$mutations"
printf 'IPV6=yes\n' >"$fw_ufw_config"
printf '8443/tcp ALLOW IN Anywhere # operator\n22410/tcp LIMIT IN Anywhere # ssh\n' >"$rules"
export SSH_CONNECTION='192.0.2.1 12345 192.0.2.2 22410'
active=yes fail_family='' listener=''

private_put() { cat >"$1"; }
cfg() { printf '%s/config.json\n' "$tmp"; }
ss() {
    if [[ -n $listener && $* == *":$listener )"* ]]; then
        printf 'LISTEN 0 100 0.0.0.0:%s 0.0.0.0:* users:(("other",pid=9,fd=3))\n' "$listener"
    fi
    return 0
}
systemctl() {
    if [[ $* == 'is-active fail2ban' ]]; then echo active; return; fi
    return 1
}
ufw() {
    if [[ $* == 'status numbered' ]]; then
        if [[ $active == yes ]]; then
            echo 'Status: active'
            awk '{printf "[%2d] %s\n", NR, $0}' "$rules"
        else
            echo 'Status: inactive'
        fi
        return
    fi
    local action=add target suffix='' family=4
    if [[ $1 == --force && $2 == delete ]]; then action=delete; shift 2; fi
    [[ $# == 12 && $1 == allow && $2 == in && $3 == proto &&
       $5 == from && $7 == to && $8 == any && $9 == port && ${11} == comment ]] || return 1
    if [[ $6 == ::/0 ]]; then family=6; suffix=' (v6)'; else [[ $6 == 0.0.0.0/0 ]] || return 1; fi
    target="${10}/$4$suffix ALLOW IN Anywhere$suffix # ${12}"
    if [[ $action == add ]]; then
        [[ $family != "$fail_family" ]] || return 1
        printf '%s\n' "$target" >>"$rules"
    else
        grep -vxF -- "$target" "$rules" >"$tmp/new" || [[ $? == 1 ]]
        mv "$tmp/new" "$rules"
    fi
    printf '%s %s\n' "$action" "$target" >>"$mutations"
}

report=$(fw_report)
[[ $report == *22410* && $report == *'Fail2ban：active'* ]]
if fw_open 22410/tcp node; then exit 1; fi
active=no
fw_open 2443/udp node
[[ ! -s $mutations ]]
active=yes
fw_mode=manual
fw_open 2443/udp node
[[ ! -s $mutations ]]
fw_mode=smart

# Reuse only the pre-existing IPv4 rule. Open the missing IPv6 family.
fw_open 8443/tcp node
fw_commit
[[ $(wc -l <"$mutations") == 1 ]]
fw_open 8443/tcp node
fw_commit
[[ $(wc -l <"$mutations") == 1 ]]
grep -qxF '8443/tcp ALLOW IN Anywhere # operator' "$rules"

# Partial add failure and certificate rollback remove only new rules.
fail_family=6
if fw_open 2443/udp node; then exit 1; fi
fw_rollback
if grep -q '2443/udp' "$rules"; then exit 1; fi
fw_pending=()
fail_family=''
fw_open 80/tcp acme
fw_rollback
if grep -q '80/tcp' "$rules"; then exit 1; fi
fw_pending=()

# Recover a killed transaction, retaining a rule for a configured node.
fw_open 20001/udp node
fw_open 20002/udp node
fw_pending=()
printf '%s\n' '{"inbounds":[{"listen_port":20002,"type":"tuic"}]}' >"$(cfg "$five")"
fw_recover
if grep -q '20001/udp' "$rules"; then exit 1; fi
grep -q '20002/udp' "$rules"

# Migrate and commit the new port. Keep the old rule while a service uses it.
fw_open 20003/udp node
printf '%s\n' '{"inbounds":[{"listen_port":20003,"type":"tuic"}]}' >"$(cfg "$five")"
fw_commit
listener=20002
fw_prune 20002/udp
grep -q '20002/udp' "$rules"
listener=''
fw_prune 20002/udp
if grep -q '20002/udp' "$rules"; then exit 1; fi
grep -q '20003/udp' "$rules"

# Uninstall cannot claim an existing rule or delete an administrator's edit.
sed -i '/20003\/udp ALLOW/s/# JC-.*/# replacement/' "$rules"
rm "$(cfg "$five")"
fw_prune
grep -qxF '8443/tcp ALLOW IN Anywhere # operator' "$rules"
grep -qxF '22410/tcp LIMIT IN Anywhere # ssh' "$rules"
grep -qxF '20003/udp ALLOW IN Anywhere # replacement' "$rules"
if grep -q '8443/tcp (v6)' "$rules"; then exit 1; fi
echo 'Smart Firewall ownership, rollback, migration, and cleanup passed'
