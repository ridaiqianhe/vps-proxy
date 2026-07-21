#!/bin/bash

# ===================================================================
# TCP 调优脚本 (BBR + 按 BDP 放大缓冲区,透明可回退)
# 仓库: https://github.com/ridaiqianhe/vps-proxy
#
# 原理: 单连接吞吐 = 窗口 / RTT。要跑满高带宽高延迟(跨境)线路,
#       缓冲区上限需 >= 带宽时延积 BDP = 带宽 x RTT。
#       本脚本按你的带宽/延迟算 BDP 设缓冲区,并启用 BBR + fq。
# ===================================================================

# 不用 set -e: 交互菜单脚本

RED='\e[31m'; GREEN='\e[92m'; YELLOW='\e[93m'; BLUE='\e[94m'; CYAN='\e[96m'; PURPLE='\e[38;5;135m'; GRAY='\e[90m'; NC='\e[0m'

SYSCTL_FILE="/etc/sysctl.d/99-vps-proxy-tcp.conf"
MODULES_FILE="/etc/modules-load.d/vps-proxy-bbr.conf"

log_info()  { echo -e "${GREEN}[INFO] $1${NC}" >&2; }
log_warn()  { echo -e "${YELLOW}[WARN] $1${NC}" >&2; }
log_error() { echo -e "${RED}[ERROR] $1${NC}" >&2; }

[ "$(id -u)" != "0" ] && { log_error "请以 root 权限运行此脚本"; exit 1; }

# 读取整数输入(带默认值)
read_int() {
    local prompt="$1" def="$2" val
    read -p "$(echo -e "${CYAN}${prompt} ${GRAY}(回车用 ${GREEN}${def}${GRAY})${CYAN}: ${NC}")" val
    val=${val:-$def}
    [[ "$val" =~ ^[0-9]+$ ]] && echo "$val" || echo "$def"
}

apply_tune() {
    # 自动检测内存(MB)
    local ram_mb
    ram_mb=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
    log_info "检测到内存: ${ram_mb} MB"
    echo ""

    # 采集网络参数(用户自己最清楚,可用 speedtest / ping 测)
    local bw lat mode
    bw=$(read_int "带宽(取本地/服务器较小值, Mbps)" 1000)
    lat=$(read_int "到主要用户的延迟 RTT(ms)" 150)
    echo -e "${CYAN}激进程度: ${GRAY}1=稳健 2=均衡(默认) 3=激进${NC}"
    mode=$(read_int "选择 [1-3]" 2)

    # 计算 BDP(字节): mbps * ms * 125  (= mbps*1e6/8 * ms/1000)
    local bdp mult maxbuf
    bdp=$(( bw * lat * 125 ))
    case "$mode" in
        1) mult=15 ;;   # 1.5x
        3) mult=30 ;;   # 3x
        *) mult=20 ;;   # 2x 均衡
    esac
    maxbuf=$(( bdp * mult / 10 ))

    # 下限 16MB(低延迟线路也给够),上限 512MB(内核实用上限)
    [ "$maxbuf" -lt 16777216 ]  && maxbuf=16777216
    [ "$maxbuf" -gt 536870912 ] && maxbuf=536870912

    # 内存保护: 单连接缓冲上限不超过内存的 30%
    local ram_bytes cap
    ram_bytes=$(( ram_mb * 1024 * 1024 ))
    cap=$(( ram_bytes * 30 / 100 ))
    [ "$maxbuf" -gt "$cap" ] && { maxbuf=$cap; log_warn "按内存上限收敛缓冲区到 $((maxbuf/1024/1024)) MB"; }

    # tcp_mem(页, 1 页=4KB): 总 TCP 内存高水位 = 内存的 50%
    local mem_high mem_pressure mem_min
    mem_high=$(( ram_bytes / 2 / 4096 ))
    mem_pressure=$(( mem_high * 8 / 10 ))
    mem_min=$(( mem_high * 4 / 10 ))

    # 检测 BBR 是否可用
    local cc="cubic" qdisc="fq_codel"
    modprobe tcp_bbr 2>/dev/null || true
    if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        cc="bbr"; qdisc="fq"
        echo "tcp_bbr" > "$MODULES_FILE"
    else
        log_warn "内核不支持 BBR,拥塞控制保持 cubic(建议升级内核到 4.9+)"
    fi

    log_info "BDP=$((bdp/1024/1024))MB  缓冲区上限=$((maxbuf/1024/1024))MB  拥塞控制=$cc"

    cat > "$SYSCTL_FILE" << EOF
# vps-proxy TCP 调优 (带宽 ${bw}Mbps / 延迟 ${lat}ms / 内存 ${ram_mb}MB / 模式 ${mode})
# 生成原理: 缓冲区上限 = BDP x $(awk "BEGIN{print $mult/10}")

# --- 按 BDP 放大的 socket 缓冲区 ---
net.core.rmem_max = $maxbuf
net.core.wmem_max = $maxbuf
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.tcp_rmem = 4096 262144 $maxbuf
net.ipv4.tcp_wmem = 4096 262144 $maxbuf
net.ipv4.tcp_mem = $mem_min $mem_pressure $mem_high

# --- 拥塞控制: BBR + $qdisc ---
net.core.default_qdisc = $qdisc
net.ipv4.tcp_congestion_control = $cc

# --- 快速爬升 / 通用优化 ---
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_notsent_lowat = 16384

# --- 连接队列 / 文件句柄 ---
net.core.netdev_max_backlog = 16384
net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
fs.file-max = 1048576
EOF

    if sysctl --system >/dev/null 2>&1; then
        log_info "调优已应用！"
    else
        log_error "sysctl 应用出现告警,请检查 sysctl --system 输出"
    fi
    echo ""
    show_current
}

show_current() {
    echo ""
    echo -e "${CYAN}=============== 当前 TCP 关键参数 ===============${NC}"
    echo -e "${BLUE}拥塞控制:   $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)${NC}"
    echo -e "${BLUE}队列调度:   $(sysctl -n net.core.default_qdisc 2>/dev/null)${NC}"
    echo -e "${BLUE}可用拥塞算法: $(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)${NC}"
    echo -e "${BLUE}rmem_max:   $(( $(sysctl -n net.core.rmem_max 2>/dev/null) / 1024 / 1024 )) MB${NC}"
    echo -e "${BLUE}wmem_max:   $(( $(sysctl -n net.core.wmem_max 2>/dev/null) / 1024 / 1024 )) MB${NC}"
    echo -e "${BLUE}tcp_rmem:   $(sysctl -n net.ipv4.tcp_rmem 2>/dev/null)${NC}"
    echo -e "${BLUE}tcp_wmem:   $(sysctl -n net.ipv4.tcp_wmem 2>/dev/null)${NC}"
    echo -e "${BLUE}slow_start_after_idle: $(sysctl -n net.ipv4.tcp_slow_start_after_idle 2>/dev/null)${NC}"
    if [ -f "$SYSCTL_FILE" ]; then
        echo -e "${GREEN}✓ 已应用 vps-proxy 调优 ($SYSCTL_FILE)${NC}"
    else
        echo -e "${GRAY}(未应用本脚本调优,以上为系统当前值)${NC}"
    fi
    echo -e "${CYAN}================================================${NC}"
    echo ""
}

revert_tune() {
    if [ ! -f "$SYSCTL_FILE" ]; then log_info "未检测到本脚本的调优配置"; return 0; fi
    read -p "$(echo -e "${YELLOW}确认移除本脚本的调优配置？[输入 yes 确认]: ${NC}")" a
    [ "$a" != "yes" ] && { log_info "已取消"; return 0; }
    rm -f "$SYSCTL_FILE" "$MODULES_FILE"
    sysctl --system >/dev/null 2>&1
    log_info "调优配置已移除。已生效的运行时值需重启后完全恢复默认。"
}

main() {
    while true; do
        clear 2>/dev/null || true
        echo ""
        echo -e "${PURPLE}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "     ${CYAN}⚙️  TCP 调优 (BBR + BDP)${NC}   ${YELLOW}(๑•̀ㅂ•́)و${NC}"
        echo -e "     ${GRAY}按带宽时延积放大缓冲区${NC}"
        echo -e "${PURPLE}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        if [ -f "$SYSCTL_FILE" ]; then
            echo -e "  ${GREEN}✓ 已应用调优${NC}"
        else
            echo -e "  ${GRAY}○ 未调优(系统默认)${NC}"
        fi
        echo ""
        echo -e "  ${GREEN}1.${NC} ⚙️  应用调优"
        echo -e "  ${GREEN}2.${NC} 📋 查看当前参数"
        echo -e "  ${GREEN}3.${NC} ↩️  恢复默认"
        echo -e "  ${YELLOW}0.${NC} 👋 退出"
        echo ""
        read -p "$(echo -e "  ${CYAN}请输入选项 [0-3]: ${NC}")" choice
        case $choice in
            1) apply_tune ;;
            2) show_current ;;
            3) revert_tune ;;
            0) echo -e "  ${PURPLE}バイバイ~ (｡･ω･)ﾉﾞ${NC}"; exit 0 ;;
            *) echo -e "  ${YELLOW}(・_・?) 没有「$choice」这个选项~${NC}"; sleep 1; continue ;;
        esac
        echo ""
        read -p "$(echo -e "  ${GRAY}按回车返回菜单...${NC}")" _
    done
}

main
