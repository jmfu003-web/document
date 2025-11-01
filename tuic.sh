#!/bin/bash
# ===================== TUIC 轻量化部署脚本 =====================
# 适配 Pterodactyl 面板 & 内存 64MB
# 所有文件集中在 proxy_files 文件夹

set -euo pipefail
IFS=$'\n\t'

WORK_DIR="proxy_files"
mkdir -p "$WORK_DIR"

# --------------------- 配置常量 ---------------------
MASQ_DOMAINS=("www.microsoft.com" "www.cloudflare.com" "www.bing.com" "www.apple.com" "www.amazon.com" "www.wikipedia.org" "cdnjs.cloudflare.com" "cdn.jsdelivr.net" "static.cloudflareinsights.com" "www.speedtest.net")
MASQ_DOMAIN=${MASQ_DOMAINS[$RANDOM % ${#MASQ_DOMAINS[@]}]}

DEFAULT_PORT="28888"
SERVICE_PORT="${SERVER_PORT:-$DEFAULT_PORT}"
SERVER_TOML="$WORK_DIR/server.toml"
CERT_PEM="$WORK_DIR/tuic-cert.pem"
KEY_PEM="$WORK_DIR/tuic-key.pem"
TUIC_BIN="$WORK_DIR/tuic-server"
USER_FILE="$WORK_DIR/tuic_user.txt"

# --------------------- 生成证书 ---------------------
generate_certificate() {
    if [[ -f "$CERT_PEM" && -f "$KEY_PEM" ]]; then
        if openssl x509 -checkend 0 -noout -in "$CERT_PEM" >/dev/null 2>&1; then
            echo "🔐 证书有效，跳过生成"
            return
        else
            echo "🔐 证书已过期，重新生成"
        fi
    else
        echo "🔐 证书不存在，生成新证书"
    fi
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$KEY_PEM" -out "$CERT_PEM" -subj "/CN=$MASQ_DOMAIN" -days 365 -nodes >/dev/null 2>&1
}

# --------------------- 下载 TUIC ---------------------
download_tuic() {
    if [[ -x "$TUIC_BIN" ]]; then
        echo "✅ tuic-server 已存在"
        return
    fi
    echo "📥 下载 tuic-server..."
    ARCH=$(uname -m)
    if [[ "$ARCH" != "x86_64" ]]; then
        echo "❌ 暂不支持架构: $ARCH"
        exit 1
    fi
    TUIC_URL="https://github.com/Itsusinn/tuic/releases/download/v1.3.5/tuic-server-x86_64-linux"
    curl -L -f -o "$TUIC_BIN" "$TUIC_URL" || { echo "❌ 下载失败，请手动下载 $TUIC_URL"; exit 1; }
    chmod +x "$TUIC_BIN"
    echo "✅ 下载完成"
}

# --------------------- 生成/读取用户 UUID & 密码 ---------------------
generate_user() {
    if [[ -f "$USER_FILE" ]]; then
        TUIC_UUID=$(sed -n '1p' "$USER_FILE")
        TUIC_PASSWORD=$(sed -n '2p' "$USER_FILE")
        echo "🔑 已读取用户信息"
    else
        TUIC_UUID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || openssl rand -hex 16)"
        TUIC_PASSWORD="$(openssl rand -hex 16)"
        echo "$TUIC_UUID" > "$USER_FILE"
        echo "$TUIC_PASSWORD" >> "$USER_FILE"
        echo "🔑 用户信息已生成并保存"
    fi
}

# --------------------- 生成 TUIC 配置 ---------------------
generate_config() {
    generate_user
    cat > "$SERVER_TOML" <<EOF
log_level = "off"
server = "0.0.0.0:${SERVICE_PORT}"

udp_relay_ipv6 = false
zero_rtt_handshake = true
dual_stack = false
auth_timeout = "10s"
task_negotiation_timeout = "5s"
gc_interval = "10s"
gc_lifetime = "10s"
max_external_packet_size = 8192

[users]
${TUIC_UUID} = "${TUIC_PASSWORD}"

[tls]
self_sign = false
certificate = "$CERT_PEM"
private_key = "$KEY_PEM"
alpn = ["h3"]

[restful]
addr = "127.0.0.1:${SERVICE_PORT}"
secret = "$(openssl rand -hex 16)"
maximum_clients_per_user = 999999999

[quic]
initial_mtu = 1500
min_mtu = 1200
gso = true
pmtu = true
send_window = 8388608
receive_window = 4194304
max_idle_time = "20s"

[quic.congestion_control]
controller = "bbr"
initial_window = 4194304
EOF
}

# --------------------- 获取服务器 IP ---------------------
get_server_ip() {
    local ip
    if command -v curl >/dev/null 2>&1; then
        ip=$(curl -s --connect-timeout 5 https://api.ipify.org)
    elif command -v wget >/dev/null 2>&1; then
        ip=$(wget -qO- --timeout=5 https://api.ipify.org)
    fi
    if [[ -n "$ip" && "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
        echo "$ip"
    else
        echo "YOUR_SERVER_IP"
    fi
}

# --------------------- 获取国家代码 ---------------------
get_country_code() {
    local ip="$1"
    local country_code
    country_code=$(curl -s "http://ip-api.com/line/${ip}?fields=countryCode" || echo "XX")
    if [[ -z "$country_code" ]]; then
        country_code="XX"
    fi
    echo "$country_code"
}

# --------------------- 生成 TUIC 链接 ---------------------
generate_link() {
    local ip="$1"
    local country="$2"
    local node_name="TUIC-${country}"
    local link="tuic://${TUIC_UUID}:${TUIC_PASSWORD}@${ip}:${SERVICE_PORT}?congestion_control=bbr&alpn=h3&allowInsecure=1&sni=${MASQ_DOMAIN}&udp_relay_mode=native&disable_sni=0&reduce_rtt=1&max_udp_relay_packet_size=8192#${node_name}"
    echo "🔗 TUIC 链接: $link"
}

# --------------------- 主函数 ---------------------
main() {
    echo "⚙️ 初始化 TUIC..."
    generate_certificate
    download_tuic
    generate_config

    local server_ip country_code
    server_ip=$(get_server_ip)
    country_code=$(get_country_code "$server_ip")

    echo "🎯 SNI/伪装域名: $MASQ_DOMAIN"
    echo "🌐 服务器 IP: $server_ip:$SERVICE_PORT"
    echo "🔑 UUID: $TUIC_UUID"
    echo "🔑 密码: $TUIC_PASSWORD"
    generate_link "$server_ip" "$country_code"

    echo "✅ 启动 TUIC 服务 (前台运行)..."
    exec "$TUIC_BIN" -c "$SERVER_TOML"
}

main "$@"
