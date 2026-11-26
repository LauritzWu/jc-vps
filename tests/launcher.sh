#!/usr/bin/env bash
set -euo pipefail
source lib/launcher.sh

root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
jc_root="$root/local"
jc_launcher="$root/jc"

make_bundle() {
    local dir=$1 revision=$2 label=$3 result=$4
    mkdir "$dir"
    printf '%s\n' "$revision" >"$dir/revision"
    cat >"$dir/bootstrap.sh" <<EOF
#!/usr/bin/env bash
[[ \$1 == --installed ]] || exit 2
case \${2:-} in
    --check) exit $result ;;
    --rollback) source lib/launcher.sh; jc_root='$jc_root'; jc_switch_bundle --rollback ;;
    '') printf '%s\n' '$label' ;;
    *) exit 2 ;;
esac
EOF
}

make_bundle "$root/one" 1111111111111111111111111111111111111111 one 0
make_bundle "$root/two" 2222222222222222222222222222222222222222 two 0
make_bundle "$root/rejected" 3333333333333333333333333333333333333333 rejected 1
printf '%s\n' '#!/usr/bin/env bash' '# Managed by JC' 'exit 91' >"$jc_launcher"
chmod +x "$jc_launcher"

jc_install_launcher "$root/one" false
[[ $("$jc_launcher") == one ]]
if "$jc_launcher" --rollback; then exit 1; fi
jc_install_launcher "$root/two" false
[[ $("$jc_launcher") == two ]]
if jc_install_launcher "$root/rejected" false; then exit 1; fi
[[ $("$jc_launcher") == two ]]
"$jc_launcher" --rollback
[[ $("$jc_launcher") == one ]]
"$jc_launcher" --rollback
[[ $("$jc_launcher") == two ]]

source <(sed -n '/^install_shortcut() {$/,/^init_tools() {$/p' bootstrap.sh | sed '$d')
dir="$root/two"
installed=false
ln -sT -- jc "$root/singdeck"
ln -sT -- jc "$root/JC"
install_shortcut
[[ $(readlink -- "$root/sd") == jc ]]
[[ $("$root/sd") == two && $("$root/singdeck") == two && $("$root/JC") == two ]]
install_shortcut

source <(sed -n '/^remove_sd_shortcut() {$/,/^}$/p' bootstrap.sh)
remove_sd_shortcut
[[ ! -e $root/sd && ! -L $root/sd ]]
[[ $("$jc_launcher") == two && $("$root/singdeck") == two && $("$root/JC") == two ]]
if remove_sd_shortcut; then exit 1; fi
printf '%s\n' 'unrelated command' >"$root/sd"
if install_shortcut; then exit 1; fi
if remove_sd_shortcut; then exit 1; fi
grep -qxF 'unrelated command' "$root/sd"
[[ $("$jc_launcher") == two ]]

echo 'Local launcher migration, failed upgrade, rollback and SingDeck shortcuts passed'
