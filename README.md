# vps-proxy

常用代理协议一键安装/管理脚本合集,支持 Debian/Ubuntu(Snell 同时支持 RHEL 系)。

| 脚本 | 协议 | 说明 |
|---|---|---|
| `snell.sh` | Snell v6 (兼容 v5) | 安装/更新/卸载/查看 systemd 日志,v6 为默认选项,自动输出 Surge 配置行(Shadow-TLS 加壳见 `shadow-tls.sh`) |
| `hysteria2.sh` | Hysteria2 | 官方脚本安装 + 自签证书,输出 Clash 配置 |
| `ss-2022.sh` | Shadowsocks 2022 (ss-rust) | 支持无交互安装 |
| `anytls.sh` | AnyTLS | 基于官方 [anytls/anytls-go](https://github.com/anytls/anytls-go) 发布二进制,安装/卸载/看配置 |
| `tuic.sh` | TUIC v5 | 基于官方 [EAimTY/tuic](https://github.com/EAimTY/tuic) 服务端,自签证书,输出 Surge/mihomo 配置 |
| `trojan.sh` | Trojan | 基于 [trojan-go](https://github.com/p4gefau1t/trojan-go),默认 SNI icloud.com,自签证书 + 允许不安全 |
| `reality.sh` | VLESS + Vision + Reality | 基于官方 [Xray-core](https://github.com/XTLS/Xray-core),自动生成 UUID/x25519/shortId,可选 VLESS Encryption 与 ML-DSA-65 后量子加固 |
| `shadow-tls.sh` | Shadow-TLS v3 前置 | 为已安装的 SS 2022 或 Snell 加壳,自动识别后端,输出 Surge/mihomo 配置 |
| `tcp-tune.sh` | TCP 调优 | 启用 BBR + fq,按带宽时延积(BDP)放大 socket 缓冲区,含内存保护,可回退 |

## 使用

### 统一入口(推荐)

```bash
bash <(wget -qO- https://raw.githubusercontent.com/ridaiqianhe/vps-proxy/refs/heads/main/vps-proxy.sh)
```

### 单独运行某个脚本

```bash
# Snell
bash <(wget -qO- https://raw.githubusercontent.com/ridaiqianhe/vps-proxy/refs/heads/main/snell.sh)

# Hysteria2
bash <(wget -qO- https://raw.githubusercontent.com/ridaiqianhe/vps-proxy/refs/heads/main/hysteria2.sh)

# Shadowsocks 2022(支持带参数无交互: -p 端口 -w 密码)
bash <(wget -qO- https://raw.githubusercontent.com/ridaiqianhe/vps-proxy/refs/heads/main/ss-2022.sh)

# AnyTLS
bash <(wget -qO- https://raw.githubusercontent.com/ridaiqianhe/vps-proxy/refs/heads/main/anytls.sh)

# TUIC v5
bash <(wget -qO- https://raw.githubusercontent.com/ridaiqianhe/vps-proxy/refs/heads/main/tuic.sh)

# Trojan(默认 SNI icloud.com,自签证书)
bash <(wget -qO- https://raw.githubusercontent.com/ridaiqianhe/vps-proxy/refs/heads/main/trojan.sh)

# VLESS+Reality
bash <(wget -qO- https://raw.githubusercontent.com/ridaiqianhe/vps-proxy/refs/heads/main/reality.sh)

# TCP 调优(BBR + BDP 缓冲)
bash <(wget -qO- https://raw.githubusercontent.com/ridaiqianhe/vps-proxy/refs/heads/main/tcp-tune.sh)

# Shadow-TLS v3(为已装的 SS 2022 / Snell 加壳)
bash <(wget -qO- https://raw.githubusercontent.com/ridaiqianhe/vps-proxy/refs/heads/main/shadow-tls.sh)
```

所有脚本都需要 root 权限。
