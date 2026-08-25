#!/usr/bin/env bash
# =========================
# 自用 sing-box 安装脚本
# 协议: vless-argo(固定隧道) + hysteria2
# 平台: Ubuntu / Debian (systemd)
# 最后更新时间: 2026.8.21
# =========================

export LANG=en_US.UTF-8
export DEBIAN_FRONTEND=noninteractive

# ── 颜色 ──────────────────────────────────────────
red()    { echo -e "\e[1;91m$1\033[0m"; }
green()  { echo -e "\e[1;32m$1\033[0m"; }
yellow() { echo -e "\e[1;33m$1\033[0m"; }
purple() { echo -e "\e[1;35m$1\033[0m"; }
skyblue(){ echo -e "\e[1;36m$1\033[0m"; }
reading(){ read -p "$(red "$1")" "$2" || exit 1; }

# ── 常量 ──────────────────────────────────────────
work_dir="/etc/sing-box"
conf_dir="${work_dir}/conf"
client_dir="${work_dir}/url.txt"
backup_dir="/etc/sing-box-backup"
SCRIPT_URL="https://raw.githubusercontent.com/wot1026/sing-box/main/sing-box.sh"
ARGO_PORT="8001"

SB_VERSION="1.13.19"

export CFIP=${CFIP:-'cf.877774.xyz'}
export CFPORT=${CFPORT:-'443'}

# ── 前置检查 ──────────────────────────────────────
[[ $EUID -ne 0 ]] && red "请在 root 用户下运行脚本" && exit 1
# 已确认是 root，顺带把 HOME 锚定为 /root：部分调用方式（sudo -E 保留调用者
# 环境、部分 systemd/cron 执行上下文）下 $HOME 不保证等于 /root 甚至未设置。
# 这不仅关系到本脚本自己读取路径用的 _acme_sh_bin（已写死 /root/... 不受
# 影响），更关键的是 get.acme.sh 装的第三方安装脚本自己会读取运行时 $HOME
# 来决定安装位置（默认装到 $HOME/.acme.sh）——如果不在这里统一锚定，安装器
# 和 _acme_sh_bin 会指向两个不同目录，导致"装是装了，但脚本读取路径下找不到
# 可执行文件"这类不一致报错。放在这里而非仅在 acme.sh 安装函数内设置，是为了
# 让 HOME 在整个脚本执行期间都保持确定，不遗漏其他可能隐式依赖 $HOME 的地方。
export HOME=/root
command -v systemctl >/dev/null 2>&1 || { red "本脚本仅支持 systemd 系统（Ubuntu/Debian）"; exit 1; }

command_exists() { command -v "$1" >/dev/null 2>&1; }

# ── 架构检测 ──────────────────────────────────────
# 用法：detect_arch  →  echo 出 amd64/arm64，失败时打印错误并 return 1
detect_arch() {
    local arch_raw
    arch_raw=$(uname -m)
    case "$arch_raw" in
        x86_64|amd64)  echo amd64 ;;
        aarch64|arm64) echo arm64 ;;
        *) red "不支持的架构: ${arch_raw}"; return 1 ;;
    esac
}

# ── crontab 安全删行 ──────────────────────────────
# 用法：_crontab_remove_matching <匹配模式>
# 直接用 `crontab -l | grep -v ... | crontab -` 有风险：crontab -l 一旦因瞬时异常
# （锁竞争、读取失败等）返回空内容而不是报错，grep -v 对空输入同样输出为空，
# 最终会把用户整个 crontab（包括本脚本之外的其他任务）静默清空，且没有任何提示。
# 这里显式检查 crontab -l 的退出码：只有确认真正读取成功（哪怕内容本来就是空）
# 才允许写回；退出码非 0（无 crontab 或读取异常）一律跳过，不做任何写入——
# 跳过最坏情况是这次没删成，写回最坏情况是清空所有任务，两者不对等，优先选跳过。
_crontab_remove_matching() {
    local pattern="$1"
    local existing ret
    existing=$(crontab -l 2>/dev/null)
    ret=$?
    [ "$ret" -ne 0 ] && return 0
    grep -vF "$pattern" <<< "$existing" | crontab - 2>/dev/null
}

# ── crontab 安全追加 ──────────────────────────────
# 用法：_crontab_append_line <新的一整行 cron 内容>
# 同样的风险在追加路径也存在：`(crontab -l; echo "...") | crontab -` 若
# crontab -l 因瞬时异常（锁竞争等）失败但仍返回空标准输出而非非零退出码，
# 子 shell 里就只剩新追加的这一行，等于把用户原有的其他 crontab 任务全部
# 静默覆盖删除。
#
# 注意：crontab -l 在该用户"从未有过 crontab"时也会返回非 0（不同实现
# 提示语不同，如 "no crontab for root" / "not found" / "cannot open"），
# 这是完全正常的初始状态，不能等同于读取异常——否则会导致没有 crontab
# 的机器上，本函数永远追加不进任何任务（这类机器恰恰最常见于全新部署
# 的场景）。这里通过匹配 stderr 里几种常见的"无 crontab"提示词，将其
# 与真正的读取异常区分开：命中则视为空列表继续追加；未命中的意外错误
# 才按原则放弃写入（跳过最坏情况是没加成，写回最坏情况是清空所有任务，
# 两者不对等，优先选跳过）。
_crontab_append_line() {
    local new_line="$1" existing ret errmsg tmp_out
    tmp_out=$(mktemp 2>/dev/null) || return 1
    errmsg=$(crontab -l 2>&1 1>"$tmp_out")
    ret=$?
    existing=$(cat "$tmp_out" 2>/dev/null)
    rm -f "$tmp_out"
    if [ "$ret" -ne 0 ]; then
        if echo "$errmsg" | grep -qiE "no crontab|not found for|cannot open|no such file"; then
            existing=""
        else
            return 1
        fi
    fi
    { [ -n "$existing" ] && printf '%s\n' "$existing"; printf '%s\n' "$new_line"; } | crontab - 2>/dev/null
}

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

# ── 安装失败回滚 ───────────────────────────────────
# install_singbox 中途失败时调用：删除已落盘的 sing-box/argo 二进制，
# 让 check_singbox/check_argo 重新返回"未安装"，避免用户卡在"半安装"
# 状态无法通过菜单重装；同时清理该次安装已放行的 hy2 防火墙规则，
# 避免留下孤儿规则。
# 用法：_install_singbox_rollback [hy2_port] [清理新生成的证书=true/false] [清理conf下的json=true/false]
# 第二个参数默认 false：证书可能是从 backup_dir 恢复的，不能无差别删除，
# 只有调用方明确知道这次是"全新生成证书后才失败"时才传 true。
# 第三个参数默认 false：conf_dir 下的 json 只有在本次安装流程已经开始
# 写入之后失败才该清理——下载二进制/选端口/生成证书这几个更早的失败点，
# conf_dir 里如果有内容，只可能是上一次半损坏安装遗留的旧配置，跟本次
# 安装无关，不该被这次失败连带清空；只有调用方明确知道这次是"json 写入
# 阶段失败"时才传 true。
_install_singbox_rollback() {
    local hy2_port="${1:-}" clean_cert="${2:-false}" clean_conf="${3:-false}"
    rm -f "${work_dir}/sing-box"
    rm -f "${work_dir}/argo"
    if [ "$clean_conf" = true ]; then
        rm -f "${conf_dir}"/*.json 2>/dev/null
    fi
    if [ "$clean_cert" = true ]; then
        rm -f "${work_dir}/cert.pem" "${work_dir}/private.key"
    fi
    if [ -n "$hy2_port" ] && [ "$hy2_port" != "null" ]; then
        remove_port "${hy2_port}/udp" 2>/dev/null
    fi
}

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
    if ! apt-get update -y; then
        red "apt-get update 失败，请检查网络或软件源配置"
        return 1
    fi
    for pkg in "${to_install[@]}"; do
        yellow "正在安装 ${pkg}…"
        apt-get install -y "$pkg" || { red "${pkg} 安装失败"; return 1; }
    done
}

# ── 持久化 iptables/ip6tables 规则到磁盘 ──────────
# 用法：_persist_iptables_rules <has_iptables:0|1> <has_ip6tables:0|1>
_persist_iptables_rules() {
    local has_iptables="$1" has_ip6tables="$2"
    if [ "$has_iptables" -eq 1 ] && command_exists iptables-save; then
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
    if [ "$has_ip6tables" -eq 1 ] && command_exists ip6tables-save; then
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

# ── 防火墙放行 ────────────────────────────────────
allow_port() {
    local has_ufw=0 has_iptables=0 has_ip6tables=0
    # 只有 ufw 处于 active 状态才当作"这台机器由 ufw 管理"；
    # 仅仅 command_exists ufw（装了但未启用/已被 setup_firewall_base
    # 统一交给 iptables 管理）不应该触发对 ufw 全局策略的修改——
    # 否则每次调用本函数都会静默把 ufw 默认出站策略改成 allow，
    # 属于跟当前防火墙管理方式不符的隐蔽副作用。
    command_exists ufw && ufw status 2>/dev/null | grep -q "Status: active" && has_ufw=1
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

    _persist_iptables_rules "$has_iptables" "$has_ip6tables"
}

# ── 防火墙删除旧规则 ──────────────────────────────
remove_port() {
    local has_ufw=0 has_iptables=0 has_ip6tables=0
    # 判断标准与 allow_port 保持一致：只有 ufw 处于 active 状态才当作
    # "这台机器由 ufw 管理"，避免两个配对函数用不同标准判定同一件事。
    command_exists ufw && ufw status 2>/dev/null | grep -q "Status: active" && has_ufw=1
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

    _persist_iptables_rules "$has_iptables" "$has_ip6tables"
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

# ── 原子写入 JSON 配置文件 ─────────────────────────
# 用法：write_json_atomic <目标路径> <<EOF ... EOF ，调用方需检查返回值
write_json_atomic() {
    local dest="$1" tmp
    tmp=$(mktemp) || { red "创建临时文件失败：${dest}"; return 1; }
    if ! cat > "$tmp"; then
        red "写入临时文件失败：${dest}"
        rm -f "$tmp"
        return 1
    fi
    # 注意：真实 jq 对完全空的输入，`jq empty` 会因为一次都没有解析到值、
    # 也就一次都没有报错而返回 0（并非"空输入=非法"）。所以必须先单独判断
    # 是否为空文件，不能只靠 jq empty，否则上游 jq 因文件损坏/过滤器出错
    # 而输出空流时，会被当作"合法"写入，把目标文件清空。
    if [ ! -s "$tmp" ]; then
        red "生成的 JSON 内容为空，未写入：${dest}"
        rm -f "$tmp"
        return 1
    fi
    if ! jq empty "$tmp" 2>/dev/null; then
        red "生成的 JSON 格式非法，未写入：${dest}"
        rm -f "$tmp"
        return 1
    fi
    if ! mv "$tmp" "$dest"; then
        red "写入目标文件失败：${dest}"
        rm -f "$tmp"
        return 1
    fi
    return 0
}

# 检测端口是否已被占用
# 用法：_port_in_use <port> <tcp|udp>  返回 0 = 已占用，1 = 空闲
_port_in_use() {
    local port="$1" proto="$2" flag
    [ "$proto" = udp ] && flag=-ulnH || flag=-tlnH
    ss "$flag" 2>/dev/null | awk '{print $4}' | grep -q ":${port}$"
}

# ── 查找未被占用的端口 ────────────────────────────
# 用法：pick_free_port udp|tcp
pick_free_port() {
    local proto="$1" port attempts=0
    port=$(shuf -i 10000-65000 -n 1)
    while _port_in_use "$port" "$proto"; do
        port=$(shuf -i 10000-65000 -n 1)
        (( attempts++ > 100 )) && { echo "无法找到空闲 ${proto^^} 端口" >&2; return 1; }
    done
    echo "$port"
}
pick_free_udp_port() { pick_free_port udp; }
pick_free_tcp_port() { pick_free_port tcp; }

# ── 安装核心 ──────────────────────────────────────
install_singbox() {
    clear
    purple "正在安装 sing-box，请稍候…"

    local sb_ver="${1:-$SB_VERSION}"

    local arch
    arch=$(detect_arch) || return 1
    if _port_in_use "$ARGO_PORT" tcp; then
        yellow "端口 ${ARGO_PORT} 已被占用，自动选用空闲 TCP 端口"
        local new_argo_port
        new_argo_port=$(pick_free_tcp_port) || { red "无法分配空闲 TCP 端口"; return 1; }
        ARGO_PORT="$new_argo_port"
        green "VLESS-Argo 端口已切换到 ${ARGO_PORT}"
    fi
    
    mkdir -p "${work_dir}" "${conf_dir}"
    chmod 700 "${work_dir}"

    download_singbox "$arch" "$sb_ver" "${work_dir}/sing-box" || { _install_singbox_rollback; return 1; }
    download_cloudflared "$arch" "${work_dir}/argo"           || { _install_singbox_rollback; return 1; }

    apt-get install -y qrencode 2>/dev/null || yellow "qrencode 安装失败，二维码功能不可用"

    local hy2_port uuid vless_path argo_port="${ARGO_PORT}" hy2_password
    local restore_backup=false

    # ── 检测是否存在卸载时保留的备份配置 ──────────
    RESTORE_DECLINED=false
    if [ -f "${backup_dir}/inbounds.json" ]; then
        yellow "\n检测到上次卸载时保留的节点配置备份"
        local restore_choice
        reading "是否恢复备份中的 UUID / 端口 / 隧道配置？(y/n，回车默认 y): " restore_choice
        if [[ -z "$restore_choice" || "$restore_choice" == [yY] ]]; then
            restore_backup=true
        else
            RESTORE_DECLINED=true
        fi
    fi

    if $restore_backup; then
        uuid=$(jq -r '.inbounds[] | select(.tag=="vless-ws") | .users[0].uuid' "${backup_dir}/inbounds.json")
        vless_path=$(jq -r '.inbounds[] | select(.tag=="vless-ws") | .transport.path' "${backup_dir}/inbounds.json")
        hy2_port=$(jq -r '.inbounds[] | select(.type=="hysteria2") | .listen_port' "${backup_dir}/inbounds.json")
        argo_port=$(jq -r '.inbounds[] | select(.tag=="vless-ws") | .listen_port' "${backup_dir}/inbounds.json")
        hy2_password=$(jq -r '.inbounds[] | select(.type=="hysteria2") | .users[0].password' "${backup_dir}/inbounds.json")
        # 兼容旧备份（密码与UUID相同的历史配置）：若读取失败则回退使用 uuid
        if [ -z "$hy2_password" ] || [ "$hy2_password" = "null" ]; then
            hy2_password="$uuid"
        fi

        # 端口字段统一走 _creds_field_valid ... port（数字 + 1-65535 范围校验），
        # 不再自己手写纯数字正则——避免备份损坏成 99999 这类超出范围的值时
        # 被误判为合法端口，进而被写进防火墙规则和 sing-box 配置。
        if [ -z "$uuid" ] || [ "$uuid" = "null" ] \
           || [ -z "$vless_path" ] || [ "$vless_path" = "null" ] \
           || ! _creds_field_valid "$hy2_port" port \
           || ! _creds_field_valid "$argo_port" port; then
            yellow "备份配置内容异常，已忽略备份，将生成全新配置"
            restore_backup=false
        else
            if _port_in_use "$hy2_port" udp; then
                yellow "备份中的 Hysteria2 端口 ${hy2_port} 已被占用，将重新分配"
                hy2_port=$(pick_free_udp_port) || { _install_singbox_rollback; return 1; }
            fi
            if _port_in_use "$argo_port" tcp; then
                yellow "备份中的 VLESS-Argo 端口 ${argo_port} 已被占用，正在重新分配 TCP 端口"
                # 不能直接回退到固定的 ${ARGO_PORT}：那只是个写死的默认值
                # （常量 "8001"），没有理由保证它一定空闲——如果它也被占用，
                # 会把一个同样冲突的端口写进 inbounds.json。改用和 Hy2 分支
                # 一致的做法，动态挑一个当前确认空闲的 TCP 端口。
                argo_port=$(pick_free_tcp_port) || { _install_singbox_rollback; return 1; }
            fi
            green "已从备份恢复 UUID 与端口配置"
        fi
    fi

    if ! $restore_backup; then
        hy2_port=$(pick_free_udp_port) || { _install_singbox_rollback; return 1; }
        uuid=$(cat /proc/sys/kernel/random/uuid)
        vless_path="/${uuid}-vless"
        hy2_password=$(openssl rand -hex 16)
    fi

    allow_port "${hy2_port}/udp"

    # ── 证书：优先从备份恢复，保持 pinSHA256 不变 ─
    # 除了校验 cert.pem 本身格式合法，还要确认 private.key 与其配对
    # （公钥指纹一致），避免不同批次的证书/私钥被误恢复，导致
    # hy2/tuic/anytls 全部握手失败且难以排查
    local cert_restored=false
    if $restore_backup \
       && [ -f "${backup_dir}/cert.pem" ] \
       && [ -f "${backup_dir}/private.key" ] \
       && openssl x509 -noout -in "${backup_dir}/cert.pem" 2>/dev/null; then
        local _cert_pub _key_pub
        _cert_pub=$(openssl x509 -noout -pubkey -in "${backup_dir}/cert.pem" 2>/dev/null | sha256sum | cut -d' ' -f1)
        _key_pub=$(openssl pkey -pubout -in "${backup_dir}/private.key" 2>/dev/null | sha256sum | cut -d' ' -f1)
        if [ -n "$_cert_pub" ] && [ "$_cert_pub" = "$_key_pub" ]; then
            cp "${backup_dir}/cert.pem"    "${work_dir}/cert.pem"
            cp "${backup_dir}/private.key" "${work_dir}/private.key"
            chmod 600 "${work_dir}/private.key"
            green "已从备份恢复 TLS 证书（pinSHA256 不变）"
            cert_restored=true
        else
            yellow "备份证书与私钥不配对，改为生成新证书"
        fi
    fi

    if ! $cert_restored; then
        yellow "正在生成新 TLS 证书..."
        if ! openssl ecparam -genkey -name prime256v1 -out "${work_dir}/private.key" 2>/dev/null; then
            red "生成私钥失败（磁盘空间/权限/OpenSSL异常），已中止"
            _install_singbox_rollback "$hy2_port" true; return 1
        fi
        if ! openssl req -new -x509 -days 3650 \
            -key "${work_dir}/private.key" \
            -out "${work_dir}/cert.pem" \
            -subj "/CN=bing.com" 2>/dev/null; then
            red "生成自签证书失败，已中止"
            _install_singbox_rollback "$hy2_port" true; return 1
        fi
        if [ ! -s "${work_dir}/private.key" ] || [ ! -s "${work_dir}/cert.pem" ]; then
            red "TLS 证书或私钥文件为空，生成异常，已中止"
            _install_singbox_rollback "$hy2_port" true; return 1
        fi
        chmod 600 "${work_dir}/private.key"
    fi

    write_json_atomic "${conf_dir}/log.json" << EOF
{
  "log": {
    "disabled": false,
    "level": "error",
    "output": "${work_dir}/sb.log",
    "timestamp": true
  }
}
EOF
    [ $? -eq 0 ] || { _install_singbox_rollback "$hy2_port" false true; return 1; }

    write_json_atomic "${conf_dir}/ntp.json" << 'EOF'
{
  "ntp": {
    "enabled": true,
    "server": "time.apple.com",
    "server_port": 123,
    "interval": "60m"
  }
}
EOF
    [ $? -eq 0 ] || { _install_singbox_rollback "$hy2_port" false true; return 1; }

    write_json_atomic "${conf_dir}/dns.json" << 'EOF'
{
  "dns": {
    "servers": [{"tag": "local", "type": "local"}],
    "strategy": "ipv4_only"
  }
}
EOF
    [ $? -eq 0 ] || { _install_singbox_rollback "$hy2_port" false true; return 1; }

    write_json_atomic "${conf_dir}/inbounds.json" << EOF
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
    [ $? -eq 0 ] || { _install_singbox_rollback "$hy2_port" false true; return 1; }

    write_json_atomic "${conf_dir}/outbounds.json" << 'EOF'
{
  "outbounds": [
    {"type": "direct", "tag": "direct"},
    {"type": "block",  "tag": "block"}
  ]
}
EOF
    [ $? -eq 0 ] || { _install_singbox_rollback "$hy2_port" false true; return 1; }

    write_json_atomic "${conf_dir}/route.json" << 'EOF'
{
  "route": {
    "rule_set": [],
    "rules": [],
    "final": "direct"
  }
}
EOF
    [ $? -eq 0 ] || { _install_singbox_rollback "$hy2_port" false true; return 1; }

    write_json_atomic "${conf_dir}/experimental.json" << EOF
{
  "experimental": {
    "cache_file": {
      "enabled": true,
      "path": "${work_dir}/cache.db"
    }
  }
}
EOF
    [ $? -eq 0 ] || { _install_singbox_rollback "$hy2_port" false true; return 1; }

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
        # 恢复 autofix 日志，使其在将来"彻底卸载"时仍能定位到被自动
        # 注释过的系统配置行并恢复；否则这条恢复链路会在这次重装后失效。
        [ -f "${backup_dir}/bbr-autofix.log" ]  && cp "${backup_dir}/bbr-autofix.log"  "$BBR_AUTOFIX_LOG"
        [ -f "${backup_dir}/ipv6-autofix.log" ] && cp "${backup_dir}/ipv6-autofix.log" "$IPV6_AUTOFIX_LOG"
        [ -f "${backup_dir}/sshd_af_added.flag" ] && cp "${backup_dir}/sshd_af_added.flag" "${work_dir}/sshd_af_added.flag"

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
                if _port_in_use "$_ep_port" "$_ep_proto"; then
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
    if ! systemctl enable sing-box; then
        yellow "\n⚠ sing-box 设置开机自启失败，重启 VPS 后可能不会自动拉起服务，请检查：systemctl status sing-box\n"
    fi
    local sb_start_ok=true
    if ! systemctl start sing-box; then
        red "\n⚠ sing-box 服务启动命令执行失败，请检查：journalctl -u sing-box -n 50 --no-pager\n"
        sb_start_ok=false
    elif ! systemctl is-active sing-box &>/dev/null; then
        red "\n⚠ sing-box 服务未能进入运行状态，请检查：journalctl -u sing-box -n 50 --no-pager\n"
        sb_start_ok=false
    fi

    TUNNEL_FULLY_RESTORED=false

    if [ -f "${work_dir}/tunnel.yml" ]; then
        # 只有已配置固定隧道时才需要 argo 常驻，才 enable 开机自启；
        # 未配置隧道时保留上面写的 /bin/true 占位 unit（不 enable、不 start），
        # 避免 check_argo 把"尚未配置"误判成"服务故障"。
        # enable 必须放在 rebuild 成功之后：rebuild 失败（Token/凭据缺失）时
        # /etc/systemd/system/argo.service 仍是上面写的占位 unit，若此时 enable，
        # 重启机器会拉起一个 ExecStart=/bin/true 的假服务。
        if _rebuild_argo_service_from_tunnel_yml; then
            if ! systemctl enable argo; then
                yellow "\n⚠ argo 设置开机自启失败，重启 VPS 后可能不会自动拉起隧道，请检查：systemctl status argo\n"
            fi
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
    server_ip=$(curl -4 -sm3 ip.sb 2>/dev/null)
    [ -z "$server_ip" ] && server_ip=$(curl -4 -sm3 api.ipify.org 2>/dev/null)
    [ -z "$server_ip" ] && server_ip=$(curl -4 -sm3 ifconfig.me 2>/dev/null)
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
    if [ -z "$hy2_password" ] || [ "$hy2_password" = "null" ]; then
        hy2_password="$uuid"
    fi

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
        # 分隔说明行（如"───── IP 直连 …"）不是链接，不生成二维码
        [[ "$line" == *"://"* ]] && command_exists qrencode && qrencode -t ANSIUTF8 "$line"
        echo ""
    done < "${client_dir}"
}

# ── 大陆拦截 ──────────────────────────────────────
cn_block_manage() {
    check_singbox &>/dev/null
    [ $? -eq 2 ] && { yellow "sing-box 尚未安装！"; sleep 1; return 0; }

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
            if ! jq '
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
            ' "$route_file" | write_json_atomic "$route_file"; then
                red "配置写入失败"; sleep 2; return 0
            fi
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
            if ! jq '
              del(.route.rules[] | select(.rule_set[]? == "geosite-cn")) |
              del(.route.rules[] | select(
                  .domain_regex? and .outbound == "direct" and
                  (.domain_regex[] | test("googleapis"))
              )) |
              del(.route.rule_set[] | select(.tag == "geosite-cn"))
            ' "$route_file" | write_json_atomic "$route_file"; then
                red "配置写入失败"; sleep 2; return 0
            fi
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
    [ $? -eq 2 ] && { yellow "sing-box 尚未安装！"; sleep 1; return 0; }

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
            # 仅修改 Argo VLESS 的 UUID 和 path（按 tag 精确匹配，避免误改 Reality 的 vless inbound）
            local _uuid_bak
            _uuid_bak=$(mktemp) && cp "$inbounds_file" "$_uuid_bak" || { red "备份配置文件失败，已取消"; sleep 2; return 0; }
            if ! jq --arg u "$new_uuid" --arg p "/${new_uuid}-vless" '
                (.inbounds[] | select(.tag=="vless-ws") | .users[] | .uuid) = $u |
                (.inbounds[] | select(.tag=="vless-ws") | .transport.path) = $p
            ' "$inbounds_file" | write_json_atomic "$inbounds_file"; then
                rm -f "$_uuid_bak"
                red "配置文件写入失败，请检查！"; sleep 2; return 0
            fi
            if restart_singbox; then
                rm -f "$_uuid_bak"
                get_info
                green "\nUUID 已修改为：${new_uuid}\n"
            else
                yellow "sing-box 重启失败，正在回滚 UUID 配置…"
                mv "$_uuid_bak" "$inbounds_file"
                if restart_singbox; then
                    red "\n已回滚到修改前的 UUID，请排查后重试\n"
                else
                    red "\n回滚后服务仍未启动，请检查：journalctl -u sing-box -n 50 --no-pager\n"
                fi
            fi
            ;;

       2)
            local old_port
            old_port=$(jq -r '.inbounds[] | select(.type=="hysteria2") | .listen_port' "$inbounds_file")
            reading "\n请输入新的 Hysteria2 端口（回车随机生成）: " new_port
            if [ -z "$new_port" ]; then
                new_port=$(pick_free_udp_port)
            else
                if ! [[ "$new_port" =~ ^[1-9][0-9]*$ ]] || (( new_port < 1 || new_port > 65535 )); then
                    red "端口无效（1-65535，不含前导零）"; sleep 1; return 0
                fi
                # 端口和当前自己正在用的端口相同时跳过占用检查，否则用户想
                # 确认/改回原端口会被自己服务正在监听的端口挡住
                if [ "$new_port" != "$old_port" ] && _port_in_use "$new_port" udp; then
                    red "端口 ${new_port} 已被占用，请换一个"; sleep 1; return 0
                fi
            fi
            local _hy2_bak
            _hy2_bak=$(mktemp) && cp "$inbounds_file" "$_hy2_bak" || { red "备份配置文件失败，已取消"; sleep 2; return 0; }
            if ! jq --argjson p "$new_port" \
                '(.inbounds[] | select(.type=="hysteria2") | .listen_port) = $p' \
                "$inbounds_file" | write_json_atomic "$inbounds_file"; then
                rm -f "$_hy2_bak"
                red "配置写入失败"; sleep 1; return 0
            fi
            # 用统一的 remove_port/allow_port（而非手动摘 DROP 再插回），
            # 天然兼容 ufw 场景，且自带持久化，避免和防火墙状态不一致
            if [ -n "$old_port" ] && [ "$old_port" != "null" ] && [ "$old_port" != "$new_port" ]; then
                remove_port "${old_port}/udp"
            fi
            allow_port "${new_port}/udp"

            if restart_singbox; then
                rm -f "$_hy2_bak"
                get_info
                green "\nHysteria2 端口已修改为：${new_port}\n"
            else
                yellow "sing-box 重启失败，正在回滚端口配置…"
                mv "$_hy2_bak" "$inbounds_file"
                # 恢复防火墙规则
                remove_port "${new_port}/udp"
                [ -n "$old_port" ] && [ "$old_port" != "null" ] && [ "$old_port" != "$new_port" ] && allow_port "${old_port}/udp"
                if restart_singbox; then
                    red "\n已回滚到端口 ${old_port}，请排查后重试\n"
                else
                    red "\n回滚后服务仍未启动，请检查：journalctl -u sing-box -n 50 --no-pager\n"
                fi
            fi
            ;;
        3)
            local old_port
            old_port=$(jq -r '.inbounds[] | select(.tag=="vless-ws") | .listen_port' "$inbounds_file")
            reading "\n请输入新的 VLESS-Argo 端口（回车随机生成）: " new_port
            [ -z "$new_port" ] && new_port=$(pick_free_tcp_port)
            if ! [[ "$new_port" =~ ^[1-9][0-9]*$ ]] || (( new_port < 1 || new_port > 65535 )); then
                red "端口无效（1-65535，不含前导零）"; sleep 1; return 0
            fi
            # 端口和当前自己正在用的端口相同时跳过占用检查，否则用户想
            # 确认/改回原端口会被自己服务正在监听的端口挡住
            if [ "$new_port" != "$old_port" ] && _port_in_use "$new_port" tcp; then
                red "端口 ${new_port} 已被占用，请换一个"; sleep 1; return 0
            fi

            # Token 模式下，本地端口和 Cloudflare Dashboard 后端配置是分离的，
            # sed 无法同步修改 Dashboard 侧配置，必须用户手动去 Dashboard 改，
            # 因此这里在写入配置前先强制确认，避免节点静默失效。
            # 判断逻辑改为跟 _rebuild_argo_service_from_tunnel_yml 一致的语义判断
            # （tunnel.yml 是否含 credentials-file 字段），不再依赖文件是否存在——
            # 后者会被模式切换后残留的旧凭据文件（如切了 JSON 模式但 argo_token
            # 没删）误导，导致误判成 Token 模式或漏判。
            local is_token_mode=false
            if [ -f "${work_dir}/tunnel.yml" ] && ! grep -q '^credentials-file:' "${work_dir}/tunnel.yml" 2>/dev/null; then
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

            local _vless_bak _tunnel_yml_bak
            _vless_bak=$(mktemp) && cp "$inbounds_file" "$_vless_bak" || { red "备份配置文件失败，已取消"; sleep 2; return 0; }
            if [ -f "${work_dir}/tunnel.yml" ] && ! $is_token_mode; then
                _tunnel_yml_bak=$(mktemp) && cp "${work_dir}/tunnel.yml" "$_tunnel_yml_bak"
            fi

            if ! jq --argjson p "$new_port" \
                '(.inbounds[] | select(.tag=="vless-ws") | .listen_port) = $p' \
                "$inbounds_file" | write_json_atomic "$inbounds_file"; then
                rm -f "$_vless_bak" "$_tunnel_yml_bak"
                red "配置写入失败"; sleep 1; return 0
            fi

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
                    rm -f "$_vless_bak" "$_tunnel_yml_bak"
                    get_info
                    green "\nVLESS-Argo 端口已修改为：${new_port}\n"
                else
                    # sing-box 重启成功但 argo 隧道重启失败：新端口对隧道来说
                    # 是"半生效"状态（本地监听已切到新端口，但 argo 侧转发不通），
                    # 节点立即不可用。既然本次改动已经具备事务式回滚能力，这里
                    # 不能只报错了事，要把 inbounds.json / tunnel.yml 都恢复到
                    # 旧端口，再重启 sing-box + argo，尽量拉回到改动前的可用状态。
                    yellow "sing-box 已重启，但 argo 隧道重启失败，正在回滚端口配置…"
                    mv "$_vless_bak" "$inbounds_file"
                    [ -n "$_tunnel_yml_bak" ] && [ -f "$_tunnel_yml_bak" ] && mv "$_tunnel_yml_bak" "${work_dir}/tunnel.yml"
                    if restart_singbox; then
                        if restart_argo; then
                            red "\n已回滚到端口 ${old_port}，argo 隧道已恢复，请排查后重试\n"
                        else
                            red "\n已回滚到端口 ${old_port}，但 argo 隧道仍未能重启，请检查：journalctl -u argo -n 50 --no-pager\n"
                        fi
                    else
                        red "\n回滚后 sing-box 仍未启动，请检查：journalctl -u sing-box -n 50 --no-pager\n"
                    fi
                fi
            else
                yellow "sing-box 重启失败，正在回滚端口配置…"
                mv "$_vless_bak" "$inbounds_file"
                [ -n "$_tunnel_yml_bak" ] && [ -f "$_tunnel_yml_bak" ] && mv "$_tunnel_yml_bak" "${work_dir}/tunnel.yml"
                if restart_singbox; then
                    red "\n已回滚到端口 ${old_port}，请排查后重试\n"
                else
                    red "\n回滚后服务仍未启动，请检查：journalctl -u sing-box -n 50 --no-pager\n"
                fi
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
                        if ! [[ "$cfport" =~ ^[1-9][0-9]*$ ]] || (( cfport > 65535 )); then
                            cfport="443"
                        fi
                        # 若用户输入类似 ":8080" 这种，冒号前为空，cfip 会被解析成空字符串，
                        # 写入 CFIP= 空值会破坏 Argo 域名/IP 解析配置，此处兜底回退默认值
                        [ -z "$cfip" ] && cfip="cloudflare-ech.com"
                    else
                        cfip="$input"; cfport="443"
                    fi
                    ;;
            esac
            if ! _write_cf_env_key CFIP "$cfip" || ! _write_cf_env_key CFPORT "$cfport"; then
                red "\nCF 优选写入失败，请检查 ${work_dir}/cf.env 权限或磁盘空间\n"
                return 0
            fi
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

# 从文件里删除与给定字符串完全匹配的行（原子写入，mktemp 失败则静默跳过）
# 用法：_remove_line_from_file <file> <line>
_remove_line_from_file() {
    local file="$1" line="$2" tmp
    tmp=$(mktemp) || return 1
    grep -vxF "$line" "$file" > "$tmp" 2>/dev/null
    mv "$tmp" "$file"
}

_mark_protocol_removed() {
    local tag="$1"
    _ensure_protocols_list
    _remove_line_from_file "$protocols_list" "$tag"
}

# ── inbounds.json 读写工具（复用主脚本 jq 风格） ──
_add_inbound_json() {
    # $1 = 新 inbound 的 JSON 字符串
    local new_inbound="$1"
    jq --argjson nb "$new_inbound" '.inbounds += [$nb]' \
        "${conf_dir}/inbounds.json" | write_json_atomic "${conf_dir}/inbounds.json"
}

_remove_inbound_json() {
    local tag="$1"
    jq --arg t "$tag" '.inbounds |= map(select(.tag != $t))' \
        "${conf_dir}/inbounds.json" | write_json_atomic "${conf_dir}/inbounds.json"
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
    # 三个字段必须同时存在才算"已保存过完整配置"（历史遗留：旧版本脚本
    # 只存了 token/domain 两个字段，没有 zone_id，若只判断前两者会误判为
    # "已配置"，导致后续 acme.sh 因缺 zone_id 直接申请失败）。
    #
    # 注意：即使三项齐全，也不再在这里直接 return 0 静默复用 —— 之前的写法
    # 会导致"只要以前配过一次 acme，以后每次添加协议都被自动认定用 acme，
    # 完全没有机会选自签"，把"是否使用 acme"和"是否复用已保存凭证"这两件
    # 独立的事绑在了一起。现在无论是否已保存过配置，都先让用户在 1/2 之间
    # 选一次；选 acme 之后，如果检测到有已保存的完整凭证，才追加问一次
    # "是否直接复用"，用户仍可选择重新手动输入。
    local has_saved_cfg=false
    [ -n "$token" ] && [ -n "$domain" ] && [ -n "$zone_id" ] && has_saved_cfg=true

    # 本函数会在 _resolve_protocol_cert 的命令替换（$(...)）中被同步调用，
    # 该外层调用会把本函数（及其调用链上所有函数）打印到 stdout 的一切内容
    # 全部当成返回值捕获，混进最终的证书域名字符串，导致生成的节点链接里
    # sni 字段变成一整段提示文字（曾实际触发：sni 里出现"acme.sh 证书已就绪：
    # ..."这样的文本）。因此这里所有仅供人看的提示一律显式 >&2，不占用 stdout；
    # reading 系列不受影响——它们的提示文字通过内部 $(red "$1") 自行捕获，
    # 与本函数外层的 stdout 无关。
    echo "" >&2
    purple "该协议需要 TLS 证书。可选择：\n" >&2
    skyblue "1. 使用 acme 自动申请真实证书（需域名 + Cloudflare API Token/Zone ID，DNS 记录须为“仅 DNS”不走代理）" >&2
    skyblue "2. 使用自签证书（客户端需 insecure=1 跳过验证，配置更快）" >&2
    reading "请选择 (1/2，回车默认 2): " acme_choice

    if [ "$acme_choice" != "1" ]; then
        return 1
    fi

    if $has_saved_cfg; then
        # 已保存过完整配置（token/domain/zone_id 三项齐全）时静默复用，不再多问一次——
        # 用户已经在上面 1/2 里明确选了"要用 acme"，既然配置本来就在，没必要每次
        # 再确认一遍是否复用同一份。如需切换到新域名/Token，走管理菜单的
        # "e. 清除 acme 配置"手动清除后重新添加即可触发下面的手动输入分支。
        green "检测到已保存的 acme 配置（域名：${domain}），自动复用" >&2
        return 0
    fi

    reading "请输入用于该协议的子域名（如 node1.yourdomain.com，需已在 Cloudflare 解析到本机 IP 且为“仅 DNS”）: " domain
    if [ -z "$domain" ]; then
        yellow "域名为空，回退使用自签证书" >&2
        return 1
    fi
    if ! [[ "$domain" =~ ^[A-Za-z0-9._-]+\.[A-Za-z]{2,}$ ]]; then
        yellow "域名格式不合法，回退使用自签证书" >&2
        return 1
    fi
    reading "请输入 Cloudflare API Token（Zone:DNS:Edit 权限，仅作用于该域名）: " token
    if [ -z "$token" ]; then
        yellow "Token 为空，回退使用自签证书" >&2
        return 1
    fi
    echo "" >&2
    yellow "acme.sh 需要 Zone ID 才能定位到具体域名（Cloudflare 后台该域名的 Overview 页面右侧“API”栏可查看）" >&2
    reading "请输入 Cloudflare Zone ID: " zone_id
    if [ -z "$zone_id" ]; then
        yellow "Zone ID 为空，回退使用自签证书" >&2
        return 1
    fi

    if ! _write_cf_env_key CF_ACME_TOKEN "$token" || \
       ! _write_cf_env_key CF_ACME_DOMAIN "$domain" || \
       ! _write_cf_env_key CF_ACME_ZONE_ID "$zone_id"; then
        red "acme 配置写入失败，回退使用自签证书" >&2
        return 1
    fi
    green "acme 配置已保存（${work_dir}/cf.env，权限 600）" >&2
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
# 不写 "${HOME}/.acme.sh/acme.sh"：脚本已在开头强制 root 运行且顺带把
# HOME 锚定为 /root（见顶部 EUID 检查附近），但这里仍不直接引用 $HOME、
# 而是写死路径——双重保险：即便以后 HOME 锚定那行被移动或误删，本变量
# 依然不受影响，不会静默拼出 "/.acme.sh/acme.sh" 这种错误路径。
# 既然前提已确保是 root，直接写死更可靠。
_acme_sh_bin="/root/.acme.sh/acme.sh"

_ensure_acme_sh_installed() {
    # 标记文件：记录"默认 cron 清理"这一步是否已经做过，避免每次调用本函数
    # （备用协议里每添加一个用 acme 的协议都会调一次）都去扫一遍 crontab。
    # 用文件而非只判断 $_acme_sh_bin 是否存在，是因为可执行文件存在只能说明
    # "acme.sh 装过"，不能说明"默认 cron 清理这一步跑过"——机器上的 acme.sh
    # 可能是本脚本更早版本（还没有这段清理逻辑时）装的，也可能是用户自己或
    # 其他项目装的，这两种情况下可执行文件都已存在，但从未清理过默认 cron。
    local _acme_cron_cleaned_flag="${work_dir}/.acme_default_cron_cleaned"

    if [ -x "$_acme_sh_bin" ]; then
        if [ ! -f "$_acme_cron_cleaned_flag" ]; then
            _acme_sh_clean_default_cron
            touch "$_acme_cron_cleaned_flag" 2>/dev/null
        fi
        return 0
    fi
    yellow "首次使用 acme.sh，正在安装…" >&2
    # 不传 email 参数：acme.sh 官方文档确认该参数默认即为空，不是必需项。
    # 曾尝试用 hostname -f 拼邮箱，但多数云 VPS 的 hostname -f 只返回短主机名（如 "74"），
    # 拼出的 "acme@74" 不是合法邮箱格式，可能导致 CA 账号注册被拒——不传更安全。
    local _acme_installer _acme_install_log
    _acme_installer=$(mktemp)
    _acme_install_log=$(mktemp)
    if ! curl -fsSL https://get.acme.sh -o "$_acme_installer" 2>/dev/null; then
        red "acme.sh 安装脚本下载失败，请检查网络" >&2
        rm -f "$_acme_installer" "$_acme_install_log"
        return 1
    fi
    # 官方安装脚本会读取当前 $HOME 决定安装目录（装到 $HOME/.acme.sh），
    # 而本脚本读取可执行文件用的是写死的 /root/.acme.sh/acme.sh —— 如果调用
    # 环境的 $HOME 不是 /root（部分 su/sudo/容器场景可能出现），两边路径就会
    # 对不上，导致"装是装了，但在预期路径找不到"。显式锚定 HOME=/root 消除这个隐患。
    #
    # 不再传 --nocron：acme.sh 官方 install.sh 在直接调用并传长参数（--xxx）时
    # 有已知 bug，会把参数自身的 "--" 重复拼接一层，导致 "--nocron" 变成
    # "----nocron"，被当成未知参数、安装直接报错退出（GitHub 官方仓库
    # issue #3683 等多个反馈过同一现象，非本脚本调用方式导致）。规避方法是
    # 完全不给 install.sh 传任何长参数，装完之后再手动删除它自动创建的系统级
    # crontab 条目，效果与 --nocron 等价，且不会触发该参数解析 bug。
    if ! HOME=/root sh "$_acme_installer" >"$_acme_install_log" 2>&1; then
        red "acme.sh 安装失败，详情：" >&2
        tail -n 20 "$_acme_install_log" >&2
        rm -f "$_acme_installer" "$_acme_install_log"
        return 1
    fi
    rm -f "$_acme_installer"
    if [ ! -x "$_acme_sh_bin" ]; then
        red "acme.sh 安装后未找到可执行文件：${_acme_sh_bin}" >&2
        red "安装脚本输出（可能提示了实际安装位置）：" >&2
        tail -n 20 "$_acme_install_log" >&2
        rm -f "$_acme_install_log"
        return 1
    fi
    rm -f "$_acme_install_log"
    _acme_sh_clean_default_cron
    touch "$_acme_cron_cleaned_flag" 2>/dev/null
    green "acme.sh 安装完成" >&2
    return 0
}

# install.sh 默认会自动写入一条系统级 crontab（用于每日续期检查），但这条
# 任务固定使用默认 --home（/root/.acme.sh），读不到本脚本实际存放证书数据的
# 自定义 --home（${work_dir}/.acme.sh），执行了也没用，等同垃圾任务。
# 之前是靠传 --nocron 从源头不生成它，现在改为装完后手动清理，效果等价，
# 见上方大段注释里对 --nocron 参数解析 bug 的说明。
#
# 注意：这里必须用 _crontab_remove_matching（安全函数），不能直接写
# `crontab -l | grep -v ... | crontab -`。原因见该函数上方注释——crontab -l
# 一旦因瞬时异常返回空内容，grep -v 对空输入同样输出空，最终会把整个 root
# crontab 静默清空。
#
# 匹配串不能只用 "acme.sh --cron"：acme.sh 官方 install.sh 给任何一次
# 安装写入的系统级 crontab 都会包含这段固定文字，如果这台机器上还有
# 其他项目独立装过 acme.sh（哪怕装在别的 --home 目录下），这个粗粒度
# 匹配会连带把那些任务也删掉。acme.sh 写入 cron 时用的是它自己可执行
# 文件的完整路径来调用 --cron（不同 --home 对应不同路径），而本脚本的
# acme.sh 固定装在 $_acme_sh_bin（/root/.acme.sh/acme.sh），因此改为
# 匹配这个具体路径，只删本次安装自己写入的那一条，不影响机器上其他
# acme.sh 实例的续期任务。
_acme_sh_clean_default_cron() {
    command -v crontab >/dev/null 2>&1 || return 0
    _crontab_remove_matching "$_acme_sh_bin --cron"
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
        red "未找到 acme Cloudflare Token/Zone ID 配置" >&2
        return 1
    fi

    _ensure_acme_sh_installed || return 1

    local cert_dir="${work_dir}/acme/${domain}"
    mkdir -p "$cert_dir"

    # 显式为这个自定义 --home 目录设置默认 CA 为 Let's Encrypt。
    # 原因：--issue 时传的 --server letsencrypt 只在该 --home 下账号首次注册时生效；
    # 一旦 account.conf 已存在（哪怕是之前某次异常中途生成的坏状态），acme.sh 会优先读取
    # account.conf 里记录的 CA，命令行 --server 参数不会再覆盖它——2026-08 实测确认
    # 即便传了 --server letsencrypt，新版 acme.sh 仍可能先走默认的 ZeroSSL 前置流程。
    # --set-default-ca 不依赖账号是否已注册、可重复执行，幂等，因此每次签发前都跑一次，
    # 从根源上避免 --home 目录下的 CA 状态被错误地固化成 ZeroSSL。
    "$_acme_sh_bin" --set-default-ca --server letsencrypt \
        --home "${work_dir}/.acme.sh" >>"${work_dir}/acme.log" 2>&1

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
            red "acme.sh 证书申请失败，详情见 ${work_dir}/acme.log" >&2
            return 1
        fi
    fi

    if ! CF_Token="$token" CF_Zone_ID="$zone_id" \
        "$_acme_sh_bin" --install-cert -d "$domain" \
        --home "${work_dir}/.acme.sh" \
        --key-file "${cert_dir}/key.pem" \
        --fullchain-file "${cert_dir}/cert.pem" \
        --reloadcmd "true" >>"${work_dir}/acme.log" 2>&1; then
        red "acme.sh 证书安装失败，详情见 ${work_dir}/acme.log" >&2
        return 1
    fi

    if [ ! -s "${cert_dir}/cert.pem" ] || [ ! -s "${cert_dir}/key.pem" ]; then
        red "证书文件未正确生成：${cert_dir}" >&2
        return 1
    fi

    green "acme.sh 证书已就绪：${cert_dir}（自动续期由 acme.sh 自带 cron 处理）" >&2

    _ensure_acme_sync_cron "$domain"
    return 0
}

# 独立于 acme.sh 自带的 reloadcmd 机制，额外加两道保险：
#
# 1) 真正的续期检查：acme.sh 安装脚本默认会自动生成一条系统级 --cron 任务，
#    但它固定使用默认的 --home（如 /root/.acme.sh），与本脚本证书数据实际存放的
#    自定义 --home（${work_dir}/.acme.sh）是两个不同目录，无法读到我们的账号/证书数据，
#    实际上不会对这里申请的证书做任何续期检查（2026-08 DediRock 实测确认此现象）。
#    因此安装时已加 --nocron 从源头消除这条无用任务（见 _ensure_acme_sh_installed），
#    但自定义 --home 这个根本问题依然存在，所以这里仍需额外注册一条指向正确
#    --home 的 --cron 任务，确保续期检查真正生效——--nocron 只是去掉了原本
#    形同虚设的那一条，不代表这条自建任务可以省略。
#
# 2) 证书同步：部分环境下 acme.sh 续期时不会按预期重新执行 install-cert（社区有相关反馈，
#    行为不完全可靠），若证书续期了但未同步到 certificate_path 指向的文件，
#    sing-box 会一直用旧证书直到过期。每天定时主动重新执行一次 install-cert，
#    把最新证书强制同步到目标路径，即使 reloadcmd 没触发也能兜底。
_ensure_acme_sync_cron() {
    local domain="$1"

    # 1) 续期检查任务：整个 --home 目录级别只需注册一次，覆盖该目录下所有域名
    #    两条 cron 命令都加了 [ -d work_dir ] || exit 0 守卫：keep 模式卸载会保留
    #    这两条 cron（供重装后继续用），但 rm -rf work_dir 之后如果用户不重装，
    #    没有这个守卫的话，cron 会永久每天报错（acme.sh 二进制、--home 目录都已不存在）。
    local renew_marker="# sing-box-extra-protocols acme renew-check"
    if ! crontab -l 2>/dev/null | grep -qF "$renew_marker"; then
        local renew_cmd="[ -d '${work_dir}' ] || exit 0; '${_acme_sh_bin}' --cron --home '${work_dir}/.acme.sh' >>'${work_dir}/acme.log' 2>&1"
        _crontab_append_line "33 3 * * * ${renew_cmd} ${renew_marker}" \
            || yellow "读取现有 crontab 失败，已跳过本次续期检查任务注册（不会清空现有任务，可稍后重试）"
    fi

    # 2) 证书同步任务：按域名单独注册（不同协议若共用同一域名，第二次调用会因 marker 已存在而跳过）
    local sync_marker="# sing-box-extra-protocols acme sync: ${domain}"
    if crontab -l 2>/dev/null | grep -qF "$sync_marker"; then
        return 0
    fi
    local cert_dir="${work_dir}/acme/${domain}"
    local sync_cmd="[ -d '${work_dir}' ] || exit 0; CF_Token=\$(grep '^CF_ACME_TOKEN=' '${work_dir}/cf.env' | cut -d'=' -f2-) CF_Zone_ID=\$(grep '^CF_ACME_ZONE_ID=' '${work_dir}/cf.env' | cut -d'=' -f2-) '${_acme_sh_bin}' --install-cert -d '${domain}' --home '${work_dir}/.acme.sh' --key-file '${cert_dir}/key.pem' --fullchain-file '${cert_dir}/cert.pem' --reloadcmd true >>'${work_dir}/acme.log' 2>&1"
    _crontab_append_line "17 4 * * * ${sync_cmd} ${sync_marker}" \
        || yellow "读取现有 crontab 失败，已跳过本次证书同步任务注册（不会清空现有任务，可稍后重试）"
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
#
# 批量添加会话缓存：同一轮 select_extra_protocols 批量勾选多个协议时，
# 检测到旧凭证存档（UUID/密码/端口）时静默复用，不再询问——用户已经明确
# 表达过要保留节点身份（否则不会有存档存在）。如需重新生成全新凭证，
# 走管理菜单的"c. 清除旧配置存档"手动清除后重新添加即可。
_ask_reuse_creds() {
    local tag="$1" proto_name="$2"
    local old_json
    old_json=$(_read_protocol_creds "$tag")
    [ -z "$old_json" ] && return 1
    green "检测到 ${proto_name} 之前的配置（UUID/密码/端口），自动复用" >&2
    return 0
}

# 校验旧凭证存档字段是否合法：非空、非 JSON null 字面量
# 用法：_creds_field_valid "$val" 或 _creds_field_valid "$val" port（端口额外校验数字范围）
# 返回 0 = 合法，1 = 非法（调用方应回退为重新生成）
_creds_field_valid() {
    local val="$1" kind="$2"
    [ -z "$val" ] && return 1
    [ "$val" = "null" ] && return 1
    if [ "$kind" = "port" ]; then
        [[ "$val" =~ ^[0-9]+$ ]] || return 1
        (( val >= 1 && val <= 65535 )) || return 1
    fi
    return 0
}

# =========================================================
# _resolve_protocol_cert：TUIC/AnyTLS 等协议共用的证书获取逻辑
# 优先 acme.sh 申请真实证书；申请失败或未配置则回退复用现有自签 cert.pem / private.key
# 用法：acme_domain=$(_resolve_protocol_cert)
#   返回 0 → acme 可用，标准输出为证书域名
#   返回 1 → 回退使用自签证书（标准输出为空）
#   返回 2 → 两者都不可用，调用方应报错并 return 1
#
# 批量添加会话缓存：select_extra_protocols 一次勾选多个协议时（如 "13"），
# TUIC/AnyTLS 若都走 acme，此前会各自完整问一遍"acme/自签"+"是否复用已保存配置"，
# 而实际这两个问题在同一轮批量操作里答案必然相同（同一份 cf.env）。
# 缓存写入 _protocol_cert_cache_file（临时文件，不是变量）：调用方通过
# acme_domain=$(_resolve_protocol_cert) 这种命令替换捕获返回值，命令替换会
# fork 出子 shell 执行函数体，子 shell 内对普通变量的赋值不会传回父 shell，
# 用变量做跨调用缓存必然失效——只有写文件才能让状态跨越这层子 shell 边界。
# select_extra_protocols 在每次进入批量循环前删除该文件；单独从菜单添加
# 单个协议时文件本就不存在，行为与之前完全一致。
# =========================================================
_resolve_protocol_cert() {
    if [ -n "$_protocol_cert_cache_file" ] && [ -f "$_protocol_cert_cache_file" ]; then
        local cached_rc cached_domain
        cached_rc=$(sed -n '1p' "$_protocol_cert_cache_file")
        cached_domain=$(sed -n '2p' "$_protocol_cert_cache_file")
        [ -n "$cached_domain" ] && echo "$cached_domain"
        return "$cached_rc"
    fi
    local acme_domain
    if ensure_acme_config; then
        acme_domain=$(_read_cf_env_key CF_ACME_DOMAIN)
        # 先在装 inbound 之前就把证书申请完，申请失败直接中止，
        # 不会出现"配置已写入但 sing-box 启动时才发现证书拿不到"导致服务崩溃重启的情况
        # （2026-08 DediRock 曾因此触发 Let's Encrypt 限流，参见脚本内相关记录）。
        if _acme_sh_issue_cert "$acme_domain"; then
            echo "$acme_domain"
            [ -n "$_protocol_cert_cache_file" ] && printf '0\n%s\n' "$acme_domain" > "$_protocol_cert_cache_file"
            return 0
        fi
        yellow "acme 证书申请失败，回退使用自签证书" >&2
    fi
    if [ -f "${work_dir}/cert.pem" ] && [ -f "${work_dir}/private.key" ]; then
        [ -n "$_protocol_cert_cache_file" ] && printf '1\n\n' > "$_protocol_cert_cache_file"
        return 1
    fi
    [ -n "$_protocol_cert_cache_file" ] && printf '2\n\n' > "$_protocol_cert_cache_file"
    return 2
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
    acme_domain=$(_resolve_protocol_cert)
    case $? in
        0) use_acme=true ;;
        1) : ;;
        *) red "未找到证书文件，请先安装 sing-box 主体（VLESS+Hysteria2）"; return 1 ;;
    esac

    local port uuid password
    if _ask_reuse_creds tuic "TUIC v5"; then
        local old_json
        old_json=$(_read_protocol_creds tuic)
        uuid=$(jq -r '.uuid' <<< "$old_json")
        password=$(jq -r '.password' <<< "$old_json")
        port=$(jq -r '.port' <<< "$old_json")
        if ! _creds_field_valid "$uuid" \
           || ! _creds_field_valid "$password" \
           || ! _creds_field_valid "$port" port; then
            yellow "旧配置存档已损坏，改为生成全新配置"
            port=$(pick_free_udp_port) || { red "无法分配空闲 UDP 端口"; return 1; }
            uuid=$(cat /proc/sys/kernel/random/uuid)
            password=$(openssl rand -hex 16)
        else
            # 旧端口若已被占用（比如期间装了别的服务），自动换新端口，不阻塞流程
            if _port_in_use "$port" udp; then
                yellow "旧端口 ${port} 已被占用，自动分配新端口"
                port=$(pick_free_udp_port) || { red "无法分配空闲 UDP 端口"; return 1; }
            fi
            green "已复用 TUIC 旧配置（UUID/密码不变，客户端链接可能仅端口变化）"
        fi
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
        if ! _creds_field_valid "$uuid" || ! _creds_field_valid "$port" port; then
            yellow "旧配置存档已损坏，改为生成全新配置"
            port=$(pick_free_tcp_port) || { red "无法分配空闲 TCP 端口"; return 1; }
            uuid=$(cat /proc/sys/kernel/random/uuid)
        else
            if _port_in_use "$port" tcp; then
                yellow "旧端口 ${port} 已被占用，自动分配新端口"
                port=$(pick_free_tcp_port) || { red "无法分配空闲 TCP 端口"; return 1; }
            fi
            green "已复用 Reality 旧配置（UUID/密钥对不变，客户端链接可能仅端口变化）"
        fi
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
    # 同 TUIC：先申请证书，成功了再生成 inbound，避免证书问题拖垮整个服务
    acme_domain=$(_resolve_protocol_cert)
    case $? in
        0) use_acme=true ;;
        1) : ;;
        *) red "未找到证书文件，请先安装 sing-box 主体（VLESS+Hysteria2）"; return 1 ;;
    esac

    local port password
    if _ask_reuse_creds anytls "AnyTLS"; then
        local old_json
        old_json=$(_read_protocol_creds anytls)
        password=$(jq -r '.password' <<< "$old_json")
        port=$(jq -r '.port' <<< "$old_json")
        if ! _creds_field_valid "$password" || ! _creds_field_valid "$port" port; then
            yellow "旧配置存档已损坏，改为生成全新配置"
            port=$(pick_free_tcp_port) || { red "无法分配空闲 TCP 端口"; return 1; }
            password=$(openssl rand -hex 16)
        else
            if _port_in_use "$port" tcp; then
                yellow "旧端口 ${port} 已被占用，自动分配新端口"
                port=$(pick_free_tcp_port) || { red "无法分配空闲 TCP 端口"; return 1; }
            fi
            green "已复用 AnyTLS 旧配置（密码不变，客户端链接可能仅端口变化）"
        fi
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
        _remove_line_from_file "${work_dir}/protocols_acme.list" "$tag"
    fi

    # 若该域名不再被任何已装协议使用，清理对应的证书同步 cron 任务，避免残留垃圾任务
    if [ -n "$_removed_acme_domain" ] && [ "$_removed_acme_domain" != "null" ]; then
        if ! jq -e --arg d "$_removed_acme_domain" \
            '.inbounds[] | select(.tls.server_name == $d)' \
            "${conf_dir}/inbounds.json" >/dev/null 2>&1; then
            _crontab_remove_matching "# sing-box-extra-protocols acme sync: ${_removed_acme_domain}"
        fi
        # 若已没有任何协议在使用 acme，续期检查任务也一并清理
        if [ ! -s "${work_dir}/protocols_acme.list" ]; then
            _crontab_remove_matching "# sing-box-extra-protocols acme renew-check"
        fi
    fi

    green "${EXTRA_PROTO_NAME[$tag]:-$tag} 已删除（UUID/密码/端口配置已保留，重新添加时可选择复用）"
}

# =========================================================
# 选择菜单：安装时或单独调用，多选（空格分隔）
# =========================================================
select_extra_protocols() {
    clear; echo ""
    purple "=== 选择要添加的备用协议 ===\n"
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
    reading "请输入序号（直接连写数字，如 13，回车取消）: " choices

    [ -z "$choices" ] && { purple "已跳过\n"; return 1; }

    # 协议数量固定为个位数，序号直接连写即可（如 "13"），仍兼容空格分隔（如 "1 3"）
    local compact="${choices// /}"
    local c idx j
    # acme 证书选择（1/2 + 域名/Token/Zone ID）的批量会话缓存（见 _resolve_protocol_cert
    # 顶部注释）：本轮批量添加中，TUIC/AnyTLS 若都走 acme，第一个协议问完 1/2 之后
    # 缓存结果，同轮内后续协议直接复用，不再重复问。必须用临时文件而非变量——
    # _resolve_protocol_cert 是通过 $(...) 命令替换调用的，子 shell 内变量赋值传不回父 shell。
    # 旧凭证复用（UUID/密码/端口）已改为只要存档存在就静默复用，不再询问，
    # 故不再需要类似缓存。
    _protocol_cert_cache_file=$(mktemp)
    rm -f "$_protocol_cert_cache_file"  # 只借用一个不会重名的临时路径，文件本身按需生成
    # 记录本轮批量新增（而非之前就已装好、这轮只是跳过）的协议 tag：
    # add_protocol_tuic/reality/anytls 各自只负责写 inbound、放行端口、
    # 标记 protocols.list（可能还有 protocols_acme.list + acme cron），
    # 并不在函数内部各自重启 sing-box——真正让配置生效的重启统一放在本函数
    # 最后一次性做。这意味着如果重启失败，需要能把"这一轮新增的"协议整体
    # 撤回，而不能动本来就已经装好、这轮没碰过的协议。
    local _added_this_batch=()
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
        local _already_installed=false
        is_protocol_installed "$tag" && _already_installed=true
        case "$tag" in
            tuic)    add_protocol_tuic ;;
            reality) add_protocol_reality ;;
            anytls)  add_protocol_anytls ;;
        esac
        # 只有"这轮之前未安装、这轮成功新装上了"的才需要在失败时回滚；
        # 已经装过的（is_protocol_installed 提前判 true，函数内部会打印
        # "已安装，跳过" 并直接 return）不能被记进回滚列表，否则重启失败时
        # 会把用户本来就在用的协议误删掉。
        if ! $_already_installed && is_protocol_installed "$tag"; then
            _added_this_batch+=("$tag")
        fi
    done
    rm -f "$_protocol_cert_cache_file"
    unset _protocol_cert_cache_file

    if [ ${#_added_this_batch[@]} -eq 0 ]; then
        # 本轮没有任何协议被成功新增（全部是已安装跳过，或全部因证书/端口
        # 等原因添加失败），没有新配置需要生效，不必重启，避免无意义重启
        # 打断正在运行的服务。
        return 0
    fi

    check_singbox &>/dev/null
    if [ $? -eq 2 ]; then
        # sing-box 主体尚未安装：备用协议的 inbound 已经写进 inbounds.json，
        # 但主体安装流程本身还没跑完、还没有"重启后应该正常"这个前提，这里
        # 重启没有意义，交由后续 do_install 统一处理。
        return 0
    fi
    if restart_singbox; then
        green "\n已应用新增协议配置\n"
        get_info
    else
        red "\n协议已写入配置，但 sing-box 重启失败，正在回滚本轮新增的协议…"
        local _rb_tag
        for _rb_tag in "${_added_this_batch[@]}"; do
            remove_protocol "$_rb_tag"
        done
        if restart_singbox; then
            red "已回滚本轮新增协议，服务已恢复到添加前状态，请排查后重试\n"
        else
            red "回滚后服务仍未启动，请检查：journalctl -u sing-box -n 50 --no-pager\n"
        fi
    fi
    return 0
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
        # acme 配置（Cloudflare Token/域名/Zone ID）独立于协议身份存档，
        # 二者分开清除：c 只清 UUID/密码/端口这类节点身份，不动 acme 凭证，
        # 避免清一个的时候误把另一个也带走。
        local has_acme_cfg=false
        if [ -f "${work_dir}/cf.env" ]; then
            local _e_tok _e_dom _e_zid
            _e_tok=$(_read_cf_env_key CF_ACME_TOKEN)
            _e_dom=$(_read_cf_env_key CF_ACME_DOMAIN)
            _e_zid=$(_read_cf_env_key CF_ACME_ZONE_ID)
            [ -n "$_e_tok" ] || [ -n "$_e_dom" ] || [ -n "$_e_zid" ] && has_acme_cfg=true
        fi
        $has_acme_cfg && yellow "e. 清除 acme 配置（Cloudflare Token/域名/Zone ID，清除后重新添加将改为询问证书类型）"
        purple "0. 返回主菜单"
        skyblue "------------"
        reading "请输入选择: " choice

        case "$choice" in
            a|A)
                select_extra_protocols
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
                # 删除前备份 inbounds.json 和 protocols.list，供 restart 失败时事务回滚。
                # restart 发生在所有删除动作完成后（批量），必须在循环前备份原始状态。
                local _del_proto_bak _del_plist_bak
                _del_proto_bak=$(mktemp) && cp "${conf_dir}/inbounds.json" "$_del_proto_bak" \
                    || { red "备份配置文件失败，已取消删除"; continue; }
                _del_plist_bak=$(mktemp) && cp "${work_dir}/protocols.list" "$_del_plist_bak" \
                    || { rm -f "$_del_proto_bak"; red "备份协议列表失败，已取消删除"; continue; }
                # protocols_acme.list 同样需要纳入这次事务：remove_protocol() 内部会调用
                # _remove_line_from_file 修改它（把被删协议从 acme 列表里摘掉），如果只
                # 备份/回滚了 inbounds.json 和 protocols.list，restart 失败回滚后会出现
                # "协议已经恢复，但 acme 列表里仍然少了这个协议"的不一致状态，以后这个
                # 协议再涉及证书续期/同步判断时会跟实际配置对不上。
                # 该文件不一定存在（没有协议用过 acme 时不会创建），空值表示"删除前不存在"，
                # 回滚时据此决定是恢复内容还是直接删掉本次流程中新建出来的文件。
                local _del_acme_bak=""
                if [ -f "${work_dir}/protocols_acme.list" ]; then
                    _del_acme_bak=$(mktemp) && cp "${work_dir}/protocols_acme.list" "$_del_acme_bak" \
                        || { rm -f "$_del_proto_bak" "$_del_plist_bak"; red "备份 ACME 协议列表失败，已取消删除"; continue; }
                fi
                local _del_ports=()  # 记录被删的端口/协议，回滚时重新放行
                for (( j=0; j<${#del_compact}; j++ )); do
                    c="${del_compact:$j:1}"
                    [[ "$c" =~ ^[0-9]$ ]] || continue
                    idx=$((c - 1))
                    [ "$idx" -lt 0 ] || [ "$idx" -ge "${#EXTRA_PROTO_ORDER[@]}" ] && continue
                    dtag="${EXTRA_PROTO_ORDER[$idx]}"
                    local _dp _dproto
                    _dp=$(jq -r --arg t "$dtag" '.inbounds[] | select(.tag==$t) | .listen_port' \
                        "${conf_dir}/inbounds.json" 2>/dev/null)
                    _dproto="${EXTRA_PROTO_TRANSPORT[$dtag]:-tcp}"
                    remove_protocol "$dtag"
                    [ -n "$_dp" ] && [ "$_dp" != "null" ] && _del_ports+=("${_dp}/${_dproto}")
                done
                if restart_singbox; then
                    rm -f "$_del_proto_bak" "$_del_plist_bak" "$_del_acme_bak"
                    get_info
                else
                    red "\n协议删除后 sing-box 重启失败，正在回滚…"
                    mv "$_del_proto_bak" "${conf_dir}/inbounds.json"
                    mv "$_del_plist_bak" "${work_dir}/protocols.list"
                    if [ -n "$_del_acme_bak" ]; then
                        mv "$_del_acme_bak" "${work_dir}/protocols_acme.list"
                    else
                        # 备份为空说明这次流程开始前 protocols_acme.list 本就不存在；
                        # 若删除过程中被新建出来（例如 _remove_line_from_file 之类的
                        # 实现在文件不存在时可能隐式创建空文件），回滚时应一并去掉，
                        # 否则会凭空多出一个删除前并不存在的文件。
                        rm -f "${work_dir}/protocols_acme.list"
                    fi
                    # remove_protocol() 删除一个用 acme 的协议时，不只是改 protocols_acme.list，
                    # 还会顺手清理对应的 acme 续期/同步 cron（该域名不再被任何协议使用时删同步任务，
                    # protocols_acme.list 清空时删续期检查任务）——这两步都是直接操作 crontab，
                    # 不在上面几个文件回滚的覆盖范围内。所以配置文件回滚后，这里要按恢复后的
                    # protocols_acme.list + inbounds.json 重新推导一遍"现在应该有哪些 acme cron"，
                    # 对每个仍在用 acme 的域名重新调用 _ensure_acme_sync_cron——它本身是幂等的
                    # （靠 marker 判断是否已存在），已存在则直接跳过，不会产生重复任务，也不会
                    # 动到用户其他跟 sing-box 无关的 crontab 内容。
                    if [ -s "${work_dir}/protocols_acme.list" ]; then
                        local _rb_tag _rb_domain
                        while IFS= read -r _rb_tag; do
                            [ -z "$_rb_tag" ] && continue
                            _rb_domain=$(jq -r --arg t "$_rb_tag" \
                                '.inbounds[] | select(.tag == $t) | .tls.server_name' \
                                "${conf_dir}/inbounds.json" 2>/dev/null)
                            [ -n "$_rb_domain" ] && [ "$_rb_domain" != "null" ] \
                                && _ensure_acme_sync_cron "$_rb_domain"
                        done < "${work_dir}/protocols_acme.list"
                    fi
                    # 恢复防火墙：重新放行被删掉的端口
                    for _rp in "${_del_ports[@]}"; do
                        allow_port "$_rp"
                    done
                    if restart_singbox; then
                        red "已回滚到删除前状态，请排查后重试\n"
                    else
                        red "回滚后服务仍未启动，请检查：journalctl -u sing-box -n 50 --no-pager\n"
                    fi
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
            e|E)
                if ! $has_acme_cfg; then
                    yellow "当前没有可清除的 acme 配置"; sleep 1; continue
                fi
                yellow "将清除已保存的 Cloudflare Token / 域名 / Zone ID，仅影响以后新证书申请，不影响已签发证书的现有有效期"
                reading "确定清除 acme 配置？此操作不可恢复 (y/N): " confirm_clear_acme
                if [[ "$confirm_clear_acme" =~ ^[yY]$ ]]; then
                    if [ -f "${work_dir}/cf.env" ]; then
                        sed -i '/^CF_ACME_TOKEN=/d;/^CF_ACME_DOMAIN=/d;/^CF_ACME_ZONE_ID=/d' "${work_dir}/cf.env"
                    fi
                    green "acme 配置已清除，下次添加需 acme 证书的协议时将重新询问"
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
        if ! _creds_field_valid "$uuid" || ! _creds_field_valid "$pass" || ! _creds_field_valid "$port" port; then
            yellow "TUIC 配置字段异常（inbounds.json 可能已损坏），跳过生成该节点链接"
        elif _protocol_uses_acme tuic; then
            sni=$(jq -r '.inbounds[] | select(.tag=="tuic") | .tls.server_name' "${conf_dir}/inbounds.json")
            if ! _creds_field_valid "$sni"; then
                yellow "TUIC 证书域名字段异常（inbounds.json 可能已损坏），跳过生成该节点链接"
            else
                # acme 真实证书，标准 TLS 验证。显式写 insecure=0（而非省略该字段），
                # 避免依赖客户端在字段缺省时的隐含默认行为（勇哥/fscarmen 脚本同样显式写 0，已验证更可靠）。
                ip_links+=$'\n'"tuic://${uuid}:${pass}@${server_ip}:${port}?sni=${sni}&alpn=h3&congestion_control=bbr&insecure=0&allowInsecure=0&allow_insecure=0#${node_prefix} tuic-ip"
                domain_links+=$'\n'"tuic://${uuid}:${pass}@${sni}:${port}?sni=${sni}&alpn=h3&congestion_control=bbr&insecure=0&allowInsecure=0&allow_insecure=0#${node_prefix} tuic-domain"
            fi
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
        if ! _creds_field_valid "$uuid" || ! _creds_field_valid "$port" port \
           || ! _creds_field_valid "$sni" || ! _creds_field_valid "$pub" || ! _creds_field_valid "$sid"; then
            yellow "Reality 配置字段异常（inbounds.json 可能已损坏），跳过生成该节点链接"
        else
            # Reality 走伪装握手，本身不依赖真实域名解析，始终只用 IP 直连
            ip_links+=$'\n'"vless://${uuid}@${server_ip}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${pub}&sid=${sid}&type=tcp&headerType=none#${node_prefix} reality"
        fi
    fi

    if is_protocol_installed anytls; then
        local port pass sni
        port=$(jq -r '.inbounds[] | select(.tag=="anytls") | .listen_port' "${conf_dir}/inbounds.json")
        pass=$(jq -r '.inbounds[] | select(.tag=="anytls") | .users[0].password' "${conf_dir}/inbounds.json")
        if ! _creds_field_valid "$pass" || ! _creds_field_valid "$port" port; then
            yellow "AnyTLS 配置字段异常（inbounds.json 可能已损坏），跳过生成该节点链接"
        elif _protocol_uses_acme anytls; then
            sni=$(jq -r '.inbounds[] | select(.tag=="anytls") | .tls.server_name' "${conf_dir}/inbounds.json")
            if ! _creds_field_valid "$sni"; then
                yellow "AnyTLS 证书域名字段异常（inbounds.json 可能已损坏），跳过生成该节点链接"
            else
                # acme 真实证书，标准 TLS 验证。显式写 insecure=0，避免依赖客户端缺省行为
                # （实测 Egern 在 anytls:// 链接缺省 insecure 字段时，界面会显示"跳过验证=开"，
                # 显式写 0 后应能纠正该显示状态，参考勇哥脚本同款写法）。
                ip_links+=$'\n'"anytls://${pass}@${server_ip}:${port}?sni=${sni}&insecure=0&allowInsecure=0#${node_prefix} anytls-ip"
                domain_links+=$'\n'"anytls://${pass}@${sni}:${port}?sni=${sni}&insecure=0&allowInsecure=0#${node_prefix} anytls-domain"
            fi
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
    [ $? -eq 2 ] && { yellow "sing-box 尚未安装！"; sleep 1; return 0; }

    local arch
    arch=$(detect_arch) || return 0

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
        return 0
    fi

    reading "确认升级到 v${latest_ver}？(y/n): " confirm
    [[ "$confirm" != [yY] ]] && { purple "已取消\n"; return 0; }

    local tmp_dest
    tmp_dest=$(mktemp)
    if ! download_singbox "$arch" "$latest_ver" "$tmp_dest"; then
        rm -f "$tmp_dest"
        red "下载失败，请检查网络"
        return 0
    fi

    if ! stop_singbox; then
        rm -f "$tmp_dest"
        red "sing-box 停止失败，已取消升级（服务可能处于异常状态，请先检查：journalctl -u sing-box -n 50 --no-pager）"
        return 0
    fi

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
    if ! command_exists jq; then
        red "缺少依赖 jq，无法解析 JSON 凭据，请先安装 sing-box（会自动装好 jq）或手动安装 jq"
        return 0
    fi
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
        # 先验证 JSON 格式合法且包含必要字段，再落盘，避免写入坏文件。
        if ! echo "$argo_auth" | jq empty 2>/dev/null; then
            red "输入内容不是合法 JSON，请重新检查后粘贴"; return 0
        fi
        local tunnel_id
        tunnel_id=$(echo "$argo_auth" \
            | jq -r '(.TunnelID // .tunnelID // .tunnel_id) // empty' 2>/dev/null)
        local tunnel_secret
        tunnel_secret=$(echo "$argo_auth" \
            | jq -r '(.TunnelSecret // .tunnelSecret // .tunnel_secret) // empty' 2>/dev/null)
        if [ -z "$tunnel_id" ] || [ -z "$tunnel_secret" ]; then
            red "JSON 中未找到 TunnelID 或 TunnelSecret 字段，请检查凭据格式"; return 0
        fi
        # 写入 JSON 模式前先清掉 Token 模式可能残留的 argo_token，避免
        # change_config 等处依赖"文件是否存在"判断模式时被旧文件误导，
        # 导致以为还是 Token 模式、走错分支（改端口静默失效等问题）。
        rm -f "${work_dir}/argo_token"
        echo "$argo_auth" > "${work_dir}/tunnel.json"
        chmod 600 "${work_dir}/tunnel.json"

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

    elif [[ "$argo_auth" =~ ^[A-Za-z0-9+/=._-]{30,500}$ ]]; then
        # 写入 Token 模式前先清掉 JSON 模式可能残留的 tunnel.json，理由同上。
        rm -f "${work_dir}/tunnel.json"
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
    if ! systemctl enable argo; then
        yellow "⚠ argo 设置开机自启失败，重启 VPS 后可能不会自动拉起隧道，请检查：systemctl status argo"
    fi
    if restart_argo; then
        sleep 2
        get_info
        green "\n固定隧道配置完成，域名：${argo_domain}\n"
        return 0
    else
        red "\n隧道配置已写入，但 argo 服务重启失败，节点当前不可用"
        red "请检查：journalctl -u argo -n 50 --no-pager\n"
        return 1
    fi
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
        1) is_fixed_tunnel_configured || { yellow "尚未配置固定隧道，请先选择 4 配置"; return 0; }
           start_argo;   return 0 ;;
        2) stop_argo;    return 0 ;;
        3) is_fixed_tunnel_configured || { yellow "尚未配置固定隧道，请先选择 4 配置"; return 0; }
           restart_argo; return 0 ;;
        4) configure_fixed_tunnel; return 0 ;;
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
        # rm -f "${backup_dir}"/* 对目录会直接报错跳过（"Is a directory"），
        # 且 * 通配符默认不匹配隐藏文件，acme/、.acme.sh/、protocol_creds/ 这几个目录
        # 都会被漏掉、残留旧内容，导致重复"卸载保留配置"时新旧数据混杂
        # （已实测验证：单纯换成 rm -rf 依然会漏掉 .acme.sh 这种隐藏目录）。
        # 用 find 逐项清空，能正确处理隐藏文件和子目录。
        find "$backup_dir" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2>/dev/null

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
        [ -f "${work_dir}/sshd_af_added.flag" ] && cp "${work_dir}/sshd_af_added.flag" "${backup_dir}/sshd_af_added.flag"
        # autofix 日志记录了"哪个系统文件的哪一行被自动注释过"，必须随节点配置
        # 一起备份，否则重装后这份日志随 work_dir 一起被删，将来彻底卸载时
        # restore_autofixed_lines 找不到日志，被自动注释的系统配置行会永久
        # 恢复不回来。
        [ -f "$BBR_AUTOFIX_LOG" ]  && cp "$BBR_AUTOFIX_LOG"  "${backup_dir}/bbr-autofix.log"
        [ -f "$IPV6_AUTOFIX_LOG" ] && cp "$IPV6_AUTOFIX_LOG" "${backup_dir}/ipv6-autofix.log"
        chmod -R go-rwx "$backup_dir" 2>/dev/null

        if [ -s "${backup_dir}/inbounds.json" ]; then
            # 之前这里要求 inbounds.json 和 cert.pem 同时存在才算备份成功，缺 cert.pem
            # 就整个 backup_dir 一起 rm -rf 删掉。但 cert.pem 只在"用过自签证书"时才会
            # 生成 —— 协议全部改用 acme 真实证书后，系统里根本不存在这个文件，属于
            # 正常场景却被当成"备份失败"，导致已经拷贝好的 argo_token、tunnel.yml、
            # cf.env 等全部被一起清空（实际复现过：三个备用协议都用 acme 证书后卸载，
            # backup_dir 因缺 cert.pem 被判定失败、整个目录被删，重装后 Argo 隧道因缺
            # token 无法启动）。inbounds.json 才是节点配置是否备份下来的关键标志，
            # cert.pem 缺失只是提示一下、不影响备份整体成败。
            if [ -s "${backup_dir}/cert.pem" ]; then
                green "节点配置与证书已备份至 ${backup_dir}，重装时将自动检测并询问是否恢复"
            else
                yellow "提示：未检测到自签证书（cert.pem），如协议均使用 acme 证书属正常现象"
                green "节点配置已备份至 ${backup_dir}，重装时将自动检测并询问是否恢复"
            fi
            BACKUP_SUCCESS=true
        else
            red "备份失败（inbounds.json 缺失），将按未保留配置继续卸载"
            rm -rf "$backup_dir" 2>/dev/null
        fi
    else
        rm -rf "$backup_dir" 2>/dev/null
        # 彻底卸载（不保留配置）时才清理 acme 相关的 cron 任务（续期检查 + 证书同步）；
        # 保留配置场景下这些任务在重装恢复后仍需继续运行，不能清
        _crontab_remove_matching "# sing-box-extra-protocols acme"

        # 彻底卸载时同时恢复安装脚本对系统层做过的改动，语义是"恢复原状"：
        # - 禁用 IPv6 的 sysctl 配置
        # - BBR 调优 sysctl 配置
        # - initcwnd/initrwnd 调优（独立的 systemd service + 脚本，不在 sysctl.d 里，
        #   之前漏了这一步，导致"彻底卸载"后 initcwnd 32 依然每次开机生效）
        # - sshd 限制为仅监听 IPv4（AddressFamily inet，仅在本脚本添加时才删）
        rm -f /etc/sysctl.d/99-disable-ipv6.conf /etc/sysctl.d/99-wot-proxy-tuning.conf
        # 只删本脚本明确创建的 .bak.* 文件，不用通配符扫全目录，避免误删其他
        # 软件或用户手工生成的同名备份。
        # - sysctl.d 下的 .bak.* 由 bbr_clean/IPv6 autofix 生成，
        #   restore_autofixed_lines 内部会清理 IPV6_AUTOFIX_LOG 记录的行，
        #   bbr_restore_autofixed_lines 也同样；剩余 sysctl.d .bak.* 保留不动。
        bbr_remove_initcwnd
        bbr_restore_autofixed_lines
        restore_autofixed_lines "$IPV6_AUTOFIX_LOG"
        # 只有本脚本在 setup_firewall_base() 中添加过 AddressFamily inet 才删除；
        # 若用户原本就有这一行，卸载时不应动它。
        # 判断依据：work_dir 内的标记文件 sshd_af_added.flag（安装时写入，见 setup_firewall_base）。
        if [ -f "${work_dir}/sshd_af_added.flag" ]; then
            if grep -q "^AddressFamily inet" /etc/ssh/sshd_config 2>/dev/null; then
                sed -i '/^AddressFamily inet/d' /etc/ssh/sshd_config
                if sshd -t 2>/dev/null; then
                    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null
                else
                    yellow "警告：移除 sshd AddressFamily inet 后配置测试失败，请手动检查 /etc/ssh/sshd_config"
                fi
            fi
        fi
        sysctl --system >/dev/null 2>&1
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
bash <(curl -fsSL ${SCRIPT_URL}) "\$@"
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
        mkdir -p "${work_dir}"
        # 先备份当前版本，这样下面写入失败或用户想回退时还有真正的旧版本可用。
        # 之前直接 mv $tmp 没有任何备份，"已回滚"的提示是误导——下载失败时旧文件
        # 还在，下载成功后写入失败才是真正的问题点；有了备份后两种情况都能恢复。
        local bak_path="${work_dir}/sb.sh.bak"
        [ -f "${work_dir}/sb.sh" ] && cp "${work_dir}/sb.sh" "$bak_path" 2>/dev/null
        if ! mv "$tmp" "${work_dir}/sb.sh"; then
            rm -f "$tmp"
            [ -f "$bak_path" ] && mv "$bak_path" "${work_dir}/sb.sh"
            red "更新失败：无法写入 ${work_dir}/sb.sh，已回滚到旧版本\n"
            return 1
        fi
        chmod +x "${work_dir}/sb.sh"
        ln -sf "${work_dir}/sb.sh" /usr/bin/sb
        rm -f "$bak_path"
        green "脚本已更新，请重新运行 sb\n"
        exit 0
    else
        rm -f "$tmp"
        red "更新失败：下载内容异常，本地脚本未变动\n"
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

                local ssh_ports
                ssh_ports=$(ss -tlnpH 2>/dev/null | awk '/sshd/{print $4}' | grep -oE '[0-9]+$' | sort -un | paste -sd, -)
                [ -z "$ssh_ports" ] && ssh_ports=$(grep -E '^[[:space:]]*Port[[:space:]]+' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | sort -un | paste -sd, -)
                [ -z "$ssh_ports" ] && ssh_ports=22

                cat > /etc/fail2ban/jail.local << EOF
[sshd]
enabled  = true
port     = ${ssh_ports}
backend  = systemd
maxretry = 5
bantime  = 3600
findtime = 600
EOF
                systemctl enable fail2ban
                systemctl restart fail2ban
                if systemctl is-active fail2ban &>/dev/null; then
                    green "\nfail2ban 已启用，正在保护 SSH 端口 ${ssh_ports}\n"
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
BBR_INITCWND_UNIT="/etc/systemd/system/wot-initcwnd.service"
BBR_INITCWND_SCRIPT="/usr/local/sbin/wot-initcwnd.sh"
# 自动注释冲突配置的记录（文件路径<TAB>行号），关闭调优/卸载时据此恢复原状；
# BBR 和 IPv6 各自独立，避免互相漏恢复。
BBR_AUTOFIX_LOG="/etc/sing-box/bbr-autofix.log"
IPV6_AUTOFIX_LOG="/etc/sing-box/ipv6-autofix.log"

# initcwnd/initrwnd 是路由属性，不是 sysctl 参数，写不进 BBR_CONF 那份 sysctl.d 文件里，
# 必须用 ip route 单独设置。作用：新连接建立时首波无需等 ACK 就能发送的包数，
# 内核默认约 10（≈14.6KB）。调到 32（≈46.7KB）能让"打开网页/切换应用"这类短连接
# 的首屏数据更可能一次发完，少等一个 RTT —— 到高延迟节点（150-200ms+）时这个提速
# 是能感知到的；对追求跑满带宽的大文件/长连接场景则没有实际收益。
# 只在带宽较低（≤100Mbps）的链路上需要谨慎：首波突发有概率打穿限速器/令牌桶，
# 反而引发首秒重传。100Mbps 以上机器一般不必担心。
#
# 路由重启会重置，所以要单独做持久化：写一个开机跑的 systemd 服务，
# 每次开机现查网关和网卡（不能写死 IP，网关地址可能变），失败也不报错中断开机流程。
bbr_apply_initcwnd() {
    local gw iface
    gw=$(ip route show default 2>/dev/null | awk '{print $3; exit}')
    iface=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
    if [ -z "$gw" ] || [ -z "$iface" ]; then
        yellow "未找到默认路由网关，跳过 initcwnd 设置\n"
        return 1
    fi
    if ! ip route replace default via "$gw" dev "$iface" initcwnd 32 initrwnd 32 2>/dev/null; then
        yellow "initcwnd 设置失败（部分虚拟化平台不支持），跳过\n"
        return 1
    fi
    cat > "$BBR_INITCWND_SCRIPT" << 'EOF'
#!/bin/bash
# 由 sing-box.sh 网络调优模块生成，开机时重新应用 initcwnd/initrwnd
GW=$(ip route show default 2>/dev/null | awk '{print $3; exit}')
IF=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
[ -n "$GW" ] && [ -n "$IF" ] && ip route replace default via "$GW" dev "$IF" initcwnd 32 initrwnd 32
exit 0
EOF
    chmod +x "$BBR_INITCWND_SCRIPT"
    cat > "$BBR_INITCWND_UNIT" << EOF
[Unit]
Description=wot-proxy initcwnd/initrwnd tuning
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${BBR_INITCWND_SCRIPT}

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable --now wot-initcwnd.service >/dev/null 2>&1
    return 0
}

bbr_remove_initcwnd() {
    local gw iface
    gw=$(ip route show default 2>/dev/null | awk '{print $3; exit}')
    iface=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
    systemctl disable --now wot-initcwnd.service >/dev/null 2>&1
    rm -f "$BBR_INITCWND_UNIT" "$BBR_INITCWND_SCRIPT"
    systemctl daemon-reload >/dev/null 2>&1
    # 尝试把路由恢复成不带 initcwnd/initrwnd 的状态（去掉持久化即可防止开机重设，
    # 这里额外把当前运行时的路由也顺手清掉，避免用户不重启就一直带着旧值）。
    if [ -n "$gw" ] && [ -n "$iface" ]; then
        ip route replace default via "$gw" dev "$iface" 2>/dev/null
    fi
}

bbr_get_status() {
    local cc qdisc initcwnd_state
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    if ip route show default 2>/dev/null | grep -q 'initcwnd 32'; then
        initcwnd_state="initcwnd=32"
    else
        initcwnd_state="initcwnd=默认"
    fi
    if [ -f "$BBR_CONF" ]; then
        local scenario
        scenario=$(grep -m1 "^# 场景:" "$BBR_CONF" 2>/dev/null | sed 's/^# 场景: *//')
        if [ -n "$scenario" ]; then
            echo "本脚本调优: 已启用 (${cc} + ${qdisc} + ${initcwnd_state})，当前场景: ${scenario}"
        else
            echo "本脚本调优: 已启用 (${cc} + ${qdisc} + ${initcwnd_state})"
        fi
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

# 只处理"BBR_CONF 里实际写了、且生效值跟 BBR_CONF 不一致"的那些参数键，
# 不做模糊关键词匹配 —— 避免像 bbr_clean 那样误伤 conntrack、端口范围等无关配置。
# 静默执行、自动备份后注释，不需要用户确认，供 bbr_write_conf 在写完配置后立即调用。
bbr_autofix_conflicts() {
    local conf="$1" key val actual line fixed_any=0
    # 同一次调用里，同一个文件只在第一次要修改它时备份一次（备份的是这次自动清理
    # 开始前的最初状态），本次调用中对同一文件的后续注释不再重复备份，避免同一
    # 文件在一轮处理里产生多份"中间状态"备份。用一个以换行分隔的字符串记录本次
    # 已经备份过的文件路径（bash 3 兼容写法，不依赖关联数组）。
    local backed_up_files=$'\n'
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        key=$(echo "$line" | sed -E 's/^([^=]+)=.*/\1/' | xargs)
        val=$(echo "$line" | sed -E 's/^[^=]+=(.*)$/\1/' | xargs)
        [ -z "$key" ] && continue
        actual=$(sysctl -n "$key" 2>/dev/null | xargs)
        [ -z "$actual" ] && continue          # 内核不支持这个参数，跳过
        [ "$actual" = "$val" ] && continue    # 生效值已经和期望一致，无需处理

        # 生效值不一致，说明有别的文件在覆盖 —— 逐个文件检查是否定义了这个 key
        # 且值不同，是的话注释掉那一行。/usr/lib/sysctl.d/ 属于系统包管理，不动。
        local f
        for f in /etc/sysctl.d/*.conf /etc/sysctl.conf; do
            [ -f "$f" ] || continue
            [ "$f" = "$conf" ] && continue
            [[ "$f" == *.bak || "$f" =~ \.bak\.[0-9]+$ ]] && continue
            grep -qE "^[[:space:]]*${key//./\\.}[[:space:]]*=" "$f" 2>/dev/null || continue
            if [[ "$backed_up_files" != *$'\n'"$f"$'\n'* ]]; then
                rm -f "${f}.bak."[0-9]*
                cp "$f" "${f}.bak.$(date +%Y%m%d%H%M%S)"
                backed_up_files="${backed_up_files}${f}"$'\n'
            fi
            local ln
            while IFS=: read -r ln; do
                [ -z "$ln" ] && continue
                mkdir -p "$(dirname "$BBR_AUTOFIX_LOG")" 2>/dev/null
                printf '%s\t%s\n' "$f" "$ln" >> "$BBR_AUTOFIX_LOG"
            done < <(grep -nE "^[[:space:]]*${key//./\\.}[[:space:]]*=" "$f" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*#' | cut -d: -f1)
            sed -i -E "/^[[:space:]]*#/! s|^([[:space:]]*${key//./\\.}[[:space:]]*=.*)\$|# [由sing-box.sh自动清理] \1|" "$f"
            fixed_any=1
        done
        # /usr/lib/sysctl.d/ 只提示不动手
        local libf
        for libf in /usr/lib/sysctl.d/*.conf; do
            [ -f "$libf" ] || continue
            grep -qE "^[[:space:]]*${key//./\\.}[[:space:]]*=" "$libf" 2>/dev/null || continue
            yellow "提示：${libf}（系统/厂商配置）中也定义了 ${key}，脚本不会修改该文件；如仍有冲突请手动处理。"
        done
    done < <(grep -E '^net\.|^kernel\.|^vm\.|^fs\.' "$conf" 2>/dev/null)

    if [ "$fixed_any" = 1 ]; then
        sysctl --system >/dev/null 2>&1
        yellow "检测到其他配置文件覆盖了本次调优参数，已自动注释冲突行并重新加载（原文件已备份为 .bak.时间戳，仅保留最新一份）\n"
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
net.ipv4.tcp_slow_start_after_idle = 0

# ── 以下参数按 RTT 分档（≥120ms 用 16384，否则 32768） ──
net.ipv4.tcp_notsent_lowat = ${notsent_lowat}

# ── 以下为固定参数，与硬件规格/场景无关，任何机器统一使用 ──
net.ipv4.tcp_autocorking = 0
net.ipv4.tcp_no_metrics_save = 0
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
EOF
    # 统一显式写回标准 Linux 默认值：如果这台机器之前跑过老版本脚本
    # 或曾应用过激进参数组，这些参数已经被改过，仅仅"配置文件里不写"不会让内核
    # 恢复默认——sysctl --system 只应用文件里存在的键，未写的键维持
    # 现状。这里显式写回标准 Linux 默认值使其真正复位。
    # tcp_max_tw_buckets 的内核默认值随内存大小变化、无统一常量，这里
    # 不做重置；如此前应用过激进参数组，请重启使其恢复内核自动计算的
    # 默认值。
    cat >> "$BBR_CONF" << EOF

# ── 显式重置为内核默认值（避免此前激进参数组/旧版本脚本的残留）──
net.ipv4.tcp_fin_timeout = 60
net.ipv4.tcp_retries2 = 15
net.ipv4.tcp_syn_retries = 6
net.ipv4.tcp_synack_retries = 5
net.ipv4.tcp_orphan_retries = 0
net.ipv4.tcp_mtu_probing = 0
EOF
    sysctl --system >/dev/null 2>&1
    # 先做一次自动冲突消除：只要 BBR_CONF 里写的参数和实际生效值不一致，
    # 说明别的文件在覆盖它（sysctl.d 内按文件名排序、sysctl.conf 最后加载），
    # 自动定位到那些文件里的对应行、备份后注释掉，不需要用户再手动跑扫描/清理。
    bbr_autofix_conflicts "$BBR_CONF"
    local cc qdisc rmem
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    rmem=$(sysctl -n net.core.rmem_max 2>/dev/null)
    if [ "$cc" = "bbr" ] && [ "$qdisc" = "fq" ] && [ "$rmem" = "$buf" ]; then
        green "\n已应用「${desc}」\n拥塞控制: ${cc}    队列: ${qdisc}    缓冲区上限: ${rmem}    notsent_lowat: ${notsent_lowat}\n"
    else
        red "\n配置已写入，但验证异常 (拥塞控制=${cc}, 队列=${qdisc}, 缓冲区=${rmem}，期望值=${buf})\n请检查是否有其他文件覆盖了此设置（可用「扫描冲突配置」查看）\n"
    fi
    local initcwnd_choice
    reading "是否同时启用 initcwnd/initrwnd=32（加快短连接首屏，低带宽/有限速的链路不建议）？(y/N): " initcwnd_choice
    if [[ "$initcwnd_choice" =~ ^[yY]$ ]]; then
        if bbr_apply_initcwnd; then
            green "initcwnd/initrwnd: 32（已设置并持久化，短连接首屏更快）\n"
        fi
    else
        bbr_remove_initcwnd >/dev/null 2>&1
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
    [ "$choice" = "0" ] && return 1
    case "$choice" in
        1) bbr_write_conf 8388608 "日常场景 (8MB)" 150 ;;
        2) bbr_write_conf 33554432 "大文件/下载场景 (32MB)" 200 ;;
        3) bbr_write_conf 4194304 "低延迟场景 (4MB)" 50 ;;
        4)
            reading "请输入带宽 (Mbps): " bw
            if ! [[ "$bw" =~ ^[1-9][0-9]*$ ]]; then
                red "输入无效，请输入正整数"
                return 0
            fi
            reading "请输入预估RTT毫秒 (不清楚直接回车，默认150ms): " rtt
            [ -z "$rtt" ] && rtt=150
            if ! [[ "$rtt" =~ ^[1-9][0-9]*$ ]]; then
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

restore_autofixed_lines() {
    # $1 = 日志路径。按"文件+行号"精确恢复，不用 .bak 整份回滚。
    local log="$1"
    [ -f "$log" ] || return 0
    local file line restored=0
    while IFS=$'\t' read -r file line; do
        [ -z "$file" ] && continue
        [ -z "$line" ] && continue
        [ -f "$file" ] || continue
        if sed -n "${line}p" "$file" 2>/dev/null | grep -qE '^[[:space:]]*# \[由sing-box\.sh(自动清理|注释)\] '; then
            sed -i -E "${line}s~^([[:space:]]*)# \[由sing-box\.sh(自动清理|注释)\] ~\1~" "$file"
            restored=1
        fi
    done < "$log"
    if [ "$restored" = 1 ]; then
        sysctl --system >/dev/null 2>&1
        yellow "已恢复此前被自动注释的其他配置文件中的原始设置\n"
    fi
    rm -f "$log"
}

bbr_restore_autofixed_lines() {
    restore_autofixed_lines "$BBR_AUTOFIX_LOG"
}

bbr_disable() {
    if [ ! -f "$BBR_CONF" ] && [ ! -f "$BBR_INITCWND_UNIT" ]; then
        yellow "\n未检测到本脚本生成的调优配置，无需关闭\n"
        return 0
    fi
    reading "确定要关闭本脚本的调优配置吗? 将恢复系统默认值 (y/n): " confirm
    if [[ "$confirm" == [yY] ]]; then
        local ts
        if [ -f "$BBR_CONF" ]; then
            ts=$(date +%Y%m%d%H%M%S)
            mv "$BBR_CONF" "${BBR_CONF}.bak.${ts}"
        fi
        bbr_remove_initcwnd
        bbr_restore_autofixed_lines
        sysctl --system >/dev/null 2>&1
        if [ -n "$ts" ]; then
            green "\n已关闭，配置已备份为 ${BBR_CONF}.bak.${ts}\n"
        else
            green "\n已关闭（仅清理了 initcwnd 持久化配置，未发现 sysctl 调优文件）\n"
        fi
    else
        purple "已取消"
    fi
    return 0
}

bbr_scan() {
    clear; echo ""
    green "=== 扫描现有配置中的网络调优相关设置 ===\n"
    yellow "(只读，不会做任何修改)\n"

    declare -gA BBR_SCAN_FILES=()
    local files
    files=$(grep -rlE "$BBR_KEYWORDS" /etc/sysctl.d/ /etc/sysctl.conf /usr/lib/sysctl.d/ 2>/dev/null)
    if [ -z "$files" ]; then
        yellow "未发现相关配置文件。"
        return 0
    fi

    local idx=0
    for f in $files; do
        idx=$((idx + 1))
        BBR_SCAN_FILES[$idx]="$f"
        if [ "$f" = "$BBR_CONF" ]; then
            skyblue "[${idx}] ${f}  ← 本脚本生成的配置（用「关闭调优」处理，不在此清理）"
        elif [[ "$f" == *.bak || "$f" =~ \.bak\.[0-9]+$ ]]; then
            skyblue "[${idx}] ${f}  ← 历史备份文件，不会被系统加载"
        elif [ -z "$(grep -E "$BBR_KEYWORDS" "$f" 2>/dev/null | grep -v '^[[:space:]]*#')" ]; then
            skyblue "[${idx}] ${f}  ← 已全部处理为注释，无需再清理"
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
    yellow "本功能不会整份删除文件，只会自动注释掉扫描到的冲突网络参数那一行，其余内容保持不变。"
    yellow "本脚本自己的配置、历史备份文件（.bak）、已处理过的文件会自动跳过，无需你判断。\n"

    reading "确认自动清理以上所有冲突文件？(y/N): " confirm_clean
    if [[ ! "$confirm_clean" =~ ^[yY]$ ]]; then
        purple "已取消"
        return 0
    fi

    local n target
    for n in "${!BBR_SCAN_FILES[@]}"; do
        target="${BBR_SCAN_FILES[$n]}"

        if [ "$target" = "$BBR_CONF" ]; then
            yellow "跳过 ${target}（本脚本自己的配置，请用「关闭调优」处理）"
            continue
        fi
        # 历史备份文件命名为 .bak.时间戳（如 xxx.conf.bak.20260716034523），
        # 不会被 sysctl 加载，处理它毫无意义；旧版判断只匹配纯 ".bak" 结尾，
        # 漏掉了这种真实生成的命名格式，导致脚本自己生成的备份被反复重新处理、
        # 越积越多。这里改用能同时匹配两种格式的写法。
        if [[ "$target" == *.bak || "$target" =~ \.bak\.[0-9]+$ ]]; then
            yellow "跳过 ${target}（历史备份文件，不会被系统加载，无实际影响）"
            continue
        fi
        # /usr/lib/sysctl.d/ 属于系统包管理，不修改，只提示
        if [[ "$target" == /usr/lib/sysctl.d/* ]]; then
            yellow "跳过 ${target}（系统/厂商配置，本脚本不会修改，如有冲突请手动处理）"
            continue
        fi
        # 若文件里涉及关键字的行已经全部是注释状态，说明之前处理过、当前不再生效，
        # 无需重复处理（避免产生没有意义的新备份文件）
        if ! grep -qE "$BBR_KEYWORDS" "$target" 2>/dev/null || \
           [ -z "$(grep -E "$BBR_KEYWORDS" "$target" 2>/dev/null | grep -v '^[[:space:]]*#')" ]; then
            yellow "跳过 ${target}（相关配置已全部是注释状态，无需重复处理）"
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
    echo   "==============="
    green  "13. 备用协议管理 (TUIC/Reality/AnyTLS)"
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
    yellow "本脚本按 IPv4 VPS 场景设计，正在禁用 IPv6…"
    if [ ! -f /etc/sysctl.d/99-disable-ipv6.conf ]; then
        yellow "检测到未禁用 IPv6，正在禁用…"
    fi
    cat > /etc/sysctl.d/99-disable-ipv6.conf << 'EOF'
# 禁用 IPv6（sing-box 脚本添加）
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
    sysctl --system &>/dev/null

    # 验证是否真的禁用；不一致说明有其他文件（云厂商镜像自带的 ipv6.conf 等）
    # 在 99-disable-ipv6.conf 之后加载、把值又覆盖回去了，自动定位并注释掉那些行，
    # 不能只打印警告了事 —— 之前就出现过 all/default/lo 全部显示 0 但用户毫无察觉的情况。
    if [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" = "1" ]; then
        green "IPv6 已在内核层禁用"
    else
        yellow "检测到 IPv6 禁用被其他配置文件覆盖，正在自动排查…"
        local ipv6_key ipv6_fixed=0
        for ipv6_key in net.ipv6.conf.all.disable_ipv6 net.ipv6.conf.default.disable_ipv6 net.ipv6.conf.lo.disable_ipv6; do
            [ "$(sysctl -n "$ipv6_key" 2>/dev/null)" = "1" ] && continue
            local f
            for f in /etc/sysctl.d/*.conf /etc/sysctl.conf; do
                [ -f "$f" ] || continue
                [ "$f" = "/etc/sysctl.d/99-disable-ipv6.conf" ] && continue
                [[ "$f" == *.bak || "$f" =~ \.bak\.[0-9]+$ ]] && continue
                grep -qE "^[[:space:]]*${ipv6_key//./\\.}[[:space:]]*=[[:space:]]*0" "$f" 2>/dev/null || continue
                # 使用时间戳追加备份，不删除已有的 .bak.* 文件——旧备份可能来自其他工具，
                # 删除会丢失用户之前的恢复点，且该文件此前可能已在本轮循环中被备份过了。
                cp "$f" "${f}.bak.$(date +%Y%m%d%H%M%S)"
                local ipv6_ln
                while IFS=: read -r ipv6_ln; do
                    [ -z "$ipv6_ln" ] && continue
                    mkdir -p "$(dirname "$IPV6_AUTOFIX_LOG")" 2>/dev/null
                    printf '%s\t%s\n' "$f" "$ipv6_ln" >> "$IPV6_AUTOFIX_LOG"
                done < <(grep -nE "^[[:space:]]*${ipv6_key//./\\.}[[:space:]]*=[[:space:]]*0" "$f" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*#' | cut -d: -f1)
                sed -i -E "/^[[:space:]]*#/! s|^([[:space:]]*${ipv6_key//./\\.}[[:space:]]*=.*)\$|# [由sing-box.sh自动清理] \1|" "$f"
                ipv6_fixed=1
            done
            # /usr/lib/sysctl.d/ 属于系统包管理范围，不直接修改，只提示。
            local libf
            for libf in /usr/lib/sysctl.d/*.conf; do
                [ -f "$libf" ] || continue
                grep -qE "^[[:space:]]*${ipv6_key//./\\.}[[:space:]]*=[[:space:]]*0" "$libf" 2>/dev/null || continue
                yellow "提示：${libf}（系统/厂商配置）中也将 ${ipv6_key} 设为 0，脚本不会修改该文件。"
            done
        done
        if [ "$ipv6_fixed" = 1 ]; then
            sysctl --system &>/dev/null
        fi
        if [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" = "1" ]; then
            green "已自动清理冲突配置，IPv6 现已在内核层禁用（原文件已备份为 .bak.时间戳）"
        else
            red "自动清理后 IPv6 仍未成功禁用，请手动检查 /etc/sysctl.d/ 下的相关文件"
        fi
    fi

    # sshd 只监听 IPv4（reload 不断当前连接）
    if ! grep -q "^AddressFamily inet" /etc/ssh/sshd_config; then
        sed -i '/^AddressFamily/d' /etc/ssh/sshd_config
        echo "AddressFamily inet" >> /etc/ssh/sshd_config
        if sshd -t 2>/dev/null; then
            systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
            green "sshd 已设置为仅监听 IPv4（reload）"
            # 记录"这一行是本脚本添加的"，卸载时据此决定是否删除，
            # 避免误删用户原本就存在的 AddressFamily inet 行。
            touch "${work_dir}/sshd_af_added.flag" 2>/dev/null
        else
            yellow "sshd 配置测试失败，回滚 AddressFamily 设置"
            sed -i '/^AddressFamily inet/d' /etc/ssh/sshd_config
        fi
    fi

    # ── 2. IPv6 防火墙 ──
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
    # destination-unreachable（含 fragmentation-needed）和 time-exceeded 必须放行，
    # 否则 PMTUD 失效：发送端收不到"包太大需要分片"的通知，UDP 协议
    # （Hysteria2/TUIC 均基于 UDP，无 TCP MSS 协商机制）在路径 MTU 较小的
    # 链路（如经过 Argo/Cloudflare 隧道）上会出现大包黑洞、握手卡死
    iptables -A INPUT -p icmp --icmp-type destination-unreachable -j ACCEPT 2>/dev/null || true
    iptables -A INPUT -p icmp --icmp-type time-exceeded -j ACCEPT 2>/dev/null || true
    iptables -A INPUT -p icmp -j DROP 2>/dev/null || true

    # ── 8. 放行 SSH 端口（优先 sshd_config，兜底 ss 探测；sshd 可能配置多个 Port，全部放行）──
    local ssh_ports
    ssh_ports=$(grep -E '^[[:space:]]*Port[[:space:]]+' /etc/ssh/sshd_config 2>/dev/null \
        | awk '{print $2}' | sort -un)
    [ -z "$ssh_ports" ] && ssh_ports=$(ss -tlnpH 2>/dev/null \
        | awk '/sshd/{print $4}' | grep -oE '[0-9]+$' | sort -un)
    if [ -z "$ssh_ports" ]; then
        ssh_ports=22
        yellow "警告：未检测到 sshd 监听端口，默认放行 22"
    fi
    local _ssh_port
    while IFS= read -r _ssh_port; do
        [ -z "$_ssh_port" ] && continue
        iptables -A INPUT -p tcp --dport "$_ssh_port" -j ACCEPT 2>/dev/null || true
    done <<< "$ssh_ports"

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
        # 不依赖固定列号（不同 ss/iproute2 版本、不同长度的 Recv-Q/Send-Q
        # 都可能导致按空格数取列错位），改为用正则精确抓 "本地地址:端口"，
        # 即紧跟在 State/Recv-Q/Send-Q 之后、Peer Address:Port 之前的那一段。
        # 地址段可能带 %接口名（如 127.0.0.53%lo:53）或是 [ipv6]:port，
        # 用 [^[:space:]]+ 兜住这些变体，只靠冒号+纯数字端口来锚定末尾。
        addr=$(echo "$line" | grep -oE '[^[:space:]]+:[0-9]+[[:space:]]+[^[:space:]]+:[0-9*]+' \
            | awk '{print $1}')
        port=$(echo "$addr"  | grep -oE '[0-9]+$')
        proto=$(echo "$line" | awk '{print $1}' | sed 's/6$//')
        proc=$(echo "$line"  | grep -oE 'users:\(\("[^"]+' \
            | grep -oE '"[^"]+' | tr -d '"')

        # 跳过 loopback（含 127.x.x.x、127.x.x.x%接口名、::1）
        echo "$addr" | grep -qE '^127\.|^\[::1\][:\[]?|^::1[:\[]' && continue
        # 跳过 IPv6 监听（反正全 DROP 了）
        echo "$addr" | grep -qE '^\[' && continue
        # 跳过 argo
        echo "$proc" | grep -qE '(cloudflared|argo)' && continue

        if [ -z "$port" ]; then
            yellow "  警告：无法解析端口，跳过：$line"
            continue
        fi

        # 端口号必须是 1-65535 的合法值，解析异常（如误取到 Send-Q 列的 0）
        # 直接跳过，避免生成 --dport 0 这种无意义的防火墙规则
        if [ "$port" -eq 0 ] || [ "$port" -gt 65535 ]; then
            yellow "  警告：解析到异常端口号 ($port)，跳过该行：$line"
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
            local p_port p_proto p_proc reply tty_ok=false
            p_port=$(echo "$entry"  | cut -d'|' -f1)
            p_proto=$(echo "$entry" | cut -d'|' -f2)
            p_proc=$(echo "$entry"  | cut -d'|' -f3)
            echo ""
            skyblue "  端口：${p_port}/${p_proto}  进程：${p_proc}"
            printf "  是否放行？[Y/n] "
            # 没有可用的 /dev/tty（如 docker exec 无终端）或 read 失败（EOF）时，
            # 强制按"拒绝"处理，不能落进下面 [Y/n] 的默认分支——那样等于把
            # "默认拒绝未知端口"的设计意图变成了"没有终端就自动全部放行"。
            # 真正拿到用户输入时（哪怕直接回车留空），仍按提示语标注的
            # [Y/n]（回车默认放行）来走，不改变正常交互体验。
            if [ -r /dev/tty ] && read -r reply </dev/tty; then
                tty_ok=true
            fi
            if ! $tty_ok; then
                yellow "  无法读取终端输入，按默认拒绝处理，跳过 ${p_port}/${p_proto}"
                continue
            fi
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

    install_packages jq openssl curl || { red "基础依赖安装失败，请检查网络或软件源"; return 1; }
    # iproute2 单独处理：install_packages 假定"参数名==命令名"（对 jq/openssl/curl
    # 成立），但 iproute2 这个包提供的命令是 ss，两者不一致，直接混进上面那行会导致
    # command_exists 永远查不到、每次都误判为未安装。ss 被 _port_in_use、SSH 端口
    # 探测等多处依赖，标准 Ubuntu/Debian 镜像通常已预装，这里只在缺失时才装。
    if ! command_exists ss; then
        yellow "未检测到 ss（iproute2），正在安装…"
        apt-get install -y iproute2 || { red "iproute2 安装失败，请检查网络或软件源"; return 1; }
    fi

    yellow "正在查询 sing-box 最新版本…"
    local install_ver
    install_ver=$(get_latest_sb_version)
    if [ -z "$install_ver" ]; then
        yellow "无法获取最新版本，使用内置版本 ${SB_VERSION}"
        install_ver="$SB_VERSION"
    else
        green "将安装最新版本 v${install_ver}"
    fi

    if ! install_singbox "$install_ver"; then
        red "\n核心安装步骤失败（详情见上方输出），已中止，未继续生成服务配置\n"
        return 1
    fi
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
        if [ "${RESTORE_DECLINED:-false}" = true ]; then
            # 用户主动选择不恢复备份，不是恢复失败，无需警告，按原样保留备份目录
            [ -d "$backup_dir" ] && true
        elif $backup_has_token && [ "${ARGO_TOKEN_RESTORED:-false}" != true ]; then
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
    if jq '
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
    ' "$route_file" | write_json_atomic "$route_file"; then
        if restart_singbox; then
            green "大陆域名拦截已默认开启"
        else
            yellow "大陆域名拦截规则已写入，但 sing-box 重启失败，可能未生效（不影响后续流程，可稍后手动检查）"
        fi
    else
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
        if [[ "$2" == "-y" || "$2" == "--yes" ]]; then
            yellow "正在无交互卸载 sing-box…\n"
        else
            reading "即将彻底卸载 sing-box（不保留配置备份），确认继续？(y/N): " _uninstall_confirm
            if [[ "$_uninstall_confirm" != [yY] ]]; then
                yellow "已取消卸载"
                exit 0
            fi
        fi
        _do_uninstall_core false
        green "\nsing-box 卸载完成\n"
        ;;
    -c|--check)
        check_nodes
        ;;
    -h|--help)
        echo ""
        green "用法: sb [参数]"
        green "  -i, --install         安装"
        green "  -u, --uninstall       卸载（会二次确认）"
        green "  -u, --uninstall -y    卸载（跳过确认，供脚本调用）"
        green "  -c, --check           查看节点"
        green "  -h, --help            帮助"
        green "  （无参数）            交互菜单"
        echo ""
        ;;
    "")
        while true; do
            menu
            reading "请输入选择(0-13): " choice
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
                    if manage_extra_protocols; then need_pause=true; else need_pause=false; fi
                    ;;
                0) exit 0 ;;
                *) red "无效选项，请输入 0-13" ;;
            esac
            [ "$need_pause" = true ] && { read -n1 -s -r -p $'\033[1;91m按任意键返回…\033[0m' || exit 0; }
            echo ""
        done
        ;;
    *)
        red "未知参数: $1"
        green "用法: sb [-i|-u|-c|-h]"
        exit 1
        ;;
esac
