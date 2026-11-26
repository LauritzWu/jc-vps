#!/usr/bin/env bash
set -euo pipefail

test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT
mkdir -p "$test_dir/bundle/lib" "$test_dir/config/jc" "$test_dir/bin"
cp bootstrap.sh manager.sh client-template.json "$test_dir/bundle/"
cp lib/{firewall,launcher}.sh "$test_dir/bundle/lib/"
printf '%s\n' 1111111111111111111111111111111111111111 >"$test_dir/bundle/revision"
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
run_menu() {
    local columns=$1 input=$2
    printf '%s\n' "$input" |
        timeout 15 script -qec "stty rows 24 cols $columns -echo && bash '$test_dir/bundle/bootstrap.sh' --installed" /dev/null
}

run_menu 96 0 >"$test_dir/wide"
run_menu 48 0 >"$test_dir/narrow"
grep -Fq 'VPS 管理' "$test_dir/wide"
grep -Fq '▀▀▀▀▀▌' "$test_dir/wide"
grep -Eq '3  服务状态 +4  服务管理' "$test_dir/wide"
grep -Eq '3  服务状态[[:space:]]*$' "$test_dir/narrow"
grep -Eq '4  服务管理[[:space:]]*$' "$test_dir/narrow"
grep -Fq '1  一键安装 sing-box' "$test_dir/narrow"
grep -Fq 'GERMAN SHEPHERD EDITION' "$test_dir/wide"
grep -Fq '⢠⣶⣄' "$test_dir/wide"
grep -Fq '⣴⣦' "$test_dir/narrow"
if grep -Eq '完整卸载|IPv6' "$test_dir/wide" || grep -Fq $'\033[' "$test_dir/wide"; then
    exit 1
fi

run_menu 96 $'2\n0\n0' >"$test_dir/tools"
grep -Fq '6  完整卸载 sing-box 和 JC' "$test_dir/tools"

NO_COLOR='' TERM=xterm-256color COLORTERM=truecolor JC_THEME=light run_menu 96 0 >"$test_dir/light"
grep -Fq $'\033[38;2;118;91;62m' "$test_dir/light"
grep -Fq 'GERMAN SHEPHERD EDITION' "$test_dir/light"

NO_COLOR='' TERM=xterm-256color COLORTERM='' JC_THEME=dark run_menu 48 0 >"$test_dir/colored"
grep -Fq $'\033[38;5;253m服务状态' "$test_dir/colored"
grep -Fq $'\033[38;5;180m3' "$test_dir/colored"
grep -Fq $'\033[38;5;137m' "$test_dir/colored"

NO_COLOR='' TERM=xterm-256color COLORTERM=truecolor JC_THEME=dark run_menu 96 0 >"$test_dir/dark"
grep -Fq $'\033[38;2;202;184;158m' "$test_dir/dark"
grep -Fq $'\033[38;2;174;150;122m' "$test_dir/dark"

JC_BANNER=plain run_menu 96 0 >"$test_dir/plain"
grep -Fq 'JC · VPS 管理' "$test_dir/plain"
if grep -Fq 'GERMAN SHEPHERD EDITION' "$test_dir/plain"; then exit 1; fi
[[ ! -e $JC_NETWORK_LOG ]]

printf '\n%s\n' 'JC home · 96 columns'
cat "$test_dir/wide"
printf '\n%s\n' 'JC home · 48 columns'
cat "$test_dir/narrow"
echo 'Offline menu width, shortcuts, banner and colors passed'
