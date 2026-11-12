#!/usr/bin/env bash
# Run as root in an isolated network and mount namespace on an ephemeral runner.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source <(sed '/^command_name=/,$d' "$root/manager.sh")
source "$root/lib/firewall.sh"
tmp=$(mktemp -d)
trap 'umount "$fw_ufw_config" /etc/ufw; rm -rf -- "$tmp"' EXIT

cp -a /etc/ufw "$tmp/ufw"
sed 's/^IPV6=.*/IPV6=yes/' "$fw_ufw_config" >"$tmp/default-ufw"
mount --bind "$tmp/ufw" /etc/ufw
mount --bind "$tmp/default-ufw" "$fw_ufw_config"
fw_dir="$tmp/firewall"
caddyfile="$tmp/Caddyfile"
cfg() { printf '%s/config.json\n' "$tmp"; }
export SSH_CONNECTION='192.0.2.1 12345 192.0.2.2 22410'

LC_ALL=C ufw --force enable
LC_ALL=C ufw limit 22410/tcp comment test-ssh
LC_ALL=C ufw deny in proto udp from 0.0.0.0/0 to any port 24443 comment operator-deny
LC_ALL=C ufw allow in log proto tcp from ::/0 to any port 24444 comment operator-log

fw_open 24443/udp node
fw_open 24444/tcp node
fw_commit
fw_status_read
[[ $fw_status == *'# operator-deny'* && $fw_status == *'# operator-log'* && $fw_status == *'# test-ssh'* ]]
[[ $(fw_rule_number 24443/udp '' 4) == DENY ]]
[[ $(fw_rule_number 24443/udp '' 6) == ALLOW ]]
[[ $(fw_rule_number 24444/tcp '' 4) == ALLOW ]]
[[ $(fw_rule_number 24444/tcp '' 6) == ALLOW ]]

fw_open 24443/udp node
fw_commit
fw_prune
fw_status_read
[[ $fw_status == *'# operator-deny'* && $fw_status == *'# operator-log'* && $fw_status == *'# test-ssh'* ]]
[[ $fw_status != *'# JC-'* ]]
echo 'Real UFW IPv4/IPv6 ownership and cleanup passed'
