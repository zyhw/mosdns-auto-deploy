#!/usr/bin/env bash
# =============================================================================
# MosDNS 规则一键更新脚本
# 可手动运行，也可由 cron 定时调用
# =============================================================================
set -euo pipefail
IP_DIR="/opt/mosdns/ip"

wget -q -O "${IP_DIR}/geoip_cn.txt" \
  "https://raw.githubusercontent.com/IceCodeNew/4Share/master/geoip_china/china_ip_list.txt"

wget -q -O "${IP_DIR}/geosite_cn.txt" \
  "https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/direct-list.txt"

wget -q -O "${IP_DIR}/geosite_geolocation-gfw.txt" \
  "https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/proxy-list.txt"

systemctl restart mosdns
echo "$(date '+%Y-%m-%d %H:%M:%S') - 规则更新完成" | tee -a /var/log/mosdns-update.log
