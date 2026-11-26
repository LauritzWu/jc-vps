#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only

jc_root=/usr/local/lib/jc
jc_launcher=/usr/local/bin/jc

jc_bundle_id_valid() {
    [[ $1 =~ ^(main|[0-9a-f]{40})-[0-9a-f]{64}$ ]]
}

jc_switch_bundle() (
    local next=$1 temp='' current='' previous='' state=()
    exec 9>"$jc_root/lock" || return 1
    flock 9 || return 1
    if [[ -f $jc_root/active ]]; then
        mapfile -t state <"$jc_root/active" || return 1
        current=${state[0]:-}
        previous=${state[1]:-}
    fi
    if [[ $next == --rollback ]]; then
        next=$previous
        if [[ -z $next ]]; then
            printf '没有可回退的本地 JC 版本。\n' >&2
            return 1
        fi
    fi
    jc_bundle_id_valid "$next" || return 1
    [[ -z $current ]] || jc_bundle_id_valid "$current" || return 1
    bash "$jc_root/versions/$next/bootstrap.sh" --installed --check || return 1
    [[ $next != "$current" ]] || return 0
    temp=$(mktemp "$jc_root/.active.XXXXXX") || return 1
    trap 'rm -f -- "$temp"' EXIT
    printf '%s\n%s\n' "$next" "$current" >"$temp" &&
        mv -fT -- "$temp" "$jc_root/active" || return 1
    printf 'jc 当前本地版本：%s\n' "${next%-*}"
)

jc_install_launcher() (
    local source=$1 installed=$2 hash revision id stage='' temp=''
    if [[ -e $jc_launcher || -L $jc_launcher ]] &&
       ! { [[ -f $jc_launcher && ! -L $jc_launcher ]] &&
           grep -qxF -e '# Managed by JC' -e '# Managed by Lauritz Duo' "$jc_launcher"; }; then
        printf '发现其他程序使用 %s，保留原文件。\n' "$jc_launcher" >&2
        return 1
    fi
    trap '[[ -z $stage ]] || rm -rf -- "$stage"; [[ -z $temp ]] || rm -f -- "$temp"' EXIT
    if ! $installed; then
        if mkdir -m 750 -- "$jc_root" 2>/dev/null; then
            touch "$jc_root/.managed-by-jc" || return 1
        fi
        if [[ -L $jc_root || ! -f $jc_root/.managed-by-jc ]]; then
            printf '无法确认 %s 由 JC 管理。\n' "$jc_root" >&2
            return 1
        fi
        mkdir -p -m 750 -- "$jc_root/versions" || return 1
        IFS= read -r revision <"$source/revision" || return 1
        hash=$(sha256sum <"$source/bootstrap.sh") || return 1
        id="$revision-${hash%% *}"
        jc_bundle_id_valid "$id" || return 1
        if [[ ! -d $jc_root/versions/$id ]]; then
            stage=$(mktemp -d "$jc_root/versions/.stage.XXXXXX") || return 1
            cp -rT -- "$source" "$stage" || return 1
            mv -T -- "$stage" "$jc_root/versions/$id" || [[ -d $jc_root/versions/$id ]] || return 1
        fi
        jc_switch_bundle "$id" || return 1
    fi

    temp=$(mktemp "$(dirname -- "$jc_launcher")/.jc.XXXXXX") || return 1
    {
        printf '%s\n' '#!/usr/bin/env bash' '# Managed by JC' 'set -eu'
        printf 'root=%q\n' "$jc_root"
        cat <<'JC'
if ! IFS= read -r id <"$root/active" ||
   [[ ! $id =~ ^(main|[0-9a-f]{40})-[0-9a-f]{64}$ ]]; then
    printf '找不到有效的本地 JC 版本，请重新安装管理入口。\n' >&2
    exit 1
fi
exec bash "$root/versions/$id/bootstrap.sh" --installed "$@"
JC
    } >"$temp" || return 1
    if [[ -x $jc_launcher ]] && cmp -s -- "$temp" "$jc_launcher"; then return 0; fi
    chmod 0755 "$temp" && mv -fT -- "$temp" "$jc_launcher" || return 1
    printf '已安装本地 jc 快捷命令。\n'
)
