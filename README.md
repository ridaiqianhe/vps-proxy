# vps-proxy

常用代理协议一键安装/管理脚本合集,支持 Debian/Ubuntu(Snell 同时支持 RHEL 系)。

| 脚本 | 协议 | 说明 |
|---|---|---|
| `snell.sh` | Snell v6 (兼容 v5) | 安装/更新/卸载/查看 systemd 日志,v6 为默认选项,自动输出 Surge 配置行(Shadow-TLS 加壳见 `shadow-tls.sh`) |
| `hysteria2.sh` | Hysteria2 | 官方脚本安装 + 自签证书,输出 Clash 配置 |
| `ss-2022.sh` | Shadowsocks 2022 (ss-rust) | 支持无交互安装 |
| `anytls.sh` | AnyTLS (sing-box) | 基于官方 [sing-box](https://github.com/SagerNet/sing-box) 的普通 TLS AnyTLS,安装/更新时自动跟随稳定版,输出 Surge/mihomo/sing-box 配置和标准导入链接 |
| `tuic.sh` | TUIC v5 | 基于持续维护的 [Itsusinn/tuic](https://github.com/Itsusinn/tuic) 服务端,自动校验稳定版,安全更新保留凭据,自签证书,输出 Surge/mihomo/sing-box 配置 |
| `trojan.sh` | Trojan | 基于 [trojan-go](https://github.com/p4gefau1t/trojan-go),默认 SNI icloud.com,自签证书 + 允许不安全 |
| `reality.sh` | VLESS + Vision + Reality | 基于官方 [Xray-core](https://github.com/XTLS/Xray-core),自动生成 UUID/x25519/shortId,可选 VLESS Encryption 与 ML-DSA-65 后量子加固 |
| `anytls-reality.sh` | AnyTLS + Reality (sing-box) | 最低要求 sing-box 1.12.12,安装/更新时自动跟随稳定版,仅供 sing-box 客户端使用,自动生成 Reality 密钥并输出客户端 JSON |
| `socks-http.sh` | SOCKS5 / HTTP / HTTPS Proxy (sing-box) | Mixed 模式同端口提供 SOCKS5 与 HTTP；HTTPS Proxy 使用 TLS，支持用户认证、配置查看、日志、安全更新与回滚 |
| `shadow-tls.sh` | Shadow-TLS v3 前置 | 为已安装的 SS 2022 或 Snell 加壳,自动识别 Snell v5/v6 并收敛后端监听,输出 Surge/mihomo 配置 |
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

# AnyTLS + Reality (sing-box 专属; 客户端也必须使用 sing-box 1.12.12+)
bash <(wget -qO- https://raw.githubusercontent.com/ridaiqianhe/vps-proxy/refs/heads/main/anytls-reality.sh)

# TUIC v5（Itsusinn/tuic）
bash <(wget -qO- https://raw.githubusercontent.com/ridaiqianhe/vps-proxy/refs/heads/main/tuic.sh)

# Trojan(默认 SNI icloud.com,自签证书)
bash <(wget -qO- https://raw.githubusercontent.com/ridaiqianhe/vps-proxy/refs/heads/main/trojan.sh)

# VLESS+Reality
bash <(wget -qO- https://raw.githubusercontent.com/ridaiqianhe/vps-proxy/refs/heads/main/reality.sh)

# TCP 调优(BBR + BDP 缓冲)
bash <(wget -qO- https://raw.githubusercontent.com/ridaiqianhe/vps-proxy/refs/heads/main/tcp-tune.sh)

# Shadow-TLS v3(为已装的 SS 2022 / Snell 加壳)
bash <(wget -qO- https://raw.githubusercontent.com/ridaiqianhe/vps-proxy/refs/heads/main/shadow-tls.sh)

# SOCKS5 / HTTP / HTTPS Proxy
bash <(wget -qO- https://raw.githubusercontent.com/ridaiqianhe/vps-proxy/refs/heads/main/socks-http.sh)
```

所有脚本都需要 root 权限。

### AnyTLS 模式说明

`anytls.sh` 和 `anytls-reality.sh` 都直接使用官方 sing-box，不再安装旧版独立 AnyTLS 服务端。每次执行安装/更新都会检查官方最新稳定版并升级旧版本，不会自动安装 beta。普通 AnyTLS 使用自签名 TLS 证书，脚本会输出 Surge、mihomo、sing-box 和标准 `anytls://` 导入配置；使用自签名证书时客户端需要开启 `skip-cert-verify`/`insecure`，Surge 也可以使用脚本输出的证书 SHA-256 指纹进行固定。

`AnyTLS + Reality` 要求 sing-box 1.12.12+，服务端和客户端都必须使用 sing-box，并且客户端配置必须保留 `tls.utls`。Surge 和 mihomo 的普通 AnyTLS 配置不能直接套用 Reality 参数。

### SOCKS5 / HTTP 模式说明

`socks-http.sh` 直接使用官方 sing-box，并提供两种互斥模式。Mixed 模式在同一个端口同时接受 SOCKS5 和 HTTP，SOCKS5 可供支持 UDP relay 的客户端使用；它没有传输加密，用户名和密码也会以明文方式经过网络，只适合可信网络、内网或已有加密隧道。HTTPS Proxy 模式在 HTTP CONNECT 外层启用 TLS，适合公网使用，但只代理 TCP、不支持 UDP。脚本生成自签名证书，并输出 Surge 的证书指纹固定配置和 curl 测试命令。

这两个模式是通用代理入口，不使用 Reality，也不用于伪装流量。公网直接部署时优先选 HTTPS Proxy，并在防火墙中仅开放实际使用的代理端口。

### TUIC 说明

`tuic.sh` 使用 [Itsusinn/tuic](https://github.com/Itsusinn/tuic) 的最新稳定版实现 TUIC v5。更新时会校验 GitHub 发布文件的 SHA-256，并保留现有端口、UUID、密码和证书；菜单提供配置查看和 systemd 日志查看。Surge 客户端必须使用 `tuic-v5` 关键字并填写 `uuid` + `password`，`tuic` 关键字属于旧版 v4/token 格式，不能混用。
