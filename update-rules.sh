#!/usr/bin/env bash
# =============================================================================
# MosDNS 规则一键更新脚本（容灾加固版）
# 可手动运行，也可由 cron 定时调用
# =============================================================================
set -euo pipefail

IP_DIR="/opt/mosdns/ip"
TMP_DIR=$(mktemp -d)
FAILED=0

# 安全下载函数：下载到临时文件 → 校验非空 → 替换目标
safe_download() {
  local url="$1"
  local target="$2"
  local tmp_file="${TMP_DIR}/$(basename "$target")"

  if wget -q -O "$tmp_file" "$url" && [ -s "$tmp_file" ]; then
    mv "$tmp_file" "$target"
  else
    echo "[ERROR] 下载失败或文件为空: $url" >&2
    FAILED=1
  fi
}

safe_download \
  "https://raw.githubusercontent.com/IceCodeNew/4Share/master/geoip_china/china_ip_list.txt" \
  "${IP_DIR}/geoip_cn.txt"

safe_download \
  "https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/direct-list.txt" \
  "${IP_DIR}/geosite_cn.txt"

safe_download \
  "https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/proxy-list.txt" \
  "${IP_DIR}/geosite_geolocation-gfw.txt"

rm -rf "$TMP_DIR"

if [ "$FAILED" -eq 1 ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') - [WARN] 部分规则下载失败，已跳过覆盖，MosDNS 未重启" | tee -a /var/log/mosdns-update.log
  exit 1
fi

systemctl restart mosdns
echo "$(date '+%Y-%m-%d %H:%M:%S') - 规则更新完成" | tee -a /var/log/mosdns-update.log
