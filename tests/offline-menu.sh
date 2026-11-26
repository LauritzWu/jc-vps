#!/usr/bin/env bash
set -euo pipefail

test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT
mkdir -p "$test_dir/bundle/lib" "$test_dir/config/jc" "$test_dir/bin"
cp bootstrap.sh manager.sh client-template.json "$test_dir/bundle/"
cp lib/{firewall,launcher}.sh "$test_dir/bundle/lib/"
printf '%s\n' 1111111111111111111111111111111111111111 >"$test_dir/bundle/revision"
printf '%s\n' 'Offline test' >"$test_dir/config/jc/region"
for command in curl apt-get; do
    cat >"$test_dir/bin/$command" <<'BASH'
#!/usr/bin/env bash
printf '%s\n' "$0" >>"$JC_NETWORK_LOG"
exit 97
BASH
    chmod +x "$test_dir/bin/$command"
done
export PATH="$test_dir/bin:$PATH" XDG_CONFIG_HOME="$test_dir/config" NO_COLOR=1
export JC_NETWORK_LOG="$test_dir/network"
printf '0\n' | timeout 15 script -qec "bash '$test_dir/bundle/bootstrap.sh' --installed" /dev/null >"$test_dir/menu"
grep -Fq '管理菜单' "$test_dir/menu"
[[ ! -e $JC_NETWORK_LOG ]]
echo 'Installed JC menu opened with curl and APT blocked'
