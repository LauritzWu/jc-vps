#!/usr/bin/env bash
set -euo pipefail

test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT
mkdir -p "$test_dir/bundle/lib" "$test_dir/config/jc" "$test_dir/bin"
cp bootstrap.sh manager.sh client-template.json "$test_dir/bundle/"
cp lib/{firewall,launcher,ui}.sh "$test_dir/bundle/lib/"
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
(
    source <(sed -n '/^home_menu() {$/,/^finish_menu() {$/p' bootstrap.sh | sed '$d')
    heading() { printf '\n%s\n' "$1"; }
    option() { printf ' %s  %s\n' "$1" "$2"; }
    home_menu true
) >"$test_dir/deployed"
for layout in wide narrow deployed; do
    mapfile -t numbers < <(sed -nE 's/^ ([0-9])  .*/\1/p' "$test_dir/$layout")
    [[ "${numbers[*]}" == '1 2 3 4 5 6 7 8 9 0' ]]
done
grep -Fq '1  一键安装 sing-box' "$test_dir/wide"
grep -Fq '1  部署概况' "$test_dir/deployed"
grep -Eq '3  服务状态[[:space:]]*$' "$test_dir/wide"
grep -Fq 'SingDeck' "$test_dir/wide"
grep -Fq 'SingDeck' "$test_dir/narrow"
grep -Fq '⢠⣶⣄' "$test_dir/wide"
grep -Fq '⣴⣦' "$test_dir/narrow"
if grep -Eq '完整卸载|IPv6' "$test_dir/wide" || grep -Fq $'\033[' "$test_dir/wide"; then
    exit 1
fi

run_menu 96 $'2\n0\n7\n0\n0' >"$test_dir/tools"
grep -Fq '3  最近 50 条 Caddy 日志' "$test_dir/tools"
grep -Fq '6  完整卸载 sing-box 和 SingDeck' "$test_dir/tools"

run_menu 96 $'\n0\n\n0' >"$test_dir/default-one"
grep -Fq '回车默认 1，0 退出' "$test_dir/default-one"
grep -Fq '一键安装 sing-box · 五协议' "$test_dir/default-one"

NO_COLOR='' TERM=xterm-256color COLORTERM=truecolor JC_THEME=light run_menu 96 0 >"$test_dir/light"
grep -Fq $'\033[38;2;41;39;35m服务状态' "$test_dir/light"

NO_COLOR='' TERM=xterm-256color COLORTERM='' JC_THEME=dark run_menu 48 0 >"$test_dir/colored"
grep -Fq $'\033[38;5;254m服务状态' "$test_dir/colored"
grep -Fq $'\033[0m\033[38;5;254m' "$test_dir/colored"
grep -Fq $'\033[38;5;173m3' "$test_dir/colored"
grep -Fq $'\033[38;5;248m' "$test_dir/colored"

NO_COLOR='' TERM=xterm-256color COLORTERM=truecolor JC_THEME=dark run_menu 96 0 >"$test_dir/dark"
grep -Fq $'\033[38;2;232;228;219m' "$test_dir/dark"
grep -Fq $'\033[38;2;181;174;162m' "$test_dir/dark"
grep -Fq $'\033[38;2;212;150;125m' "$test_dir/dark"

JC_BANNER=plain run_menu 96 0 >"$test_dir/plain"
grep -Fq 'SingDeck · VPS 管理' "$test_dir/plain"
if grep -Fq '⢠⣶⣄' "$test_dir/plain"; then exit 1; fi
[[ ! -e $JC_NETWORK_LOG ]]

printf '\n%s\n' 'SingDeck home · 96 columns'
cat "$test_dir/wide"
printf '\n%s\n' 'SingDeck home · 48 columns'
cat "$test_dir/narrow"
echo 'Offline menu width, shortcuts, banner and colors passed'
