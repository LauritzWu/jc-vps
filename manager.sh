#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail
umask 077

core=/usr/bin/sing-box
caddyfile=/etc/caddy/Caddyfile
units=/etc/systemd/system
profiles=/var/lib/caddy/private-profiles
real=sing-box-reality
hy2=sing-box-hy2
five=sing-box-lauritz-five
template=$(dirname -- "$0")/client-template.json
kinds=(reality vmess hy2 tuic anytls)
protocols=(tcp tcp udp udp tcp)

fail() { printf '操作未完成：%s\n' "$*" >&2; exit 1; }
cfg() { printf '/etc/%s/config.json' "$1"; }
fetch() { curl -4 -fsSL --retry 2 --connect-timeout 8 --max-time 25 "$@"; }
put() {
    local dest=$1 mode=$2 group=$3 temp
    temp=$(mktemp "$(dirname -- "$dest")/.duo.XXXXXX")
    if cat >"$temp" && chmod "$mode" "$temp" && chgrp "$group" "$temp" && mv -fT -- "$temp" "$dest"; then return; fi
    rm -f -- "$temp"
    return 1
}
private_put() { put "$1" 600 root; }
valid_domain() {
    local re='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,62}$'
    [[ $# == 1 && ${#1} -le 253 && $1 =~ $re ]] || fail '请输入有效的小写域名'
}
valid_ip() {
    local a b c d
    [[ $1 =~ ^(0|[1-9][0-9]{0,2})(\.(0|[1-9][0-9]{0,2})){3}$ ]] || fail '请输入公网 IPv4'
    IFS=. read -r a b c d <<<"$1"
    (( a>0 && a<224 && b<=255 && c<=255 && d<=255 && a!=10 && a!=127 &&
       !(a==100 && b>=64 && b<=127) && !(a==169 && b==254) &&
       !(a==172 && b>=16 && b<=31) && !(a==192 && (b==168 || (b==0 && (c==0 || c==2)))) &&
       !(a==198 && (b==18 || b==19 || (b==51 && c==100))) && !(a==203 && b==0 && c==113) )) ||
        fail '请输入公网 IPv4'
}
site_curl() {
    curl --noproxy '*' --max-time 8 --resolve "$1:8443:127.0.0.1" "${@:3}" "https://$1:8443$2"
}
find_cert() {
    local matches=() item
    for item in /var/lib/caddy/.local/share/caddy/certificates/*/"$1"/"$1".crt; do
        [[ -f $item && -f ${item%.crt}.key ]] && matches+=("$item")
    done
    (( ${#matches[@]} == 1 )) || fail '需要恰好一组 Caddy 证书和私钥'
    cert=${matches[0]}
    openssl x509 -in "$cert" -checkend 0 -noout >/dev/null
}
reload_site() {
    local candidate=$1 backup
    caddy validate --config "$candidate" --adapter caddyfile
    backup="$caddyfile.duo.$(date +%s%N).bak"
    private_put "$backup" <"$caddyfile"
    put "$caddyfile" 644 root <"$candidate"
    if ! systemctl reload caddy; then
        put "$caddyfile" 644 root <"$backup"
        systemctl reload caddy
        fail 'Caddy 重载失败，已恢复原配置'
    fi
}
packages() {
    local version=${2:-} key=/etc/apt/keyrings/sagernet.asc source=/etc/apt/sources.list.d/sagernet.sources
    local apt=(apt-get -o Acquire::ForceIPv4=true)
    local target=(sing-box)
    if (( $# )); then
        [[ $# == 2 && $1 == --version && $version =~ ^[0-9][0-9A-Za-z.+:~\-]*$ ]] ||
            fail '请输入完整 APT 版本号'
        target=(--allow-downgrades "sing-box=$version")
    fi
    [[ ! -e $units/sing-box.service || -x $core ]] || fail '检测到旧同名服务，请先迁移'
    if ! command -v caddy >/dev/null; then
        "${apt[@]}" update
        "${apt[@]}" install -y ca-certificates curl caddy
    fi
    mkdir -p /etc/apt/keyrings
    if [[ ! -s $key ]]; then
        fetch https://sing-box.app/gpg.key -o "$scratch/sagernet.asc"
        grep -qxF -- '-----BEGIN PGP PUBLIC KEY BLOCK-----' "$scratch/sagernet.asc" || fail '软件源密钥格式异常'
        put "$key" 644 root <"$scratch/sagernet.asc"
    fi
    if [[ ! -e $source ]]; then
        put "$source" 644 root <<'APT'
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Signed-By: /etc/apt/keyrings/sagernet.asc
APT
    fi
    "${apt[@]}" update
    "${apt[@]}" install -y "${target[@]}"
    "$core" version
}
uninstall() {
    local state service pid answer package processes
    local managed=() owned_pids=()
    package=$(dpkg-query -W -f='${Status}' sing-box 2>/dev/null) || package=''
    if [[ $package != 'install ok installed' ]]; then
        printf '未安装 sing-box 软件包。\n'
        return
    fi
    for service in sing-box-hy2-hopping "$five" "$hy2" "$real"; do
        state=$(systemctl show -p LoadState --value "$service.service")
        case "$state" in
            not-found) continue ;;
            loaded) managed+=("$service.service") ;;
            *) fail "无法确认 $service.service 的状态（$state）" ;;
        esac
        pid=$(systemctl show -p MainPID --value "$service.service")
        owned_pids+=("$pid")
    done
    processes=$(pgrep -x sing-box) || [[ $? == 1 ]] || fail '无法检查正在运行的 sing-box 进程'
    for pid in $processes; do
        [[ " ${owned_pids[*]} " == *" $pid "* ]] || fail "检测到其他 sing-box 进程（PID $pid），请先检查"
    done
    dpkg --no-act --remove sing-box
    if (( ${#managed[@]} )); then
        printf '将停止并取消开机启动的服务\n'
        printf '  %s\n' "${managed[@]}"
    fi
    printf '%s\n' '将移除 sing-box 软件包，保留配置以便恢复。' \
        '如果当前 SSH 经过这些节点，请先改用独立的管理连接。'
    read -r -p '输入 UNINSTALL 确认，或直接回车返回：' answer || return 0
    if [[ $answer != UNINSTALL ]]; then
        printf '已取消卸载。\n'
        return
    fi
    if (( ${#managed[@]} )); then
        systemctl disable --now "${managed[@]}"
    fi
    dpkg --remove sing-box
    printf 'sing-box 软件包已卸载。\n'
}
site() {
    valid_domain "$1"
    if grep -qxF "$1:8443 {" "$caddyfile"; then
        printf '站点已存在，继续检查证书。\n'
        return
    fi
    grep -Eq '^[[:space:]]*:80[[:space:]]*\{' "$caddyfile" || fail '未找到 Caddy 默认 :80 站点'
    if grep -Eq '^[[:space:]]*(\{[[:space:]]*$|auto_https\>)' "$caddyfile"; then
        fail '检测到自定义 Caddy 全局设置'
    fi
    {
        printf '{\n    auto_https disable_redirects\n}\n\n'
        cat "$caddyfile"
        cat <<CADDY

$1:8443 {
    bind 127.0.0.1
    tls {
        issuer acme {
            disable_tlsalpn_challenge
        }
    }
    respond "LAX server is online."
}
CADDY
    } >"$scratch/Caddyfile"
    reload_site "$scratch/Caddyfile"
    printf 'Caddy 已重载。证书签发需要公网 TCP 80。\n'
}
reality_keys() {
    local pair
    pair=$("$core" generate reality-keypair)
    private=$(awk 'tolower($0) ~ /^private *key:/ {print $NF}' <<<"$pair")
    public=$(awk 'tolower($0) ~ /^public *key:/ {print $NF}' <<<"$pair")
    [[ $private =~ ^[A-Za-z0-9_-]{43}$ && $public =~ ^[A-Za-z0-9_-]{43}$ ]] || fail 'REALITY 密钥格式异常'
}
unit_file() {
    local service=$1 cap=$2
    put "$units/$service.service" 644 root <<UNIT
[Unit]
Description=Lauritz Duo $service
Wants=network-online.target caddy.service
After=network-online.target caddy.service

[Service]
ExecStart=$core run -c $(cfg "$service")
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
CapabilityBoundingSet=CAP_NET_BIND_SERVICE$cap

[Install]
WantedBy=multi-user.target
UNIT
}
socket_ready() {
    local service=$1 pid i index port proto flag rows okay
    shift
    for ((i=0; i<10; i++)); do
        pid=$(systemctl show -p MainPID --value "$service") || return 1
        if [[ $pid =~ ^[1-9][0-9]*$ && $(readlink "/proc/$pid/exe") == "$core" ]]; then
            okay=1
            for index in "$@"; do
                port=${index%/*}; proto=${index#*/}
                flag=-lntp
                [[ $proto == udp ]] && flag=-lnup
                rows=$(ss -H "$flag" "( sport = :$port )") || return 1
                [[ $rows == *"pid=$pid,"* ]] || okay=0
            done
            (( okay )) && return 0
        fi
        sleep .5
    done
    return 1
}
check() { "$core" check -c "$1"; }

created=() started=()
rollback_config='' rollback_backup='' rollback_service=''
cleanup() {
    local code=$? name
    if (( code != 0 )); then
        if [[ -n $rollback_config ]]; then
            if private_put "$rollback_config" <"$rollback_backup"; then
                systemctl restart "$rollback_service" || true
            else
                created=()
                printf '恢复配置失败，原配置位于 %s\n' "$rollback_backup" >&2
            fi
        fi
        for name in "${started[@]}"; do systemctl stop "$name" || true; done
        for name in "${created[@]}"; do rm -rf -- "$name"; done
        if (( ${#started[@]} )); then systemctl daemon-reload || true; fi
    fi
    rm -rf -- "$scratch"
}
new_service() {
    local service=$1 dir
    dir=$(dirname "$(cfg "$service")")
    mkdir -m 700 -- "$dir"
    created+=("$dir" "$units/$service.service")
}
ensure_unused() {
    [[ ! -e $(dirname "$(cfg "$1")") && ! -L $(dirname "$(cfg "$1")") &&
       ! -e $units/$1.service && ! -L $units/$1.service ]] || fail "$1 已存在"
}
preflight() {
    valid_domain "$1"
    dpkg-query -S "$core" >/dev/null
    site_curl "$1" / -fsS -o /dev/null
    find_cert "$1"
}
server_doc() {
    jq '{inbounds:.,outbounds:[{type:"direct",tag:"direct"}],
         route:{rules:[{ip_is_private:true,action:"reject"}],final:"direct"}}'
}
deploy() {
    local domain=$1 listen=0.0.0.0 cert private public user short password rows
    if [[ ${2:-} == --ipv6 ]]; then listen=::; fi
    preflight "$domain"
    ensure_unused "$real"
    ensure_unused "$hy2"
    rows=$(ss -H -lntup '( sport = :443 )')
    [[ -z $rows ]] || fail '443 已被占用'
    reality_keys
    user=$(cat /proc/sys/kernel/random/uuid)
    short=$(openssl rand -hex 4)
    password=$(openssl rand -hex 24)
    DUO_UUID=$user DUO_KEY=$private DUO_SID=$short \
    jq -n --arg listen "$listen" --arg domain "$domain" \
        '[{type:"vless",listen:$listen,listen_port:443,users:[{uuid:$ENV.DUO_UUID,flow:"xtls-rprx-vision"}],
        tls:{enabled:true,server_name:$domain,reality:{enabled:true,private_key:$ENV.DUO_KEY,short_id:[$ENV.DUO_SID],
        handshake:{server:"127.0.0.1",server_port:8443}}}}]' | server_doc >"$scratch/real.json"
    DUO_PASS=$password jq -n --arg listen "$listen" --arg cert "$cert" --arg key "${cert%.crt}.key" \
        '[{type:"hysteria2",listen:$listen,listen_port:443,users:[{name:"lax",password:$ENV.DUO_PASS}],
        tls:{enabled:true,certificate_path:$cert,key_path:$key}}]' | server_doc >"$scratch/hy2.json"
    check "$scratch/real.json"
    check "$scratch/hy2.json"
    new_service "$real"
    new_service "$hy2"
    private_put "$(cfg "$real")" <"$scratch/real.json"
    private_put "$(cfg "$hy2")" <"$scratch/hy2.json"
    printf 'UUID=%s\nPublic key=%s\nShort ID=%s\n' "$user" "$public" "$short" |
        private_put "/etc/$real/client.txt"
    printf 'hysteria2://%s@%s:443/?sni=%s&insecure=0#Lauritz-Duo-HY2\n' "$password" "$domain" "$domain" |
        private_put "/etc/$hy2/client-uri.txt"
    unit_file "$real" ''
    unit_file "$hy2" ' CAP_DAC_READ_SEARCH'
    systemctl daemon-reload
    started+=("$real" "$hy2")
    systemctl start "$real" "$hy2"
    socket_ready "$real" 443/tcp && socket_ready "$hy2" 443/udp || fail '未确认主备监听'
    printf '两条线路已在本机监听。外网实测通过后启用开机启动。\n'
}

rules() {
    local service=$1 port path new backup
    case "$service" in "$real") port=443/tcp;; "$hy2") port=443/udp;; *) fail '未知服务';; esac
    socket_ready "$service" "$port" || fail '服务未监听'
    path=$(cfg "$service")
    jq -e '
      def expected: [{rule_set:"cn-domains",action:"reject"},{action:"resolve",server:"vps-dns"},
        {ip_is_private:true,action:"reject"},{rule_set:"cn-addresses",action:"reject"}];
      (.route.rules == expected or .route.rules == [{ip_is_private:true,action:"reject"}]) and
      ((.dns // {servers:[{type:"local",tag:"vps-dns"}]}) == {servers:[{type:"local",tag:"vps-dns"}]}) and
      all(.route.rule_set[]?; .tag == "cn-domains" or .tag == "cn-addresses")
    ' "$path" >/dev/null || fail '检测到自定义规则，已停止'
    new=$(mktemp -d "$(dirname "$path")/cn-rules.XXXXXX")
    created+=("$new")
    fetch https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-geolocation-cn.srs -o "$new/cn-domains.srs"
    fetch https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs -o "$new/cn-addresses.srs"
    jq --arg dir "$new" '
      .dns = {servers:[{type:"local",tag:"vps-dns"}]} |
      .route.rules = [{rule_set:"cn-domains",action:"reject"},{action:"resolve",server:"vps-dns"},
        {ip_is_private:true,action:"reject"},{rule_set:"cn-addresses",action:"reject"}] |
      .route.rule_set = (["cn-domains","cn-addresses"] | map({type:"local",tag:.,format:"binary",path:($dir+"/"+.+".srs")}))
    ' "$path" >"$scratch/config.json"
    check "$scratch/config.json"
    backup="$(dirname "$path")/config.before-cn.$(date +%s%N).json"
    private_put "$backup" <"$path"
    rollback_config=$path
    rollback_backup=$backup
    rollback_service=$service
    private_put "$path" <"$scratch/config.json"
    systemctl restart "$service" && socket_ready "$service" "$port" || fail '监听验证失败，正在恢复原配置'
    rollback_config=''
    printf '%s 已恢复监听。原配置备份 %s\n' "$service" "$backup"
}
port_number() { [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] && (( $1 <= 65535 )); }
hop_range() {
    port_number "$1" && port_number "$2" && (( $1>=1024 && $2>$1 && $2-$1<100 )) ||
        fail '跳跃范围应为 1024–65535 内连续的 2 至 100 个端口'
}
hopping() {
    local first=$1 last=$2 nft unit=sing-box-hy2-hopping path="/etc/$hy2/hopping.nft" rows
    hop_range "$first" "$last"
    socket_ready "$hy2" 443/udp || fail 'HY2 未监听'
    nft=$(command -v nft) || fail '请通过 APT 安装 nftables'
    [[ ! -e $path && ! -e $units/$unit.service ]] || fail '跳跃服务或配置已存在'
    if "$nft" list table inet yg_plus_hy2 >/dev/null 2>&1; then fail '同名 nftables 表已存在'; fi
    rows=$(ss -H -lnu "( sport >= :$first and sport <= :$last )")
    [[ -z $rows ]] || fail '范围内存在 UDP 监听'
    cat >"$scratch/hopping.nft" <<NFT
table inet yg_plus_hy2 {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        udp dport $first-$last counter redirect to :443
    }
}
NFT
    "$nft" -c -f "$scratch/hopping.nft"
    private_put "$path" <"$scratch/hopping.nft"
    created+=("$path")
    put "$units/$unit.service" 644 root <<UNIT
[Unit]
Description=Lauritz Duo Hysteria 2 port hopping
After=sing-box-hy2.service nftables.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$nft -f $path
ExecStop=$nft delete table inet yg_plus_hy2

[Install]
WantedBy=multi-user.target
UNIT
    created+=("$units/$unit.service")
    systemctl daemon-reload
    started+=("$unit")
    systemctl start "$unit"
    printf 'UDP %s-%s 已转发至 UDP 443。外网实测通过后运行 systemctl enable %s。\n' "$first" "$last" "$unit"
    printf '发布订阅时可指定 --hop-range %s:%s\n' "$first" "$last"
}
real_metadata() {
    domain=$(jq -er '.inbounds[0].tls.server_name' "$(cfg "$real")")
    valid_domain "$domain"
    public=$(sed -n 's/^Public key=//p' "/etc/$real/client.txt")
    [[ $public =~ ^[A-Za-z0-9_-]{43}$ ]] || fail 'REALITY 公钥格式异常'
}
reality_uri() {
    printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&flow=xtls-rprx-vision#%s\n' \
        "$1" "$2" "$3" "$domain" "$public" "$4" "$5"
}
dual_links() {
    local domain public user short password rport hport
    real_metadata
    user=$(jq -er '.inbounds[0].users[0].uuid' "$(cfg "$real")")
    short=$(jq -er '.inbounds[0].tls.reality.short_id[0]' "$(cfg "$real")")
    rport=$(jq -er '.inbounds[0].listen_port' "$(cfg "$real")")
    hport=$(jq -er '.inbounds[0].listen_port' "$(cfg "$hy2")")
    password=$(jq -er '.inbounds[0].users[0].password|@uri' "$(cfg "$hy2")")
    reality_uri "$user" "$domain" "$rport" "$short" Lauritz-Duo-REALITY
    printf 'hysteria2://%s@%s:%s/?sni=%s&insecure=0#Lauritz-Duo-HY2\n' "$password" "$domain" "$hport" "$domain"
}
sync_profile() {
    local host=$1 range=$2 first last table
    valid_ip "$host"
    real_metadata
    if [[ -n $range ]]; then
        [[ $range == *:* ]] || fail '格式为 START:END'
        first=${range%:*}; last=${range#*:}
        hop_range "$first" "$last"
        table=$(nft list table inet yg_plus_hy2)
        [[ $table == *"udp dport $first-$last "* && $table == *'redirect to :443'* ]] ||
            fail '实际跳跃规则与指定范围不符'
    fi
    jq --arg host "$host" --arg domain "$domain" --arg public "$public" --arg hop "$range" \
        --slurpfile real "$(cfg "$real")" --slurpfile hy2 "$(cfg "$hy2")" '
        "Lauritz-Duo-REALITY" as $main | "Lauritz-Duo-HY2" as $backup |
        .outbounds as $all |
        ([$all[] | select(.tag=="PROXY" and .type=="selector")]) as $groups |
        if ($groups|length)!=1 then error("需要唯一 PROXY selector") else . end |
        $groups[0] as $group |
        if any($group.outbounds[]; . as $tag |
          ([ $all[] | select(.tag==$tag and (.type|IN("selector","urltest","direct","block")|not)) ]|length)!=1)
          then error("PROXY 引用无效") else . end |
        ($group.outbounds - [$main,$backup]) as $removed |
        $real[0].inbounds[0] as $r | $hy2[0].inbounds[0] as $h |
        {enabled:true,server_name:$domain} as $tls |
        .outbounds = [
          ($group | .outbounds=[$main,$backup] | .default=$main),
          {type:"vless",tag:$main,server:$host,server_port:$r.listen_port,
           uuid:$r.users[0].uuid,flow:"xtls-rprx-vision",
           tls:($tls+{utls:{enabled:true,fingerprint:"chrome"},
             reality:{enabled:true,public_key:$public,short_id:$r.tls.reality.short_id[0]}})},
          ({type:"hysteria2",tag:$backup,server:$host,server_port:$h.listen_port,
            password:$h.users[0].password,tls:($tls+{insecure:false})} |
            if $hop=="" then . else del(.server_port)+{server_ports:[$hop],hop_interval:"30s"} end),
          ($all[] | select(.tag as $tag | ($removed+["PROXY",$main,$backup]|index($tag))==null))
        ] |
        if any(..|strings; . as $value | ($removed|index($value))!=null)
          then error("模板仍引用旧节点") else . end
    ' "$template" >"$scratch/profile.json"
    check "$scratch/profile.json"
}
auth_block() {
    local pass repeat version major minor LC_ALL=C
    read -r -s -p '订阅密码（16–72 字节）：' pass; printf '\n' >&2
    read -r -s -p '再输入一次：' repeat; printf '\n' >&2
    [[ ${#pass} -ge 16 && ${#pass} -le 72 && $pass == "$repeat" ]] || fail '密码长度不符或两次输入不同'
    hash=$(printf '%s\n' "$pass" | caddy hash-password)
    [[ $hash =~ ^\$2[aby]\$[0-9]{2}\$[./A-Za-z0-9]{53}$ ]] || fail '密码哈希无效'
    version=$(caddy version)
    [[ $version =~ ^v?([0-9]+)\.([0-9]+) ]] || fail '无法识别 Caddy 版本'
    major=${BASH_REMATCH[1]}; minor=${BASH_REMATCH[2]}
    auth=basicauth
    if (( major>2 || (major==2 && minor>=8) )); then auth=basic_auth; fi
}
auth_required() {
    local code
    code=$(site_curl "$1" "$2" -sS -o /dev/null -w '%{http_code}')
    [[ $code == 401 ]] || fail "匿名访问 $2 返回 $code，停止发布"
}
profile_dir() {
    mkdir -p -- "$1"
    chown root:caddy -- "$1"
    chmod 750 -- "$1"
}
publish_dual() {
    local domain=$1 hash auth
    if ! grep -Fq '/profiles/lax.json' "$caddyfile"; then
        [[ $(grep -Ec '^[[:blank:]]*respond "LAX server is online\."[[:blank:]]*$' "$caddyfile") == 1 ]] ||
            fail 'Caddyfile 与预期不同'
        auth_block
        cat >"$scratch/block" <<CADDY
    handle /profiles/lax.json {
        $auth {
            lax $hash
        }
        header Cache-Control "no-store"
        root * $profiles
        rewrite * /lax.json
        file_server
    }
    handle {
        respond "LAX server is online."
    }
CADDY
        awk -v block="$scratch/block" '/^[[:blank:]]*respond "LAX server is online\."[[:blank:]]*$/ {
            while ((getline line < block) > 0) print line; next
        } {print}' "$caddyfile" >"$scratch/Caddyfile"
        reload_site "$scratch/Caddyfile"
    fi
    auth_required "$domain" /profiles/lax.json
    profile_dir "$profiles"
    if [[ -f $profiles/lax.json ]]; then
        private_put "/root/lax-profile-before.$(date +%s%N).json" <"$profiles/lax.json"
    fi
    put "$profiles/lax.json" 640 caddy <"$scratch/profile.json"
    printf '订阅已发布 https://%s/profiles/lax.json\n用户名 lax，请在客户端验证认证后可下载。\n' "$domain"
}

five_deploy() {
    local domain=$1 host=$2 ports_text=$3 user=$4 cert private public short ws hp tp ap i port flag rows label attempt
    local ports=() listeners=() used=' ' dir="/etc/$five/profiles"
    valid_ip "$host"
    preflight "$domain"
    ensure_unused "$five"
    if [[ -z $user ]]; then user=$(cat /proc/sys/kernel/random/uuid); fi
    [[ $user =~ ^[a-fA-F0-9]{8}(-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$ ]] || fail 'UUID 格式无效'
    if [[ -n $ports_text ]]; then
        [[ $ports_text =~ ^[0-9]{1,5}(,[0-9]{1,5}){4}$ ]] || fail '请输入五个端口'
        IFS=, read -ra ports <<<"$ports_text"
    fi
    for i in "${!kinds[@]}"; do
        flag=-lnt
        [[ ${protocols[i]} == udp ]] && flag=-lnu
        if [[ -z $ports_text ]]; then
            port=''
            for ((attempt=0; attempt<100; attempt++)); do
                port=$((10000 + (RANDOM * 32768 + RANDOM) % 55536))
                rows=$(ss -H "$flag" "( sport = :$port )")
                if [[ -z $rows && $used != *" $port "* ]]; then break; fi
                port=''
            done
            [[ -n $port ]] || fail '未找到可用随机端口'
            ports[i]=$port
        fi
        port=${ports[i]}
        port_number "$port" && [[ $used != *" $port "* ]] || fail '端口无效或重复'
        rows=$(ss -H "$flag" "( sport = :$port )")
        [[ -z $rows ]] || fail "端口 $port 已被占用"
        used+="$port "
        listeners+=("$port/${protocols[i]}")
    done
    reality_keys
    short=$(openssl rand -hex 4)
    ws=/$(openssl rand -hex 12)
    hp=$(openssl rand -hex 24)
    tp=$(openssl rand -hex 24)
    ap=$(openssl rand -hex 24)
    jq -n --args '$ARGS.positional | map(tonumber)' "${ports[@]}" >"$scratch/ports.json"
    DUO_UUID=$user DUO_KEY=$private DUO_SID=$short DUO_WS=$ws DUO_HP=$hp DUO_TP=$tp DUO_AP=$ap \
    jq -n --slurpfile ports "$scratch/ports.json" --arg domain "$domain" --arg host "$host" \
        --arg pub "$public" --arg cert "$cert" --arg certkey "${cert%.crt}.key" '
      $ENV.DUO_UUID as $uuid | $ENV.DUO_KEY as $key | $ENV.DUO_SID as $sid | $ENV.DUO_WS as $ws |
      $ENV.DUO_HP as $hp | $ENV.DUO_TP as $tp | $ENV.DUO_AP as $ap |
      {enabled:true,server_name:$domain} as $tls |
      ($tls+{certificate_path:$cert,key_path:$certkey}) as $cert_tls |
      {type:"ws",path:$ws} as $transport |
      {uuid:$uuid,flow:"xtls-rprx-vision"} as $vision |
      [
        {type:"vless",users:[$vision],tls:($tls+{reality:{enabled:true,private_key:$key,
          short_id:[$sid],handshake:{server:"127.0.0.1",server_port:8443}}})},
        {type:"vmess",users:[{uuid:$uuid}],transport:$transport,tls:$cert_tls},
        {type:"hysteria2",users:[{password:$hp}],tls:$cert_tls},
        {type:"tuic",users:[{uuid:$uuid,password:$tp}],tls:($cert_tls+{alpn:["h3"]})},
        {type:"anytls",users:[{password:$ap}],tls:$cert_tls}
      ] as $ins |
      [
        ({type:"vless",tls:($tls+{utls:{enabled:true,fingerprint:"chrome"},
          reality:{enabled:true,public_key:$pub,short_id:$sid}})}+$vision),
        {type:"vmess",uuid:$uuid,security:"auto",alter_id:0,transport:$transport,tls:$tls},
        {type:"hysteria2",password:$hp,tls:$tls},
        {type:"tuic",uuid:$uuid,password:$tp,tls:($tls+{alpn:["h3"]})},
        {type:"anytls",password:$ap,tls:$tls}
      ] as $outs |
      ["reality","vmess","hy2","tuic","anytls"] as $tags |
      {ins:[range(5) as $i | $ins[$i]+{listen:"0.0.0.0",listen_port:$ports[0][$i]}],
       outs:[range(5) as $i | $outs[$i]+{tag:$tags[$i],server:$host,server_port:$ports[0][$i]}]}
    ' >"$scratch/five.json"
    jq '.ins' "$scratch/five.json" | server_doc >"$scratch/server.json"
    check "$scratch/server.json"
    {
        reality_uri "$user" "$host" "${ports[0]}" "$short" Lauritz-REALITY
        printf 'vmess://'
        DUO_UUID=$user DUO_WS=$ws jq -cn --arg host "$host" --arg port "${ports[1]}" --arg sni "$domain" \
            '{v:"2",ps:"Lauritz-VMess",add:$host,port:$port,id:$ENV.DUO_UUID,aid:"0",scy:"auto",net:"ws",
              type:"none",path:$ENV.DUO_WS,tls:"tls",sni:$sni,host:$sni}' | base64 -w0
        printf '\nhysteria2://%s@%s:%s?sni=%s&insecure=0#Lauritz-HY2\n' "$hp" "$host" "${ports[2]}" "$domain"
        printf 'tuic://%s:%s@%s:%s?sni=%s&alpn=h3#Lauritz-TUIC\n' "$user" "$tp" "$host" "${ports[3]}" "$domain"
        printf 'anytls://%s@%s:%s?sni=%s#Lauritz-AnyTLS\n' "$ap" "$host" "${ports[4]}" "$domain"
    } >"$scratch/links.txt"
    new_service "$five"
    mkdir -m 700 "$dir"
    private_put "$dir/links.txt" <"$scratch/links.txt"
    for label in "${kinds[@]}" all; do
        jq --arg label "$label" --slurpfile five "$scratch/five.json" '
            ($five[0].outs | map(select($label=="all" or .tag==$label))) as $nodes |
            .outbounds = ([.outbounds[] | select(.tag=="PROXY") |
              .outbounds=($nodes|map(.tag)) | .default=$nodes[0].tag] +
              $nodes + [.outbounds[]|select(.tag=="DIRECT")]) |
            .experimental.cache_file |= (.path=("lauritz-five-"+$label+".db") | .cache_id=("lauritz-five-"+$label))
        ' "$template" >"$dir/$label.json"
        check "$dir/$label.json"
        if [[ $label == all ]]; then
            base64 -w0 "$scratch/links.txt" >"$dir/$label.sub"
        else
            i=0
            while [[ ${kinds[i]} != "$label" ]]; do i=$((i+1)); done
            sed -n "$((i+1))p" "$scratch/links.txt" | base64 -w0 >"$dir/$label.sub"
        fi
        printf '\n' >>"$dir/$label.sub"
    done
    private_put "$(cfg "$five")" <"$scratch/server.json"
    unit_file "$five" ' CAP_DAC_READ_SEARCH'
    systemctl daemon-reload
    started+=("$five")
    systemctl start "$five"
    socket_ready "$five" "${listeners[@]}" || fail '未确认五个端口均由新服务监听'
    printf '已监听 %s\n' "${listeners[@]}"
    printf '客户端配置与分享链接位于 %s\n' "$dir"
}

show_qr() {
    printf '%s\n' "$1"
    if command -v qrencode >/dev/null; then printf '%s' "$1" | qrencode -t ANSIUTF8 -m 2; fi
}

five_share() {
    local domain hash auth dir="/etc/$five/profiles" prefix=/profiles/five
    local i=0 link label ext
    domain=$(jq -er '.inbounds[0].tls.server_name' "$(cfg "$five")")
    valid_domain "$domain"
    if [[ ${1:-} == --publish ]]; then
        if ! grep -Fq "handle_path $prefix/*" "$caddyfile"; then
            [[ $(grep -cxF "$domain:8443 {" "$caddyfile") == 1 ]] || fail '未找到唯一的 8443 站点'
            auth_block
            cat >"$scratch/block" <<CADDY
    handle_path $prefix/* {
        $auth {
            lax $hash
        }
        header Cache-Control "no-store"
        root * $profiles/five
        file_server
    }
CADDY
            awk -v marker="$domain:8443 {" -v block="$scratch/block" '
              {print} $0 == marker {while ((getline line < block) > 0) print line}
            ' "$caddyfile" >"$scratch/Caddyfile"
            reload_site "$scratch/Caddyfile"
        fi
        for label in "${kinds[@]}" all; do
            for ext in json sub; do
                test -s "$dir/$label.$ext"
                auth_required "$domain" "$prefix/$label.$ext"
            done
        done
        profile_dir "$profiles"
        profile_dir "$profiles/five"
        for label in "${kinds[@]}" all; do
            for ext in json sub; do
                put "$profiles/five/$label.$ext" 640 caddy <"$dir/$label.$ext"
            done
        done
    fi
    while IFS= read -r link; do
        label=${kinds[i]}
        printf '\n[%s]\n' "$label"
        show_qr "$link"
        if [[ ${1:-} == --publish ]]; then
            printf '订阅 https://%s%s/%s.sub\nsing-box https://%s%s/%s.json\n' "$domain" "$prefix" "$label" "$domain" "$prefix" "$label"
        fi
        i=$((i+1))
    done <"$dir/links.txt"
    printf '\n全部节点链接\n'
    cat "$dir/links.txt"
    if [[ ${1:-} == --publish ]]; then
        printf '\n聚合订阅，用户名 lax\n'
        show_qr "https://$domain$prefix/all.sub"
        printf '聚合 sing-box JSON https://%s%s/all.json\n' "$domain" "$prefix"
    fi
}

help_text() {
    cat <<'HELP'
Lauritz Duo
  packages [--version VERSION]
  uninstall
  site DOMAIN
  deploy DOMAIN [--ipv6]
  status [DOMAIN]
  links
  export IPV4 OUTPUT [--template FILE] [--hop-range START:END]
  publish IPV4 [--template FILE] [--hop-range START:END]
  rules SERVICE
  hopping FIRST LAST
  five DOMAIN IPV4 [--ports P1,P2,P3,P4,P5] [--uuid UUID] [--template FILE]
  five-share [--publish]
HELP
}

command_name=${1:---help}
case "$command_name" in --help|-h) help_text; exit 0;; esac
shift
[[ $OSTYPE == linux* && $EUID == 0 ]] || fail '请在 Ubuntu/Debian VPS 的 root 会话中运行'
exec 9>/run/lock/sing-box-yg-plus.lock
flock -n 9 || fail '另一个 Lauritz Duo 操作正在运行'
scratch=$(mktemp -d)
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
case "$command_name" in
    packages) packages "$@";;
    uninstall) [[ $# == 0 ]] || fail '用法 uninstall'; uninstall;;
    site) [[ $# == 1 ]] || fail '用法 site DOMAIN'; site "$1";;
    deploy)
        [[ $# == 1 || ( $# == 2 && $2 == --ipv6 ) ]] || fail '用法 deploy DOMAIN [--ipv6]'
        deploy "$@";;
    status)
        [[ $# -le 1 ]] || fail '用法 status [DOMAIN]'
        systemctl --no-pager show "$real" "$hy2" caddy -p Id -p ActiveState -p UnitFileState -p ExecStart || true
        ss -lntup '( sport = :22 or sport = :80 or sport = :443 or sport = :8443 )'
        ip -6 addr show scope global
        if (( $# )); then valid_domain "$1"; getent ahosts "$1"; site_curl "$1" / -fsS; printf '\n'; fi;;
    links) [[ $# == 0 ]] || fail '用法 links'; dual_links;;
    rules) [[ $# == 1 ]] || fail '用法 rules SERVICE'; rules "$1";;
    hopping) [[ $# == 2 ]] || fail '用法 hopping FIRST LAST'; hopping "$@";;
    five-share)
        [[ $# == 0 || ( $# == 1 && $1 == --publish ) ]] || fail '用法 five-share [--publish]'
        five_share "$@";;
    five|publish|export)
        host=${1:-}; arg=${2:-}; port_text=''; uuid_text=''; range=''
        case "$command_name" in
            five|export) [[ $# -ge 2 ]] || fail '缺少位置参数'; shift 2;;
            publish) [[ $# -ge 1 ]] || fail '缺少 VPS IPv4'; shift;;
        esac
        while (( $# )); do
            [[ $# -ge 2 ]] || fail "缺少 $1 的值"
            case "$command_name:$1" in
                *:--template) template=$2;;
                five:--ports) port_text=$2;;
                five:--uuid) uuid_text=$2;;
                export:--hop-range|publish:--hop-range) range=$2;;
                *) fail "未知参数 $1";;
            esac
            shift 2
        done
        if [[ $command_name == five ]]; then five_deploy "$host" "$arg" "$port_text" "$uuid_text"
        else
            domain='' public=''
            sync_profile "$host" "$range"
            if [[ $command_name == publish ]]; then publish_dual "$domain"
            else
                (set -o noclobber; cat "$scratch/profile.json" >"$arg") || fail '无法写入，请使用新的文件名'
                printf '本地客户端配置已写入 %s。文件含节点凭据。\n' "$arg"
            fi
        fi;;
    *) fail "未知命令 $command_name";;
esac
