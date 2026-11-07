#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Lauritz Duo dual-protocol manager."""
import argparse
import base64
import copy
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


def install_packages(version=None):
    if version and not re.fullmatch(r"[0-9][0-9A-Za-z.+:~\-]*", version):
        raise ValueError("请输入 APT 软件源中的完整版本号")
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
    run("apt-get", "-o", "Acquire::ForceIPv4=true", "install", "-y", *(["--allow-downgrades", f"sing-box={version}"] if version else ["sing-box"]))
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



FIVE = (("reality", "tcp"), ("vmess", "tcp"), ("hy2", "udp"), ("tuic", "udp"), ("anytls", "tcp"))
FIVE_SERVICE = "sing-box-lauritz-five"


def five_documents(domain, ports, user, keys, cert, host):
    short = secrets.token_hex(4)
    passwords = {kind: secrets.token_hex(24) for kind in ("hy2", "tuic", "anytls")}
    ws = "/" + secrets.token_hex(12)
    tls = {"enabled": True, "server_name": domain}
    cert_tls = {**tls, "certificate_path": str(cert), "key_path": str(cert.with_suffix(".key"))}
    real_in = {**tls, "reality": {"enabled": True, "private_key": keys["privatekey"],
               "short_id": [short], "handshake": {"server": "127.0.0.1", "server_port": 8443}}}
    real_out = {**tls, "utls": {"enabled": True, "fingerprint": "chrome"},
                "reality": {"enabled": True, "public_key": keys["publickey"], "short_id": short}}
    ws_options = {"type": "ws", "path": ws}
    vision = {"uuid": user, "flow": "xtls-rprx-vision"}
    in_fields = [
        {"type": "vless", "users": [vision], "tls": real_in},
        {"type": "vmess", "users": [{"uuid": user}], "transport": ws_options, "tls": cert_tls},
        {"type": "hysteria2", "users": [{"password": passwords["hy2"]}], "tls": cert_tls},
        {"type": "tuic", "users": [{"uuid": user, "password": passwords["tuic"]}], "tls": {**cert_tls, "alpn": ["h3"]}},
        {"type": "anytls", "users": [{"password": passwords["anytls"]}], "tls": cert_tls},
    ]
    out_fields = [
        {"type": "vless", **vision, "tls": real_out},
        {"type": "vmess", "uuid": user, "security": "auto", "alter_id": 0, "transport": ws_options, "tls": tls},
        {"type": "hysteria2", "password": passwords["hy2"], "tls": tls},
        {"type": "tuic", "uuid": user, "password": passwords["tuic"], "tls": {**tls, "alpn": ["h3"]}},
        {"type": "anytls", "password": passwords["anytls"], "tls": tls},
    ]
    inbound = [{"listen": "0.0.0.0", "listen_port": port, **fields} for port, fields in zip(ports, in_fields)]
    outbound = [{"tag": kind, "server": host, "server_port": port, **fields}
                for (kind, _), port, fields in zip(FIVE, ports, out_fields)]
    from urllib.parse import urlencode
    def uri(scheme, credential, port, label, **params):
        return f"{scheme}://{credential}@{host}:{port}?{urlencode(params)}#{label}"
    vmess = dict(v="2", ps="Lauritz-VMess", add=host, port=str(ports[1]), id=user, aid="0",
                 scy="auto", net="ws", type="none", path=ws, tls="tls", sni=domain, host=domain)
    links = [
        uri("vless", user, ports[0], "Lauritz-REALITY", encryption="none", security="reality",
            sni=domain, fp="chrome", pbk=keys["publickey"], sid=short, type="tcp", flow=vision["flow"]),
        "vmess://" + base64.b64encode(json.dumps(vmess).encode()).decode(),
        uri("hysteria2", passwords["hy2"], ports[2], "Lauritz-HY2", sni=domain, insecure=0),
        uri("tuic", user + ":" + passwords["tuic"], ports[3], "Lauritz-TUIC", sni=domain, alpn="h3"),
        uri("anytls", passwords["anytls"], ports[4], "Lauritz-AnyTLS", sni=domain),
    ]
    server = server_config(inbound[0])
    server["inbounds"] = inbound
    return server, outbound, links


def five_profiles(directory, template, nodes, links):
    for label, selected in [("all", nodes), *((n["tag"], [n]) for n in nodes)]:
        doc = copy.deepcopy(template)
        selector = next(n for n in doc["outbounds"] if n["tag"] == "PROXY")
        selector.update(outbounds=[n["tag"] for n in selected], default=selected[0]["tag"])
        doc["outbounds"] = [selector, *selected, *(n for n in doc["outbounds"] if n["tag"] == "DIRECT")]
        doc["experimental"]["cache_file"].update(path=f"lauritz-five-{label}.db", cache_id=f"lauritz-five-{label}")
        data = encode(doc)
        path = directory / (label + ".json")
        check_config(path, data)
        write(path, data)
    for label, selected in [("all", links), *((n["tag"], [link]) for n, link in zip(nodes, links))]:
        write(directory / (label + ".sub"), base64.b64encode(("\n".join(selected) + "\n").encode()) + b"\n")
    write(directory / "links.txt", ("\n".join(links) + "\n").encode())


def five_deploy(domain, host, port_text, uuid_text, template):
    domain = domain_name(domain)
    host = str(ipaddress.IPv4Address(host))
    if not ipaddress.ip_address(host).is_global:
        raise ValueError("请输入公网 IPv4")
    user = str(uuid.UUID(uuid_text)) if uuid_text else str(uuid.uuid4())
    path = config_path(FIVE_SERVICE)
    unit = UNITS / (FIVE_SERVICE + ".service")
    if path.parent.exists() or unit.exists():
        raise ValueError("五协议实例已经存在")
    run("dpkg-query", "-S", CORE, capture=True)
    cert = find_cert(domain)
    run("curl", "--noproxy", "*", "-fsS", "--max-time", "8", "--resolve",
        f"{domain}:8443:127.0.0.1", f"https://{domain}:8443/", capture=True)

    def free(port, protocol):
        flag = "-lnt" if protocol == "tcp" else "-lnu"
        return not run("ss", "-H", flag, f"( sport = :{port} )", capture=True).strip()

    if port_text:
        ports = [int(x) for x in port_text.split(",")]
    else:
        ports = []
        for _, protocol in FIVE:
            for _ in range(100):
                candidate = 10000 + secrets.randbelow(55536)
                if candidate not in ports and free(candidate, protocol):
                    ports.append(candidate)
                    break
            else:
                raise ValueError("未找到可用随机端口")
    if len(ports) != 5 or len(set(ports)) != 5 or not all(1 <= p <= 65535 for p in ports):
        raise ValueError("请输入五个不同的有效端口")
    if not all(free(port, proto) for port, (_, proto) in zip(ports, FIVE)):
        raise ValueError("指定端口已被占用")
    keys = {re.sub(r"[^a-z]", "", k.lower()): v.strip() for k, v in
            (line.split(":", 1) for line in run(CORE, "generate", "reality-keypair", capture=True).splitlines() if ":" in line)}
    server, nodes, links = five_documents(domain, ports, user, keys, cert, host)
    doc = read(template)
    path.parent.mkdir(mode=0o700)
    try:
        check_config(path, encode(server))
        profiles = path.parent / "profiles"
        profiles.mkdir(mode=0o700)
        five_profiles(profiles, doc, nodes, links)
        write(path, encode(server))
        write(unit, f"""[Unit]
Description=Lauritz five-protocol sing-box
After=network-online.target caddy.service
Wants=network-online.target
[Service]
ExecStart=/usr/bin/sing-box run -c {path}
Restart=on-failure
NoNewPrivileges=true
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_DAC_READ_SEARCH
[Install]
WantedBy=multi-user.target
""".encode(), 0o644)
        run("systemctl", "daemon-reload")
        run("systemctl", "start", FIVE_SERVICE)
        for _ in range(10):
            pid = run("systemctl", "show", "-p", "MainPID", "--value", FIVE_SERVICE, capture=True).strip()
            if pid != "0" and all(
                f"pid={pid}," in run("ss", "-H", "-lntp" if proto == "tcp" else "-lnup",
                                    f"( sport = :{port} )", capture=True)
                for port, (_, proto) in zip(ports, FIVE)
            ):
                break
            time.sleep(.5)
        else:
            raise ValueError("未确认五个端口均由新服务监听")
    except Exception:
        if unit.exists():
            subprocess.run(["systemctl", "stop", FIVE_SERVICE], check=False)
            unit.unlink()
            subprocess.run(["systemctl", "daemon-reload"], check=False)
        shutil.rmtree(path.parent)
        raise
    for (kind, protocol), port in zip(FIVE, ports):
        print(f"{kind:8} {port}/{protocol}")
    print(f"本机监听已确认。配置与分享链接位于 {profiles}；请用客户端验证后再启用开机启动。")



def five_share(publish_files):
    import grp
    root = config_path(FIVE_SERVICE).parent
    profiles = root / "profiles"
    domain = read(root / "config.json")["inbounds"][0]["tls"]["server_name"]
    labels = [kind for kind, _ in FIVE]
    names = [f"{label}.{ext}" for label in [*labels, "all"] for ext in ("json", "sub")]
    if publish_files:
        prefix = "/profiles/five"
        destination = PROFILES / "five"
        source = CADDY.read_text()
        local = f"https://{domain}:8443{prefix}/"
        curl = ("curl", "--noproxy", "*", "-sS", "--max-time", "8", "--resolve",
                f"{domain}:8443:127.0.0.1", "-o", "/dev/null", "-w", "%{http_code}")
        if f"handle_path {prefix}/*" not in source:
            password = getpass.getpass("设置五协议订阅密码（16 至 72 字节）：")
            if not 16 <= len(password.encode()) <= 72 or password != getpass.getpass("再输入一次："):
                raise ValueError("密码长度不符或两次输入不同")
            hashed = subprocess.run(["caddy", "hash-password"], input=password + "\n",
                                    capture_output=True, text=True, check=True).stdout.strip()
            if not re.fullmatch(r"\$2[aby]\$\d\d\$[./A-Za-z0-9]{53}", hashed):
                raise ValueError("订阅密码哈希无效")
            version = re.search(r"v?(\d+)\.(\d+)", run("caddy", "version", capture=True))
            if not version:
                raise ValueError("无法识别 Caddy 版本")
            auth = "basic_auth" if tuple(map(int, version.groups())) >= (2, 8) else "basicauth"
            marker = f"{domain}:8443 {{"
            if source.count(marker) != 1:
                raise ValueError("未找到唯一的现有 8443 站点")
            block = f"""
    handle_path {prefix}/* {{
        {auth} {{
            lax {hashed}
        }}
        header Cache-Control "no-store"
        root * {destination}
        file_server
    }}
"""
            reload_site(source.replace(marker, marker + block, 1).encode())
        if any(run(*curl, local + name, capture=True) != "401" for name in names):
            raise ValueError("匿名认证检查失败，未发布配置")
        gid = grp.getgrnam("caddy").gr_gid
        for directory in (PROFILES, destination):
            directory.mkdir(mode=0o750, exist_ok=True)
            os.chown(directory, 0, gid)
            directory.chmod(0o750)
        for name in names:
            write(destination / name, (profiles / name).read_bytes(), 0o640, gid)
    qr = shutil.which("qrencode")
    def show(link):
        print(link, flush=True)
        if qr:
            subprocess.run([qr, "-t", "ANSIUTF8", "-m", "2"], input=link, text=True, check=True)
    links = (profiles / "links.txt").read_text().splitlines()
    for label, link in zip(labels, links):
        print(f"\n[{label}]")
        show(link)
        if publish_files:
            print(f"订阅： https://{domain}/profiles/five/{label}.sub")
            print(f"sing-box： https://{domain}/profiles/five/{label}.json")
    print("\n全部节点链接：\n" + "\n".join(links))
    if publish_files:
        print("聚合订阅，用户名 lax，密码请在客户端输入：")
        show(f"https://{domain}/profiles/five/all.sub")
        print(f"聚合 sing-box JSON：https://{domain}/profiles/five/all.json")
    if not qr:
        print("可通过 APT 安装 qrencode 后显示二维码。")


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
    packages = sub.add_parser("packages")
    packages.add_argument("--version")
    share = sub.add_parser("five-share")
    share.add_argument("--publish", action="store_true")
    five = sub.add_parser("five")
    five.add_argument("domain")
    five.add_argument("ipv4")
    five.add_argument("--ports", default="")
    five.add_argument("--uuid", default="")
    five.add_argument("--template", type=Path, default=Path(__file__).with_name("client-template.json"))
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
                "packages": lambda: install_packages(args.version),
                "five-share": lambda: five_share(args.publish),
                "five": lambda: five_deploy(args.domain, args.ipv4, args.ports, args.uuid, args.template),
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
