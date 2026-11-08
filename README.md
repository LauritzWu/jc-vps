# JC · sing-box VPS 管理工具

面向个人 VPS 的 sing-box 管理工具。使用官方 APT 版 sing-box，提供五协议安装向导，支持选择 IPv4 或 IPv6 节点地址，并可发布带密码的 HTTPS 订阅，并兼容已有 REALITY / Hysteria 2 主备服务。

## 安装 v1.1.0

在 VPS 的 root Bash 会话中运行。入口需要 curl。安装脚本、管理脚本、客户端模板和后续的 `jc` 命令均使用同一提交。

```bash
revision=cb3f61c6a6c963d52e011af1454490b721a362a0
s=$(curl -4fsSL -m 25 "https://raw.githubusercontent.com/LauritzWu/lauritz-duo/$revision/bootstrap.sh") &&
  bash -c "$s" -- "$revision"
```

在菜单选「6 一键安装 sing-box」。其他版本的安装命令见 [GitHub Releases](https://github.com/LauritzWu/lauritz-duo/releases)。

**已验收范围**为 Ubuntu 24.04 LTS 和 Debian 13，均为 x86_64、IPv4。五个协议均通过公网连通测试，两套系统也通过了公信证书签发、订阅认证、重启恢复、内核切换和失败回退，以及卸载重装。五协议也已通过公网 IPv6 连通测试，IPv6 订阅已在隔离环境验收，分享链接已通过 v2rayN 导入检查。详见 [v1.1.0 发布说明](https://github.com/LauritzWu/lauritz-duo/releases/tag/v1.1.0)。

首页包含服务状态、服务管理、客户端与订阅、网络与防火墙和系统工具。支持数字选择、回车默认和子菜单按 0 返回。底部显示系统、接口地址和服务状态。服务器地区通过 ipwho.is 按 VPS 公网出口 IP 查询并缓存 24 小时。5 → 3 可手动覆盖，已保存的地区优先使用。

首次运行自动安装 `jc` 快捷命令，并通过 APT 补齐缺失的 jq、qrencode、OpenSSL、iproute2 和 flock。以后输入 `jc` 即可打开菜单。已有 `duo` 的用户可运行一次 `duo`，新版会自动安装 `jc`。主菜单选「6 一键安装 sing-box」，按顺序选择内核、输入域名和公网节点地址（IPv4 或 IPv6）、分配端口、生成或填写 UUID，最后确认安装。旧主备仍可在「2 服务管理」启动。

## 卸载和重装

主菜单选「7 完整卸载 JC」后，输入 `1` 确认，输入 `0` 或直接回车取消。确认后会停止 JC 服务、移除官方软件包，并删除 JC 节点配置、凭据、订阅文件和快捷命令。Caddy 网站及订阅路由定义、证书、防火墙和手动保存的备份会保留。重新安装时请使用上面的一键命令。

## 已搭好主备的 VPS

先把本目录传到 VPS。通过 SSH 运行以下命令，替换示例域名和 IPv4。

    bash duo.sh status node.example.com
    bash duo.sh publish 203.0.113.10

publish 使用随附的无凭据模板，从现有 /etc/sing-box-reality 和 /etc/sing-box-hy2 读取参数。它要求现有 Caddy 站点采用此前部署的 8443 布局。首次发布时设置订阅密码。发布后验证匿名请求返回 401、认证请求返回 200，再导入远程配置。

## 新 VPS

确认域名直指 VPS，公网 TCP 80 可用于 Caddy 签发和续期，随后选主菜单 6。每次安装选择一种节点地址。选择 IPv6 时，输入不带方括号的公网地址，并确认 VPS 和客户端都具备 IPv6 连通性。下载安装脚本和依赖仍需要 VPS 的 IPv4 出站。安装后按输出在云防火墙放行各协议对应的 TCP 或 UDP 端口。客户端验收通过后，在「2 服务管理」开启五协议自启动。命令行入口见 `bash duo.sh --help`。

## 五协议节点与订阅

- 协议为 REALITY、VMess WS + TLS、Hysteria 2、TUIC 和 AnyTLS。可随机选端口，也可指定五个端口。随机检查本机监听，云防火墙还需单独放行。UUID 可生成或指定，三种密码型协议各自生成密码。
- 3 → 6 显示五条链接和二维码。3 → 7 发布六份 sing-box JSON 和六份 Base64 链接订阅，含单节点和聚合版本。订阅通过五协议的 REALITY TCP 端口访问，使用 HTTPS Basic Auth。
- 4 → 1 可按 TCP/UDP 放行指定端口或范围；全开只对已启用的本机 UFW 生效，需手动输入 OPEN-ALL 确认。回退可用 ufw status numbered 找到 JC open all 规则，再用 ufw delete 编号移除。
- 5 → 1 支持官方 APT 候选版本或指定仓库版本。切换前会下载当前版本作为回退包。运行中的 JC 服务会短暂重启。若安装、配置校验或监听检查失败，脚本会尝试恢复原版本及服务。恢复失败时会显示保留的安装包路径。切换后请用客户端复测。

## 连不上时怎么查

1. 运行 `jc`，选「1 服务状态」。检查五协议服务是否运行。再运行 `ss -lntup`，核对安装向导列出的端口是否在本机监听。
2. 若本机已监听，从云服务商面板核对入站规则。REALITY、VMess 和 AnyTLS 用 TCP，Hysteria 2 和 TUIC 用 UDP。按安装向导显示的端口逐个检查。
3. 若证书签发失败，检查域名 A 记录是否指向 VPS，公网 TCP 80 是否开放。运行 `journalctl -u caddy -n 50 --no-pager` 查看原因。若域名也有 AAAA 记录，确认对应 IPv6 的 TCP 80 同样可达。
4. 若订阅下载失败，用浏览器打开菜单生成的 HTTPS 地址。匿名访问应要求认证。输入正确凭据后应能下载配置。分享排障信息前，删去节点链接、订阅密码和私钥。

## 来源与许可

此版本从此前为 sing-box-yg 改版编写的独立管理模块拆出。发行包不包含上游 sb.sh，旧菜单、旧快捷入口及旧脚本的自更新逻辑已移除。原型参考 yonggekkk/sing-box-yg，基准提交 b13f9435c4792fccf04d4fbc73e24a1948abff1b。项目独立维护，与上游作者及 SagerNet 无隶属关系。代码采用 GPL-3.0，许可证见 LICENSE。

证书自然续期后的公网复测和 HY2 公网端口跳跃仍待验收。见 [VPS 验收清单](docs/vps-acceptance.md)。
