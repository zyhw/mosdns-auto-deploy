# MosDNS v5 + AdGuardHome 自动化部署方案

## 方案概述

MosDNS v5 + AdGuardHome**一键 Shell 脚本**，在 Ubuntu/Debian Linux 虚拟机上自动完成所有安装和配置工作。

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

### 一键远程部署（推荐）

SSH 登录服务器后，直接执行：

```bash
# 使用默认账号 admin/admin123
curl -fsSL https://raw.githubusercontent.com/zyhw/mosdns-auto-deploy/refs/heads/main/deploy.sh | sudo bash

# 自定义管理员账号（推荐）
curl -fsSL https://raw.githubusercontent.com/zyhw/mosdns-auto-deploy/refs/heads/main/deploy.sh | sudo AGH_USER=myuser AGH_PASS=mypassword bash
```

### 备选：手动上传部署

```bash
# 从 Mac 通过 scp 上传
scp -r ./auto-deploy user@<服务器IP>:~/

# SSH 登录后执行
ssh user@<服务器IP>
sudo AGH_USER=myuser AGH_PASS=mypassword bash ~/auto-deploy/deploy.sh
```

#### 管理员账号配置

脚本通过环境变量设置 AdGuardHome 管理员账号，部署时自动写入配置：

| 环境变量 | 说明 | 默认值 |
|----------|------|--------|
| `AGH_USER` | 管理员用户名 | `admin` |
| `AGH_PASS` | 管理员密码 | `admin123` |

> [!IMPORTANT]
> 默认账号密码仅供测试，**正式部署请务必通过环境变量修改**。
> 密码会自动转换为 bcrypt 哈希存储，不会明文保存。

部署后如需修改密码，通过命令行操作：

```bash
# 1. 生成新密码的 bcrypt 哈希（将 新密码 替换为你的密码）
NEW_HASH=$(htpasswd -nbB "" "新密码" | cut -d: -f2)

# 2. 替换配置文件中的密码哈希
sed -i "s|password: .*|password: ${NEW_HASH}|" /opt/AdGuardHome/AdGuardHome.yaml

# 3. 重启生效
systemctl restart AdGuardHome
```

如需同时修改用户名，直接编辑 `/opt/AdGuardHome/AdGuardHome.yaml` 中的 `name:` 字段即可。

#### 部署流程

脚本会自动完成以下所有步骤：

| 步骤 | 内容 |
|------|------|
| ① | 安装系统依赖（curl, wget, unzip, jq, apache2-utils） |
| ② | 配置 systemd-resolved，释放 53 端口 |
| ③ | 下载 MosDNS v5.3.4 二进制 |
| ④ | 下载国内 IP/域名、GFW 域名规则列表 |
| ⑤ | 生成 MosDNS config.yaml |
| ⑥ | 注册并启动 MosDNS systemd 服务 |
| ⑦ | 用官方脚本安装 AdGuardHome |
| ⑧ | **预生成 AdGuardHome 配置（含账号密码，跳过初始化向导）** |
| ⑨ | 设置每日 04:00 自动更新规则的 cron |
| ⑩ | 打印状态检查、访问地址和账号信息 |

### 3. 部署完成后

部署完成后可直接访问 `http://<服务器IP>` 进入管理面板，**无需执行初始化向导**。
脚本末尾会打印管理员账号密码，请妥善记录。

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

## AdGuardHome 预设配置说明

| 配置项 | 值 | 说明 |
|--------|------|------|
| Web 界面 | `0.0.0.0:80` | 直接用 IP 访问，无需加端口号 |
| DNS 缓存 | 关闭 | 由 MosDNS 统一缓存，避免双重缓存 |
| 限速 | 关闭 (0) | 局域网环境不需要限速 |
| AAAA | 启用 | 支持 IPv6 网络 |
| 上游 DNS | `127.0.0.1:5335` | 负载均衡模式转发到 MosDNS |
| 语言 | 中文 | 管理界面默认中文 |

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

- 访问 `http://<IP>` → 查询日志，应能看到域名被正确分流

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

### 不支持 IPv6 的网络环境

默认配置支持 IPv6（AAAA 查询已启用）。如果你的网络**不支持 IPv6**，可手动禁用以减少不必要的查询，提升解析速度：

**步骤一：在 AdGuardHome 中禁用 AAAA 查询**

方式 A — Web 界面操作：

管理面板 → **设置 → DNS 设置** → 勾选 **「禁用 IPv6 的 AAAA 解析」** → 保存

方式 B — 命令行修改：

```bash
# 编辑配置文件
sed -i 's/aaaa_disabled: false/aaaa_disabled: true/' /opt/AdGuardHome/AdGuardHome.yaml

# 重启生效
systemctl restart AdGuardHome
```

**步骤二（可选）：验证 AAAA 已禁用**

```bash
# 应返回空结果
dig @127.0.0.1 google.com AAAA +short
```

> [!NOTE]
> MosDNS 中的 `prefer_ipv4` 配置无需修改——它仅对国外域名做 IPv4 优先排序，不影响 IPv6 流量。
> 如需恢复 IPv6，将上述 `aaaa_disabled` 改回 `false` 并重启即可。

---

## 清空 DNS 缓存

### MosDNS 缓存

**方式一：API 实时刷新（推荐，无需重启）**

```bash
curl -X POST http://127.0.0.1:9091/plugins/lazy_cache/flush
```

**方式二：删除缓存文件并重启**

```bash
rm -f /opt/mosdns/cache.dump && systemctl restart mosdns
```

### AdGuardHome 缓存

**命令行**（替换账号密码）：

```bash
curl -u admin:密码 -X POST http://127.0.0.1/control/cache_clear
```

---

## 后续运维

| 操作 | 命令 |
|------|------|
| 重启 MosDNS | `systemctl restart mosdns` |
| 手动更新规则（本地） | `sudo bash /usr/local/bin/update-mosdns-rules.sh` |
| 手动更新规则（远程） | `curl -fsSL https://raw.githubusercontent.com/zyhw/mosdns-auto-deploy/refs/heads/main/update-rules.sh \| sudo bash` |
| 查看日志 | `tail -f /opt/mosdns/log.log` |
| 重启 AdGuardHome | `systemctl restart AdGuardHome` |
| 升级 MosDNS | 重新执行 `deploy.sh` 或手动替换 `/opt/mosdns/mosdns` 二进制 |
