#!/usr/bin/env bash
# =============================================================================
# MosDNS v5 + AdGuardHome 自动化部署脚本
# 适用系统: Ubuntu / Debian (x86_64 / arm64 / armv7)
# 功能: 国内外 DNS 分流，国外 IPv4 优先
# 用法: sudo bash deploy.sh
# =============================================================================

set -euo pipefail

# ---- 颜色输出 ----------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ---- 版本配置（可手动改为最新版本）------------------------------------------
MOSDNS_VERSION="v5.3.4"
# AdGuardHome 使用官方安装脚本，自动获取最新版

# ---- 安装路径 ----------------------------------------------------------------
MOSDNS_DIR="/opt/mosdns"
AGH_DIR="/opt/AdGuardHome"

# ---- 检查 root ---------------------------------------------------------------
[[ $EUID -ne 0 ]] && error "请以 root 权限运行: sudo bash $0"

# ---- 检测架构 ----------------------------------------------------------------
detect_arch() {
  local arch
  arch=$(uname -m)
  case $arch in
    x86_64)  echo "amd64" ;;
    aarch64) echo "arm64" ;;
    armv7*)  echo "armv7" ;;
    armv6*)  echo "armv6" ;;
    *)       error "不支持的架构: $arch" ;;
  esac
}
ARCH=$(detect_arch)
info "检测到架构: $ARCH"

# ---- 安装依赖 ----------------------------------------------------------------
install_deps() {
  info "安装系统依赖..."
  apt-get update -qq
  apt-get install -y -qq curl wget unzip jq
}

# ---- 修复 systemd-resolved（释放 53 端口）-----------------------------------
fix_systemd_resolved() {
  info "配置 systemd-resolved，释放 53 端口..."
  mkdir -p /etc/systemd/resolved.conf.d
  cat > /etc/systemd/resolved.conf.d/adguardhome.conf <<EOF
[Resolve]
DNS=127.0.0.1
DNSStubListener=no
EOF
  if [[ -f /etc/resolv.conf && ! -L /etc/resolv.conf ]]; then
    mv /etc/resolv.conf /etc/resolv.conf.backup
    ln -s /run/systemd/resolve/resolv.conf /etc/resolv.conf
  fi
  systemctl reload-or-restart systemd-resolved
  info "systemd-resolved 已重新配置"
}

# ---- 安装 MosDNS ------------------------------------------------------------
install_mosdns() {
  info "安装 MosDNS ${MOSDNS_VERSION}..."
  local url="https://github.com/IrineSistiana/mosdns/releases/download/${MOSDNS_VERSION}/mosdns-linux-${ARCH}.zip"
  local tmp_dir
  tmp_dir=$(mktemp -d)
  wget -q --show-progress -O "${tmp_dir}/mosdns.zip" "$url"
  unzip -q "${tmp_dir}/mosdns.zip" -d "${tmp_dir}"
  mkdir -p "${MOSDNS_DIR}/ip"
  install -m 755 "${tmp_dir}/mosdns" "${MOSDNS_DIR}/mosdns"
  ln -sf "${MOSDNS_DIR}/mosdns" /usr/local/bin/mosdns
  rm -rf "${tmp_dir}"
  info "MosDNS 安装完成: ${MOSDNS_DIR}/mosdns"
}

# ---- 下载 IP/域名规则列表 ---------------------------------------------------
download_rules() {
  info "下载 IP 和域名规则列表..."
  local ip_dir="${MOSDNS_DIR}/ip"
  cd "${ip_dir}"

  # 国内 IP 列表
  wget -q --show-progress -O geoip_cn.txt \
    "https://raw.githubusercontent.com/IceCodeNew/4Share/master/geoip_china/china_ip_list.txt"

  # 国内直连域名
  wget -q --show-progress -O geosite_cn.txt \
    "https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/direct-list.txt"

  # 国外/被墙域名
  wget -q --show-progress -O geosite_geolocation-gfw.txt \
    "https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/proxy-list.txt"

  # 默认 hosts
  echo "localhost 127.0.0.1" > "${MOSDNS_DIR}/ip/hosts.txt"

  info "规则列表下载完成"
}

# ---- 生成 MosDNS 配置 -------------------------------------------------------
write_mosdns_config() {
  info "生成 MosDNS 配置文件..."
  cat > "${MOSDNS_DIR}/config.yaml" <<'EOF'
log:
  level: error
  file: "/opt/mosdns/log.log"

api:
  http: "127.0.0.1:9091"

plugins:
  # ---- 自定义 hosts ----
  - tag: mosdns_hosts
    type: hosts
    args:
      files:
        - "/opt/mosdns/ip/hosts.txt"

  # ---- 国内 DNS (DoT) ----
  - tag: forward_local
    type: forward
    args:
      concurrent: 3
      upstreams:
        - addr: "tls://223.5.5.5"        # 阿里
          enable_pipeline: false
        - addr: "tls://1.12.12.12"        # 腾讯 DNSPod
          enable_pipeline: true
        - addr: "tls://120.53.53.53"      # 腾讯备用
          enable_pipeline: true

  # ---- 国外 DNS (DoT, IPv4 优先) ----
  - tag: forward_remote
    type: forward
    args:
      concurrent: 3
      upstreams:
        - addr: "tls://8.8.8.8"           # Google
          enable_pipeline: true
        - addr: "tls://1.1.1.1"           # Cloudflare
          enable_pipeline: true
        - addr: "tls://208.67.222.222"    # OpenDNS
          enable_pipeline: true

  # ---- 域名集合 ----
  - tag: geosite_cn
    type: domain_set
    args:
      files:
        - "/opt/mosdns/ip/geosite_cn.txt"

  - tag: geosite_no_cn
    type: domain_set
    args:
      files:
        - "/opt/mosdns/ip/geosite_geolocation-gfw.txt"

  # ---- IP 集合 ----
  - tag: geoip_cn
    type: ip_set
    args:
      files:
        - "/opt/mosdns/ip/geoip_cn.txt"

  # ---- 缓存 ----
  - tag: lazy_cache
    type: cache
    args:
      size: 20000
      lazy_cache_ttl: 86400
      dump_file: "/opt/mosdns/cache.dump"
      dump_interval: 600

  # ---- 国内解析 ----
  - tag: local_sequence
    type: sequence
    args:
      - exec: $forward_local

  # ---- 国外解析（prefer_ipv4 保证 IPv4 优先）----
  - tag: remote_sequence
    type: sequence
    args:
      - exec: prefer_ipv4
      - exec: $forward_remote

  # ---- 有响应则终止 ----
  - tag: has_resp_sequence
    type: sequence
    args:
      - matches: has_resp
        exec: accept

  # ---- Fallback: 本地返回非国内 IP 则丢弃响应 ----
  - tag: query_is_local_ip
    type: sequence
    args:
      - exec: $local_sequence
      - matches: "!resp_ip $geoip_cn"
        exec: drop_resp

  - tag: query_is_remote
    type: sequence
    args:
      - exec: $remote_sequence

  # ---- Fallback 插件 ----
  - tag: fallback
    type: fallback
    args:
      primary: query_is_local_ip
      secondary: query_is_remote
      threshold: 500
      always_standby: true

  # ---- 国内域名查询 ----
  - tag: query_is_local_domain
    type: sequence
    args:
      - matches: qname $geosite_cn
        exec: $local_sequence

  # ---- 国外(被墙)域名查询 ----
  - tag: query_is_no_local_domain
    type: sequence
    args:
      - matches: qname $geosite_no_cn
        exec: $remote_sequence

  # ---- 主逻辑 ----
  - tag: main_sequence
    type: sequence
    args:
      - exec: $mosdns_hosts
      - exec: $lazy_cache
      - exec: $query_is_local_domain
      - exec: jump has_resp_sequence
      - exec: $query_is_no_local_domain
      - exec: jump has_resp_sequence
      - exec: $fallback

  # ---- 监听（仅本机，供 AdGuardHome 调用）----
  - tag: server_udp
    type: udp_server
    args:
      entry: main_sequence
      listen: 127.0.0.1:5335

  - tag: server_tcp
    type: tcp_server
    args:
      entry: main_sequence
      listen: 127.0.0.1:5335
EOF
  info "MosDNS 配置完成: ${MOSDNS_DIR}/config.yaml"
}

# ---- 注册 MosDNS 为 systemd 服务 -------------------------------------------
register_mosdns_service() {
  info "注册 MosDNS systemd 服务..."
  cat > /etc/systemd/system/mosdns.service <<EOF
[Unit]
Description=MosDNS DNS Proxy
After=network.target

[Service]
Type=simple
User=root
ExecStart=${MOSDNS_DIR}/mosdns start -d ${MOSDNS_DIR} -c ${MOSDNS_DIR}/config.yaml
Restart=on-failure
RestartSec=5s
LimitNOFILE=16384

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now mosdns
  info "MosDNS 服务已启动并设为开机自启"
}

# ---- 安装 AdGuardHome -------------------------------------------------------
install_adguardhome() {
  info "安装 AdGuardHome..."
  # 使用官方安装脚本
  curl -fsSL https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh -s -- -v
  info "AdGuardHome 安装完成"
}

# ---- 配置 AdGuardHome 上游指向 MosDNS（API 方式）---------------------------
configure_adguardhome_upstream() {
  info "配置 AdGuardHome 上游 DNS 为 MosDNS (127.0.0.1:5335)..."
  # AdGuardHome 配置文件路径
  local agh_yaml="/opt/AdGuardHome/AdGuardHome.yaml"
  if [[ ! -f "$agh_yaml" ]]; then
    warn "AdGuardHome 配置文件尚未生成，请完成初始化后手动设置上游为: 127.0.0.1:5335"
    return
  fi
  # 使用 sed 替换 upstream_dns（简单处理）
  if grep -q "upstream_dns:" "$agh_yaml"; then
    sed -i '/upstream_dns:/,/^[^ ]/s|.*-.*|    - 127.0.0.1:5335|' "$agh_yaml"
    systemctl restart AdGuardHome || true
    info "AdGuardHome 上游已更新"
  else
    warn "未找到 upstream_dns 字段，请手动在 AdGuardHome Web 界面设置上游: 127.0.0.1:5335"
  fi
}

# ---- 创建规则更新脚本 + cron ------------------------------------------------
setup_auto_update() {
  info "设置规则自动更新..."
  cat > /usr/local/bin/update-mosdns-rules.sh <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
IP_DIR="/opt/mosdns/ip"
wget -q -O "${IP_DIR}/geoip_cn.txt" \
  "https://raw.githubusercontent.com/IceCodeNew/4Share/master/geoip_china/china_ip_list.txt"
wget -q -O "${IP_DIR}/geosite_cn.txt" \
  "https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/direct-list.txt"
wget -q -O "${IP_DIR}/geosite_geolocation-gfw.txt" \
  "https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/proxy-list.txt"
systemctl restart mosdns
echo "$(date '+%Y-%m-%d %H:%M:%S') - 规则更新完成" >> /var/log/mosdns-update.log
SCRIPT
  chmod +x /usr/local/bin/update-mosdns-rules.sh

  # 每天凌晨 4 点自动更新
  (crontab -l 2>/dev/null; echo "0 4 * * * /usr/local/bin/update-mosdns-rules.sh") | crontab -
  info "已设置每日 04:00 自动更新规则"
}

# ---- 状态检查 ---------------------------------------------------------------
check_status() {
  echo ""
  info "===== 部署完成，状态检查 ====="
  echo ""
  echo "📌 MosDNS:"
  systemctl is-active --quiet mosdns && echo "  ✅ 运行中 (127.0.0.1:5335)" || echo "  ❌ 未运行"

  echo ""
  echo "📌 AdGuardHome:"
  systemctl is-active --quiet AdGuardHome && echo "  ✅ 运行中" || echo "  ❌ 未运行"

  local ip
  ip=$(hostname -I | awk '{print $1}')
  echo ""
  echo "📌 访问 AdGuardHome 管理面板:"
  echo "   http://${ip}:3000"
  echo ""
  echo "📌 将路由器/DHCP 的 DNS 指向: ${ip}:53"
  echo ""
  echo "📌 测试 DNS 解析:"
  echo "   dig @127.0.0.1 baidu.com     # 应返回国内 IP"
  echo "   dig @127.0.0.1 google.com    # 应返回国外 IP"
  echo ""
  echo "📌 查看 MosDNS 日志:"
  echo "   journalctl -u mosdns -f"
  echo "   tail -f /opt/mosdns/log.log"
}

# ---- 主流程 -----------------------------------------------------------------
main() {
  info "开始部署 MosDNS + AdGuardHome DNS 分流系统"
  install_deps
  fix_systemd_resolved
  install_mosdns
  download_rules
  write_mosdns_config
  register_mosdns_service
  install_adguardhome
  configure_adguardhome_upstream
  setup_auto_update
  check_status
}

main "$@"
