#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Lauritz Duo dual-protocol manager."""
import argparse
import getpass
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

CORE = Path("/usr/bin/sing-box")
CADDY = Path("/etc/caddy/Caddyfile")
UNITS = Path("/etc/systemd/system")
PROFILES = Path("/var/lib/caddy/private-profiles")
SERVICES = ("sing-box-reality", "sing-box-hy2")
CN = {
    "cn-domains": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-geolocation-cn.srs",
    "cn-addresses": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs",
}
PROFILE_PATH = "/profiles/lax.json"


def run(*args, capture=False):
    return subprocess.run(args, check=True, text=True, stdout=subprocess.PIPE if capture else None).stdout


def write(path, data, mode=0o600, group=None):
    fd, name = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as out:
            out.write(data)
            if group is not None:
                os.fchown(out.fileno(), 0, group)
            os.fchmod(out.fileno(), mode)
        os.replace(name, path)
    finally:
        Path(name).unlink(missing_ok=True)


def encode(data):
    return (json.dumps(data, indent=2, ensure_ascii=False) + "\n").encode()


def config_path(service):
    return Path("/etc") / service / "config.json"


def read(path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def check_config(path, data):
    with tempfile.TemporaryDirectory(dir=path.parent) as tmp:
        candidate = Path(tmp) / "config.json"
        write(candidate, data)
        run(CORE, "check", "-c", candidate)


def checked_socket(service):
    flag = "-lntp" if service == SERVICES[0] else "-lnup"
    for _ in range(10):
        pid = run("systemctl", "show", "-p", "MainPID", "--value", service, capture=True).strip()
        rows = run("ss", "-H", flag, "( sport = :443 )", capture=True)
        if pid.isdigit() and int(pid) > 0 and f"pid={pid}," in rows:
            if Path(f"/proc/{pid}/exe").resolve() == CORE.resolve():
                return
        time.sleep(0.5)
    raise ValueError(f"{service} 未确认由官方程序监听 443")


def domain_name(value):
    if not re.fullmatch(r"(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,62}", value):
        raise ValueError("请输入有效的小写子域名")
    return value


def install_packages():
    if Path("/etc/systemd/system/sing-box.service").exists() and not CORE.exists():
        raise ValueError("发现旧同名服务，先完成迁移或在干净 VPS 上安装")
    if not all(shutil.which(name) for name in ("caddy", "curl")):
        run("apt-get", "update")
        run("apt-get", "install", "-y", "ca-certificates", "curl", "caddy")
    key = Path("/etc/apt/keyrings/sagernet.asc")
    key.parent.mkdir(exist_ok=True)
    if not key.exists():
        print("正在通过 IPv4 下载 SagerNet APT 签名密钥…", flush=True)
        try:
            data = run("curl", "-4", "-fsSL", "--retry", "2", "--retry-all-errors",
                       "--connect-timeout", "8", "--max-time", "15", "--retry-max-time", "35",
                       "https://sing-box.app/gpg.key", capture=True).encode()
        except subprocess.CalledProcessError:
            raise ValueError("SagerNet 签名密钥下载失败，检查 VPS 到 sing-box.app 的 HTTPS 连接。") from None
        if not data.startswith(b"-----BEGIN PGP PUBLIC KEY BLOCK-----"):
            raise ValueError("官方软件源密钥格式异常")
        write(key, data, 0o644)
    source = Path("/etc/apt/sources.list.d/sagernet.sources")
    apt_source = b"Types: deb\nURIs: https://deb.sagernet.org/\nSuites: *\nComponents: *\nSigned-By: /etc/apt/keyrings/sagernet.asc\n"
    if not source.exists():
        write(source, apt_source, 0o644)
    run("apt-get", "-o", "Acquire::ForceIPv4=true", "update")
    run("apt-get", "-o", "Acquire::ForceIPv4=true", "install", "-y", "sing-box")
    run(CORE, "version")


def reload_site(data):
    with tempfile.TemporaryDirectory() as tmp:
        candidate = Path(tmp) / "Caddyfile"
        write(candidate, data)
        run("caddy", "validate", "--config", candidate, "--adapter", "caddyfile")
    old = CADDY.read_bytes()
    backup = CADDY.with_name(f"Caddyfile.yg-plus.{time.time_ns()}.bak")
    write(backup, old)
    write(CADDY, data, 0o644)
    try:
        run("systemctl", "reload", "caddy")
    except subprocess.CalledProcessError:
        write(CADDY, old, 0o644)
        run("systemctl", "reload", "caddy")
        raise


def setup_site(domain):
    domain = domain_name(domain)
    old = CADDY.read_text()
    if domain + ":8443" in old:
        raise ValueError("已经有同域名的 8443 站点")
    if re.search(r"(?m)^\s*auto_https\b", old):
        raise ValueError("已有自定义 HTTPS 配置，请保留原配置并单独建立 8443 站点")
    block = f"""
{domain}:8443 {{
    bind 127.0.0.1
    tls {{
        issuer acme {{
            disable_tlsalpn_challenge
        }}
    }}
    respond "LAX server is online."
}}
"""
    # Preserve an installed default :80 site so Caddy can answer HTTP-01.
    if not re.search(r"(?m)^\s*:80\s*\{", old):
        raise ValueError("未检测到 Caddy 默认 :80 站点，停止自动修改")
    if re.search(r"(?m)^\s*\{\s*$", old):
        raise ValueError("检测到已有全局配置，请单独配置网站")
    reload_site(("{\n    auto_https disable_redirects\n}\n\n" + old + "\n" + block).encode())
    print("Caddy 已重载。证书签发需要公网 TCP 80，可用 status 检查。")


def find_cert(domain):
    root = Path("/var/lib/caddy/.local/share/caddy/certificates")
    certs = [p for p in root.glob(f"*/{domain}/{domain}.crt") if p.with_suffix(".key").is_file()]
    if len(certs) != 1:
        raise ValueError("需要恰好一组 Caddy 证书和私钥，先完成签发")
    cert = certs[0]
    run("openssl", "x509", "-in", cert, "-checkend", "0", "-noout")
    return cert


def server_config(inbound):
    return {
        "inbounds": [inbound], "outbounds": [{"type": "direct", "tag": "direct"}],
        "route": {"rules": [{"ip_is_private": True, "action": "reject"}], "final": "direct"},
    }


def deploy(domain, ipv6):
    domain = domain_name(domain)
    run("dpkg-query", "-S", CORE, capture=True)
    run("curl", "--noproxy", "*", "-fsS", "--max-time", "8", "--resolve",
        f"{domain}:8443:127.0.0.1", f"https://{domain}:8443/", capture=True)
    cert = find_cert(domain)
    for service in SERVICES:
        if config_path(service).parent.exists() or (UNITS / f"{service}.service").exists():
            raise ValueError("已存在主备服务，请使用 rules / publish / status 管理")
    if run("ss", "-H", "-lntup", "( sport = :443 )", capture=True).strip():
        raise ValueError("443 已被占用，请先核对现有服务")
    pair = run(CORE, "generate", "reality-keypair", capture=True)
    keys = {re.sub(r"[^a-z]", "", k.lower()): v.strip() for k, v in
            (line.split(":", 1) for line in pair.splitlines() if ":" in line)}
    private, public = keys["privatekey"], keys["publickey"]
    if any(not re.fullmatch(r"[A-Za-z0-9_-]{43}", key) for key in (private, public)):
        raise ValueError("密钥格式异常")
    user, short, password = str(uuid.uuid4()), secrets.token_hex(4), secrets.token_hex(24)
    listen = "::" if ipv6 else "0.0.0.0"
    real = server_config({
        "type": "vless", "listen": listen, "listen_port": 443,
        "users": [{"uuid": user, "flow": "xtls-rprx-vision"}],
        "tls": {"enabled": True, "server_name": domain, "reality": {
            "enabled": True, "private_key": private, "short_id": [short],
            "handshake": {"server": "127.0.0.1", "server_port": 8443}}},
    })
    hy2 = server_config({
        "type": "hysteria2", "listen": listen, "listen_port": 443,
        "users": [{"name": "lax", "password": password}],
        "tls": {"enabled": True, "certificate_path": str(cert), "key_path": str(cert.with_suffix(".key"))},
    })
    created = []
    started = []
    try:
        for service, doc in zip(SERVICES, (real, hy2)):
            path = config_path(service)
            path.parent.mkdir(mode=0o700)
            created.append(path.parent)
            data = encode(doc)
            check_config(path, data)
            write(path, data)
            cap = " CAP_DAC_READ_SEARCH" if service == SERVICES[1] else ""
            unit = UNITS / f"{service}.service"
            write(unit, f"""[Unit]
Description={service}
Wants=network-online.target caddy.service
After=network-online.target caddy.service
[Service]
ExecStart=/usr/bin/sing-box run -c {path}
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
CapabilityBoundingSet=CAP_NET_BIND_SERVICE{cap}
[Install]
WantedBy=multi-user.target
""".encode(), 0o644)
            created.append(unit)
        write(config_path(SERVICES[0]).parent / "client.txt",
              f"UUID={user}\nPublic key={public}\nShort ID={short}\n".encode())
        write(config_path(SERVICES[1]).parent / "client-uri.txt",
              f"hysteria2://{password}@{domain}:443/?sni={domain}&insecure=0#Lauritz-Duo-HY2\n".encode())
        run("systemctl", "daemon-reload")
        for service in SERVICES:
            started.append(service)
            run("systemctl", "start", service)
            checked_socket(service)
    except Exception:
        for service in reversed(started):
            subprocess.run(["systemctl", "stop", service], check=False)
        for path in reversed(created):
            if path.is_dir():
                for name in ("config.json", "client.txt", "client-uri.txt"):
                    (path / name).unlink(missing_ok=True)
                path.rmdir()
            else:
                path.unlink(missing_ok=True)
        subprocess.run(["systemctl", "daemon-reload"], check=False)
        raise
    print("两条线路已在本机监听。外网实测通过后启用开机启动。")


def update_rules(service):
    checked_socket(service)
    path = config_path(service)
    doc = read(path)
    route = doc["route"]
    private = {"ip_is_private": True, "action": "reject"}
    expected = [{"rule_set": "cn-domains", "action": "reject"}, {"action": "resolve", "server": "vps-dns"},
                private, {"rule_set": "cn-addresses", "action": "reject"}]
    dns = {"servers": [{"type": "local", "tag": "vps-dns"}]}
    if route["rules"] not in ([private], expected) or doc.get("dns", dns) != dns:
        raise ValueError("检测到自定义规则，停止自动改写")
    if any(rule.get("tag") not in CN for rule in route.get("rule_set", [])):
        raise ValueError("检测到其他规则集，停止自动改写")
    backup = path.with_name(f"config.before-cn.{time.time_ns()}.json")
    old = path.read_bytes()
    new_rules = Path(tempfile.mkdtemp(prefix="cn-rules.", dir=path.parent))
    try:
        entries = []
        for tag, url in CN.items():
            file = new_rules / (tag + ".srs")
            run("curl", "-4", "-fsSL", "--max-time", "40", "--retry", "2", url, "-o", file)
            entries.append({"type": "local", "tag": tag, "format": "binary", "path": str(file)})
        doc["dns"], route["rules"], route["rule_set"] = dns, expected, entries
        data = encode(doc)
        check_config(path, data)
        write(backup, old)
        write(path, data)
        try:
            run("systemctl", "restart", service)
            checked_socket(service)
        except Exception:
            write(path, old)
            run("systemctl", "restart", service)
            raise
    except Exception:
        if path.read_bytes() == old:
            shutil.rmtree(new_rules)
        raise
    print(f"{service} 已恢复监听。原配置备份：{backup}")


def hopping(first, last):
    if not 1024 <= first <= last <= 65535 or not 2 <= last - first + 1 <= 100:
        raise ValueError("跳跃端口必须是 1024–65535 内连续的 2 至 100 个 UDP 端口")
    checked_socket(SERVICES[1])
    nft = shutil.which("nft")
    if not nft:
        raise ValueError("请先用 APT 安装 nftables")
    unit = UNITS / "sing-box-hy2-hopping.service"
    rules = config_path(SERVICES[1]).parent / "hopping.nft"
    if unit.exists() or rules.exists():
        raise ValueError("跳跃服务或规则已存在，请先检查")
    table = "yg_plus_hy2"
    if subprocess.run([nft, "list", "table", "inet", table], stdout=subprocess.DEVNULL,
                      stderr=subprocess.DEVNULL).returncode == 0:
        raise ValueError("同名 nftables 表已经存在")
    rows = run("ss", "-H", "-lnu", f"( sport >= :{first} and sport <= :{last} )", capture=True)
    if rows.strip():
        raise ValueError("范围内有 UDP 监听，换一个未占用的范围")
    data = f"""table inet {table} {{
    chain prerouting {{
        type nat hook prerouting priority dstnat; policy accept;
        udp dport {first}-{last} counter redirect to :443
    }}
}}
""".encode()
    write(rules, data)
    try:
        run(nft, "-c", "-f", rules)
        write(unit, f"""[Unit]
Description=Hysteria 2 UDP port hopping
After=sing-box-hy2.service nftables.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart={nft} -f {rules}
ExecStop={nft} delete table inet {table}

[Install]
WantedBy=multi-user.target
""".encode(), 0o644)
        run("systemctl", "daemon-reload")
        run("systemctl", "start", unit.name)
    except Exception:
        if unit.exists():
            subprocess.run(["systemctl", "stop", unit.name], check=False)
        unit.unlink(missing_ok=True)
        rules.unlink(missing_ok=True)
        subprocess.run(["systemctl", "daemon-reload"], check=False)
        raise
    print(f"UDP {first}-{last} 已转发至 UDP 443。请放行公网入站并实际测试跨端口切换。")
    print(f"通过后执行 systemctl enable {unit.name}")
    print(f"发布订阅时加 --hop-range {first}:{last}")


def sync_profile(template, ip, hop_range=None):
    ip = str(ipaddress.IPv4Address(ip))
    if not ipaddress.ip_address(ip).is_global:
        raise ValueError("节点地址应为 VPS 公网 IPv4")
    doc = read(template)
    real, hy2 = (read(config_path(s))["inbounds"][0] for s in SERVICES)
    domain = domain_name(real["tls"]["server_name"])
    public = dict(line.split("=", 1) for line in
                  (config_path(SERVICES[0]).parent / "client.txt").read_text().splitlines())["Public key"]
    if not re.fullmatch(r"[A-Za-z0-9_-]{43}", public):
        raise ValueError("REALITY 公钥格式异常")
    proxies = [x for x in doc["outbounds"] if x.get("tag") == "PROXY" and x.get("type") == "selector"]
    if len(proxies) != 1:
        raise ValueError("模板需包含唯一的 PROXY selector")
    selector = proxies[0]
    if not all(tag in {x["tag"] for x in doc["outbounds"]} for tag in selector["outbounds"]):
        raise ValueError("模板中 PROXY 引用不存在的节点")
    main, backup = "Lauritz-Duo-REALITY", "Lauritz-Duo-HY2"
    removed = set(selector["outbounds"]) - {main, backup}
    nodes = {x["tag"]: x for x in doc["outbounds"]}
    if any(nodes[tag]["type"] in {"selector", "urltest", "direct", "block"} for tag in selector["outbounds"]):
        raise ValueError("此模板的 PROXY 包含其他组或直连，请使用专用两节点模板")
    selector.update(outbounds=[main, backup], default=main)
    doc["outbounds"] = [selector, {
        "type": "vless", "tag": main, "server": ip, "server_port": 443,
        "uuid": real["users"][0]["uuid"], "flow": "xtls-rprx-vision",
        "tls": {"enabled": True, "server_name": domain, "utls": {"enabled": True, "fingerprint": "chrome"},
                "reality": {"enabled": True, "public_key": public,
                            "short_id": real["tls"]["reality"]["short_id"][0]}},
    }, {
        "type": "hysteria2", "tag": backup, "server": ip, "server_port": 443,
        "password": hy2["users"][0]["password"],
        "tls": {"enabled": True, "server_name": domain, "insecure": False},
    }, *(x for x in doc["outbounds"] if x["tag"] not in removed | {"PROXY", main, backup})]
    def has_removed_tag(value):
        if isinstance(value, dict):
            return any(has_removed_tag(x) for x in value.values())
        if isinstance(value, list):
            return any(has_removed_tag(x) for x in value)
        return isinstance(value, str) and value in removed

    if has_removed_tag(doc):
        raise ValueError("模板其他位置仍引用旧节点，请先清理引用")
    if hop_range is not None:
        first, last = map(int, hop_range.split(":"))
        if not 1024 <= first < last <= 65535 or last - first >= 100:
            raise ValueError("跳跃范围格式为 START:END，最多 100 个端口")
        table = run("nft", "list", "table", "inet", "yg_plus_hy2", capture=True)
        if f"udp dport {first}-{last}" not in table or "redirect to :443" not in table:
            raise ValueError("实际跳跃规则与指定范围不符")
        doc["outbounds"][2].pop("server_port")
        doc["outbounds"][2].update(server_ports=[hop_range], hop_interval="30s")
    return doc, domain


def subscription_block(source, hashed, auth="basicauth"):
    marker = r'(?m)^[ 	]*respond "LAX server is online\."[ \t]*$'
    if len(re.findall(marker, source)) != 1 or PROFILE_PATH in source:
        raise ValueError("Caddyfile 与预期不同，停止自动改写")
    block = """    handle /profiles/lax.json {
        AUTH {
            lax HASH
        }
        header Cache-Control "no-store"
        root * /var/lib/caddy/private-profiles
        rewrite * /lax.json
        file_server
    }
    handle {
        respond "LAX server is online."
    }"""
    return re.sub(marker, lambda _: block.replace("AUTH", auth).replace("HASH", hashed), source)


def publish(template, ip, hop_range):
    import grp
    doc, domain = sync_profile(template, ip, hop_range)
    path = PROFILES / "lax.json"
    data = encode(doc)
    check_config(template, data)
    source = CADDY.read_text()
    url = f"https://{domain}{PROFILE_PATH}"
    curl = ("curl", "--noproxy", "*", "-sS", "--max-time", "8", "--resolve",
            f"{domain}:8443:127.0.0.1", "-o", "/dev/null", "-w", "%{http_code}")
    local = f"https://{domain}:8443{PROFILE_PATH}"
    status = run(*curl, local, capture=True)
    if PROFILE_PATH not in source:
        password = getpass.getpass("设置订阅密码（至少 16 字符）：")
        if not 16 <= len(password.encode()) <= 72 or password != getpass.getpass("再次输入订阅密码："):
            raise ValueError("密码过短或两次输入不一致")
        hashed = subprocess.run(["caddy", "hash-password"], input=password + "\n",
                                capture_output=True, text=True, check=True).stdout.strip()
        if not re.fullmatch(r"\$2[aby]\$\d\d\$[./A-Za-z0-9]{53}", hashed):
            raise ValueError("无法生成订阅密码哈希")
        version = re.search(r"v?(\d+)\.(\d+)", run("caddy", "version", capture=True))
        if version is None:
            raise ValueError("无法识别 Caddy 版本")
        auth = "basic_auth" if tuple(map(int, version.groups())) >= (2, 8) else "basicauth"
        reload_site(subscription_block(source, hashed, auth).encode())
        status = run(*curl, local, capture=True)
    if status != "401":
        raise ValueError(f"匿名访问返回 {status}，应为 401，停止发布")
    gid = grp.getgrnam("caddy").gr_gid
    PROFILES.mkdir(mode=0o750, exist_ok=True)
    os.chown(PROFILES, 0, gid)
    PROFILES.chmod(0o750)
    if path.exists():
        write(Path("/root") / f"lax-profile-before.{time.time_ns()}.json", path.read_bytes())
    write(path, data, 0o640, gid)
    print(f"订阅已发布：{url}\n用户名：lax。请在客户端验证认证后可下载。")


def export_profile(template, ip, output, hop_range):
    if output.exists():
        raise ValueError("目标文件已存在，请换文件名")
    doc, _ = sync_profile(template, ip, hop_range)
    data = encode(doc)
    check_config(output, data)
    write(output, data)
    print(f"本地客户端配置已写入：{output}。文件含节点凭据。")


def status(domain):
    run("systemctl", "--no-pager", "show", *SERVICES, "caddy", "-p", "Id", "-p", "ActiveState",
        "-p", "UnitFileState", "-p", "ExecStart")
    run("ss", "-lntup", "( sport = :22 or sport = :80 or sport = :443 or sport = :8443 )")
    run("ip", "-6", "addr", "show", "scope", "global")
    if domain:
        domain_name(domain)
        run("getent", "ahosts", domain)
        run("curl", "--noproxy", "*", "-fsS", "--max-time", "8", "--resolve",
            f"{domain}:8443:127.0.0.1", f"https://{domain}:8443/")
        print()


def main():
    parser = argparse.ArgumentParser(description="Lauritz Duo · sing-box 双协议管理")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("packages")
    sub.add_parser("site").add_argument("domain")
    setup = sub.add_parser("deploy")
    setup.add_argument("domain")
    setup.add_argument("--ipv6", action="store_true")
    sub.add_parser("rules").add_argument("service", choices=SERVICES)
    for command in ("publish", "export"):
        profile = sub.add_parser(command)
        profile.add_argument("ipv4")
        profile.add_argument("--template", type=Path, default=Path(__file__).with_name("client-template.json"))
        profile.add_argument("--hop-range", metavar="START:END")
        if command == "export":
            profile.add_argument("output", type=Path)
    hop = sub.add_parser("hopping")
    hop.add_argument("first", type=int)
    hop.add_argument("last", type=int)
    sub.add_parser("status").add_argument("domain", nargs="?")
    args = parser.parse_args()
    if not sys.platform.startswith("linux") or os.geteuid() != 0:
        parser.exit(1, "请在 Ubuntu/Debian VPS 的 root 会话中运行。\n")
    os.umask(0o077)
    import fcntl
    with open("/run/lock/sing-box-yg-plus.lock", "a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            {
                "packages": lambda: install_packages(),
                "site": lambda: setup_site(args.domain),
                "deploy": lambda: deploy(args.domain, args.ipv6),
                "rules": lambda: update_rules(args.service),
                "publish": lambda: publish(args.template, args.ipv4, args.hop_range),
                "export": lambda: export_profile(args.template, args.ipv4, args.output, args.hop_range),
                "hopping": lambda: hopping(args.first, args.last),
                "status": lambda: status(args.domain),
            }[args.command]()
        except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
            parser.exit(1, f"操作未完成：{error}\n")


if __name__ == "__main__":
    main()
