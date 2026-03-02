# MosDNS v5 + AdGuardHome 自动化部署方案

## 方案概述

基于你文档中已有的配置思路，将整个部署过程封装为**一键 Shell 脚本**，在 Ubuntu/Debian Linux 虚拟机上自动完成所有安装和配置工作。

### 架构设计

```
客户端 DNS 请求
      │
      ▼
AdGuardHome :53   ← 负责去广告、日志、管理面板
      │ 上游转发
      ▼
MosDNS :5335      ← 负责智能分流
      │
   ┌──┴──────────────────────┐
   │ 国内域名                │ 国外/GFW 域名       │ 未知域名 (fallback)
   ▼                         ▼                      ▼
阿里/腾讯 DoT            Google/CF/OpenDNS DoT  本地先试(非国内IP则丢弃)
                          + prefer_ipv4            → 再用国外 DoT
```

**职责分工：**

- **AdGuardHome**：监听 `:53`，提供 Web 管理界面、统计日志、去广告过滤，上游指向 MosDNS
- **MosDNS**：监听 `127.0.0.1:5335`（仅本机），负责分流逻辑和缓存

---

## 脚本文件结构

```
auto-deploy/
├── deploy.sh          # 一键安装主脚本
└── update-rules.sh    # 规则单独更新脚本（也可 cron 定时调用）
```

---

## 部署步骤

### 1. 上传脚本到 Linux 虚拟机

```bash
# 从 Mac 通过 scp 上传（替换 user@192.168.x.x）
scp -r /Users/zyhw/mosdns+adgardhome/auto-deploy user@192.168.x.x:~/
```

### 2. 一键部署

```bash
ssh user@192.168.x.x
chmod +x ~/auto-deploy/deploy.sh
sudo bash ~/auto-deploy/deploy.sh
```

脚本会自动完成以下所有步骤：

| 步骤 | 内容 |
|------|------|
| ① | 安装系统依赖（curl, wget, unzip, jq） |
| ② | 配置 systemd-resolved，释放 53 端口 |
| ③ | 下载 MosDNS v5.3.4 二进制 |
| ④ | 下载国内 IP/域名、GFW 域名规则列表 |
| ⑤ | 生成 MosDNS config.yaml |
| ⑥ | 注册并启动 MosDNS systemd 服务 |
| ⑦ | 用官方脚本安装 AdGuardHome |
| ⑧ | 配置 AdGuardHome 上游指向 MosDNS |
| ⑨ | 设置每日 04:00 自动更新规则的 cron |
| ⑩ | 打印状态检查和访问地址 |

### 3. AdGuardHome 初始化

浏览器访问 `http://<虚拟机IP>:3000`，完成初始化向导：

- 管理界面监听：`0.0.0.0:3000`
- DNS 监听：`0.0.0.0:53`
- 设置管理员账号密码

> [!IMPORTANT]
> 初始化完成后，在 **设置 → DNS 设置 → 上游 DNS 服务器** 中填写：
>
> ```
> 127.0.0.1:5335
> ```
>
> 并勾选"并行请求"或"负载均衡"。

---

## MosDNS 配置关键逻辑说明

| 配置项 | 说明 |
|--------|------|
| 国内 DNS | 阿里 `tls://223.5.5.5`、腾讯 `tls://1.12.12.12`、`tls://120.53.53.53`，三路并发 |
| 国外 DNS | Google `tls://8.8.8.8`、CF `tls://1.1.1.1`、OpenDNS `tls://208.67.222.222` |
| `prefer_ipv4` | 国外解析时 **IPv4 优先**（正如文档要求） |
| Fallback | 本地 DNS 若返回非国内 IP → 丢弃 → 改用国外 DNS（防污染） |
| 缓存 | 2 万条，持久化到磁盘，lazy TTL 24h |
| 监听 | MosDNS 仅监听 `127.0.0.1:5335`，不对外暴露 |

---

## 验证方法

### 自动检查（脚本末尾自动输出）

```
✅ MosDNS 运行中 (127.0.0.1:5335)
✅ AdGuardHome 运行中
```

### 手动测试

```bash
# 国内域名 → 应返回国内 IP
dig @127.0.0.1 baidu.com A

# 国外域名 → 应返回国外 IP，且 IPv4 优先
dig @127.0.0.1 google.com A

# 查看 MosDNS 实时日志
journalctl -u mosdns -f

# 查看 MosDNS API 状态
curl http://127.0.0.1:9091
```

### AdGuardHome 管理界面查验

- 访问 `http://<IP>:3000` → 查询日志，应能看到域名被正确分流

---

## 常见问题

### 53 端口被占用

脚本已自动处理 `systemd-resolved` 冲突。如仍有问题：

```bash
sudo lsof -i :53
sudo systemctl stop systemd-resolved
sudo systemctl disable systemd-resolved
```

### GitHub 下载慢/超时

在中国大陆部署时，规则列表从 GitHub 下载可能超时。
**解决方案**：在脚本中将 GitHub raw URL 替换为镜像，例如：

```
https://raw.githubusercontent.com → https://mirror.ghproxy.com/https://raw.githubusercontent.com
```

或提前在 Mac 上下载好上传到虚拟机。

### MosDNS 服务启动失败

```bash
journalctl -u mosdns -n 50 --no-pager
mosdns verify -c /opt/mosdns/config.yaml   # 验证配置语法
```

### 架构支持

脚本自动检测并支持：`x86_64 (amd64)` / `aarch64 (arm64)` / `armv7` / `armv6`

---

## 后续运维

| 操作 | 命令 |
|------|------|
| 重启 MosDNS | `systemctl restart mosdns` |
| 手动更新规则 | `sudo bash /usr/local/bin/update-mosdns-rules.sh` |
| 查看日志 | `tail -f /opt/mosdns/log.log` |
| 重启 AdGuardHome | `systemctl restart AdGuardHome` |
| 升级 MosDNS | 重新执行 `deploy.sh` 或手动替换 `/opt/mosdns/mosdns` 二进制 |
