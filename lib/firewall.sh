#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# All Smart Firewall operations run under the manager's flock.
fw_dir=/var/lib/jc/firewall
fw_ufw_config=/etc/default/ufw
fw_mode=smart
fw_pending=()
fw_unmanaged=()
fw_status=''

fw_load_mode() {
    if [[ -f $fw_dir/mode ]]; then read -r fw_mode <"$fw_dir/mode" || fail '无法读取防火墙管理模式'; fi
    fw_mode=${JC_FIREWALL_MODE:-$fw_mode}
    [[ $fw_mode == smart || $fw_mode == manual ]] || fail '防火墙管理模式应为 smart 或 manual'
}

fw_save_mode() {
    mkdir -p -m 700 -- "$fw_dir" &&
        printf '%s\n' "$fw_mode" | private_put "$fw_dir/mode"
}

fw_status_read() {
    fw_status=''
    command -v ufw >/dev/null || return 2
    fw_status=$(LC_ALL=C ufw status numbered) || return 1
    case "$fw_status" in
        'Status: active'*) return 0 ;;
        'Status: inactive'*) return 2 ;;
        *) return 1 ;;
    esac
}

fw_ssh_ports() {
    local listeners
    listeners=$(ss -H -lntp) || return 1
    {
        if command -v sshd >/dev/null; then
            sshd -T 2>/dev/null | awk '$1 == "port" {print $2}' || true
        elif [[ -x /usr/sbin/sshd ]]; then
            /usr/sbin/sshd -T 2>/dev/null | awk '$1 == "port" {print $2}' || true
        fi
        awk '/"sshd(-session)?"/ {sub(/.*:/,"",$4); print $4}' <<<"$listeners"
        systemctl show ssh.socket -p Listen --value 2>/dev/null |
            awk '$2 == "(Stream)" {sub(/.*:/,"",$1); if ($1 ~ /^[0-9]+$/) print $1}' || true
        if [[ -n ${SSH_CONNECTION:-} ]]; then awk '{print $4}' <<<"$SSH_CONNECTION"; fi
    } | sort -nu
}

fw_report() {
    local state ssh_ports fail2ban
    if fw_status_read; then state='已启用'; else
        case $? in 2) state='未启用或未安装';; *) state='无法读取';; esac
    fi
    ssh_ports=$(fw_ssh_ports | paste -sd, -) || ssh_ports=''
    fail2ban=$(systemctl is-active fail2ban 2>/dev/null) || true
    printf 'UFW：%s · SSH 端口：%s · Fail2ban：%s\n' "$state" "${ssh_ports:-未知}" "${fail2ban:-未知}"
}

# With a tag, match only our exact inbound allow rule. Without a tag, match
# any existing rule on the same tuple because UFW can replace its action,
# logging and comment when adding a new rule.
fw_rule_number() {
    local key=$1 tag=${2:-} family=${3:-}
    awk -v key="$key" -v tag="$tag" -v family="$family" '
        /^\[[[:space:]]*[0-9]+\]/ {
            number=$0
            sub(/\].*/, "", number)
            gsub(/[^0-9]/, "", number)
            sub(/^\[[[:space:]]*[0-9]+\][[:space:]]*/, "")
            count=split($0, parts, /[[:space:]]+# /)
            $0=parts[1]
            if (family == "4" && $2 == "(v6)") next
            if (family == "6" && $2 != "(v6)") next
            if ($2 == "(v6)" && $6 == "(v6)") {
                $2=$3; $3=$4; $4=$5
                for (i=7; i<=NF; i++) $(i-2)=$i
                NF-=2
            }
            if ($1==key && $3=="IN" && $4=="Anywhere") {
                if (tag=="" && (NF==4 || (NF==5 && $5 ~ /^\(log(-all)?\)$/))) {
                    print $2; exit
                }
                if (tag!="" && NF==4 && $2=="ALLOW" && count==2 && parts[2]==tag) {
                    print number; exit
                }
            }
        }
    ' <<<"$fw_status"
}

fw_open() {
    local key=$1 purpose=$2 port=${1%/*} proto=${1#*/} path tag rc family source ssh_ports existing
    [[ $fw_mode == smart ]] || return 0
    port_number "$port" && [[ $proto == tcp || $proto == udp ]] || return 1
    if [[ $proto == tcp ]]; then
        ssh_ports=$(fw_ssh_ports) || return 1
        if grep -qxF "$port" <<<"$ssh_ports"; then
            printf 'TCP %s 已用于 SSH，JC 无法接管。\n' "$port" >&2
            return 1
        fi
    fi
    fw_status_read || {
        rc=$?
        if (( rc == 2 )); then
            fw_unmanaged+=("$key")
            return 0
        fi
        return 1
    }
    # Plan each family independently to preserve asymmetric existing rules.
    for family in 4 6; do
        if [[ $family == 6 ]]; then
            if ! grep -qiE '^[[:space:]]*IPV6=yes[[:space:]]*$' "$fw_ufw_config"; then
                continue
            fi
            source=::/0
        else
            source=0.0.0.0/0
        fi
        existing=$(fw_rule_number "$key" '' "$family") || return 1
        if [[ -n $existing ]]; then
            if [[ $existing != ALLOW ]]; then
                printf '保留 IPv%s 上 %s 的既有 UFW %s 规则，请核对客户端连通性。\n' "$family" "$key" "$existing" >&2
            fi
            continue
        fi
        mkdir -p -m 700 -- "$fw_dir" || return 1
        path="$fw_dir/$port-$proto-$family"
        # Record intent before invoking UFW so a killed process cannot orphan a rule.
        tag=$(openssl rand -hex 16) || return 1
        tag="JC-$tag"
        printf '%s %s\n' "$tag" "$purpose" | private_put "$path.pending" || return 1
        fw_pending+=("$path.pending")
        LC_ALL=C ufw allow in proto "$proto" from "$source" to any port "$port" comment "$tag" || return 1
        fw_status_read && [[ -n $(fw_rule_number "$key" "$tag" "$family") ]] || return 1
    done
}

fw_report_unmanaged() {
    if (( ${#fw_unmanaged[@]} )); then
        printf '本机 UFW 未启用或未安装。若有入站限制，请检查这些端口是否已放行：%s。\n' "${fw_unmanaged[*]}" >&2
    fi
}

fw_read() {
    local name=${1##*/} extra
    [[ $name =~ ^([0-9]+)-(tcp|udp)-(4|6)(\.pending)?$ ]] || return 1
    fw_port=${BASH_REMATCH[1]} fw_proto=${BASH_REMATCH[2]} fw_family=${BASH_REMATCH[3]}
    port_number "$fw_port" && read -r fw_tag fw_purpose extra <"$1" || return 1
    [[ $fw_tag =~ ^JC-[0-9a-f]{32}$ && -z $extra ]] &&
        [[ $fw_purpose == node || $fw_purpose == acme || $fw_purpose == subscription ]]
}

fw_remove() {
    local path=$1 policy=$2 number listeners flag=-lntp ssh_ports config rc source=0.0.0.0/0
    fw_read "$path" || return 1
    if [[ $fw_proto == tcp ]]; then
        ssh_ports=$(fw_ssh_ports) || return 1
        if grep -qxF "$fw_port" <<<"$ssh_ports"; then return 0; fi
    else
        flag=-lnup
    fi
    if [[ $fw_family == 6 ]]; then source=::/0; fi
    config=$(cfg "$five") || return 1
    if [[ -f $config ]]; then
        if jq -e --argjson port "$fw_port" --arg proto "$fw_proto" '
            any(.inbounds[]; .listen_port == $port and
                (if .type == "hysteria2" or .type == "tuic" then "udp" else "tcp" end) == $proto)
        ' "$config" >/dev/null; then
            return 0
        else
            rc=$?
            [[ $rc == 1 ]] || return 1
        fi
    fi
    listeners=$(ss -H "$flag" "( sport = :$fw_port )") || return 1
    if [[ -n $listeners ]]; then
        # A failed JC HTTP-01 attempt may leave Caddy's port 80 listener up.
        # Any other listener may depend on this rule, so keep its ownership record.
        [[ $policy == rollback && $fw_purpose == acme ]] &&
            ! grep -vq '"caddy"' <<<"$listeners" || return 0
    fi
    # A stopped Caddy can still need these ports when it starts again.
    if [[ $policy != rollback && -r $caddyfile ]]; then
        case "$fw_purpose" in
            acme) if grep -qE '^[^[:space:]#]+:8443[[:space:]]*\{' "$caddyfile"; then return 0; fi ;;
            subscription)
                if grep -qF 'handle_path /profiles/five/*' "$caddyfile"; then return 0; fi ;;
        esac
    fi
    fw_status_read || return 1
    number=$(fw_rule_number "$fw_port/$fw_proto" "$fw_tag" "$fw_family") || return 1
    if [[ -n $number ]]; then
        # Delete by exact family and tuple after checking the ownership tag.
        # A concurrent unrelated UFW edit can renumber the entire rule list.
        LC_ALL=C ufw --force delete allow in proto "$fw_proto" from "$source" to any port "$fw_port" comment "$fw_tag" || return 1
        fw_status_read && [[ -z $(fw_rule_number "$fw_port/$fw_proto" "$fw_tag" "$fw_family") ]] || return 1
    fi
    rm -f -- "$path"
}

fw_commit() {
    local path
    for path in "${fw_pending[@]}"; do
        mv -fT -- "$path" "${path%.pending}" || return 1
    done
    fw_pending=()
}

fw_rollback() {
    local path
    for path in "${fw_pending[@]}"; do
        [[ -f $path ]] || continue
        fw_remove "$path" rollback ||
            printf 'UFW 回退待重试，规则记录位于 %s。\n' "$path" >&2
    done
}

fw_recover() {
    local path
    [[ $fw_mode == smart ]] || return 0
    for path in "$fw_dir/"*.pending; do
        [[ -f $path ]] || continue
        # After an untrappable interruption, retain rules for configured or
        # listening services. Leave the record pending for a later retry.
        fw_remove "$path" recover ||
            printf 'UFW 恢复待重试，规则记录位于 %s。\n' "$path" >&2
    done
}

fw_prune() {
    local path key=${1:-} port proto
    for path in "$fw_dir/"*; do
        [[ -f $path && ${path##*/} != .* ]] || continue
        fw_read "$path" || continue
        port=$fw_port proto=$fw_proto
        [[ -z $key || $key == "$port/$proto" ]] || continue
        fw_remove "$path" prune ||
            printf 'UFW 清理待重试，规则记录位于 %s。\n' "$path" >&2
    done
}

certificate_ready() {
    curl -s --noproxy '*' --max-time 2 \
        --resolve "$1:8443:127.0.0.1" "https://$1:8443/" -o /dev/null
}

wait_for_certificate() {
    local domain=$1 started=$2 deadline=$((SECONDS + 90)) next_update=$((SECONDS + 15))
    local logs listeners
    if certificate_ready "$domain"; then
        echo 'Caddy 公信证书已就绪。'
        return 0
    fi
    listeners=$(ss -H -lnt '( sport = :80 )') || return 1
    if [[ -z $listeners ]]; then
        printf '%s%s%s\n' "$red" '本机 TCP 80 未监听，Caddy 无法处理 HTTP 签发验证。' "$reset" >&2
        return 1
    fi
    echo '正在等待 Caddy 公信证书（最多约 90 秒）…'
    while (( SECONDS < deadline )); do
        if ! systemctl is-active --quiet caddy; then break; fi
        if certificate_ready "$domain"; then
            echo 'Caddy 公信证书已就绪。'
            return 0
        fi
        if (( SECONDS >= next_update )); then
            printf '仍在等待 %s 的签发结果…\n' "$domain"
            next_update=$((SECONDS + 15))
        fi
        sleep 1
    done
    printf '%s%s%s\n' "$red" '证书暂未就绪。请核对域名 A/AAAA 记录和公网 TCP 80。修正后选 1 重试。' "$reset" >&2
    logs=$(journalctl -u caddy --since "@$started" --no-pager -o cat 2>/dev/null | grep -F -- "$domain" | tail -n 8 || true)
    if [[ -z $logs ]]; then
        logs=$(journalctl -u caddy -n 8 --no-pager -o cat 2>/dev/null || true)
    fi
    if [[ -n $logs ]]; then printf '\nCaddy 最近的日志\n%s\n' "$logs" >&2; fi
    return 1
}
