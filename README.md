# Lauritz Duo

面向个人 VPS 的 sing-box 双协议管理工具。使用官方 APT 版 sing-box，提供 REALITY 主线、Hysteria 2 备用、Caddy HTTPS、国内目标拒绝规则和受密码保护的远程配置。

## 一键打开菜单

在 Ubuntu 或 Debian VPS 的 Bash 会话中粘贴。需要 curl 和 Python 3。

```bash
f=$(mktemp) && curl -4 -fSL --connect-timeout 8 --max-time 25 https://raw.githubusercontent.com/LauritzWu/lauritz-duo/main/bootstrap.sh -o "$f" && bash "$f"; r=$?; if [ -n "$f" ]; then rm -f -- "$f"; fi; (exit "$r")
```

菜单支持数字选择、回车默认及 0 返回。选 2 导出客户端配置并查看验收步骤，选 3 检查端口或向现有 UFW 放行必要端口，选 7 查看或更新官方 APT 稳定版。进入菜单时只下载程序和模板。管理操作从菜单选择后执行。新 VPS 选 4 引导安装、签发证书并部署主备。若证书等待超时，修好 DNS 或 TCP 80 后选 5 续跑。

## 已搭好主备的 VPS

先把本目录传到 VPS。通过 SSH 运行以下命令，替换示例域名和 IPv4。

    bash duo.sh status node.example.com
    bash duo.sh publish 203.0.113.10

publish 使用随附的无凭据模板，从现有 /etc/sing-box-reality 和 /etc/sing-box-hy2 读取参数。它要求现有 Caddy 站点采用此前部署的 8443 布局。首次设置订阅密码，随后验证匿名请求返回 401、认证请求返回 200，再导入远程配置。

## 新 VPS

确认域名直指 VPS，公网 TCP 80、TCP 443、UDP 443 可用。分步执行：

    bash duo.sh packages
    bash duo.sh site node.example.com
    bash duo.sh status node.example.com
    bash duo.sh deploy node.example.com

先验证 Caddy 公信证书，再运行 deploy。外网验收两条线路后，用 systemctl enable sing-box-reality sing-box-hy2 设置开机启动。其他命令见 bash duo.sh --help。应用 rules 前使用另一条线路或独立 SSH。启用 hopping 前核对 UDP 范围及现有 NAT，IPv6 和证书续期需另行实测。Hy2 读取 Caddy 私有证书目录时会使用 CAP_DAC_READ_SEARCH，这项能力的范围不限于证书目录。

## 来源与许可

此版本从此前为 sing-box-yg 改版编写的独立管理模块拆出。发行包不包含上游 sb.sh，旧菜单、旧快捷入口及旧脚本的自更新逻辑已移除。原型参考 yonggekkk/sing-box-yg，基准提交 b13f9435c4792fccf04d4fbc73e24a1948abff1b。项目独立维护，与上游作者及 SagerNet 无隶属关系。代码采用 GPL-3.0，许可证见 LICENSE。

当前为 0.1.0 预览版。客户端生成曾用测试凭据校验。VPS 上安装、证书续期、跳跃和 IPv6 需现场验收。
