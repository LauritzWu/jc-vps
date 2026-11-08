# JC

面向个人 VPS 的 sing-box 管理工具。使用官方 APT 版 sing-box，提供五协议安装向导、Caddy HTTPS 和受密码保护的远程配置，并兼容已有 REALITY / Hysteria 2 主备服务。

## 一键打开预览版菜单

在 Ubuntu 或 Debian VPS 的 root Bash 会话中粘贴。入口需要 curl。菜单和管理命令使用 Bash，JSON 由 jq 处理。

将鼠标移到下面的代码块，点击右上角的 **复制** 图标，然后在 Termius 粘贴整段。

```bash
s=$(curl -4fsSL -m 25 \
  https://raw.githubusercontent.com/LauritzWu/lauritz-duo/main/bootstrap.sh) && bash -c "$s"
```

首页包含服务状态、服务管理、客户端与订阅、网络与防火墙和系统工具。支持数字选择、回车默认和子菜单按 0 返回。底部显示系统、接口地址和服务状态。服务器地区通过 ipwho.is 按 VPS 公网出口 IP 查询并缓存 24 小时。5 → 3 可手动覆盖，已保存的地区优先使用。

首次运行自动安装 `jc` 快捷命令，并通过 APT 补齐缺失的 jq、qrencode、OpenSSL、iproute2 和 flock。以后输入 `jc` 即可打开菜单。已有 `duo` 的用户可运行一次 `duo`，新版会自动安装 `jc`。主菜单选「6 一键安装 sing-box」，按顺序选择内核、输入域名和 IPv4、分配端口、生成或填写 UUID，最后确认安装。旧主备仍可在「2 服务管理」启动。

## 按提交固定版本

从待安装版本的 GitHub 发布页获取完整的 40 位提交 SHA，替换下面的 `完整提交SHA`。选择包含此安装方式的版本。入口、管理脚本、模板及后续的 `jc` 调用均使用同一提交。要切换版本，使用目标提交重新运行这段命令。

```bash
revision=完整提交SHA
[[ $revision =~ ^[0-9a-f]{40}$ ]] &&
  s=$(curl -4fsSL -m 25 "https://raw.githubusercontent.com/LauritzWu/lauritz-duo/$revision/bootstrap.sh") &&
  bash -c "$s" -- "$revision"
```

主菜单选「7 完整卸载 JC」后，输入 `1` 确认，输入 `0` 或直接回车取消。确认后会停止 JC 服务、移除官方软件包，并删除 JC 节点配置、凭据、订阅文件和快捷命令。Caddy 网站及订阅路由定义、证书、防火墙和手动保存的备份会保留。重新安装时请使用上面的一键命令。

## 已搭好主备的 VPS

先把本目录传到 VPS。通过 SSH 运行以下命令，替换示例域名和 IPv4。

    bash duo.sh status node.example.com
    bash duo.sh publish 203.0.113.10

publish 使用随附的无凭据模板，从现有 /etc/sing-box-reality 和 /etc/sing-box-hy2 读取参数。它要求现有 Caddy 站点采用此前部署的 8443 布局。首次设置订阅密码，随后验证匿名请求返回 401、认证请求返回 200，再导入远程配置。

## 新 VPS

确认域名直指 VPS，公网 TCP 80 可用于 Caddy 签发和续期，随后选主菜单 6。安装后按输出在云防火墙放行各协议对应的 TCP 或 UDP 端口。客户端验收通过后，在「2 服务管理」开启五协议自启动。命令行入口见 `bash duo.sh --help`。

## 五协议节点与订阅

- 协议为 REALITY、VMess WS + TLS、Hysteria 2、TUIC 和 AnyTLS。可随机选端口，也可指定五个端口。随机检查本机监听，云防火墙还需单独放行。UUID 可生成或指定，三种密码型协议各自生成密码。
- 3 → 6 显示五条链接和二维码。3 → 7 发布六份 sing-box JSON 和六份 Base64 链接订阅，含单节点和聚合版本。订阅通过五协议的 REALITY TCP 端口访问，使用 HTTPS Basic Auth。
- 4 → 1 可按 TCP/UDP 放行指定端口或范围；全开只对已启用的本机 UFW 生效，需手动输入 OPEN-ALL 确认。回退可用 ufw status numbered 找到 JC open all 规则，再用 ufw delete 编号移除。
- 5 → 1 支持官方 APT 候选版本或指定仓库版本。切换前会下载当前版本作为回退包。运行中的 JC 服务会短暂重启。若安装、配置校验或监听检查失败，脚本会尝试恢复原版本及服务。恢复失败时会显示保留的安装包路径。切换后请用客户端复测。

测试凭据下，五协议服务端配置及六份客户端 JSON 已通过 sing-box 检查，订阅内容已验证可解码。实际 VPS 部署、公开端口、认证订阅和各客户端连通需单独验收。

## 来源与许可

此版本从此前为 sing-box-yg 改版编写的独立管理模块拆出。发行包不包含上游 sb.sh，旧菜单、旧快捷入口及旧脚本的自更新逻辑已移除。原型参考 yonggekkk/sing-box-yg，基准提交 b13f9435c4792fccf04d4fbc73e24a1948abff1b。项目独立维护，与上游作者及 SagerNet 无隶属关系。代码采用 GPL-3.0，许可证见 LICENSE。

当前为 0.1.0 预览版。客户端生成曾用测试凭据校验。VPS 上安装、证书续期、跳跃和 IPv6 需现场验收，见 [VPS 验收清单](docs/vps-acceptance.md)。
