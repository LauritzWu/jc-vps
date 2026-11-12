#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/lib/firewall.sh"
red='' reset=''
domain=example.com

curl() {
    [[ " $* " == *" --resolve $domain:8443:127.0.0.1 "* ]] || return 1
    [[ " $* " != *' -fs '* && " $* " != *' --fail '* ]] || return 22
    [[ $ready == yes ]]
}
ss() { if [[ $listening == yes ]]; then echo 'LISTEN :80'; fi; }
systemctl() { return 1; }
journalctl() { echo 'ACME example.com validation failed'; }

ready=yes listening=no
output=$(wait_for_certificate "$domain" 1)
[[ $output == *'证书已就绪'* ]]

ready=no
if output=$(wait_for_certificate "$domain" 1 2>&1); then exit 1; fi
[[ $output == *'TCP 80 未监听'* ]]

listening=yes
if output=$(wait_for_certificate "$domain" 1 2>&1); then exit 1; fi
[[ $output == *'ACME example.com validation failed'* ]]
echo 'Certificate reuse, missing listener, and diagnostic log checks passed'
