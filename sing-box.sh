#!/usr/bin/env bash
# =========================
# 自用 sing-box 安装脚本
# 协议: vless-argo(固定隧道) + hysteria2
# 平台: Ubuntu / Debian (systemd)
# 最后更新时间: 2026.6.21
# =========================

export LANG=en_US.UTF-8
export DEBIAN_FRONTEND=noninteractive

# ── 颜色 ──────────────────────────────────────────
red()    { echo -e "\e[1;91m$1\033[0m"; }
green()  { echo -e "\e[1;32m$1\033[0m"; }
yellow() { echo -e "\e[1;33m$1\033[0m"; }
purple() { echo -e "\e[1;35m$1\033[0m"; }
skyblue(){ echo -e "\e[1;36m$1\033[0m"; }
reading(){ read -p "$(red "$1")" "$2"; }

# ── 常量 ──────────────────────────────────────────
work_dir="/etc/sing-box"
conf_dir="${work_dir}/conf"
client_dir="${work_dir}/url.txt"
backup_dir="/etc/sing-box-backup"
SCRIPT_URL="https://raw.githubusercontent.com/wot1026/sing-box/main/sing-box.sh"
ARGO_PORT="8001"

SB_VERSION="1.13.13"

export CFIP=${CFIP:-'cf.877774.xyz'}
export CFPORT=${CFPORT:-'443'}

# ── 前置检查 ──────────────────────────────────────
[[ $EUID -ne 0 ]] && red "请在 root 用户下运行脚本" && exit 1
command -v systemctl >/dev/null 2>&1 || { red "本脚本仅支持 systemd 系统（Ubuntu/Debian）"; exit 1; }

command_exists() { command -v "$1" >/dev/null 2>&1; }

# ── 服务状态检查 ───────────────────────────────────
check_service() {
    local name="$1" binary="$2"
    [[ ! -f "$binary" ]] && { red "not installed"; return 2; }
    if systemctl is-active "$name" &>/dev/null; then
        green "running"; return 0
    else
        yellow "not running"; return 1
    fi
}

check_singbox() { check_service "sing-box" "${work_dir}/sing-box"; }
check_argo()    { check_service "argo"     "${work_dir}/argo"; }

# ── 包安装 ────────────────────────────────────────
install_packages() {
    local to_install=()
    for pkg in "$@"; do
        command_exists "$pkg" && { yellow "${pkg} 已安装，跳过"; continue; }
        to_install+=("$pkg")
    done
    if [ ${#to_install[@]} -eq 0 ]; then
        return 0
    fi
    apt-get update -y
    for pkg in "${to_install[@]}"; do
        yellow "正在安装 ${pkg}…"
        apt-get install -y "$pkg" || { red "${pkg} 安装失败"; return 1; }
    done
}

# ── 防火墙放行 ────────────────────────────────────
allow_port() {
    local has_ufw=0 has_iptables=0 has_ip6tables=0
    command_exists ufw       && has_ufw=1
    command_exists iptables  && has_iptables=1
    command_exists ip6tables && has_ip6tables=1

    [ $has_ufw -eq 1 ] && ufw --force default allow outgoing >/dev/null 2>&1

    for rule in "$@"; do
        local port="${rule%/*}" proto="${rule#*/}"
        [ $has_ufw -eq 1 ] && ufw allow in "${port}/${proto}" >/dev/null 2>&1
        if [ $has_iptables -eq 1 ]; then
            iptables  -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null \
                || iptables  -I INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null || true
        fi
        if [ $has_ip6tables -eq 1 ]; then
            ip6tables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null \
                || ip6tables -I INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null || true
        fi
    done

    if [ $has_iptables -eq 1 ] && command_exists iptables-save; then
        mkdir -p /etc/iptables
        local _tmp4
        _tmp4=$(mktemp 2>/dev/null)
        if [ -n "$_tmp4" ] && iptables-save > "$_tmp4" 2>/dev/null; then
            mv "$_tmp4" /etc/iptables/rules.v4
        else
            rm -f "$_tmp4"
            yellow "保存 rules.v4 失败"
        fi
    fi
    if [ $has_ip6tables -eq 1 ] && command_exists ip6tables-save; then
        mkdir -p /etc/iptables
        local _tmp6
        _tmp6=$(mktemp 2>/dev/null)
        if [ -n "$_tmp6" ] && ip6tables-save > "$_tmp6" 2>/dev/null; then
            mv "$_tmp6" /etc/iptables/rules.v6
        else
            rm -f "$_tmp6"
            yellow "保存 rules.v6 失败"
        fi
    fi
}

# ── 防火墙删除旧规则 ──────────────────────────────
remove_port() {
    local has_ufw=0 has_iptables=0 has_ip6tables=0
    command_exists ufw       && has_ufw=1
    command_exists iptables  && has_iptables=1
    command_exists ip6tables && has_ip6tables=1

    for rule in "$@"; do
        local port="${rule%/*}" proto="${rule#*/}"
        [ $has_ufw -eq 1 ] && ufw delete allow "${port}/${proto}" >/dev/null 2>&1
        if [ $has_iptables -eq 1 ]; then
            iptables  -D INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null || true
        fi
        if [ $has_ip6tables -eq 1 ]; then
            ip6tables -D INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null || true
        fi
    done

    if [ $has_iptables -eq 1 ] && command_exists iptables-save; then
        mkdir -p /etc/iptables
        local _tmp4
        _tmp4=$(mktemp 2>/dev/null)
        if [ -n "$_tmp4" ] && iptables-save > "$_tmp4" 2>/dev/null; then
            mv "$_tmp4" /etc/iptables/rules.v4
        else
            rm -f "$_tmp4"
            yellow "保存 rules.v4 失败"
        fi
    fi
    if [ $has_ip6tables -eq 1 ] && command_exists ip6tables-save; then
        mkdir -p /etc/iptables
        local _tmp6
        _tmp6=$(mktemp 2>/dev/null)
        if [ -n "$_tmp6" ] && ip6tables-save > "$_tmp6" 2>/dev/null; then
            mv "$_tmp6" /etc/iptables/rules.v6
        else
            rm -f "$_tmp6"
            yellow "保存 rules.v6 失败"
        fi
    fi
}

# ── 节点名称 ──────────────────────────────────────
get_flag() {
    local code
    code=$(curl -sm3 -H "User-Agent: Mozilla/5.0" "https://api.ip.sb/geoip" | jq -r '.country_code // empty' 2>/dev/null)
    [ -z "$code" ] && code=$(curl -sm3 "https://ipapi.co/country_code" 2>/dev/null)
    case "$code" in
        US) echo "🇺🇸" ;; KR) echo "🇰🇷" ;; JP) echo "🇯🇵" ;;
        HK) echo "🇭🇰" ;; SG) echo "🇸🇬" ;; DE) echo "🇩🇪" ;;
        GB) echo "🇬🇧" ;; FR) echo "🇫🇷" ;; NL) echo "🇳🇱" ;;
        CA) echo "🇨🇦" ;; AU) echo "🇦🇺" ;; TW) echo "🇹🇼" ;;
        CN) echo "🇨🇳" ;; RU) echo "🇷🇺" ;; IN) echo "🇮🇳" ;;
        BR) echo "🇧🇷" ;; *)  echo "🌐" ;;
    esac
}

get_node_name() { echo "$(get_flag) $(hostname)"; }

# ── Hysteria2 指纹 ────────────────────────────────
get_hy2_fingerprint() {
    openssl x509 -noout -fingerprint -sha256 -in "${work_dir}/cert.pem" 2>/dev/null \
        | cut -d'=' -f2 | sed 's/:/%3A/g'
}

# ── 官方源下载 ────────────────────────────────────
get_latest_sb_version() {
    curl -fsSL "https://api.github.com/repos/SagerNet/sing-box/releases/latest" \
        | jq -r '.tag_name // empty' | tr -d 'v'
}

download_singbox() {
    local arch="$1" version="$2" dest="$3"
    local base_url="https://github.com/SagerNet/sing-box/releases/download/v${version}"
    local tarball="sing-box-${version}-linux-${arch}.tar.gz"
    local tmp_tar tmp_dir
    tmp_tar=$(mktemp)
    tmp_dir=$(mktemp -d)

    yellow "正在下载 sing-box v${version}..."
    curl -fsSLo "$tmp_tar" "${base_url}/${tarball}" \
        || { red "sing-box 下载失败"; rm -f "$tmp_tar"; rm -rf "$tmp_dir"; return 1; }

    tar -xzf "$tmp_tar" -C "$tmp_dir" \
        || { red "解压失败"; rm -f "$tmp_tar"; rm -rf "$tmp_dir"; return 1; }
    mv "${tmp_dir}/sing-box-${version}-linux-${arch}/sing-box" "$dest" \
        || { red "移动文件失败"; rm -f "$tmp_tar"; rm -rf "$tmp_dir"; return 1; }

    rm -f "$tmp_tar"; rm -rf "$tmp_dir"
    chmod +x "$dest"
    chown root:root "$dest"
}

download_cloudflared() {
    local arch="$1" dest="$2"
    local bin_name="cloudflared-linux-${arch}"
    local base_url="https://github.com/cloudflare/cloudflared/releases/latest/download"
    local tmp_file
    tmp_file=$(mktemp)

    yellow "正在下载 cloudflared..."
    curl -fsSLo "$tmp_file" "${base_url}/${bin_name}" \
        || { red "cloudflared 下载失败"; rm -f "$tmp_file"; return 1; }

    mv "$tmp_file" "$dest"
    chmod +x "$dest"
    chown root:root "$dest"
}

# ── 查找未被占用的 UDP 端口 ───────────────────────
pick_free_udp_port() {
    local port attempts=0
    port=$(shuf -i 10000-65000 -n 1)
    while ss -ulnH | awk '{print $5}' | grep -q ":${port}$"; do
        port=$(shuf -i 10000-65000 -n 1)
        (( attempts++ > 100 )) && { echo "无法找到空闲 UDP 端口" >&2; return 1; }
    done
    echo "$port"
}
# ── 查找未被占用的 TCP 端口 ───────────────────────
pick_free_tcp_port() {
    local port attempts=0
    port=$(shuf -i 10000-65000 -n 1)
    while ss -tlnH | awk '{print $5}' | grep -q ":${port}$"; do
        port=$(shuf -i 10000-65000 -n 1)
        (( attempts++ > 100 )) && { echo "无法找到空闲 TCP 端口" >&2; return 1; }
    done
    echo "$port"
}

# ── 安装核心 ──────────────────────────────────────
install_singbox() {
    clear
    purple "正在安装 sing-box，请稍候…"

    local sb_ver="${1:-$SB_VERSION}"

    local arch_raw arch
    arch_raw=$(uname -m)
    case "$arch_raw" in
        x86_64|amd64)  arch='amd64' ;;
        aarch64|arm64) arch='arm64' ;;
        *) red "不支持的架构: ${arch_raw}"; exit 1 ;;
    esac
    
    if ss -tlnH | awk '{print $5}' | grep -q ":${ARGO_PORT}$"; then
        yellow "端口 ${ARGO_PORT} 已被占用，自动选用空闲 TCP 端口"
        local new_argo_port
        new_argo_port=$(pick_free_tcp_port) || { red "无法分配空闲 TCP 端口"; exit 1; }
        ARGO_PORT="$new_argo_port"
        green "VLESS-Argo 端口已切换到 ${ARGO_PORT}"
    fi
    
    mkdir -p "${work_dir}" "${conf_dir}"
    chmod 700 "${work_dir}"

    download_singbox "$arch" "$sb_ver" "${work_dir}/sing-box" || exit 1
    download_cloudflared "$arch" "${work_dir}/argo"           || exit 1

    apt-get install -y qrencode 2>/dev/null || yellow "qrencode 安装失败，二维码功能不可用"

    local hy2_port uuid vless_path argo_port="${ARGO_PORT}" hy2_password
    local restore_backup=false

    # ── 检测是否存在卸载时保留的备份配置 ──────────
    if [ -f "${backup_dir}/inbounds.json" ]; then
        yellow "\n检测到上次卸载时保留的节点配置备份"
        local restore_choice
        reading "是否恢复备份中的 UUID / 端口 / 隧道配置？(y/n，回车默认 y): " restore_choice
        if [[ -z "$restore_choice" || "$restore_choice" == [yY] ]]; then
            restore_backup=true
        fi
    fi

    if $restore_backup; then
        uuid=$(jq -r '.inbounds[] | select(.tag=="vless-ws") | .users[0].uuid' "${backup_dir}/inbounds.json")
        vless_path=$(jq -r '.inbounds[] | select(.tag=="vless-ws") | .transport.path' "${backup_dir}/inbounds.json")
        hy2_port=$(jq -r '.inbounds[] | select(.type=="hysteria2") | .listen_port' "${backup_dir}/inbounds.json")
        argo_port=$(jq -r '.inbounds[] | select(.tag=="vless-ws") | .listen_port' "${backup_dir}/inbounds.json")
        hy2_password=$(jq -r '.inbounds[] | select(.type=="hysteria2") | .users[0].password' "${backup_dir}/inbounds.json")
        # 兼容旧备份（密码与UUID相同的历史配置）：若读取失败则回退使用 uuid
        [ -z "$hy2_password" ] || [ "$hy2_password" = "null" ] && hy2_password="$uuid"

        if [ -z "$uuid" ] || [ "$uuid" = "null" ] \
           || [ -z "$vless_path" ] || [ "$vless_path" = "null" ] \
           || ! [[ "$hy2_port" =~ ^[0-9]+$ ]] \
           || ! [[ "$argo_port" =~ ^[0-9]+$ ]]; then
            yellow "备份配置内容异常，已忽略备份，将生成全新配置"
            restore_backup=false
        else
            if ss -ulnH | awk '{print $5}' | grep -q ":${hy2_port}$"; then
                yellow "备份中的 Hysteria2 端口 ${hy2_port} 已被占用，将重新分配"
                hy2_port=$(pick_free_udp_port) || exit 1
            fi
            if ss -tlnH | awk '{print $5}' | grep -q ":${argo_port}$"; then
                yellow "备份中的 VLESS-Argo 端口 ${argo_port} 已被占用，将使用默认端口 ${ARGO_PORT}"
                argo_port="${ARGO_PORT}"
            fi
            green "已从备份恢复 UUID 与端口配置"
        fi
    fi

    if ! $restore_backup; then
        hy2_port=$(pick_free_udp_port) || exit 1
        uuid=$(cat /proc/sys/kernel/random/uuid)
        vless_path="/${uuid}-vless"
        hy2_password=$(openssl rand -hex 16)
    fi

    allow_port "${hy2_port}/udp"

    # ── 证书：优先从备份恢复，保持 pinSHA256 不变 ─
    local cert_restored=false
    if $restore_backup \
       && [ -f "${backup_dir}/cert.pem" ] \
       && [ -f "${backup_dir}/private.key" ] \
       && openssl x509 -noout -in "${backup_dir}/cert.pem" 2>/dev/null; then
        cp "${backup_dir}/cert.pem"    "${work_dir}/cert.pem"
        cp "${backup_dir}/private.key" "${work_dir}/private.key"
        chmod 600 "${work_dir}/private.key"
        green "已从备份恢复 TLS 证书（pinSHA256 不变）"
        cert_restored=true
    else
        yellow "正在生成新 TLS 证书..."
        openssl ecparam -genkey -name prime256v1 -out "${work_dir}/private.key" 2>/dev/null
        openssl req -new -x509 -days 3650 \
            -key "${work_dir}/private.key" \
            -out "${work_dir}/cert.pem" \
            -subj "/CN=bing.com" 2>/dev/null
        chmod 600 "${work_dir}/private.key"
    fi

    cat > "${conf_dir}/log.json" << EOF
{
  "log": {
    "disabled": false,
    "level": "error",
    "output": "${work_dir}/sb.log",
    "timestamp": true
  }
}
EOF

    cat > "${conf_dir}/ntp.json" << 'EOF'
{
  "ntp": {
    "enabled": true,
    "server": "time.apple.com",
    "server_port": 123,
    "interval": "60m"
  }
}
EOF

    cat > "${conf_dir}/dns.json" << 'EOF'
{
  "dns": {
    "servers": [{"tag": "local", "type": "local"}],
    "strategy": "ipv4_only"
  }
}
EOF

    cat > "${conf_dir}/inbounds.json" << EOF
{
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-ws",
      "listen": "127.0.0.1",
      "listen_port": ${argo_port},
      "users": [
        {
          "uuid": "${uuid}"
        }
      ],
      "transport": {
        "type": "ws",
        "path": "${vless_path}",
        "max_early_data": 2560,
        "early_data_header_name": "Sec-WebSocket-Protocol"
      }
    },
    {
      "type": "hysteria2",
      "tag": "hysteria2",
      "listen": "0.0.0.0",
      "listen_port": ${hy2_port},
      "users": [{"password": "${hy2_password}"}],
      "ignore_client_bandwidth": false,
      "masquerade": "https://bing.com",
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "min_version": "1.3",
        "max_version": "1.3",
        "certificate_path": "${work_dir}/cert.pem",
        "key_path": "${work_dir}/private.key"
      }
    }
  ]
}
EOF

    cat > "${conf_dir}/outbounds.json" << 'EOF'
{
  "outbounds": [
    {"type": "direct", "tag": "direct"},
    {"type": "block",  "tag": "block"}
  ]
}
EOF

    cat > "${conf_dir}/route.json" << 'EOF'
{
  "route": {
    "rule_set": [],
    "rules": [],
    "final": "direct"
  }
}
EOF

    cat > "${conf_dir}/experimental.json" << EOF
{
  "experimental": {
    "cache_file": {
      "enabled": true,
      "path": "${work_dir}/cache.db"
    }
  }
}
EOF

    # ── 恢复 Argo 隧道与 CF 优选配置（若有备份）──
    if $restore_backup; then
        if [ -f "${backup_dir}/tunnel.yml" ]; then
            cp "${backup_dir}/tunnel.yml" "${work_dir}/tunnel.yml"
            sed -i "s|service: http://localhost:[0-9]*|service: http://localhost:${argo_port}|" \
                "${work_dir}/tunnel.yml"
        fi
        if [ -f "${backup_dir}/tunnel.json" ]; then
            cp "${backup_dir}/tunnel.json" "${work_dir}/tunnel.json"
            chmod 600 "${work_dir}/tunnel.json"
        fi
        if [ -f "${backup_dir}/argo_token" ]; then
            cp "${backup_dir}/argo_token" "${work_dir}/argo_token"
            chmod 600 "${work_dir}/argo_token"
            if [ -s "${work_dir}/argo_token" ]; then
                ARGO_TOKEN_RESTORED=true
            else
                yellow "警告：argo_token 备份文件为空，恢复失败"
            fi
        fi
        if [ -f "${backup_dir}/cf.env" ]; then
            cp "${backup_dir}/cf.env" "${work_dir}/cf.env"
            chmod 600 "${work_dir}/cf.env"
        fi

        # ── 恢复备用协议（TUIC / Reality / AnyTLS）──
        # inbounds.json 是按固定模板重新生成的（不是整体复制备份），
        # 所以备用协议的 inbound 段需要从备份的 inbounds.json 里单独取出合并回来
        if [ -f "${backup_dir}/protocols.list" ]; then
            [ -f "${backup_dir}/reality.key" ]     && cp "${backup_dir}/reality.key" "${work_dir}/reality.key" && chmod 600 "${work_dir}/reality.key"
            [ -f "${backup_dir}/reality.shortid" ] && cp "${backup_dir}/reality.shortid" "${work_dir}/reality.shortid" && chmod 600 "${work_dir}/reality.shortid"
            # acme.sh 签发的证书文件与其账号/续期状态目录，inbound 里的
            # certificate_path/key_path 直接指向 acme/<domain>/ 下的文件，
            # 不恢复这两个目录会导致恢复后的 acme 协议指向空证书、服务启动失败。
            [ -d "${backup_dir}/acme" ]     && cp -r "${backup_dir}/acme" "${work_dir}/acme"
            [ -d "${backup_dir}/.acme.sh" ] && cp -r "${backup_dir}/.acme.sh" "${work_dir}/.acme.sh"
            [ -d "${backup_dir}/protocol_creds" ] && cp -r "${backup_dir}/protocol_creds" "${work_dir}/protocol_creds"

            local _ep_tag _ep_inbound _ep_port _ep_proto _tmp_merge
            while IFS= read -r _ep_tag; do
                [ -z "$_ep_tag" ] && continue
                _ep_inbound=$(jq -c --arg t "$_ep_tag" \
                    '.inbounds[] | select(.tag == $t)' "${backup_dir}/inbounds.json" 2>/dev/null)
                [ -z "$_ep_inbound" ] && { yellow "备份中未找到 ${_ep_tag} 的配置，跳过恢复"; continue; }

                _ep_port=$(jq -r '.listen_port' <<< "$_ep_inbound")
                case "$_ep_tag" in tuic) _ep_proto="udp" ;; *) _ep_proto="tcp" ;; esac
                if { [ "$_ep_proto" = udp ] && ss -ulnH | awk '{print $5}' | grep -q ":${_ep_port}$"; } \
                   || { [ "$_ep_proto" = tcp ] && ss -tlnH | awk '{print $5}' | grep -q ":${_ep_port}$"; }; then
                    yellow "备份中 ${_ep_tag} 端口 ${_ep_port} 已被占用，跳过恢复该协议（可安装后手动重新添加）"
                    continue
                fi

                _tmp_merge=$(mktemp)
                jq --argjson nb "$_ep_inbound" '.inbounds += [$nb]' \
                    "${conf_dir}/inbounds.json" > "$_tmp_merge"
                if [ $? -eq 0 ] && [ -s "$_tmp_merge" ]; then
                    mv "$_tmp_merge" "${conf_dir}/inbounds.json"
                    allow_port "${_ep_port}/${_ep_proto}"
                    echo "$_ep_tag" >> "${work_dir}/protocols.list"
                    if [ -f "${backup_dir}/protocols_acme.list" ] && grep -qxF "$_ep_tag" "${backup_dir}/protocols_acme.list"; then
                        echo "$_ep_tag" >> "${work_dir}/protocols_acme.list"
                        green "已恢复备用协议：${_ep_tag}（端口 ${_ep_port}，acme 证书）"
                    else
                        green "已恢复备用协议：${_ep_tag}（端口 ${_ep_port}，自签证书）"
                    fi
                else
                    rm -f "$_tmp_merge"
                    yellow "恢复 ${_ep_tag} 配置写入失败"
                fi
            done < "${backup_dir}/protocols.list"
        fi
    fi

    green "sing-box 核心安装完成"
}

# ── systemd 服务 ──────────────────────────────────
setup_services() {
    cat > /etc/systemd/system/sing-box.service << 'EOF'
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target
StartLimitIntervalSec=600
StartLimitBurst=5

[Service]
User=root
WorkingDirectory=/etc/sing-box
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=/etc/sing-box/sing-box run -C /etc/sing-box/conf
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=15
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/argo.service << 'EOF'
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
Type=simple
NoNewPrivileges=yes
TimeoutStartSec=0
ExecStart=/bin/true
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable sing-box
    local sb_start_ok=true
    if ! systemctl start sing-box; then
        red "\n⚠ sing-box 服务启动命令执行失败，请检查：journalctl -u sing-box -n 50 --no-pager\n"
        sb_start_ok=false
    elif ! systemctl is-active sing-box &>/dev/null; then
        red "\n⚠ sing-box 服务未能进入运行状态，请检查：journalctl -u sing-box -n 50 --no-pager\n"
        sb_start_ok=false
    fi
    systemctl enable argo

    TUNNEL_FULLY_RESTORED=false

    if [ -f "${work_dir}/tunnel.yml" ]; then
        if _rebuild_argo_service_from_tunnel_yml; then
            systemctl daemon-reload
            systemctl restart argo
        fi
    fi

    $sb_start_ok && return 0
    return 1
}

# ── 根据 tunnel.yml 重建 argo.service（用于恢复备份场景）──
_rebuild_argo_service_from_tunnel_yml() {
    # JSON 凭据模式：tunnel.yml 内含 credentials-file 字段
    local is_json_mode=false
    grep -q '^credentials-file:' "${work_dir}/tunnel.yml" 2>/dev/null && is_json_mode=true

    if ! $is_json_mode; then
        # Token 模式
        if [ ! -f "${work_dir}/argo_token" ]; then
            local argo_domain
            argo_domain=$(get_fixed_domain)
            yellow "检测到 Token 模式的隧道备份，域名：${argo_domain}"
            yellow "Token 文件缺失，请重新执行「Argo 隧道管理 → 配置固定隧道」输入 Token"
            TUNNEL_TOKEN_MODE=true
            return 1
        fi
        local argo_token
        argo_token=$(cat "${work_dir}/argo_token")
        cat > /etc/systemd/system/argo.service << EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
Type=simple
NoNewPrivileges=yes
TimeoutStartSec=0
ExecStart=/etc/sing-box/argo tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token ${argo_token}
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
        TUNNEL_FULLY_RESTORED=true
        return 0
    fi

    # JSON 凭据模式：tunnel.yml 已含 credentials-file，直接用
    if [ -f "${work_dir}/tunnel.json" ]; then
        cat > /etc/systemd/system/argo.service << EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
Type=simple
NoNewPrivileges=yes
TimeoutStartSec=0
ExecStart=/etc/sing-box/argo tunnel --edge-ip-version auto --config ${work_dir}/tunnel.yml run
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
        TUNNEL_FULLY_RESTORED=true
        return 0
    fi

    yellow "隧道配置文件存在但缺少凭据，请重新配置固定隧道"
    return 1
}

# ── 服务管理 ──────────────────────────────────────
manage_service() {
    local name="$1" action="$2"
    case "$action" in
        start)
            yellow "正在启动 ${name}…"
            systemctl daemon-reload
            systemctl start "$name"
            if systemctl is-active "$name" &>/dev/null; then
                green "${name} 已启动"
                return 0
            else
                red "${name} 启动失败"
                return 1
            fi
            ;;
        stop)
            yellow "正在停止 ${name}…"
            systemctl stop "$name"
            if ! systemctl is-active "$name" &>/dev/null; then
                green "${name} 已停止"
                return 0
            else
                red "${name} 停止失败"
                return 1
            fi
            ;;
        restart)
            yellow "正在重启 ${name}…"
            systemctl daemon-reload
            systemctl restart "$name"
            if systemctl is-active "$name" &>/dev/null; then
                green "${name} 已重启"
                return 0
            else
                red "${name} 重启失败"
                return 1
            fi
            ;;
    esac
}

start_singbox()  { manage_service "sing-box" "start"; }
stop_singbox()   { manage_service "sing-box" "stop";  }
restart_singbox(){ manage_service "sing-box" "restart"; }
start_argo()     { manage_service "argo" "start"; }
stop_argo()      { manage_service "argo" "stop";  }
restart_argo()   { manage_service "argo" "restart"; }

# ── 隧道工具 ──────────────────────────────────────
get_fixed_domain() {
    grep 'hostname:' "${work_dir}/tunnel.yml" 2>/dev/null \
        | head -1 | sed 's/.*hostname:[[:space:]]*//' | tr -d '[:space:]'
}

is_fixed_tunnel_configured() { [ -f "${work_dir}/tunnel.yml" ]; }

# ── 节点信息生成 ──────────────────────────────────
get_info() {
    yellow "\nIP 检测中，请稍候…\n"
    local server_ip node_prefix
    server_ip=$(curl -4 -sm3 ip.sb)
    [ -z "$server_ip" ] && { red "获取 IP 失败"; return 1; }
    node_prefix=$(get_node_name)

    if [ -f "${work_dir}/cf.env" ]; then
        local _cfip _cfport
        _cfip=$(grep  '^CFIP='   "${work_dir}/cf.env" | cut -d'=' -f2-)
        _cfport=$(grep '^CFPORT=' "${work_dir}/cf.env" | cut -d'=' -f2-)
        [ -n "$_cfip" ]   && CFIP="$_cfip"
        [ -n "$_cfport" ] && CFPORT="$_cfport"
    fi

    clear

    local hy2_port uuid hy2_password fingerprint
    hy2_port=$(jq -r '.inbounds[] | select(.type=="hysteria2") | .listen_port' "${conf_dir}/inbounds.json")
    uuid=$(jq -r '.inbounds[] | select(.tag=="vless-ws") | .users[0].uuid' "${conf_dir}/inbounds.json")
    hy2_password=$(jq -r '.inbounds[] | select(.type=="hysteria2") | .users[0].password' "${conf_dir}/inbounds.json")
    # 兼容旧配置（密码与UUID相同的历史配置）：若读取失败则回退使用 uuid
    [ -z "$hy2_password" ] || [ "$hy2_password" = "null" ] && hy2_password="$uuid"

    fingerprint=$(get_hy2_fingerprint)
    if [ -z "$fingerprint" ]; then
        red "证书读取失败，无法生成节点信息（请检查 ${work_dir}/cert.pem 是否存在）"
        return 1
    fi

    local vless_path
    vless_path=$(jq -r '.inbounds[] | select(.tag=="vless-ws") | .transport.path' "${conf_dir}/inbounds.json" \
        | sed 's|^/||')

    local argodomain=""
    is_fixed_tunnel_configured && argodomain=$(get_fixed_domain)

    if [ -z "$argodomain" ]; then
        yellow "未检测到固定隧道域名，VLESS 节点暂不可用，请先配置 Argo 固定隧道\n"
        cat > "${client_dir}" << EOF
hysteria2://${hy2_password}@${server_ip}:${hy2_port}?sni=bing.com&pinSHA256=${fingerprint}&alpn=h3#${node_prefix} hy2
EOF
    else
        green "\nArgo 域名：${argodomain}\n"

        local _port="${CFPORT:-443}"
        [[ "$_port" =~ ^[0-9]+$ ]] || _port="443"

        local encoded_path
        encoded_path="%2F${vless_path}%3Fed%3D2560"

        cat > "${client_dir}" << EOF
vless://${uuid}@${CFIP}:${_port}?encryption=none&security=tls&sni=${argodomain}&fp=chrome&type=ws&host=${argodomain}&path=${encoded_path}#${node_prefix} argo

hysteria2://${hy2_password}@${server_ip}:${hy2_port}?sni=bing.com&pinSHA256=${fingerprint}&alpn=h3#${node_prefix} hy2
EOF
    fi

    # 追加备用协议链接（TUIC / Reality / AnyTLS，未安装则跳过）
    append_extra_protocol_links "$server_ip" "$node_prefix"

    echo ""
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        echo -e "\e[1;35m${line}\033[0m"
    done < "${client_dir}"
}

# ── 查看节点 ──────────────────────────────────────
check_nodes() {
    [ ! -f "${client_dir}" ] && { red "节点信息不存在，请先安装 sing-box"; return 1; }
    clear; echo ""
    green "=== 当前节点信息 ===\n"
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        echo -e "\e[1;35m${line}\033[0m\n"
        command_exists qrencode && qrencode -t ANSIUTF8 "$line"
        echo ""
    done < "${client_dir}"
}

# ── 大陆拦截 ──────────────────────────────────────
cn_block_manage() {
    check_singbox &>/dev/null
    [ $? -eq 2 ] && { yellow "sing-box 尚未安装！"; sleep 1; return 1; }

    local route_file="${conf_dir}/route.json"
    jq empty "$route_file" 2>/dev/null || { red "route.json 格式异常，请检查文件内容"; sleep 2; return 1; }
    local block_enabled=false
    jq -e '.route.rules[] | select(.rule_set[]? == "geosite-cn")' \
        "$route_file" >/dev/null 2>&1 && block_enabled=true

    clear; echo ""
    green "=== 大陆域名拦截管理 ===\n"
    $block_enabled && green "当前状态：已开启\n" || yellow "当前状态：未开启\n"
    green  "1. 开启大陆拦截"
    skyblue "---------------"
    red    "2. 关闭大陆拦截"
    skyblue "---------------"
    purple "0. 返回主菜单"
    skyblue "---------------"
    reading "请输入选择: " choice

    case "$choice" in
        1)
            if $block_enabled; then
                yellow "大陆拦截已开启，无需重复操作\n"; sleep 1; return 1
            fi
            local tmp_file
            tmp_file=$(mktemp)
            jq '
              del(.route.rules[] | select(.rule_set[]? == "geosite-cn")) |
              del(.route.rules[] | select(
                  .domain_regex? and .outbound == "direct" and
                  (.domain_regex[] | test("googleapis"))
              )) |
              del(.route.rule_set[] | select(.tag == "geosite-cn")) |
              .route.rule_set += [{"type":"remote","tag":"geosite-cn","format":"binary",
                "url":"https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs",
                "download_detour":"direct"}] |
              .route.rules = [
                {"domain_regex":["^([a-zA-Z0-9_-]+\\.)*googleapis\\.cn$",
                  "^([a-zA-Z0-9_-]+\\.)*googleapis\\.com$",
                  "^([a-zA-Z0-9_-]+\\.)*gstatic\\.com$",
                  "^([a-zA-Z0-9_-]+\\.)*xn--ngstr-lra8j\\.com$"],
                 "outbound":"direct"},
                {"rule_set":["geosite-cn"],"outbound":"block"}
              ] + .route.rules
            ' "$route_file" > "$tmp_file"
            if [ $? -ne 0 ] || [ ! -s "$tmp_file" ]; then
                rm -f "$tmp_file"; red "配置写入失败"; sleep 2; return 0
            fi
            mv "$tmp_file" "$route_file"
            if restart_singbox; then
                green "\n大陆域名拦截已开启\n"
            else
                red "\n路由规则已写入，但 sing-box 重启失败，拦截可能未生效"
                red "请检查：journalctl -u sing-box -n 50 --no-pager\n"
            fi
            ;;
        2)
            if ! $block_enabled; then
                yellow "大陆拦截未开启\n"; sleep 1; return 1
            fi
            local tmp_file
            tmp_file=$(mktemp)
            jq '
              del(.route.rules[] | select(.rule_set[]? == "geosite-cn")) |
              del(.route.rules[] | select(
                  .domain_regex? and .outbound == "direct" and
                  (.domain_regex[] | test("googleapis"))
              )) |
              del(.route.rule_set[] | select(.tag == "geosite-cn"))
            ' "$route_file" > "$tmp_file"
            if [ $? -ne 0 ] || [ ! -s "$tmp_file" ]; then
                rm -f "$tmp_file"; red "配置写入失败"; sleep 2; return 0
            fi
            mv "$tmp_file" "$route_file"
            if restart_singbox; then
                green "\n大陆域名拦截已关闭\n"
            else
                red "\n路由规则已写入，但 sing-box 重启失败，请检查：journalctl -u sing-box -n 50 --no-pager\n"
            fi
            ;;
        0) return 1 ;;
        *) red "无效选项"; return 0 ;;
    esac
}

# ── 修改节点配置 ──────────────────────────────────
change_config() {
    check_singbox &>/dev/null
    [ $? -eq 2 ] && { yellow "sing-box 尚未安装！"; sleep 1; return 1; }

    local inbounds_file="${conf_dir}/inbounds.json"
    local sb_status
    sb_status=$(check_singbox 2>&1)

    clear; echo ""
    green "=== 修改节点配置 === sing-box: ${sb_status}\n"
    green  "1. 修改 UUID"
    green  "2. 修改 Hysteria2 端口"
    green  "3. 修改 VLESS-Argo 端口"
    green  "4. 修改 CF 优选域名/IP"
    purple "0. 返回主菜单"
    skyblue "------------"
    reading "请输入选择: " choice

    case "$choice" in
        1)
            reading "\n请输入新的 UUID（回车随机生成）: " new_uuid
            [ -z "$new_uuid" ] && new_uuid=$(cat /proc/sys/kernel/random/uuid)
            if [[ -n "$new_uuid" ]] && \
               ! [[ "$new_uuid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
                red "UUID 格式不合法"; sleep 1; return 0
            fi
            local tmp_file
            tmp_file=$(mktemp)
            # 仅修改 Argo VLESS 的 UUID 和 path（按 tag 精确匹配，避免误改 Reality 的 vless inbound）
            jq --arg u "$new_uuid" --arg p "/${new_uuid}-vless" '
                (.inbounds[] | select(.tag=="vless-ws") | .users[] | .uuid) = $u |
                (.inbounds[] | select(.tag=="vless-ws") | .transport.path) = $p
            ' "$inbounds_file" > "$tmp_file"
            if [ $? -ne 0 ] || [ ! -s "$tmp_file" ]; then
                rm -f "$tmp_file"; red "配置文件写入失败，请检查！"; sleep 2; return 0
            fi
            mv "$tmp_file" "$inbounds_file"
            if restart_singbox; then
                get_info
                green "\nUUID 已修改为：${new_uuid}\n"
            else
                red "\n配置文件中的 UUID 已更新为 ${new_uuid}，但 sing-box 重启失败，节点当前不可用"
                red "请检查：journalctl -u sing-box -n 50 --no-pager\n"
            fi
            ;;

       2)
            reading "\n请输入新的 Hysteria2 端口（回车随机生成）: " new_port
            if [ -z "$new_port" ]; then
                new_port=$(pick_free_udp_port)
            else
                if ! [[ "$new_port" =~ ^[0-9]+$ ]] || (( new_port < 1 || new_port > 65535 )); then
                    red "端口无效（1-65535）"; sleep 1; return 0
                fi
                if ss -ulnH | awk '{print $5}' | grep -q ":${new_port}$"; then
                    red "端口 ${new_port} 已被占用，请换一个"; sleep 1; return 0
                fi
            fi
            local old_port
            old_port=$(jq -r '.inbounds[] | select(.type=="hysteria2") | .listen_port' "$inbounds_file")
            local tmp_file
            tmp_file=$(mktemp)
            jq --argjson p "$new_port" \
                '(.inbounds[] | select(.type=="hysteria2") | .listen_port) = $p' \
                "$inbounds_file" > "$tmp_file"
            if [ $? -ne 0 ] || [ ! -s "$tmp_file" ]; then
                rm -f "$tmp_file"; red "配置写入失败"; sleep 1; return 0
            fi
            mv "$tmp_file" "$inbounds_file"
            # 删旧端口规则（IPv4，精确删除避免误伤）
            if ! iptables -D INPUT -p udp --dport "$old_port" -j ACCEPT 2>/dev/null; then
                yellow "警告：未能删除旧端口 ${old_port} 的防火墙规则，可能需要手动检查 iptables"
            fi

            # 摘下 DROP 兜底 → 追加新端口 → 重新压入 DROP（只操作 IPv4，v6 全 DROP 不动）
            iptables -D INPUT -j DROP 2>/dev/null || true
            iptables -A INPUT -p udp --dport "$new_port" -j ACCEPT 2>/dev/null || true
            iptables -A INPUT -j DROP 2>/dev/null || true

            # 持久化（只存 IPv4，v6 规则固定不变）
            mkdir -p /etc/iptables
            local _t4
            _t4=$(mktemp)
            if [ -n "$_t4" ] && iptables-save > "$_t4" 2>/dev/null; then
                mv "$_t4" /etc/iptables/rules.v4
            else
                rm -f "$_t4"
                yellow "保存 rules.v4 失败"
            fi

            if restart_singbox; then
                get_info
                green "\nHysteria2 端口已修改为：${new_port}\n"
            else
                red "\n端口已更新为 ${new_port}，但 sing-box 重启失败，节点当前不可用"
                red "请检查：journalctl -u sing-box -n 50 --no-pager\n"
            fi
            ;;
        3)
            reading "\n请输入新的 VLESS-Argo 端口（回车随机生成）: " new_port
            [ -z "$new_port" ] && new_port=$(pick_free_tcp_port)
            if ! [[ "$new_port" =~ ^[0-9]+$ ]] || (( new_port < 1 || new_port > 65535 )); then
                red "端口无效（1-65535）"; sleep 1; return 0
            fi
            if ss -tlnH | awk '{print $5}' | grep -q ":${new_port}$"; then
                red "端口 ${new_port} 已被占用，请换一个"; sleep 1; return 0
            fi

            # Token 模式下，本地端口和 Cloudflare Dashboard 后端配置是分离的，
            # sed 无法同步修改 Dashboard 侧配置，必须用户手动去 Dashboard 改，
            # 因此这里在写入配置前先强制确认，避免节点静默失效
            local is_token_mode=false
            if [ -f "${work_dir}/tunnel.yml" ] && [ -f "${work_dir}/argo_token" ] && [ ! -f "${work_dir}/tunnel.json" ]; then
                is_token_mode=true
            fi

            if $is_token_mode; then
                yellow "\n⚠ 检测到 Token 模式固定隧道"
                yellow "本地端口修改后，还需要手动前往 Cloudflare Dashboard"
                yellow "将该隧道的后端端口（Public Hostname → Service）改为 ${new_port}"
                yellow "在改完 Dashboard 配置之前，VLESS 节点会连接失败\n"
                reading "是否已确认要继续修改本地端口？(y/n): " confirm_token
                if [[ "$confirm_token" != [yY] ]]; then
                    purple "已取消端口修改\n"; sleep 1; return 0
                fi
            fi

            local tmp_file
            tmp_file=$(mktemp)
            jq --argjson p "$new_port" \
                '(.inbounds[] | select(.tag=="vless-ws") | .listen_port) = $p' \
                "$inbounds_file" > "$tmp_file"
            if [ $? -ne 0 ] || [ ! -s "$tmp_file" ]; then
                rm -f "$tmp_file"; red "配置写入失败"; sleep 1; return 0
            fi
            mv "$tmp_file" "$inbounds_file"

            if [ -f "${work_dir}/tunnel.yml" ]; then
                if $is_token_mode; then
                    yellow "⚠ 请立即前往 Cloudflare Dashboard 将后端端口改为 ${new_port}，否则节点无法连接"
                else
                    sed -i "s|service: http://localhost:[0-9]*|service: http://localhost:${new_port}|" \
                        "${work_dir}/tunnel.yml"
                fi
            fi
            if restart_singbox; then
                if restart_argo; then
                    get_info
                    green "\nVLESS-Argo 端口已修改为：${new_port}\n"
                else
                    red "\n端口已更新为 ${new_port}，sing-box 已重启，但 argo 隧道重启失败，节点当前不可用"
                    red "请检查：journalctl -u argo -n 50 --no-pager\n"
                fi
            else
                red "\n端口已更新为 ${new_port}，但 sing-box 重启失败，节点当前不可用"
                red "请检查：journalctl -u sing-box -n 50 --no-pager\n"
            fi
            ;;

        4)
            clear
            green "1: ct.877774.xyz  2: cf.877774.xyz  3: cloudflare-ech.com  4: www.visa.com.sg\n"
            reading "请输入优选域名或 IP[:端口]（回车默认 cloudflare-ech.com）: " input
            local cfip cfport
            case "$input" in
                ""|"3") cfip="cloudflare-ech.com"; cfport="443" ;;
                "1")    cfip="ct.877774.xyz";      cfport="443" ;;
                "2")    cfip="cf.877774.xyz";      cfport="443" ;;
                "4")    cfip="www.visa.com.sg";    cfport="443" ;;
                *)
                    if [[ "$input" =~ : ]]; then
                        cfip="${input%%:*}"; cfport="${input##*:}"
                        [[ ! "$cfport" =~ ^[0-9]+$ ]] || (( cfport > 65535 )) && cfport="443"
                        # 若用户输入类似 ":8080" 这种，冒号前为空，cfip 会被解析成空字符串，
                        # 写入 CFIP= 空值会破坏 Argo 域名/IP 解析配置，此处兜底回退默认值
                        [ -z "$cfip" ] && cfip="cloudflare-ech.com"
                    else
                        cfip="$input"; cfport="443"
                    fi
                    ;;
            esac
            printf 'CFIP=%s\nCFPORT=%s\n' "$cfip" "$cfport" > "${work_dir}/cf.env"
            chmod 600 "${work_dir}/cf.env"
            get_info
            green "\nCF 优选已更新为：${cfip}:${cfport}\n"
            ;;

        0) return 1 ;;
        *) red "无效选项！"; return 0 ;;
    esac
}
# =========================================================
# 备用协议模块：TUIC v5 / VLESS-Reality / AnyTLS
# 依赖主脚本已定义：work_dir conf_dir client_dir backup_dir
#                    red/green/yellow/purple/skyblue/reading
#                    command_exists allow_port remove_port
#                    pick_free_udp_port pick_free_tcp_port
#                    get_node_name restart_singbox check_singbox
# =========================================================

protocols_list="${work_dir}/protocols.list"
reality_key_file="${work_dir}/reality.key"

# 协议元信息：tag → 中文名 / 传输层
declare -A EXTRA_PROTO_NAME=(
    [tuic]="TUIC v5"
    [reality]="VLESS-Reality"
    [anytls]="AnyTLS"
)
declare -A EXTRA_PROTO_TRANSPORT=(
    [tuic]="udp"
    [reality]="tcp"
    [anytls]="tcp"
)
# 固定展示顺序（bash 关联数组无序，遍历要用这个）
EXTRA_PROTO_ORDER=(tuic reality anytls)

# ── 协议清单读写 ──────────────────────────────────
_ensure_protocols_list() {
    mkdir -p "${work_dir}"
    [ -f "$protocols_list" ] || touch "$protocols_list"
}

is_protocol_installed() {
    local tag="$1"
    _ensure_protocols_list
    grep -qxF "$tag" "$protocols_list" 2>/dev/null
}

_mark_protocol_installed() {
    local tag="$1"
    _ensure_protocols_list
    is_protocol_installed "$tag" || echo "$tag" >> "$protocols_list"
}

_mark_protocol_removed() {
    local tag="$1"
    _ensure_protocols_list
    local tmp
    tmp=$(mktemp)
    if [ -n "$tmp" ]; then
        grep -vxF "$tag" "$protocols_list" > "$tmp" 2>/dev/null
        mv "$tmp" "$protocols_list"
    fi
}

# ── inbounds.json 读写工具（复用主脚本 jq 风格） ──
_inbound_exists() {
    local tag="$1"
    jq -e --arg t "$tag" '.inbounds[] | select(.tag == $t)' \
        "${conf_dir}/inbounds.json" >/dev/null 2>&1
}

_add_inbound_json() {
    # $1 = 新 inbound 的 JSON 字符串
    local new_inbound="$1"
    local tmp
    tmp=$(mktemp)
    jq --argjson nb "$new_inbound" '.inbounds += [$nb]' \
        "${conf_dir}/inbounds.json" > "$tmp"
    if [ $? -ne 0 ] || [ ! -s "$tmp" ]; then
        rm -f "$tmp"
        return 1
    fi
    mv "$tmp" "${conf_dir}/inbounds.json"
}

_remove_inbound_json() {
    local tag="$1"
    local tmp
    tmp=$(mktemp)
    jq --arg t "$tag" '.inbounds |= map(select(.tag != $t))' \
        "${conf_dir}/inbounds.json" > "$tmp"
    if [ $? -ne 0 ] || [ ! -s "$tmp" ]; then
        rm -f "$tmp"
        return 1
    fi
    mv "$tmp" "${conf_dir}/inbounds.json"
}

# ── Reality 密钥对：生成一次、持久化，重装时复用 ──
_ensure_reality_keypair() {
    if [ -s "$reality_key_file" ]; then
        return 0
    fi
    if [ ! -x "${work_dir}/sing-box" ]; then
        red "sing-box 二进制不存在，无法生成 Reality 密钥对"
        return 1
    fi
    local out priv pub
    out=$("${work_dir}/sing-box" generate reality-keypair 2>/dev/null)
    priv=$(awk -F': ' '/PrivateKey/{print $2}' <<< "$out")
    pub=$(awk -F': ' '/PublicKey/{print $2}'  <<< "$out")
    if [ -z "$priv" ] || [ -z "$pub" ]; then
        red "生成 Reality 密钥对失败"
        return 1
    fi
    printf '%s\n%s\n' "$priv" "$pub" > "$reality_key_file"
    chmod 600 "$reality_key_file"
}

_reality_private_key() { sed -n '1p' "$reality_key_file" 2>/dev/null; }
_reality_public_key()  { sed -n '2p' "$reality_key_file" 2>/dev/null; }

# ── short_id：8 位十六进制，生成一次持久化到清单同目录 ──
_reality_short_id_file="${work_dir}/reality.shortid"
_ensure_reality_shortid() {
    if [ -s "$_reality_short_id_file" ]; then
        return 0
    fi
    openssl rand -hex 4 > "$_reality_short_id_file"
    chmod 600 "$_reality_short_id_file"
}
_reality_short_id() { cat "$_reality_short_id_file" 2>/dev/null; }

# =========================================================
# acme 证书配置：TUIC / AnyTLS 共用
# 优先用 cf.env 里已保存的 CF_ACME_TOKEN / CF_ACME_DOMAIN；
# 没有则询问一次是否设置；用户选择跳过则回退自签证书 + insecure
# =========================================================
_read_cf_env_key() {
    local key="$1"
    [ -f "${work_dir}/cf.env" ] || return 1
    grep "^${key}=" "${work_dir}/cf.env" | cut -d'=' -f2-
}

_write_cf_env_key() {
    local key="$1" val="$2"
    _ensure_protocols_list  # 顺带确保 work_dir 存在
    touch "${work_dir}/cf.env"
    # 不用 sed 做行内替换：Cloudflare Token 可能包含 & 或 | 等字符，
    # & 在 sed 替换文本里代表"匹配到的整行"，| 又是这里 sed 用的分隔符，
    # 两者都会导致写入损坏或静默失败（已实测验证）。改用 grep 过滤旧行 + 追加新行，
    # 不依赖任何转义规则，任意字符的 Token 都能正确处理。
    local tmp
    tmp=$(mktemp)
    if [ -z "$tmp" ]; then
        red "临时文件创建失败（如 /tmp 空间不足），${key} 未写入"
        return 1
    fi
    grep -v "^${key}=" "${work_dir}/cf.env" > "$tmp" 2>/dev/null
    echo "${key}=${val}" >> "$tmp"
    if ! mv "$tmp" "${work_dir}/cf.env"; then
        red "写入 ${work_dir}/cf.env 失败，${key} 未生效"
        rm -f "$tmp"
        return 1
    fi
    chmod 600 "${work_dir}/cf.env"
}

# 返回值：0 = 已配置 acme（供调用方读取 CF_ACME_TOKEN/CF_ACME_DOMAIN）
#         1 = 用户选择跳过，使用自签证书
ensure_acme_config() {
    local token zone_id domain acme_choice
    token=$(_read_cf_env_key CF_ACME_TOKEN)
    domain=$(_read_cf_env_key CF_ACME_DOMAIN)
    zone_id=$(_read_cf_env_key CF_ACME_ZONE_ID)
    # 三个字段必须同时存在才算已配置完整（历史遗留：旧版本脚本只存了
    # token/domain 两个字段，没有 zone_id，若只判断前两者会误判为"已配置"，
    # 导致后续 acme.sh 因缺 zone_id 直接申请失败，且不会再询问用户补齐）。
    if [ -n "$token" ] && [ -n "$domain" ] && [ -n "$zone_id" ]; then
        return 0
    fi

    echo ""
    purple "该协议需要 TLS 证书。可选择：\n"
    skyblue "1. 使用 acme 自动申请真实证书（需域名 + Cloudflare API Token/Zone ID，DNS 记录须为“仅 DNS”不走代理）"
    skyblue "2. 使用自签证书（客户端需 insecure=1 跳过验证，配置更快）"
    reading "请选择 (1/2，回车默认 2): " acme_choice

    if [ "$acme_choice" != "1" ]; then
        return 1
    fi

    reading "请输入用于该协议的子域名（如 node1.yourdomain.com，需已在 Cloudflare 解析到本机 IP 且为“仅 DNS”）: " domain
    if [ -z "$domain" ]; then
        yellow "域名为空，回退使用自签证书"
        return 1
    fi
    if ! [[ "$domain" =~ ^[A-Za-z0-9._-]+\.[A-Za-z]{2,}$ ]]; then
        yellow "域名格式不合法，回退使用自签证书"
        return 1
    fi
    reading "请输入 Cloudflare API Token（Zone:DNS:Edit 权限，仅作用于该域名）: " token
    if [ -z "$token" ]; then
        yellow "Token 为空，回退使用自签证书"
        return 1
    fi
    echo ""
    yellow "acme.sh 需要 Zone ID 才能定位到具体域名（Cloudflare 后台该域名的 Overview 页面右侧“API”栏可查看）"
    reading "请输入 Cloudflare Zone ID: " zone_id
    if [ -z "$zone_id" ]; then
        yellow "Zone ID 为空，回退使用自签证书"
        return 1
    fi

    if ! _write_cf_env_key CF_ACME_TOKEN "$token" || \
       ! _write_cf_env_key CF_ACME_DOMAIN "$domain" || \
       ! _write_cf_env_key CF_ACME_ZONE_ID "$zone_id"; then
        red "acme 配置写入失败，回退使用自签证书"
        return 1
    fi
    green "acme 配置已保存（${work_dir}/cf.env，权限 600）"
    return 0
}

# =========================================================
# acme.sh 证书申请：TUIC / AnyTLS 共用
# 不使用 sing-box 内置 acme 客户端（其 DNS-01 传播检测在纯 IPv4 环境下
# 会因写死的 IPv6 解析器而失败，参见 2026-08 DediRock 实测记录）。
# 改用 acme.sh 独立申请证书后，以 certificate_path/key_path 形式接入 sing-box；
# sing-box 官方文档确认证书文件在被修改时会自动重新加载，
# 续期由 acme.sh 自带的 cron 任务处理，全程无需重启 sing-box。
# =========================================================
_acme_sh_bin="${HOME}/.acme.sh/acme.sh"

_ensure_acme_sh_installed() {
    if [ -x "$_acme_sh_bin" ]; then
        return 0
    fi
    yellow "首次使用 acme.sh，正在安装…"
    # 不传 email 参数：acme.sh 官方文档确认该参数默认即为空，不是必需项。
    # 曾尝试用 hostname -f 拼邮箱，但多数云 VPS 的 hostname -f 只返回短主机名（如 "74"），
    # 拼出的 "acme@74" 不是合法邮箱格式，可能导致 CA 账号注册被拒——不传更安全。
    if ! curl -fsSL https://get.acme.sh | sh >/dev/null 2>&1; then
        red "acme.sh 安装失败，请检查网络"
        return 1
    fi
    if [ ! -x "$_acme_sh_bin" ]; then
        red "acme.sh 安装后未找到可执行文件：${_acme_sh_bin}"
        return 1
    fi
    green "acme.sh 安装完成"
    return 0
}

# 为指定域名申请证书，成功后把证书/私钥安装到 ${work_dir}/acme/<domain>/{cert.pem,key.pem}
# 供 inbound 的 certificate_path/key_path 直接引用。
# 用法：_acme_sh_issue_cert <domain>
_acme_sh_issue_cert() {
    local domain="$1"
    local token zone_id
    token=$(_read_cf_env_key CF_ACME_TOKEN)
    zone_id=$(_read_cf_env_key CF_ACME_ZONE_ID)
    if [ -z "$token" ] || [ -z "$zone_id" ]; then
        red "未找到 acme Cloudflare Token/Zone ID 配置"
        return 1
    fi

    _ensure_acme_sh_installed || return 1

    local cert_dir="${work_dir}/acme/${domain}"
    mkdir -p "$cert_dir"

    # 已有证书且未接近过期（acme.sh --issue 对已存在且未到期的证书会直接跳过重复申请，
    # 幂等，可放心重复调用）
    if CF_Token="$token" CF_Zone_ID="$zone_id" \
        "$_acme_sh_bin" --issue --dns dns_cf -d "$domain" --server letsencrypt \
        --home "${work_dir}/.acme.sh" >>"${work_dir}/acme.log" 2>&1; then
        : # 申请成功或证书仍在有效期内被跳过，均视为成功
    else
        local ret=$?
        # acme.sh 对"证书未到期无需续期"返回码为 2，不是失败
        if [ "$ret" -ne 2 ]; then
            red "acme.sh 证书申请失败，详情见 ${work_dir}/acme.log"
            return 1
        fi
    fi

    if ! CF_Token="$token" CF_Zone_ID="$zone_id" \
        "$_acme_sh_bin" --install-cert -d "$domain" \
        --home "${work_dir}/.acme.sh" \
        --key-file "${cert_dir}/key.pem" \
        --fullchain-file "${cert_dir}/cert.pem" \
        --reloadcmd "true" >>"${work_dir}/acme.log" 2>&1; then
        red "acme.sh 证书安装失败，详情见 ${work_dir}/acme.log"
        return 1
    fi

    if [ ! -s "${cert_dir}/cert.pem" ] || [ ! -s "${cert_dir}/key.pem" ]; then
        red "证书文件未正确生成：${cert_dir}"
        return 1
    fi

    green "acme.sh 证书已就绪：${cert_dir}（自动续期由 acme.sh 自带 cron 处理）"

    _ensure_acme_sync_cron "$domain"
    return 0
}

# 独立于 acme.sh 自带的 reloadcmd 机制，额外加两道保险：
#
# 1) 真正的续期检查：acme.sh 安装脚本会自动生成一条系统级 --cron 任务，
#    但它固定使用默认的 --home（如 /root/.acme.sh），与本脚本证书数据实际存放的
#    自定义 --home（${work_dir}/.acme.sh）是两个不同目录，无法读到我们的账号/证书数据，
#    实际上不会对这里申请的证书做任何续期检查（2026-08 DediRock 实测确认此现象）。
#    此处额外注册一条指向正确 --home 的 --cron 任务，确保续期检查真正生效。
#
# 2) 证书同步：部分环境下 acme.sh 续期时不会按预期重新执行 install-cert（社区有相关反馈，
#    行为不完全可靠），若证书续期了但未同步到 certificate_path 指向的文件，
#    sing-box 会一直用旧证书直到过期。每天定时主动重新执行一次 install-cert，
#    把最新证书强制同步到目标路径，即使 reloadcmd 没触发也能兜底。
_ensure_acme_sync_cron() {
    local domain="$1"

    # 1) 续期检查任务：整个 --home 目录级别只需注册一次，覆盖该目录下所有域名
    local renew_marker="# sing-box-extra-protocols acme renew-check"
    if ! crontab -l 2>/dev/null | grep -qF "$renew_marker"; then
        local renew_cmd="'${_acme_sh_bin}' --cron --home '${work_dir}/.acme.sh' >>'${work_dir}/acme.log' 2>&1"
        (crontab -l 2>/dev/null; echo "33 3 * * * ${renew_cmd} ${renew_marker}") | crontab -
    fi

    # 2) 证书同步任务：按域名单独注册（不同协议若共用同一域名，第二次调用会因 marker 已存在而跳过）
    local sync_marker="# sing-box-extra-protocols acme sync: ${domain}"
    if crontab -l 2>/dev/null | grep -qF "$sync_marker"; then
        return 0
    fi
    local cert_dir="${work_dir}/acme/${domain}"
    local sync_cmd="CF_Token=\$(grep '^CF_ACME_TOKEN=' '${work_dir}/cf.env' | cut -d'=' -f2-) CF_Zone_ID=\$(grep '^CF_ACME_ZONE_ID=' '${work_dir}/cf.env' | cut -d'=' -f2-) '${_acme_sh_bin}' --install-cert -d '${domain}' --home '${work_dir}/.acme.sh' --key-file '${cert_dir}/key.pem' --fullchain-file '${cert_dir}/cert.pem' --reloadcmd true >>'${work_dir}/acme.log' 2>&1"
    (crontab -l 2>/dev/null; echo "17 4 * * * ${sync_cmd} ${sync_marker}") | crontab -
}

# =========================================================
# 协议凭证存档：删除协议时不清除，重新添加时可选择复用，
# 避免每次删除+重装都要在客户端重新导入链接（UUID/密码/端口全变）。
# 存档路径：${work_dir}/protocol_creds/<tag>.json
# =========================================================
_creds_dir="${work_dir}/protocol_creds"

_ensure_creds_dir() {
    mkdir -p "$_creds_dir"
}

# 用法：_save_protocol_creds <tag> <json字符串>
_save_protocol_creds() {
    local tag="$1" json="$2"
    _ensure_creds_dir
    echo "$json" > "${_creds_dir}/${tag}.json"
    chmod 600 "${_creds_dir}/${tag}.json"
}

# 用法：_read_protocol_creds <tag>；无存档时输出为空，调用方需自行判断
_read_protocol_creds() {
    local tag="$1"
    [ -s "${_creds_dir}/${tag}.json" ] && cat "${_creds_dir}/${tag}.json"
}

# 询问是否复用旧凭证；仅在存档存在时才会问，否则静默返回1（走新生成分支）
# 返回 0 = 复用（调用方自行从 _read_protocol_creds 取值），1 = 重新生成
_ask_reuse_creds() {
    local tag="$1" proto_name="$2"
    local old_json
    old_json=$(_read_protocol_creds "$tag")
    [ -z "$old_json" ] && return 1

    echo ""
    yellow "检测到 ${proto_name} 之前的配置（UUID/密码/端口），是否复用？"
    yellow "复用可避免客户端重新导入链接；选择重新生成则视为全新节点。"
    local reuse_choice
    reading "是否复用旧配置？(Y/n，回车默认 Y): " reuse_choice
    if [[ "$reuse_choice" =~ ^[nN]$ ]]; then
        return 1
    fi
    return 0
}

# =========================================================
# add_protocol_tuic：生成 TUIC v5 inbound
# 优先 acme.sh 申请真实证书；否则回退复用现有自签 cert.pem / private.key
# =========================================================
add_protocol_tuic() {
    if is_protocol_installed tuic; then
        yellow "TUIC 已安装，跳过"
        return 0
    fi

    local use_acme=false acme_domain
    if ensure_acme_config; then
        acme_domain=$(_read_cf_env_key CF_ACME_DOMAIN)
        # 先在装 inbound 之前就把证书申请完，申请失败直接中止，
        # 不会出现"配置已写入但 sing-box 启动时才发现证书拿不到"导致服务崩溃重启的情况
        # （2026-08 DediRock 曾因此触发 Let's Encrypt 限流，参见脚本内相关记录）。
        if _acme_sh_issue_cert "$acme_domain"; then
            use_acme=true
        else
            yellow "acme 证书申请失败，回退使用自签证书"
        fi
    fi
    if ! $use_acme && { [ ! -f "${work_dir}/cert.pem" ] || [ ! -f "${work_dir}/private.key" ]; }; then
        red "未找到证书文件，请先安装 sing-box 主体（VLESS+Hysteria2）"
        return 1
    fi

    local port uuid password
    local reused=false
    if _ask_reuse_creds tuic "TUIC v5"; then
        local old_json
        old_json=$(_read_protocol_creds tuic)
        uuid=$(jq -r '.uuid' <<< "$old_json")
        password=$(jq -r '.password' <<< "$old_json")
        port=$(jq -r '.port' <<< "$old_json")
        # 旧端口若已被占用（比如期间装了别的服务），自动换新端口，不阻塞流程
        if ss -ulnH 2>/dev/null | awk '{print $5}' | grep -q ":${port}$"; then
            yellow "旧端口 ${port} 已被占用，自动分配新端口"
            port=$(pick_free_udp_port) || { red "无法分配空闲 UDP 端口"; return 1; }
        fi
        reused=true
        green "已复用 TUIC 旧配置（UUID/密码不变，客户端链接可能仅端口变化）"
    else
        port=$(pick_free_udp_port) || { red "无法分配空闲 UDP 端口"; return 1; }
        uuid=$(cat /proc/sys/kernel/random/uuid)
        password=$(openssl rand -hex 16)
    fi

    local inbound
    if $use_acme; then
        inbound=$(jq -n \
            --argjson port "$port" \
            --arg uuid "$uuid" \
            --arg pass "$password" \
            --arg domain "$acme_domain" \
            --arg cert "${work_dir}/acme/${acme_domain}/cert.pem" \
            --arg key  "${work_dir}/acme/${acme_domain}/key.pem" \
            '{
                type: "tuic",
                tag: "tuic",
                listen: "0.0.0.0",
                listen_port: $port,
                users: [{uuid: $uuid, password: $pass}],
                congestion_control: "bbr",
                tls: {
                    enabled: true,
                    server_name: $domain,
                    alpn: ["h3"],
                    certificate_path: $cert,
                    key_path: $key
                }
            }')
    else
        inbound=$(jq -n \
            --argjson port "$port" \
            --arg uuid "$uuid" \
            --arg pass "$password" \
            --arg cert "${work_dir}/cert.pem" \
            --arg key  "${work_dir}/private.key" \
            '{
                type: "tuic",
                tag: "tuic",
                listen: "0.0.0.0",
                listen_port: $port,
                users: [{uuid: $uuid, password: $pass}],
                congestion_control: "bbr",
                tls: {
                    enabled: true,
                    alpn: ["h3"],
                    certificate_path: $cert,
                    key_path: $key
                }
            }')
    fi

    _add_inbound_json "$inbound" || { red "写入 TUIC 配置失败"; return 1; }
    allow_port "${port}/udp"
    _mark_protocol_installed tuic
    _save_protocol_creds tuic "$(jq -n --arg u "$uuid" --arg p "$password" --argjson port "$port" \
        '{uuid: $u, password: $p, port: $port}')"
    if $use_acme; then
        echo "tuic" >> "${work_dir}/protocols_acme.list"
        green "TUIC v5 已添加，端口：${port}（acme 证书：${acme_domain}）"
    else
        green "TUIC v5 已添加，端口：${port}（自签证书）"
    fi
}

# =========================================================
# add_protocol_reality：生成 VLESS-Reality inbound（不走 Argo，直连）
# =========================================================
add_protocol_reality() {
    if is_protocol_installed reality; then
        yellow "Reality 已安装，跳过"
        return 0
    fi

    _ensure_reality_keypair || return 1
    _ensure_reality_shortid || return 1

    local port uuid sni
    # www.microsoft.com 实测在部分客户端（v2rayN）握手失败，改用 apple.com（已实测多端可连）
    sni="www.apple.com"

    if _ask_reuse_creds reality "VLESS-Reality"; then
        local old_json
        old_json=$(_read_protocol_creds reality)
        uuid=$(jq -r '.uuid' <<< "$old_json")
        port=$(jq -r '.port' <<< "$old_json")
        if ss -tlnH 2>/dev/null | awk '{print $5}' | grep -q ":${port}$"; then
            yellow "旧端口 ${port} 已被占用，自动分配新端口"
            port=$(pick_free_tcp_port) || { red "无法分配空闲 TCP 端口"; return 1; }
        fi
        green "已复用 Reality 旧配置（UUID/密钥对不变，客户端链接可能仅端口变化）"
    else
        port=$(pick_free_tcp_port) || { red "无法分配空闲 TCP 端口"; return 1; }
        uuid=$(cat /proc/sys/kernel/random/uuid)
    fi

    local priv short_id
    priv=$(_reality_private_key)
    short_id=$(_reality_short_id)

    local inbound
    inbound=$(jq -n \
        --argjson port "$port" \
        --arg uuid "$uuid" \
        --arg sni "$sni" \
        --arg priv "$priv" \
        --arg sid "$short_id" \
        '{
            type: "vless",
            tag: "reality",
            listen: "0.0.0.0",
            listen_port: $port,
            users: [{uuid: $uuid, flow: "xtls-rprx-vision"}],
            tls: {
                enabled: true,
                server_name: $sni,
                reality: {
                    enabled: true,
                    handshake: {server: $sni, server_port: 443},
                    private_key: $priv,
                    short_id: [$sid]
                }
            }
        }')

    _add_inbound_json "$inbound" || { red "写入 Reality 配置失败"; return 1; }
    allow_port "${port}/tcp"
    _mark_protocol_installed reality
    _save_protocol_creds reality "$(jq -n --arg u "$uuid" --argjson port "$port" \
        '{uuid: $u, port: $port}')"
    green "VLESS-Reality 已添加，端口：${port}（直连，不走 Argo）"
}

# =========================================================
# add_protocol_anytls：生成 AnyTLS inbound
# 优先 acme 真实证书；否则回退复用现有自签证书
# =========================================================
add_protocol_anytls() {
    if is_protocol_installed anytls; then
        yellow "AnyTLS 已安装，跳过"
        return 0
    fi

    local use_acme=false acme_domain
    if ensure_acme_config; then
        acme_domain=$(_read_cf_env_key CF_ACME_DOMAIN)
        # 同 TUIC：先申请证书，成功了再生成 inbound，避免证书问题拖垮整个服务
        if _acme_sh_issue_cert "$acme_domain"; then
            use_acme=true
        else
            yellow "acme 证书申请失败，回退使用自签证书"
        fi
    fi
    if ! $use_acme && { [ ! -f "${work_dir}/cert.pem" ] || [ ! -f "${work_dir}/private.key" ]; }; then
        red "未找到证书文件，请先安装 sing-box 主体（VLESS+Hysteria2）"
        return 1
    fi

    local port password
    if _ask_reuse_creds anytls "AnyTLS"; then
        local old_json
        old_json=$(_read_protocol_creds anytls)
        password=$(jq -r '.password' <<< "$old_json")
        port=$(jq -r '.port' <<< "$old_json")
        if ss -tlnH 2>/dev/null | awk '{print $5}' | grep -q ":${port}$"; then
            yellow "旧端口 ${port} 已被占用，自动分配新端口"
            port=$(pick_free_tcp_port) || { red "无法分配空闲 TCP 端口"; return 1; }
        fi
        green "已复用 AnyTLS 旧配置（密码不变，客户端链接可能仅端口变化）"
    else
        port=$(pick_free_tcp_port) || { red "无法分配空闲 TCP 端口"; return 1; }
        password=$(openssl rand -hex 16)
    fi

    local inbound
    if $use_acme; then
        inbound=$(jq -n \
            --argjson port "$port" \
            --arg pass "$password" \
            --arg domain "$acme_domain" \
            --arg cert "${work_dir}/acme/${acme_domain}/cert.pem" \
            --arg key  "${work_dir}/acme/${acme_domain}/key.pem" \
            '{
                type: "anytls",
                tag: "anytls",
                listen: "0.0.0.0",
                listen_port: $port,
                users: [{name: "user1", password: $pass}],
                tls: {
                    enabled: true,
                    server_name: $domain,
                    certificate_path: $cert,
                    key_path: $key
                }
            }')
    else
        inbound=$(jq -n \
            --argjson port "$port" \
            --arg pass "$password" \
            --arg cert "${work_dir}/cert.pem" \
            --arg key  "${work_dir}/private.key" \
            '{
                type: "anytls",
                tag: "anytls",
                listen: "0.0.0.0",
                listen_port: $port,
                users: [{name: "user1", password: $pass}],
                tls: {
                    enabled: true,
                    certificate_path: $cert,
                    key_path: $key
                }
            }')
    fi

    _add_inbound_json "$inbound" || { red "写入 AnyTLS 配置失败"; return 1; }
    allow_port "${port}/tcp"
    _mark_protocol_installed anytls
    _save_protocol_creds anytls "$(jq -n --arg p "$password" --argjson port "$port" \
        '{password: $p, port: $port}')"
    if $use_acme; then
        echo "anytls" >> "${work_dir}/protocols_acme.list"
        green "AnyTLS 已添加，端口：${port}（acme 证书：${acme_domain}）"
    else
        green "AnyTLS 已添加，端口：${port}（自签证书）"
    fi
}

# =========================================================
# remove_protocol：按 tag 精确删除单个备用协议
# =========================================================
remove_protocol() {
    local tag="$1"
    if ! is_protocol_installed "$tag"; then
        yellow "${EXTRA_PROTO_NAME[$tag]:-$tag} 未安装，无需删除"
        return 0
    fi

    local port proto acme_domain
    port=$(jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .listen_port' \
        "${conf_dir}/inbounds.json" 2>/dev/null)
    proto="${EXTRA_PROTO_TRANSPORT[$tag]:-tcp}"
    # 必须在删除 inbound 之前读取 server_name，删除后就查不到了
    acme_domain=$(jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .tls.server_name' \
        "${conf_dir}/inbounds.json" 2>/dev/null)

    _remove_inbound_json "$tag" || { red "删除 ${tag} 配置失败"; return 1; }

    if [ -n "$port" ] && [ "$port" != "null" ]; then
        remove_port "${port}/${proto}"
    fi

    _mark_protocol_removed "$tag"
    local _removed_acme_domain=""
    if [ -f "${work_dir}/protocols_acme.list" ] && grep -qxF "$tag" "${work_dir}/protocols_acme.list"; then
        _removed_acme_domain="$acme_domain"
        local _tmp
        _tmp=$(mktemp)
        if [ -n "$_tmp" ]; then
            grep -vxF "$tag" "${work_dir}/protocols_acme.list" > "$_tmp" 2>/dev/null
            mv "$_tmp" "${work_dir}/protocols_acme.list"
        fi
    fi

    # 若该域名不再被任何已装协议使用，清理对应的证书同步 cron 任务，避免残留垃圾任务
    if [ -n "$_removed_acme_domain" ] && [ "$_removed_acme_domain" != "null" ]; then
        if ! jq -e --arg d "$_removed_acme_domain" \
            '.inbounds[] | select(.tls.server_name == $d)' \
            "${conf_dir}/inbounds.json" >/dev/null 2>&1; then
            crontab -l 2>/dev/null | grep -vF "# sing-box-extra-protocols acme sync: ${_removed_acme_domain}" | crontab - 2>/dev/null
        fi
        # 若已没有任何协议在使用 acme，续期检查任务也一并清理
        if [ ! -s "${work_dir}/protocols_acme.list" ]; then
            crontab -l 2>/dev/null | grep -vF "# sing-box-extra-protocols acme renew-check" | crontab - 2>/dev/null
        fi
    fi

    green "${EXTRA_PROTO_NAME[$tag]:-$tag} 已删除（UUID/密码/端口配置已保留，重新添加时可选择复用）"
}

# =========================================================
# 选择菜单：安装时或单独调用，多选（空格分隔）
# =========================================================
select_extra_protocols() {
    clear; echo ""
    purple "=== 选择要添加的备用协议（可多选，直接连写数字，如 13 表示装 TUIC 和 AnyTLS，回车跳过）===\n"
    local i=1 tag
    for tag in "${EXTRA_PROTO_ORDER[@]}"; do
        if is_protocol_installed "$tag"; then
            green  "${i}. ${EXTRA_PROTO_NAME[$tag]}  [已安装]"
        else
            skyblue "${i}. ${EXTRA_PROTO_NAME[$tag]}"
        fi
        (( i++ ))
    done
    echo ""
    reading "请输入序号: " choices

    [ -z "$choices" ] && { purple "已跳过\n"; return 0; }

    # 协议数量固定为个位数，序号直接连写即可（如 "13"），仍兼容空格分隔（如 "1 3"）
    local compact="${choices// /}"
    local c idx j
    for (( j=0; j<${#compact}; j++ )); do
        c="${compact:$j:1}"
        if ! [[ "$c" =~ ^[0-9]$ ]]; then
            yellow "忽略无效输入：${c}"
            continue
        fi
        idx=$((c - 1))
        if [ "$idx" -lt 0 ] || [ "$idx" -ge "${#EXTRA_PROTO_ORDER[@]}" ]; then
            yellow "忽略无效序号：${c}"
            continue
        fi
        tag="${EXTRA_PROTO_ORDER[$idx]}"
        case "$tag" in
            tuic)    add_protocol_tuic ;;
            reality) add_protocol_reality ;;
            anytls)  add_protocol_anytls ;;
        esac
    done

    check_singbox &>/dev/null
    [ $? -ne 2 ] && restart_singbox
}

# =========================================================
# 管理菜单：查看 / 增加 / 删除
# =========================================================
manage_extra_protocols() {
    check_singbox &>/dev/null
    [ $? -eq 2 ] && { yellow "sing-box 尚未安装！"; sleep 1; return 0; }

    while true; do
        clear; echo ""
        purple "=== 备用协议管理（TUIC / Reality / AnyTLS）===\n"
        local i=1 tag any_installed=false
        for tag in "${EXTRA_PROTO_ORDER[@]}"; do
            if is_protocol_installed "$tag"; then
                green  "${i}. ${EXTRA_PROTO_NAME[$tag]}  [已安装]"
                any_installed=true
            else
                skyblue "${i}. ${EXTRA_PROTO_NAME[$tag]}  [未安装]"
            fi
            (( i++ ))
        done
        echo ""
        green  "a. 增加协议"
        $any_installed && red "d. 删除协议"
        local has_creds=false
        [ -d "${work_dir}/protocol_creds" ] && [ -n "$(ls -A "${work_dir}/protocol_creds" 2>/dev/null)" ] && has_creds=true
        $has_creds && yellow "c. 清除旧配置存档（清除后重新添加将不再提示复用）"
        purple "0. 返回主菜单"
        skyblue "------------"
        reading "请输入选择: " choice

        case "$choice" in
            a|A)
                select_extra_protocols
                get_info
                ;;
            d|D)
                if ! $any_installed; then
                    yellow "当前没有已安装的备用协议"; sleep 1; continue
                fi
                reading "请输入要删除的序号（直接连写数字，如 13，回车取消）: " del_choices
                [ -z "$del_choices" ] && continue
                # 协议数量固定为个位数，序号直接连写即可，仍兼容空格分隔
                local del_compact="${del_choices// /}"
                local c idx dtag j
                for (( j=0; j<${#del_compact}; j++ )); do
                    c="${del_compact:$j:1}"
                    [[ "$c" =~ ^[0-9]$ ]] || continue
                    idx=$((c - 1))
                    [ "$idx" -lt 0 ] || [ "$idx" -ge "${#EXTRA_PROTO_ORDER[@]}" ] && continue
                    dtag="${EXTRA_PROTO_ORDER[$idx]}"
                    remove_protocol "$dtag"
                done
                if restart_singbox; then
                    get_info
                else
                    red "\n协议已删除，但 sing-box 重启失败，请检查：journalctl -u sing-box -n 50 --no-pager\n"
                fi
                ;;
            c|C)
                if ! $has_creds; then
                    yellow "当前没有可清除的存档"; sleep 1; continue
                fi
                reading "确定清除所有旧配置存档？此操作不可恢复 (y/N): " confirm_clear
                if [[ "$confirm_clear" =~ ^[yY]$ ]]; then
                    rm -rf "${work_dir}/protocol_creds"
                    green "存档已清除"
                fi
                sleep 1
                ;;
            0) return 1 ;;
            *) red "无效选项"; sleep 1 ;;
        esac
    done
}

# =========================================================
# 生成订阅链接：追加进 client_dir（由 get_info 调用）
# =========================================================
_protocol_uses_acme() {
    [ -f "${work_dir}/protocols_acme.list" ] && grep -qxF "$1" "${work_dir}/protocols_acme.list" 2>/dev/null
}

append_extra_protocol_links() {
    [ ! -f "${conf_dir}/inbounds.json" ] && return 0

    local server_ip="$1"
    local node_prefix="$2"
    local ip_links="" domain_links=""

    if is_protocol_installed tuic; then
        local port uuid pass sni
        port=$(jq -r '.inbounds[] | select(.tag=="tuic") | .listen_port' "${conf_dir}/inbounds.json")
        uuid=$(jq -r '.inbounds[] | select(.tag=="tuic") | .users[0].uuid' "${conf_dir}/inbounds.json")
        pass=$(jq -r '.inbounds[] | select(.tag=="tuic") | .users[0].password' "${conf_dir}/inbounds.json")
        if _protocol_uses_acme tuic; then
            sni=$(jq -r '.inbounds[] | select(.tag=="tuic") | .tls.server_name' "${conf_dir}/inbounds.json")
            # acme 真实证书，标准 TLS 验证。显式写 insecure=0（而非省略该字段），
            # 避免依赖客户端在字段缺省时的隐含默认行为（勇哥/fscarmen 脚本同样显式写 0，已验证更可靠）。
            ip_links+=$'\n'"tuic://${uuid}:${pass}@${server_ip}:${port}?sni=${sni}&alpn=h3&congestion_control=bbr&insecure=0&allowInsecure=0&allow_insecure=0#${node_prefix} tuic-ip"
            domain_links+=$'\n'"tuic://${uuid}:${pass}@${sni}:${port}?sni=${sni}&alpn=h3&congestion_control=bbr&insecure=0&allowInsecure=0&allow_insecure=0#${node_prefix} tuic-domain"
        else
            # 实测：pinSHA256 在 Egern / v2rayN 的 TUIC 解析器里均不生效（2026-08 验证）。
            # 自签证书场景下必须显式 insecure=1，三个字段名同写以兼容不同客户端。
            # 如需指纹校验，请导入后在客户端内手动填写证书指纹并关闭"跳过验证"，
            # 指纹可通过菜单"5. 刷新节点信息"输出中查看，与 hy2/anytls 共用同一张证书。
            ip_links+=$'\n'"tuic://${uuid}:${pass}@${server_ip}:${port}?sni=bing.com&alpn=h3&congestion_control=bbr&insecure=1&allowInsecure=1&allow_insecure=1#${node_prefix} tuic"
        fi
    fi

    if is_protocol_installed reality; then
        local port uuid pub sid sni
        port=$(jq -r '.inbounds[] | select(.tag=="reality") | .listen_port' "${conf_dir}/inbounds.json")
        uuid=$(jq -r '.inbounds[] | select(.tag=="reality") | .users[0].uuid' "${conf_dir}/inbounds.json")
        sni=$(jq -r '.inbounds[] | select(.tag=="reality") | .tls.server_name' "${conf_dir}/inbounds.json")
        pub=$(_reality_public_key)
        sid=$(_reality_short_id)
        # Reality 走伪装握手，本身不依赖真实域名解析，始终只用 IP 直连
        ip_links+=$'\n'"vless://${uuid}@${server_ip}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${pub}&sid=${sid}&type=tcp&headerType=none#${node_prefix} reality"
    fi

    if is_protocol_installed anytls; then
        local port pass sni
        port=$(jq -r '.inbounds[] | select(.tag=="anytls") | .listen_port' "${conf_dir}/inbounds.json")
        pass=$(jq -r '.inbounds[] | select(.tag=="anytls") | .users[0].password' "${conf_dir}/inbounds.json")
        if _protocol_uses_acme anytls; then
            sni=$(jq -r '.inbounds[] | select(.tag=="anytls") | .tls.server_name' "${conf_dir}/inbounds.json")
            # acme 真实证书，标准 TLS 验证。显式写 insecure=0，避免依赖客户端缺省行为
            # （实测 Egern 在 anytls:// 链接缺省 insecure 字段时，界面会显示"跳过验证=开"，
            # 显式写 0 后应能纠正该显示状态，参考勇哥脚本同款写法）。
            ip_links+=$'\n'"anytls://${pass}@${server_ip}:${port}?sni=${sni}&insecure=0&allowInsecure=0#${node_prefix} anytls-ip"
            domain_links+=$'\n'"anytls://${pass}@${sni}:${port}?sni=${sni}&insecure=0&allowInsecure=0#${node_prefix} anytls-domain"
        else
            # 实测：pinSHA256/hpkp/pcs 等指纹字段在 Egern / v2rayN 的 AnyTLS 解析器里均不生效（2026-08 验证）。
            # 自签证书场景下必须显式 insecure=1，两个字段名同写以兼容不同客户端。
            # 如需指纹校验，请导入后在客户端内手动填写证书指纹并关闭"跳过验证"，
            # 指纹可通过菜单"5. 刷新节点信息"输出中查看，与 hy2/tuic 共用同一张证书。
            ip_links+=$'\n'"anytls://${pass}@${server_ip}:${port}?sni=bing.com&insecure=1&allowInsecure=1#${node_prefix} anytls"
        fi
    fi

    if [ -n "$ip_links" ]; then
        {
            echo ""
            echo "───── IP 直连（推荐，不依赖 DNS）─────"
            echo "$ip_links"
        } >> "${client_dir}"
    fi

    if [ -n "$domain_links" ]; then
        {
            echo ""
            echo "───── 域名连接（IP 变更后仅需改 DNS，无需重发链接）─────"
            echo "$domain_links"
        } >> "${client_dir}"
    fi
}

# ── 升级 sing-box ─────────────────────────────────
upgrade_singbox() {
    check_singbox &>/dev/null
    [ $? -eq 2 ] && { yellow "sing-box 尚未安装！"; sleep 1; return 1; }

    local arch_raw arch
    arch_raw=$(uname -m)
    case "$arch_raw" in
        x86_64|amd64)  arch='amd64' ;;
        aarch64|arm64) arch='arm64' ;;
        *) red "不支持的架构: ${arch_raw}"; return 0 ;;
    esac

    local current_ver
    current_ver=$("${work_dir}/sing-box" version 2>/dev/null \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    yellow "当前版本: ${current_ver:-未知}"

    yellow "正在查询最新版本…"
    local latest_ver
    latest_ver=$(get_latest_sb_version)
    if [ -z "$latest_ver" ]; then
        yellow "无法获取最新版本，将使用脚本内置版本 ${SB_VERSION}"
        latest_ver="$SB_VERSION"
    else
        green "最新版本: ${latest_ver}"
    fi

    if [ "$current_ver" = "$latest_ver" ]; then
        green "已是最新版 ${latest_ver}，无需升级\n"
        return 1
    fi

    reading "确认升级到 v${latest_ver}？(y/n): " confirm
    [[ "$confirm" != [yY] ]] && { purple "已取消\n"; return 1; }

    local tmp_dest
    tmp_dest=$(mktemp)
    if ! download_singbox "$arch" "$latest_ver" "$tmp_dest"; then
        red "下载失败，请检查网络"
        return 0
    fi

    stop_singbox

    cp "${work_dir}/sing-box" "${work_dir}/sing-box.bak"

    if mv "$tmp_dest" "${work_dir}/sing-box" && \
       chmod +x "${work_dir}/sing-box" && \
       chown root:root "${work_dir}/sing-box" && \
       "${work_dir}/sing-box" version &>/dev/null; then
        if start_singbox; then
            rm -f "${work_dir}/sing-box.bak"
            green "\nsing-box 已升级至 v${latest_ver}\n"
            "${work_dir}/sing-box" version
        else
            red "\n新版本二进制已就位，但服务启动失败，正在自动回滚到升级前版本…"
            mv "${work_dir}/sing-box.bak" "${work_dir}/sing-box"
            if start_singbox; then
                red "已自动回滚到旧版本，新版本可能与当前配置不兼容，请检查：journalctl -u sing-box -n 50 --no-pager\n"
            else
                red "回滚后服务仍无法启动，请检查：journalctl -u sing-box -n 50 --no-pager\n"
            fi
        fi
    else
        red "升级失败，正在回滚…"
        mv "${work_dir}/sing-box.bak" "${work_dir}/sing-box"
        if start_singbox; then
            red "已回滚到旧版本，请检查网络或稍后重试\n"
        else
            red "回滚后服务仍无法启动，请检查：journalctl -u sing-box -n 50 --no-pager\n"
        fi
    fi
    return 0
}

# ── 配置固定 Argo 隧道 ────────────────────────────
configure_fixed_tunnel() {
    clear
    yellow "\n固定隧道支持 JSON 凭据或 Token 两种方式"
    yellow "JSON 获取：https://fscarmen.cloudflare.now.cc\n"

    local argo_domain argo_auth
    reading "\n请输入 Argo 域名: " argo_domain
    [ -z "$argo_domain" ] && { red "域名不能为空"; return 0; }

    if ! [[ "$argo_domain" =~ ^[A-Za-z0-9._-]+\.[A-Za-z]{2,}$ ]]; then
        red "域名格式不合法"; return 0
    fi

    reading "\n请输入 Argo 密钥（Token 或 JSON）: " argo_auth
    [ -z "$argo_auth" ] && { red "密钥不能为空"; return 0; }

    local current_argo_port
    current_argo_port=$(jq -r '.inbounds[] | select(.tag=="vless-ws") | .listen_port' "${conf_dir}/inbounds.json" 2>/dev/null)
    [[ "$current_argo_port" =~ ^[0-9]+$ ]] || current_argo_port="${ARGO_PORT}"
    yellow "当前 VLESS 端口: ${current_argo_port}\n"

    if [[ "$argo_auth" =~ TunnelSecret ]]; then
        echo "$argo_auth" > "${work_dir}/tunnel.json"
        chmod 600 "${work_dir}/tunnel.json"
        local tunnel_id
        tunnel_id=$(echo "$argo_auth" \
            | jq -r '(.TunnelID // .tunnelID // .tunnel_id) // empty' 2>/dev/null)

        [ -z "$tunnel_id" ] && { red "无法解析 TunnelID，请检查 JSON 格式"; return 0; }

        cat > "${work_dir}/tunnel.yml" << EOF
tunnel: ${tunnel_id}
credentials-file: ${work_dir}/tunnel.json
protocol: http2

ingress:
  - hostname: ${argo_domain}
    service: http://localhost:${current_argo_port}
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF

        cat > /etc/systemd/system/argo.service << EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
Type=simple
NoNewPrivileges=yes
TimeoutStartSec=0
ExecStart=/etc/sing-box/argo tunnel --edge-ip-version auto --config ${work_dir}/tunnel.yml run
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    elif [[ "$argo_auth" =~ ^[A-Za-z0-9+/=._-]{100,500}$ ]]; then
        printf '# token mode\nhostname: %s\n' "$argo_domain" > "${work_dir}/tunnel.yml"
        echo "$argo_auth" > "${work_dir}/argo_token"
        chmod 600 "${work_dir}/argo_token"
        cat > /etc/systemd/system/argo.service << EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
Type=simple
NoNewPrivileges=yes
TimeoutStartSec=0
ExecStart=/etc/sing-box/argo tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token ${argo_auth}
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
    else
        red "密钥格式不匹配（请确认是 JSON 凭据或有效 Token）"; return 0
    fi

    systemctl daemon-reload
    if restart_argo; then
        sleep 2
        get_info
        green "\n固定隧道配置完成，域名：${argo_domain}\n"
    else
        red "\n隧道配置已写入，但 argo 服务重启失败，节点当前不可用"
        red "请检查：journalctl -u argo -n 50 --no-pager\n"
    fi
    return 0
}

# ── Argo 管理菜单 ─────────────────────────────────
manage_argo() {
    local argo_status
    argo_status=$(check_argo 2>&1)
    clear; echo ""
    green "=== Argo 隧道管理 === 状态: ${argo_status}\n"
    is_fixed_tunnel_configured && green "当前域名: $(get_fixed_domain)\n" || yellow "固定隧道尚未配置\n"
    green  "1. 启动 Argo"
    green  "2. 停止 Argo"
    green  "3. 重启 Argo"
    green  "4. 配置固定隧道"
    purple "0. 返回主菜单"
    skyblue "————"
    reading "\n请输入选择: " choice
    case "$choice" in
        1) start_argo;   return 0 ;;
        2) stop_argo;    return 0 ;;
        3) restart_argo; return 0 ;;
        4) configure_fixed_tunnel ;;
        0) return 1 ;;
        *) red "无效选项！"; return 0 ;;
    esac
}

# ── sing-box 管理菜单 ─────────────────────────────
manage_singbox() {
    local sb_status
    while true; do
        sb_status=$(check_singbox 2>&1)
        clear; echo ""
        green "=== sing-box 管理 === 状态: ${sb_status}\n"
        green  "1. 启动 sing-box"
        green  "2. 停止 sing-box"
        green  "3. 重启 sing-box"
        purple "0. 返回主菜单"
        skyblue "————"
        reading "\n请输入选择: " choice
        case "$choice" in
            1) start_singbox ;;
            2) stop_singbox ;;
            3) restart_singbox ;;
            0) return ;;
            *) red "无效选项！"; sleep 1 ;;
        esac
    done
}

# ── 卸载核心逻辑（共享） ──────────────────────────
_do_uninstall_core() {
    local keep_config="${1:-false}"
    BACKUP_SUCCESS=false

    if [ "$keep_config" = true ]; then
        yellow "正在备份节点配置以便重装时恢复…"
        mkdir -p "$backup_dir"
        chmod 700 "$backup_dir"
        rm -f "${backup_dir}"/* 2>/dev/null

        [ -f "${conf_dir}/inbounds.json" ]  && cp "${conf_dir}/inbounds.json"  "${backup_dir}/inbounds.json"
        [ -f "${work_dir}/cert.pem" ]        && cp "${work_dir}/cert.pem"        "${backup_dir}/cert.pem"
        [ -f "${work_dir}/private.key" ]     && cp "${work_dir}/private.key"     "${backup_dir}/private.key"
        [ -f "${work_dir}/tunnel.yml" ]      && cp "${work_dir}/tunnel.yml"      "${backup_dir}/tunnel.yml"
        [ -f "${work_dir}/tunnel.json" ]     && cp "${work_dir}/tunnel.json"     "${backup_dir}/tunnel.json"
        [ -f "${work_dir}/cf.env" ]          && cp "${work_dir}/cf.env"          "${backup_dir}/cf.env"
        [ -f "${work_dir}/argo_token" ]      && cp "${work_dir}/argo_token"      "${backup_dir}/argo_token"
        [ -f "${work_dir}/protocols.list" ]  && cp "${work_dir}/protocols.list"  "${backup_dir}/protocols.list"
        [ -f "${work_dir}/protocols_acme.list" ] && cp "${work_dir}/protocols_acme.list" "${backup_dir}/protocols_acme.list"
        [ -d "${work_dir}/acme" ]      && cp -r "${work_dir}/acme"      "${backup_dir}/acme"
        [ -d "${work_dir}/.acme.sh" ]  && cp -r "${work_dir}/.acme.sh"  "${backup_dir}/.acme.sh"
        [ -f "${work_dir}/reality.key" ]     && cp "${work_dir}/reality.key"     "${backup_dir}/reality.key"
        [ -f "${work_dir}/reality.shortid" ] && cp "${work_dir}/reality.shortid" "${backup_dir}/reality.shortid"
        [ -d "${work_dir}/protocol_creds" ]  && cp -r "${work_dir}/protocol_creds" "${backup_dir}/protocol_creds"
        chmod -R go-rwx "$backup_dir" 2>/dev/null

        if [ -s "${backup_dir}/inbounds.json" ] && [ -s "${backup_dir}/cert.pem" ]; then
            green "节点配置与证书已备份至 ${backup_dir}，重装时将自动检测并询问是否恢复"
            BACKUP_SUCCESS=true
        else
            red "备份失败（inbounds.json 或 cert.pem 缺失），将按未保留配置继续卸载"
            rm -rf "$backup_dir" 2>/dev/null
        fi
    else
        rm -rf "$backup_dir" 2>/dev/null
        # 彻底卸载（不保留配置）时才清理 acme 相关的 cron 任务（续期检查 + 证书同步）；
        # 保留配置场景下这些任务在重装恢复后仍需继续运行，不能清
        crontab -l 2>/dev/null | grep -v "# sing-box-extra-protocols acme" | crontab - 2>/dev/null
    fi

    systemctl stop    sing-box argo 2>/dev/null
    systemctl disable sing-box argo 2>/dev/null
    systemctl daemon-reload
    rm -f /etc/systemd/system/sing-box.service /etc/systemd/system/argo.service

    local hy2_port
    hy2_port=$(jq -r '.inbounds[] | select(.type=="hysteria2") | .listen_port' \
        "${conf_dir}/inbounds.json" 2>/dev/null)
    if [ -n "$hy2_port" ] && [ "$hy2_port" != "null" ]; then
        remove_port "${hy2_port}/udp"
    else
        yellow "警告：无法读取 Hy2 端口，防火墙规则可能未清理，请手动检查 iptables\n"
    fi

    # 清理备用协议（TUIC / Reality / AnyTLS）占用的端口
    if [ -f "${work_dir}/protocols.list" ]; then
        local _ep_tag _ep_port _ep_proto
        while IFS= read -r _ep_tag; do
            [ -z "$_ep_tag" ] && continue
            _ep_port=$(jq -r --arg t "$_ep_tag" '.inbounds[] | select(.tag == $t) | .listen_port' \
                "${conf_dir}/inbounds.json" 2>/dev/null)
            case "$_ep_tag" in
                tuic) _ep_proto="udp" ;;
                *)    _ep_proto="tcp" ;;
            esac
            if [ -n "$_ep_port" ] && [ "$_ep_port" != "null" ]; then
                remove_port "${_ep_port}/${_ep_proto}"
            fi
        done < "${work_dir}/protocols.list"
    fi

    rm -rf "${work_dir}"
    [ -L /usr/bin/sb ] && rm -f /usr/bin/sb
}

# ── 卸载（交互） ──────────────────────────────────
uninstall_singbox() {
    reading "确定要卸载 sing-box 吗? (y/n): " choice
    [[ "$choice" != [yY] ]] && { purple "已取消卸载\n"; return; }

    reading "是否保留节点配置与证书（UUID/端口/隧道/pinSHA256）以便重装时恢复？(y/n，回车默认 y): " keep_choice
    local keep_config=false
    [[ -z "$keep_choice" || "$keep_choice" == [yY] ]] && keep_config=true

    yellow "正在卸载…"
    _do_uninstall_core "$keep_config"

    if $keep_config && [ "${BACKUP_SUCCESS:-false}" = true ]; then
        green "\nsing-box 卸载完成，节点配置与证书已保留，下次安装时可选择恢复\n"
    else
        green "\nsing-box 卸载完成\n"
    fi
    exit 0
}

# ── 快捷指令 ──────────────────────────────────────
create_shortcut() {
    cat > "${work_dir}/sb.sh" << EOF
#!/usr/bin/env bash
bash <(curl -fsSL ${SCRIPT_URL}) \$1
EOF
    chmod +x "${work_dir}/sb.sh"
    ln -sf "${work_dir}/sb.sh" /usr/bin/sb
    [ -s /usr/bin/sb ] && green "\n快捷指令 sb 创建成功\n" || red "\n快捷指令创建失败\n"
}

# ── 更新脚本 ──────────────────────────────────────
update_script() {
    yellow "正在从 GitHub 拉取最新脚本…\n"
    local tmp
    tmp=$(mktemp)
    curl -fsSL "$SCRIPT_URL" -o "$tmp"
    if [ -s "$tmp" ] && grep -q 'install_singbox' "$tmp"; then
        mv "$tmp" "${work_dir}/sb.sh"
        chmod +x "${work_dir}/sb.sh"
        ln -sf "${work_dir}/sb.sh" /usr/bin/sb
        green "脚本已更新，请重新运行 sb\n"
        exit 0
    else
        rm -f "$tmp"
        red "更新失败：下载内容异常，已回滚\n"
    fi
}

# ── 主菜单 ────────────────────────────────────────
# ── SSH 防护管理 ──────────────────────────────────
manage_fail2ban() {
    clear; echo ""
    green "=== SSH 防护 (fail2ban) ===\n"

    if ! command_exists fail2ban-client; then
        yellow "fail2ban 未安装"
        green  "1. 安装并启用 SSH 防护"
        purple "0. 返回主菜单"
        skyblue "————"
        reading "\n请输入选择: " choice
        case "$choice" in
            1)
                install_packages fail2ban || { red "安装失败"; return 0; }

                local ssh_port
                ssh_port=$(ss -tlnpH 2>/dev/null | awk '/sshd/{print $4}' | grep -oE '[0-9]+$' | head -1)
                [ -z "$ssh_port" ] && ssh_port=$(grep -E '^Port ' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1)
                [ -z "$ssh_port" ] && ssh_port=22

                cat > /etc/fail2ban/jail.local << EOF
[sshd]
enabled  = true
port     = ${ssh_port}
backend  = systemd
maxretry = 5
bantime  = 3600
findtime = 600
EOF
                systemctl enable fail2ban
                systemctl restart fail2ban
                if systemctl is-active fail2ban &>/dev/null; then
                    green "\nfail2ban 已启用，正在保护 SSH 端口 ${ssh_port}\n"
                else
                    red "\nfail2ban 启动失败，请检查日志: journalctl -u fail2ban\n"
                fi
                return 0
                ;;
            0) return 1 ;;
            *) red "无效选项"; return 0 ;;
        esac
    fi

    local f2b_status
    if systemctl is-active fail2ban &>/dev/null; then
        f2b_status="running"
    else
        f2b_status="not running"
    fi

    local banned_count
    banned_count=$(fail2ban-client status sshd 2>/dev/null \
        | grep "Currently banned" | grep -oE '[0-9]+$')
    [ -z "$banned_count" ] && banned_count=0

    green "状态: ${f2b_status}    当前封禁数: ${banned_count}\n"
    green  "1. 启动 fail2ban"
    green  "2. 停止 fail2ban"
    green  "3. 重启 fail2ban"
    green  "4. 查看被封禁 IP 列表"
    green  "5. 解封指定 IP"
    red    "6. 卸载 fail2ban"
    purple "0. 返回主菜单"
    skyblue "————"
    reading "\n请输入选择: " choice
    case "$choice" in
        1) systemctl start fail2ban   && green "已启动"; return 0 ;;
        2) systemctl stop fail2ban    && green "已停止"; return 0 ;;
        3) systemctl restart fail2ban && green "已重启"; return 0 ;;
        4)
            echo ""
            fail2ban-client status sshd 2>/dev/null || yellow "暂无数据"
            return 0
            ;;
        5)
            reading "请输入要解封的 IP: " unban_ip
            [ -z "$unban_ip" ] && { red "IP 不能为空"; return 0; }
            fail2ban-client set sshd unbanip "$unban_ip" \
                && green "已解封 ${unban_ip}" \
                || red "解封失败，请确认该 IP 是否在封禁列表中"
            return 0
            ;;
        6)
            reading "确定要卸载 fail2ban 吗? (y/n): " confirm
            if [[ "$confirm" == [yY] ]]; then
                systemctl stop fail2ban 2>/dev/null
                systemctl disable fail2ban 2>/dev/null
                apt-get remove -y fail2ban 2>/dev/null
                green "fail2ban 已卸载"
                return 0
            else
                purple "已取消"
                return 1
            fi
            ;;
        0) return 1 ;;
        *) red "无效选项"; return 0 ;;
    esac
}

# ── BBR 网络调优管理 ──────────────────────────────────
BBR_CONF="/etc/sysctl.d/99-wot-proxy-tuning.conf"
BBR_KEYWORDS='tcp_|rmem|wmem|conntrack|congestion_control|qdisc'

bbr_get_status() {
    local cc qdisc
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    if [ -f "$BBR_CONF" ]; then
        echo "本脚本调优: 已启用 (${cc} + ${qdisc})"
    elif [ "$cc" = "bbr" ]; then
        echo "本脚本调优: 未启用，但检测到其他来源已开启 BBR (${cc} + ${qdisc})"
    else
        echo "本脚本调优: 未启用 (当前: ${cc} + ${qdisc})"
    fi
}

# 按机器物理内存返回 rmem/wmem 缓冲区上限的安全封顶值（字节）。
# 用于给 BDP 公式算出的值兜底，避免小内存机器被算出的大缓冲值占满内存。
bbr_mem_buffer_cap() {
    local mem_kb mem_mb
    mem_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null)
    mem_mb=$(( ${mem_kb:-1048576} / 1024 ))
    if [ "$mem_mb" -lt 512 ]; then
        echo $((8 * 1024 * 1024))
    elif [ "$mem_mb" -lt 1024 ]; then
        echo $((16 * 1024 * 1024))
    elif [ "$mem_mb" -lt 2048 ]; then
        echo $((32 * 1024 * 1024))
    elif [ "$mem_mb" -lt 4096 ]; then
        echo $((64 * 1024 * 1024))
    else
        echo $((128 * 1024 * 1024))
    fi
}

bbr_write_conf() {
    # $1 = rmem/wmem 上限字节数, $2 = 场景描述文字, $3 = RTT毫秒（可选，用于 notsent_lowat 分档，默认150）
    local buf="$1" desc="$2" rtt="${3:-150}" notsent_lowat
    if [ "$rtt" -ge 120 ]; then
        notsent_lowat=16384
    else
        notsent_lowat=32768
    fi
    cat > "$BBR_CONF" << EOF
# 由 sing-box.sh 网络调优模块生成
# 场景: ${desc}
# 生成时间: $(date)

# ── 拥塞控制 ──
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# ── 缓冲区 (随场景变化) ──
net.core.rmem_max = ${buf}
net.core.wmem_max = ${buf}
net.ipv4.tcp_rmem = 4096 87380 ${buf}
net.ipv4.tcp_wmem = 4096 65536 ${buf}

# ── 连接队列 ──
net.core.netdev_max_backlog = 8192
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 4096

# ── TCP 连接优化 ──
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_retries2 = 15
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0

# ── 以下参数按 RTT 分档（≥120ms 用 16384，否则 32768） ──
net.ipv4.tcp_notsent_lowat = ${notsent_lowat}

# ── 以下为固定参数，与硬件规格/场景无关，任何机器统一使用 ──
net.ipv4.tcp_autocorking = 0
net.ipv4.tcp_no_metrics_save = 0
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_orphan_retries = 3
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_max_tw_buckets = 6000
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
EOF
    sysctl --system >/dev/null 2>&1
    local cc qdisc rmem
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    rmem=$(sysctl -n net.core.rmem_max 2>/dev/null)
    if [ "$cc" = "bbr" ] && [ "$qdisc" = "fq" ] && [ "$rmem" = "$buf" ]; then
        green "\n已应用「${desc}」\n拥塞控制: ${cc}    队列: ${qdisc}    缓冲区上限: ${rmem}    notsent_lowat: ${notsent_lowat}\n"
    else
        red "\n配置已写入，但验证异常 (拥塞控制=${cc}, 队列=${qdisc}, 缓冲区=${rmem}，期望值=${buf})\n请检查是否有其他文件覆盖了此设置（可用「扫描冲突配置」查看）\n"
    fi
    return 0
}

bbr_apply_menu() {
    clear; echo ""
    green "=== 选择调优场景 ===\n"
    green  "1. 日常场景      缓冲区 8MB  | 不追求跑满带宽，网页/聊天/一般视频够用"
    green  "2. 大文件/下载   缓冲区 32MB | 追求单连接吞吐，适合美国等高延迟节点"
    green  "3. 低延迟场景    缓冲区 4MB  | 韩国/日本等低延迟节点，游戏/实时性优先"
    green  "4. 自定义带宽    输入 Mbps，按 BDP 公式现算"
    purple "0. 返回上一级"
    skyblue "————"
    reading "\n请输入选择: " choice
    case "$choice" in
        1) bbr_write_conf 8388608 "日常场景 (8MB)" 150 ;;
        2) bbr_write_conf 33554432 "大文件/下载场景 (32MB)" 200 ;;
        3) bbr_write_conf 4194304 "低延迟场景 (4MB)" 50 ;;
        4)
            reading "请输入带宽 (Mbps): " bw
            if ! [[ "$bw" =~ ^[0-9]+$ ]] || [ "$bw" -eq 0 ]; then
                red "输入无效，请输入正整数"
                return 0
            fi
            reading "请输入预估RTT毫秒 (不清楚直接回车，默认150ms): " rtt
            [ -z "$rtt" ] && rtt=150
            if ! [[ "$rtt" =~ ^[0-9]+$ ]] || [ "$rtt" -eq 0 ]; then
                red "RTT 输入无效，请输入正整数"
                return 0
            fi
            local bw_bps bdp_bytes buf_bytes mem_cap
            bw_bps=$((bw * 1000000))
            bdp_bytes=$((bw_bps * rtt / 1000 / 8))
            buf_bytes=$((bdp_bytes * 2))
            [ "$buf_bytes" -lt 4194304 ] && buf_bytes=4194304
            # 先按硬性上限 128MB 截断，再用机器内存做安全封顶（小内存机器封顶更低，
            # 防止 BDP 公式在小内存实例上算出过大的值而挤占可用内存）。
            [ "$buf_bytes" -gt 134217728 ] && buf_bytes=134217728
            mem_cap=$(bbr_mem_buffer_cap)
            if [ "$buf_bytes" -gt "$mem_cap" ]; then
                yellow "\n按 BDP 公式算出的缓冲区超过本机内存安全上限，已从 $((buf_bytes / 1024 / 1024))MB 封顶至 $((mem_cap / 1024 / 1024))MB\n"
                buf_bytes="$mem_cap"
            fi
            yellow "\nBDP ≈ $((bdp_bytes / 1024 / 1024))MB，取2倍余量，最终缓冲区上限 = $((buf_bytes / 1024 / 1024))MB\n"
            bbr_write_conf "$buf_bytes" "自定义 (${bw}Mbps / ${rtt}ms RTT)" "$rtt"
            ;;
        0) return 1 ;;
        *) red "无效选项"; return 0 ;;
    esac
}

bbr_disable() {
    if [ ! -f "$BBR_CONF" ]; then
        yellow "\n未检测到本脚本生成的调优配置，无需关闭\n"
        return 0
    fi
    reading "确定要关闭本脚本的调优配置吗? 将恢复系统默认值 (y/n): " confirm
    if [[ "$confirm" == [yY] ]]; then
        local ts
        ts=$(date +%Y%m%d%H%M%S)
        mv "$BBR_CONF" "${BBR_CONF}.bak.${ts}"
        sysctl --system >/dev/null 2>&1
        green "\n已关闭，配置已备份为 ${BBR_CONF}.bak.${ts}\n"
    else
        purple "已取消"
    fi
    return 0
}

bbr_scan() {
    clear; echo ""
    green "=== 扫描现有配置中的网络调优相关设置 ===\n"
    yellow "(只读，不会做任何修改)\n"

    local files
    files=$(grep -rlE "$BBR_KEYWORDS" /etc/sysctl.d/ /etc/sysctl.conf /usr/lib/sysctl.d/ 2>/dev/null)
    if [ -z "$files" ]; then
        yellow "未发现相关配置文件。"
        return 0
    fi

    local idx=0
    declare -gA BBR_SCAN_FILES=()
    for f in $files; do
        idx=$((idx + 1))
        BBR_SCAN_FILES[$idx]="$f"
        if [ "$f" = "$BBR_CONF" ]; then
            skyblue "[${idx}] ${f}  ← 本脚本生成的配置（用「关闭调优」处理，不在此清理）"
        else
            purple "[${idx}] ${f}"
        fi
        grep -nE "$BBR_KEYWORDS" "$f" 2>/dev/null | grep -v '^\s*#' | sed 's/^/      /'
        echo ""
    done

    echo "===== 重复参数检测 ====="
    local dups
    dups=$(grep -rhE '^net\.|^kernel\.|^vm\.|^fs\.' /etc/sysctl.d/*.conf /etc/sysctl.conf /usr/lib/sysctl.d/*.conf 2>/dev/null \
        | sed 's/=.*//' | sed 's/ *$//' | sort | uniq -d)
    if [ -z "$dups" ]; then
        green "未发现重复设置的参数。"
    else
        while read -r dup; do
            [ -z "$dup" ] && continue
            yellow "⚠ 参数 '${dup}' 在多个文件中重复设置，最终生效值以 sysctl --system 加载顺序中最后一次为准："
            grep -rnE "^${dup}\s*=" /etc/sysctl.d/*.conf /etc/sysctl.conf /usr/lib/sysctl.d/*.conf 2>/dev/null | sed 's/^/      /'
            echo ""
        done <<< "$dups"
    fi
    green "\n扫描完成。如需清理，请使用菜单中的「清理冲突配置」选项。\n"
    return 0
}

bbr_clean() {
    bbr_scan
    if [ -z "${BBR_SCAN_FILES[*]}" ]; then
        return 0
    fi

    echo ""
    yellow "重要提示：以上文件里可能混有 BBR 之外的其他配置（安全加固、IPv6、端口范围等），"
    yellow "本功能不会整份删除文件，只会帮你注释掉扫描到的冲突网络参数那一行，其余内容保持不变。\n"

    reading "请输入要处理的编号 (空格分隔，如 \"1 2\"，或输入 0 取消): " nums
    [ -z "$nums" ] || [ "$nums" = "0" ] && { purple "已取消"; return 0; }

    for n in $nums; do
        local target="${BBR_SCAN_FILES[$n]}"
        if [ -z "$target" ]; then
            red "编号 ${n} 无效，跳过"
            continue
        fi
        if [ "$target" = "$BBR_CONF" ]; then
            yellow "编号 ${n} 是本脚本自己的配置，跳过（请用「关闭调优」处理）"
            continue
        fi
        if [[ "$target" == *.bak ]]; then
            yellow "${target} 是 .bak 文件，不会被 sysctl 加载，无实际影响，跳过"
            continue
        fi

        local backup="${target}.bak.$(date +%Y%m%d%H%M%S)"
        cp "$target" "$backup"
        # 只注释掉涉及BBR/网络调优关键字的行（关键字可能出现在行中任意位置，如 net.core.rmem_max），
        # 已经是注释的行跳过，其余内容原样保留
        sed -i -E "/^[[:space:]]*#/! s/^(.*(${BBR_KEYWORDS}).*)$/# [由sing-box.sh注释] \1/" "$target"
        green "已处理 ${target}（已备份至 ${backup}，仅注释相关行，未删除文件）"
    done

    sysctl --system >/dev/null 2>&1
    echo ""
    green "===== 处理后验证 ====="
    sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc net.core.rmem_max 2>/dev/null
    yellow "\n如发现异常，可用对应的 .bak.时间戳 文件手动恢复。\n"
    return 0
}
# ── DNS 管理 ──────────────────────────────────
dns_get_mode() {
    local target
    target=$(readlink -f /etc/resolv.conf 2>/dev/null)
    if [[ "$target" == *"systemd/resolve"* ]]; then
        echo "systemd-resolved"
    else
        echo "static"
    fi
}

dns_get_status() {
    local mode="$1"
    if [ "$mode" = "systemd-resolved" ]; then
        resolvectl status 2>/dev/null | grep -A2 "Current DNS Server\|DNS Servers" | head -6
    else
        grep "^nameserver" /etc/resolv.conf 2>/dev/null
    fi
}

dns_apply() {
    # $1 = 主DNS, $2 = 备用DNS
    local dns1="$1" dns2="$2"
    local mode
    mode=$(dns_get_mode)

    if [ "$mode" = "systemd-resolved" ]; then
        [ -f /etc/systemd/resolved.conf ] && cp /etc/systemd/resolved.conf "/etc/systemd/resolved.conf.bak.$(date +%Y%m%d%H%M%S)"
        if grep -q "^DNS=" /etc/systemd/resolved.conf 2>/dev/null; then
            sed -i "s/^DNS=.*/DNS=${dns1} ${dns2}/" /etc/systemd/resolved.conf
        elif grep -q "^#DNS=" /etc/systemd/resolved.conf 2>/dev/null; then
            sed -i "s/^#DNS=.*/DNS=${dns1} ${dns2}/" /etc/systemd/resolved.conf
        else
            echo "DNS=${dns1} ${dns2}" >> /etc/systemd/resolved.conf
        fi
        systemctl restart systemd-resolved
        green "\n已通过 systemd-resolved 设置 DNS: ${dns1} ${dns2}\n"
    else
        [ -f /etc/resolv.conf ] && cp /etc/resolv.conf "/etc/resolv.conf.bak.$(date +%Y%m%d%H%M%S)"
        cat > /etc/resolv.conf << EOF
nameserver ${dns1}
nameserver ${dns2}
EOF
        green "\n已直接写入 /etc/resolv.conf，DNS: ${dns1} ${dns2}\n"
    fi
    echo ""
    yellow "当前生效DNS："
    dns_get_status "$mode"
}

dns_menu() {
    clear; echo ""
    purple "=== DNS 管理 ===\n"
    local mode
    mode=$(dns_get_mode)
    green "当前模式: ${mode}"
    yellow "当前DNS配置："
    dns_get_status "$mode"
    echo ""
    green  "1. 设为 Google DNS (8.8.8.8 / 8.8.4.4)"
    green  "2. 设为 Cloudflare DNS (1.1.1.1 / 1.0.0.1)"
    green  "3. 自定义 DNS"
    purple "0. 返回主菜单"
    skyblue "————"
    reading "\n请输入选择: " choice
    case "$choice" in
        1) dns_apply "8.8.8.8" "8.8.4.4"; return 0 ;;
        2) dns_apply "1.1.1.1" "1.0.0.1"; return 0 ;;
        3)
            reading "请输入主DNS: " d1
            reading "请输入备用DNS: " d2
            if [[ ! "$d1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ ! "$d2" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                red "IP格式不正确"
                return 0
            fi
            dns_apply "$d1" "$d2"
            return 0
            ;;
        0) return 1 ;;
        *) red "无效选项"; return 0 ;;
    esac
}

bbr_tune_menu() {
    clear; echo ""
    purple "=== 网络调优 (BBR) 管理 ===\n"
    bbr_get_status
    echo ""
    green  "1. 应用调优 (选择场景)"
    green  "2. 关闭调优"
    green  "3. 扫描冲突配置"
    green  "4. 清理冲突配置"
    purple "0. 返回主菜单"
    skyblue "————"
    reading "\n请输入选择: " choice
    case "$choice" in
        1) bbr_apply_menu ;;
        2) bbr_disable ;;
        3) bbr_scan ;;
        4) bbr_clean ;;
        0) return 1 ;;
        *) red "无效选项"; return 0 ;;
    esac
}

menu() {
    local sb_status argo_status
    sb_status=$(check_singbox 2>&1)
    argo_status=$(check_argo 2>&1)
    clear; echo ""
    purple "=== 自用 sing-box 脚本 ===\n"
    purple "  Argo 状态: ${argo_status}"
    purple "singbox 状态: ${sb_status}\n"
    green  "1. 安装 sing-box"
    red    "2. 卸载 sing-box"
    echo   "==============="
    green  "3. sing-box 管理"
    green  "4. Argo 隧道管理"
    echo   "==============="
    green  "5. 刷新节点信息"
    green  "6. 修改节点配置"
    echo   "==============="
    green  "7. 大陆域名拦截"
    echo   "==============="
    green  "8. 升级 sing-box"
    green  "9. 更新脚本"
    echo   "==============="
    purple "10. SSH 综合工具箱"
    purple "11. SSH 防护 (fail2ban)"
    purple "12. 网络调优 (BBR)"
    purple "13. DNS 管理"
    echo   "==============="
    green  "14. 备用协议管理 (TUIC/Reality/AnyTLS)"
    echo   "==============="
    red    "0. 退出脚本"
    echo   "==========="
}

# ── 安装后防火墙收尾 ─────────────────────────────

setup_firewall_base() {
    # ── 0. 前置检查 ──
    if ! command -v iptables &>/dev/null; then
        yellow "未检测到 iptables，正在安装…"
        apt-get install -y iptables 2>/dev/null || { red "iptables 安装失败，跳过防火墙配置"; return; }
    fi
    if command_exists ufw && ufw status | grep -q "Status: active"; then
        yellow "检测到 UFW 已启用，正在卸载以统一交由 iptables 管理…"
        ufw disable 2>/dev/null || true
        apt-get remove -y ufw 2>/dev/null || true
        # 清空 UFW 残留的链，避免冲突
        iptables -F 2>/dev/null || true
        iptables -X 2>/dev/null || true
        iptables -t nat -F 2>/dev/null || true
        iptables -t nat -X 2>/dev/null || true
        green "UFW 已卸载，继续执行 iptables 防火墙配置"
    fi
    if [ "$(id -u)" -ne 0 ]; then
        yellow "警告：当前非 root，进程名将无法显示"
    fi

    # ── 1. 禁用 IPv6（内核层，使用 sysctl.d 覆盖云厂商配置）──
    if [ ! -f /etc/sysctl.d/99-disable-ipv6.conf ]; then
        yellow "检测到未禁用 IPv6，正在禁用…"
        cat > /etc/sysctl.d/99-disable-ipv6.conf << 'EOF'
# 禁用 IPv6（sing-box 脚本添加）
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
        sysctl --system &>/dev/null

        # 验证是否真的禁用
        if [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" = "1" ]; then
            green "IPv6 已在内核层禁用"
        else
            yellow "警告：IPv6 禁用可能未生效，请检查 /etc/sysctl.d/ 下是否有冲突配置"
        fi

        # sshd 只监听 IPv4（reload 不断当前连接）
        if ! grep -q "^AddressFamily inet" /etc/ssh/sshd_config; then
            sed -i '/^AddressFamily/d' /etc/ssh/sshd_config
            echo "AddressFamily inet" >> /etc/ssh/sshd_config
            if sshd -t 2>/dev/null; then
                systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
                green "sshd 已设置为仅监听 IPv4（reload）"
            else
                yellow "sshd 配置测试失败，回滚 AddressFamily 设置"
                sed -i '/^AddressFamily inet/d' /etc/ssh/sshd_config
            fi
        fi
    fi

    # ── 2. IPv6 防火墙：直接全 DROP，无需维护具体规则 ──
    ip6tables -P INPUT ACCEPT 2>/dev/null || true
    ip6tables -F INPUT 2>/dev/null || true
    ip6tables -A INPUT -i lo -j ACCEPT 2>/dev/null || true
    ip6tables -A INPUT -j DROP 2>/dev/null || true

    # ── 3. 清空 IPv4 INPUT 链，重建 ──
    iptables -P INPUT ACCEPT 2>/dev/null || true
    iptables -F INPUT 2>/dev/null || true

    # ── 4. 放行 ESTABLISHED/RELATED ──
    iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true

    # ── 5. 丢弃 INVALID 包（防扫描/异常包）──
    iptables -A INPUT -m conntrack --ctstate INVALID -j DROP 2>/dev/null || true

    # ── 6. 放行 loopback ──
    iptables -A INPUT -i lo -j ACCEPT 2>/dev/null || true

    # ── 7. ICMP 限速（防 ping flood，正常 ping 不受影响）──
    iptables -A INPUT -p icmp --icmp-type echo-request \
        -m limit --limit 1/s --limit-burst 5 -j ACCEPT 2>/dev/null || true
    iptables -A INPUT -p icmp -j DROP 2>/dev/null || true

    # ── 8. 放行 SSH 端口（优先 sshd_config，兜底 ss 探测）──
    local ssh_port
    ssh_port=$(grep -E '^[[:space:]]*Port[[:space:]]+' /etc/ssh/sshd_config 2>/dev/null \
        | awk '{print $2}' | head -1)
    [ -z "$ssh_port" ] && ssh_port=$(ss -tlnpH 2>/dev/null \
        | awk '/sshd/{print $4}' | grep -oE '[0-9]+$' | sort -u | head -1)
    if [ -z "$ssh_port" ]; then
        ssh_port=22
        yellow "警告：未检测到 sshd 监听端口，默认放行 22"
    fi
    iptables -A INPUT -p tcp --dport "$ssh_port" -j ACCEPT 2>/dev/null || true

    # ── 9. 放行 hy2 端口 ──
    local hy2_port_reapply
    hy2_port_reapply=$(jq -r '.inbounds[] | select(.type=="hysteria2") | .listen_port' \
        "${conf_dir}/inbounds.json" 2>/dev/null)
    if [ -n "$hy2_port_reapply" ] && [ "$hy2_port_reapply" != "null" ]; then
        iptables -A INPUT -p udp --dport "$hy2_port_reapply" -j ACCEPT 2>/dev/null || true
    fi

    # ── 9b. 放行备用协议端口（TUIC / Reality / AnyTLS）──
    # 本函数会清空重建整条 INPUT 链，之前 install_singbox() 恢复备份时
    # 调用 allow_port 加的规则会被这里的 flush 冲掉，必须在重建后再放行一次，
    # 否则会依赖第 10 步的人工确认兜底才能补上（如遇到这种情况请检查此处逻辑）。
    if [ -f "${work_dir}/protocols.list" ]; then
        local _fw_tag _fw_port _fw_proto
        while IFS= read -r _fw_tag; do
            [ -z "$_fw_tag" ] && continue
            _fw_port=$(jq -r --arg t "$_fw_tag" '.inbounds[] | select(.tag == $t) | .listen_port' \
                "${conf_dir}/inbounds.json" 2>/dev/null)
            case "$_fw_tag" in tuic) _fw_proto="udp" ;; *) _fw_proto="tcp" ;; esac
            if [ -n "$_fw_port" ] && [ "$_fw_port" != "null" ]; then
                iptables -A INPUT -p "$_fw_proto" --dport "$_fw_port" -j ACCEPT 2>/dev/null || true
            fi
        done < "${work_dir}/protocols.list"
    fi

    # ── 10. 扫描其他公网监听端口（只检测 IPv4）──
    local accepted4_tcp accepted4_udp
    accepted4_tcp=$(iptables -S INPUT 2>/dev/null \
        | grep ' -p tcp ' | grep -oE -- '--dport [0-9]+' | awk '{print $2}')
    accepted4_udp=$(iptables -S INPUT 2>/dev/null \
        | grep ' -p udp ' | grep -oE -- '--dport [0-9]+' | awk '{print $2}')

    local unknown_ports=()
    local addr port proto proc already dup_key is_dup existing
    while IFS= read -r line; do
        addr=$(echo "$line"  | awk '{print $5}')
        port=$(echo "$addr"  | grep -oE '[0-9]+$')
        proto=$(echo "$line" | awk '{print $1}' | sed 's/6$//')
        proc=$(echo "$line"  | grep -oE 'users:\(\("[^"]+' \
            | grep -oE '"[^"]+' | tr -d '"')

        # 跳过 loopback
        echo "$addr" | grep -qE '^127\.|^\[::1\][:\[]?|^::1[:\[]' && continue
        # 跳过 IPv6 监听（反正全 DROP 了）
        echo "$addr" | grep -qE '^\[' && continue
        # 跳过 argo
        echo "$proc" | grep -qE '(cloudflared|argo)' && continue

        if [ -z "$port" ]; then
            yellow "  警告：无法解析端口，跳过：$line"
            continue
        fi

        already=false
        if [ "$proto" = "tcp" ]; then
            echo "$accepted4_tcp" | grep -qx "$port" && already=true
        elif [ "$proto" = "udp" ]; then
            echo "$accepted4_udp" | grep -qx "$port" && already=true
        fi
        [[ "$already" == true ]] && continue

        dup_key="${port}|${proto}"
        is_dup=false
        for existing in "${unknown_ports[@]}"; do
            [[ "$existing" == "${dup_key}|"* ]] && is_dup=true && break
        done
        [[ "$is_dup" == true ]] && continue

        unknown_ports+=("${port}|${proto}|${proc:-unknown}")
    done < <(ss -tlunpH 2>/dev/null)

    # ── 11. 逐一询问 ──
    local ports_to_allow=()
    if [ ${#unknown_ports[@]} -gt 0 ]; then
        echo ""
        yellow "检测到以下端口有进程监听但未在防火墙放行，逐一确认是否放行："
        for entry in "${unknown_ports[@]}"; do
            local p_port p_proto p_proc reply
            p_port=$(echo "$entry"  | cut -d'|' -f1)
            p_proto=$(echo "$entry" | cut -d'|' -f2)
            p_proc=$(echo "$entry"  | cut -d'|' -f3)
            echo ""
            skyblue "  端口：${p_port}/${p_proto}  进程：${p_proc}"
            printf "  是否放行？[Y/n] "
            read -r reply </dev/tty
            case "$reply" in
                [Nn]*) yellow "  跳过 ${p_port}/${p_proto}" ;;
                *)     ports_to_allow+=("${p_port}|${p_proto}") ;;
            esac
        done
    fi

    # ── 12. 追加放行 ──
    for entry in "${ports_to_allow[@]}"; do
        local p_port p_proto
        p_port=$(echo "$entry"  | cut -d'|' -f1)
        p_proto=$(echo "$entry" | cut -d'|' -f2)
        iptables -A INPUT -p "$p_proto" --dport "$p_port" -j ACCEPT 2>/dev/null || true
        green "  已放行 ${p_port}/${p_proto}"
    done

    # ── 13. DROP 兜底前给用户撤销窗口 ──
    echo ""
    yellow "5 秒后将启用 INPUT 链 DROP 兜底规则"
    yellow "如有异常请按 Ctrl+C 中止，然后执行："
    yellow "    iptables -P INPUT ACCEPT && iptables -F INPUT"
    sleep 5
    iptables -A INPUT -j DROP 2>/dev/null || true

    # ── 14. 设置默认策略为 DROP（更规范）──
    iptables  -P INPUT DROP 2>/dev/null || true
    ip6tables -P INPUT DROP 2>/dev/null || true

    # ── 15. 持久化 ──
    mkdir -p /etc/iptables 2>/dev/null || true
    local tmp4 tmp6
    tmp4=$(mktemp 2>/dev/null)
    if [ -n "$tmp4" ] && iptables-save > "$tmp4" 2>/dev/null; then
        mv "$tmp4" /etc/iptables/rules.v4
    else
        rm -f "$tmp4"
        yellow "保存 rules.v4 失败"
    fi
    tmp6=$(mktemp 2>/dev/null)
    if [ -n "$tmp6" ] && ip6tables-save > "$tmp6" 2>/dev/null; then
        mv "$tmp6" /etc/iptables/rules.v6
    else
        rm -f "$tmp6"
        yellow "保存 rules.v6 失败"
    fi

    # ── 16. 持久化服务检查 ──
    if command -v systemctl &>/dev/null; then
        if ! systemctl is-enabled netfilter-persistent 2>/dev/null | grep -q enabled; then
            yellow "警告：重启后规则可能不会自动恢复"
            printf "是否现在安装 iptables-persistent？[y/N] "
            local ans_persist
            read -r -t 30 ans_persist </dev/tty || ans_persist="n"
            case "$ans_persist" in
                [Yy]*)
                    apt-get install -y iptables-persistent 2>/dev/null \
                        || yellow "自动安装失败，请手动安装 iptables-persistent"
                    ;;
                *)
                    yellow "跳过，建议手动安装 iptables-persistent"
                    ;;
            esac
        fi
    fi

    # ── 17. fail2ban 兼容 ──
    if command -v systemctl &>/dev/null && systemctl is-active fail2ban &>/dev/null; then
        yellow "检测到 fail2ban 正在运行，重新加载以恢复 jump 规则…"
        systemctl reload fail2ban 2>/dev/null || systemctl restart fail2ban 2>/dev/null || \
            yellow "fail2ban reload 失败，请手动执行 systemctl restart fail2ban"
    fi

    green "防火墙规则已配置完成"
}
# ── 安装流程 ──────────────────────────────────────
do_install() {
    TUNNEL_FULLY_RESTORED=false
    BACKUP_SUCCESS=false
    TUNNEL_TOKEN_MODE=false
    ARGO_TOKEN_RESTORED=false

    install_packages jq openssl curl || { red "基础依赖安装失败，请检查网络或软件源"; exit 1; }

    yellow "正在查询 sing-box 最新版本…"
    local install_ver
    install_ver=$(get_latest_sb_version)
    if [ -z "$install_ver" ]; then
        yellow "无法获取最新版本，使用内置版本 ${SB_VERSION}"
        install_ver="$SB_VERSION"
    else
        green "将安装最新版本 v${install_ver}"
    fi

    install_singbox "$install_ver"
    if setup_services; then
        local sb_setup_ok=true
    else
        local sb_setup_ok=false
        red "\n⚠ sing-box 核心服务未能正常启动，装机流程仍会继续完成配置文件生成，"
        red "但节点当前不可用，请先排查：journalctl -u sing-box -n 50 --no-pager\n"
        sleep 3
    fi
    sleep 2
    create_shortcut

    # 清理备份目录前，确认所有该恢复的敏感文件确实落盘，避免误删导致无法重新排查
    local backup_has_token=false
    [ -f "${backup_dir}/argo_token" ] && backup_has_token=true

    if [ -s "${conf_dir}/inbounds.json" ]; then
        if $backup_has_token && [ "${ARGO_TOKEN_RESTORED:-false}" != true ]; then
            yellow "警告：备份中存在 Token 但未能成功恢复到 ${work_dir}，保留备份目录以便排查"
            yellow "请检查 ${backup_dir}/argo_token 内容，确认无误后可手动删除该目录"
        else
            [ -d "$backup_dir" ] && rm -rf "$backup_dir"
        fi
    else
        yellow "警告：inbounds.json 未落盘，保留备份目录以供重试"
    fi
# 默认开启大陆域名拦截
    local route_file="${conf_dir}/route.json"
    local tmp_file
    tmp_file=$(mktemp)
    jq '
      .route.rule_set += [{"type":"remote","tag":"geosite-cn","format":"binary",
        "url":"https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs",
        "download_detour":"direct"}] |
      .route.rules = [
        {"domain_regex":["^([a-zA-Z0-9_-]+\\.)*googleapis\\.cn$",
          "^([a-zA-Z0-9_-]+\\.)*googleapis\\.com$",
          "^([a-zA-Z0-9_-]+\\.)*gstatic\\.com$",
          "^([a-zA-Z0-9_-]+\\.)*xn--ngstr-lra8j\\.com$"],
         "outbound":"direct"},
        {"rule_set":["geosite-cn"],"outbound":"block"}
      ] + .route.rules
    ' "$route_file" > "$tmp_file"
    if [ $? -eq 0 ] && [ -s "$tmp_file" ] && jq empty "$tmp_file" 2>/dev/null; then
        mv "$tmp_file" "$route_file"
        if restart_singbox; then
            green "大陆域名拦截已默认开启"
        else
            yellow "大陆域名拦截规则已写入，但 sing-box 重启失败，可能未生效（不影响后续流程，可稍后手动检查）"
        fi
    else
        rm -f "$tmp_file"
        yellow "大陆域名拦截配置失败，已跳过（不影响核心功能）"
    fi
    setup_firewall_base
    if $sb_setup_ok; then
        green "\nsing-box 安装完成！"
    else
        red "\n⚠ sing-box 安装流程已走完，但核心服务未能正常启动，节点当前不可用"
        red "请检查：journalctl -u sing-box -n 50 --no-pager，排查后可到菜单「3. sing-box 管理」手动重启\n"
    fi

    if is_fixed_tunnel_configured && [ "${TUNNEL_FULLY_RESTORED}" = true ]; then
        # sing-box 在装机流程中被重启过（大陆拦截配置、防火墙等步骤），
        # 但 argo 隧道服务此前一直在跑、没有跟着重启，它与本地 sing-box 之间
        # 的连接会停留在旧进程上，导致隧道能连通 Cloudflare 边缘节点、
        # 但转发到本地 vless-ws 时失败（journalctl -u argo 可见 "context canceled"）。
        # 此处显式重启 argo，让它与新启动的 sing-box 进程重新建立本地连接。
        if restart_argo; then
            green "Argo 固定隧道已完整恢复（已同步重启 argo 服务）"
            get_info
        else
            red "Argo 隧道配置已恢复，但 argo 服务重启失败，节点当前不可用"
            red "请检查：journalctl -u argo -n 50 --no-pager\n"
        fi
    elif is_fixed_tunnel_configured && [ "${TUNNEL_TOKEN_MODE}" = true ]; then
        yellow "检测到 Token 模式隧道备份，域名：$(get_fixed_domain)"
        yellow "请进入 Argo 隧道管理 → 配置固定隧道，重新输入 Token 后用 sb -c 查看节点\n"
    elif is_fixed_tunnel_configured; then
        yellow "隧道配置文件存在但缺少凭据，请重新配置固定隧道\n"
    else
        yellow "请进入 Argo 隧道管理 配置固定隧道，再用 sb -c 查看节点\n"
    fi
}

# ── 入口 ──────────────────────────────────────────
trap 'echo ""; red "强制退出"; exit 1' INT

case "$1" in
    -i|--install)
        check_singbox &>/dev/null
        [ $? -ne 2 ] && { yellow "sing-box 已安装，跳过"; exit 0; }
        do_install
        ;;
    -u|--uninstall)
        yellow "正在无交互卸载 sing-box…\n"
        _do_uninstall_core false
        green "\nsing-box 卸载完成\n"
        ;;
    -c|--check)
        check_nodes
        ;;
    -h|--help)
        echo ""
        green "用法: sb [参数]"
        green "  -i, --install    安装"
        green "  -u, --uninstall  卸载"
        green "  -c, --check      查看节点"
        green "  -h, --help       帮助"
        green "  （无参数）       交互菜单"
        echo ""
        ;;
    "")
        while true; do
            menu
            reading "请输入选择(0-14): " choice
            echo ""
            need_pause=true
            case "$choice" in
                1)
                    check_singbox &>/dev/null
                    if [ $? -ne 2 ]; then
                        yellow "sing-box 已经安装！\n"
                    else
                        do_install
                    fi
                    ;;
                2)  uninstall_singbox;  need_pause=false ;;
                3)  manage_singbox;     need_pause=false ;;
                4)
                    if manage_argo; then need_pause=true; else need_pause=false; fi
                    ;;
                5)  get_info;           need_pause=true  ;;
                6)
                    if change_config; then need_pause=true; else need_pause=false; fi
                    ;;
                7)
                    if cn_block_manage; then need_pause=true; else need_pause=false; fi
                    ;;
                8)
                    if upgrade_singbox; then need_pause=true; else need_pause=false; fi
                    ;;
                9)  update_script;      need_pause=false ;;
                10)
                    clear
                    bash <(curl -fsSL https://ssh_tool.eooce.com)
                    need_pause=false
                    ;;
                11)
                    if manage_fail2ban; then need_pause=true; else need_pause=false; fi
                    ;;
                12)
                    if bbr_tune_menu; then need_pause=true; else need_pause=false; fi
                    ;;
                13)
                    if dns_menu; then need_pause=true; else need_pause=false; fi
                    ;;
                14)
                    if manage_extra_protocols; then need_pause=true; else need_pause=false; fi
                    ;;
                0) exit 0 ;;
                *) red "无效选项，请输入 0-14" ;;
            esac
            [ "$need_pause" = true ] && read -n1 -s -r -p $'\033[1;91m按任意键返回…\033[0m'
            echo ""
        done
        ;;
    *)
        red "未知参数: $1"
        green "用法: sb [-i|-u|-c|-h]"
        exit 1
        ;;
esac
