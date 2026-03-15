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

# ---- AdGuardHome 管理员账号（部署前请修改）-----------------------------------
AGH_USER="${AGH_USER:-admin}"
AGH_PASS="${AGH_PASS:-admin123}"

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
  apt-get install -y -qq curl wget unzip jq apache2-utils
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
  # 安装后立即停止，等待配置写入后再启动
  systemctl stop AdGuardHome || true
  info "AdGuardHome 安装完成"
}

# ---- 预生成 AdGuardHome 配置（跳过初始化向导）-------------------------------
write_adguardhome_config() {
  info "生成 AdGuardHome 配置文件..."

  # 生成 bcrypt 密码哈希
  local pass_hash
  pass_hash=$(htpasswd -nbB "" "${AGH_PASS}" | cut -d: -f2)
  info "管理员用户: ${AGH_USER}"

  cat > "${AGH_DIR}/AdGuardHome.yaml" <<EOF
http:
  pprof:
    port: 6060
    enabled: false
  address: 0.0.0.0:80
  session_ttl: 720h
users:
  - name: ${AGH_USER}
    password: ${pass_hash}
auth_attempts: 5
block_auth_min: 15
http_proxy: ""
language: zh-cn
theme: auto
dns:
  bind_hosts:
    - 0.0.0.0
  port: 53
  anonymize_client_ip: false
  ratelimit: 0
  ratelimit_subnet_len_ipv4: 24
  ratelimit_subnet_len_ipv6: 56
  ratelimit_whitelist: []
  refuse_any: true
  upstream_dns:
    - 127.0.0.1:5335
    - tcp://127.0.0.1:5335
  upstream_dns_file: ""
  bootstrap_dns:
    - 9.9.9.10
    - 149.112.112.10
    - 2620:fe::10
    - 2620:fe::fe:10
  fallback_dns: []
  upstream_mode: load_balance
  fastest_timeout: 1s
  allowed_clients: []
  disallowed_clients: []
  blocked_hosts:
    - version.bind
    - id.server
    - hostname.bind
  trusted_proxies:
    - 127.0.0.0/8
    - ::1/128
  cache_enabled: false
  cache_size: 0
  cache_ttl_min: 0
  cache_ttl_max: 0
  cache_optimistic: false
  bogus_nxdomain: []
  aaaa_disabled: false
  enable_dnssec: false
  edns_client_subnet:
    custom_ip: ""
    enabled: false
    use_custom: false
  max_goroutines: 300
  handle_ddr: true
  ipset: []
  ipset_file: ""
  bootstrap_prefer_ipv6: false
  upstream_timeout: 10s
  private_networks: []
  use_private_ptr_resolvers: false
  local_ptr_upstreams: []
  use_dns64: false
  dns64_prefixes: []
  serve_http3: false
  use_http3_upstreams: false
  serve_plain_dns: true
  hostsfile_enabled: true
tls:
  enabled: false
  server_name: ""
  force_https: false
  port_https: 443
  port_dns_over_tls: 853
  port_dns_over_quic: 853
  port_dnscrypt: 0
  dnscrypt_config_file: ""
  allow_unencrypted_doh: false
  certificate_chain: ""
  private_key: ""
  certificate_path: ""
  private_key_path: ""
  strict_sni_check: false
querylog:
  dir_path: ""
  ignored: []
  interval: 72h
  size_memory: 1000
  enabled: true
  file_enabled: true
statistics:
  dir_path: ""
  ignored: []
  interval: 72h
  enabled: true
filters:
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt
    name: AdGuard DNS filter
    id: 1
  - enabled: false
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_2.txt
    name: AdAway Default Blocklist
    id: 2
whitelist_filters: []
user_rules: []
dhcp:
  enabled: false
  interface_name: ""
  local_domain_name: lan
  dhcpv4:
    gateway_ip: ""
    subnet_mask: ""
    range_start: ""
    range_end: ""
    lease_duration: 86400
    icmp_timeout_msec: 1000
    options: []
  dhcpv6:
    range_start: ""
    lease_duration: 86400
    ra_slaac_only: false
    ra_allow_slaac: false
filtering:
  blocking_ipv4: ""
  blocking_ipv6: ""
  blocked_services:
    schedule:
      time_zone: Local
    ids: []
  protection_disabled_until: null
  safe_search:
    enabled: false
    bing: true
    duckduckgo: true
    ecosia: true
    google: true
    pixabay: true
    yandex: true
    youtube: true
  blocking_mode: default
  parental_block_host: family-block.dns.adguard.com
  safebrowsing_block_host: standard-block.dns.adguard.com
  rewrites: []
  safebrowsing_cache_size: 1048576
  safesearch_cache_size: 1048576
  parental_cache_size: 1048576
  cache_time: 30
  filters_update_interval: 24
  blocked_response_ttl: 10
  filtering_enabled: true
  parental_enabled: false
  safebrowsing_enabled: false
  protection_enabled: true
clients:
  runtime_sources:
    whois: true
    arp: true
    rdns: false
    dhcp: true
    hosts: true
  persistent: []
log:
  enabled: true
  file: ""
  max_backups: 0
  max_size: 100
  max_age: 3
  compress: false
  local_time: false
  verbose: false
os:
  group: ""
  user: ""
  rlimit_nofile: 0
schema_version: 29
EOF

  # 启动 AdGuardHome
  systemctl start AdGuardHome
  info "AdGuardHome 配置已生成并启动（无需初始化向导）"
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

  # 每天凌晨 4 点自动更新（先去重再添加）
  (crontab -l 2>/dev/null | grep -v "update-mosdns-rules"; echo "0 4 * * * /usr/local/bin/update-mosdns-rules.sh") | crontab -
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
  echo "   http://${ip}"
  echo "   用户名: ${AGH_USER}"
  echo "   密码: ${AGH_PASS}"
  echo ""
  echo "📌 将路由器/DHCP 的 DNS 指向: ${ip}"
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
  write_adguardhome_config
  setup_auto_update
  check_status
}

main "$@"
