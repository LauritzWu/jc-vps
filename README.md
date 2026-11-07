# Lauritz Duo

面向个人 VPS 的 sing-box 双协议管理工具。使用官方 APT 版 sing-box，提供 REALITY 主线、Hysteria 2 备用、Caddy HTTPS、国内目标拒绝规则和受密码保护的远程配置。

## 一键打开菜单

在 Ubuntu 或 Debian VPS 的 Bash 会话中粘贴。需要 curl 和 Python 3。

```bash
f=$(mktemp) && curl -4 -fSL --connect-timeout 8 --max-time 25 https://raw.githubusercontent.com/LauritzWu/lauritz-duo/main/bootstrap.sh -o "$f" && bash "$f"; r=$?; if [ -n "$f" ]; then rm -f -- "$f"; fi; (exit "$r")
```

首页分为服务状态、安装与部署、客户端与订阅、网络与防火墙、系统工具。支持数字选择、回车默认和子菜单按 0 返回。底部显示系统、接口地址和服务状态。服务器地区通过 ipwho.is 按 VPS 公网出口 IP 查询并缓存 24 小时。5 → 3 可手动覆盖，已保存的地区优先使用。

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

## 五协议预览

2 → 3 → 1 创建独立的五协议服务。需提前完成同机 Caddy 证书签发，并使用支持这五种协议的内核。现有双协议服务仍可单独管理。

- 协议为 REALITY、VMess WS + TLS、Hysteria 2、TUIC 和 AnyTLS。可随机选端口，也可指定五个端口。随机检查本机监听，云防火墙还需单独放行。UUID 可生成或指定，三种密码型协议各自生成密码。
- 2 → 3 → 2 显示五条链接和二维码。二维码使用本机 qrencode，可从 3 → 5 安装。2 → 3 → 3 发布六份 sing-box JSON 和六份 Base64 链接订阅，含单节点和聚合版本。订阅要求 HTTPS Basic Auth。聚合二维码指向订阅地址，导入时还需输入凭据。
- 4 → 1 可按 TCP/UDP 放行指定端口或范围；全开只对已启用的本机 UFW 生效，需手动输入 OPEN-ALL 确认。回退可用 ufw status numbered 找到 Lauritz Duo open all 规则，再用 ufw delete 编号移除。
- 5 → 1 支持官方 APT 候选版本或指定仓库版本。旧版可能无法加载含 AnyTLS 的配置，升级或降级后先校验配置，再逐个重启服务。

测试凭据下，五协议服务端配置及六份客户端 JSON 已通过 sing-box 检查，订阅内容已验证可解码。实际 VPS 部署、公开端口、认证订阅和各客户端连通需单独验收。

## 来源与许可

此版本从此前为 sing-box-yg 改版编写的独立管理模块拆出。发行包不包含上游 sb.sh，旧菜单、旧快捷入口及旧脚本的自更新逻辑已移除。原型参考 yonggekkk/sing-box-yg，基准提交 b13f9435c4792fccf04d4fbc73e24a1948abff1b。项目独立维护，与上游作者及 SagerNet 无隶属关系。代码采用 GPL-3.0，许可证见 LICENSE。

当前为 0.1.0 预览版。客户端生成曾用测试凭据校验。VPS 上安装、证书续期、跳跃和 IPv6 需现场验收。
