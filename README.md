# CHECK-IP

Cloudflare 优选 IP 扫描工具（Linux CLI 版），基于 TLS 握手 + HTTP 301 校验，快速筛选可用的 Cloudflare 优选 IP。

## 功能特性

- 三阶段筛选：TLS 证书匹配 → HTTP 301/302 重定向校验 → 自定义域名校验
- 支持目标：ASN / CIDR 网段 / 单 IP / IP 列表文件，可混合输入
- 延迟测量：记录每个节点 TCP+TLS 握手延迟，按延迟排序优选
- 错误统计：扫描结束输出超时/拒绝/重置/非CF证书分类汇总
- 交互式向导 + 命令行参数双模式
- 结果输出：`IP:PORT` 文本、`CSV`（UTF-8 BOM）、`XLSX`（全部单元格居中对齐）
- HTTP 下载服务：扫描完成后一条链接下载结果

## 快速安装到 VPS

### 1. 安装依赖

```bash
# Debian / Ubuntu
apt-get update
apt-get install -y python3 python3-pip git curl

# CentOS / RHEL / Rocky
yum install -y python3 python3-pip git curl
```

### 2. 克隆仓库

```bash
git clone https://github.com/yu-929/CHECK-IP.git
cd CHECK-IP/check-linux
```

### 3. 赋予执行权限并安装为系统命令

```bash
chmod +x check.sh
pip install --break-system-packages openpyxl
./check.sh --install
```

`openpyxl` 用于生成居中对齐的 XLSX 表格，不安装会自动回退为 HTML `.xls`。
`./check.sh --install` 会把脚本软链到 `/usr/local/bin/ck`，之后直接运行 `ck` 即可。

### 4. 运行

```bash
# 交互式向导（推荐）
ck

# 参数模式：按 ASN 扫描并启动下载服务
ck -t AS206300 -p 443 -v -s 8000
```

### 5. 更新到最新版本

```bash
cd CHECK-IP && git pull
```

`ck` 是软链指向仓库内的 `check.sh`，拉取后自动生效，无需重新安装。

## 使用方法

### 交互模式

无参数运行或 `-i` 进入引导向导，按提示配置目标、端口、域名、并发、输出目录，开始前二次确认。

### 参数模式

```
用法: ./check.sh [选项]
  -i, --interactive      强制进入交互式引导向导
  -t, --target <目标>    目标: ASN / CIDR / IP / .txt 文件，可混合
  -p, --ports <端口>     端口列表 (默认: 443)
  -d, --domain <域名>    自定义 CF 域名，启用第三阶段校验
  -c, --concurrency <N>  阶段一并发数 (默认: 3000)
  -w, --workers <N>      多进程并行数，利用多核加速 (默认: 1)
  -o, --output <目录>    结果输出目录 (默认: history)
  -v, --validate         扫描后校验节点信息
  -s, --serve <端口>     扫描后启动 HTTP 下载服务
  --install              安装为系统命令 ck (软链到 /usr/local/bin/ck)
  -h, --help             帮助
```

示例：

```bash
./check.sh -t AS206300 -p 443
./check.sh -t "AS206300 AS13335" -p "443,13720" -c 5000
./check.sh -t 16.162.0.0/16 -p 443 -d example.com -v
./check.sh -t targets.txt -p 443 -v -s 8000
./check.sh -t 129.153.0.0/16 -p 28863 -w 4   # 4 进程并行扫大网段
```

### 结果文件

扫描完成后在 `history/` 目录生成：

| 文件 | 说明 |
|------|------|
| `<目标>.txt` | 可用节点 `IP:PORT`，按延迟升序 |
| `<目标>.csv` | 9 列汇总（IP地址/端口/TLS/数据中心/地区/城市/网络延迟/ASN机构/ASN编号） |
| `<目标>.xlsx` | Excel 表格，全部单元格居中对齐 |
| `<目标>_meta.txt` | 节点元数据（延迟 + TLS 状态） |
| `<目标>_valid.txt` | 节点信息明细（`-v` 时生成） |

## 环境变量

`TARGET_LIST`、`ASN_LIST`、`CUSTOM_CF_DOMAIN`、`OUTPUT_DIR`、`SCAN_CONCURRENCY`、`SCAN_TIMEOUT`、`SCAN_TIMEOUT_STAGE2`、`SCAN_CONCURRENCY_STAGE2`

## VPS 部署注意事项

1. **文件描述符**：高并发扫描需大量 socket，脚本会自动尝试提升 `ulimit -n`；普通用户权限不足时可手动设置：
   ```bash
   ulimit -n 65535
   # 永久生效: 在 /etc/security/limits.conf 添加
   # * soft nofile 65535
   # * hard nofile 65535
   ```
2. **防火墙**：使用下载服务时放行对应端口：
   ```bash
   # UFW
   ufw allow 8000/tcp
   # firewalld
   firewall-cmd --permanent --add-port=8000/tcp && firewall-cmd --reload
   ```
3. **长期运行**：用 `screen` / `tmux` / `systemd` 保持后台运行：
   ```bash
   # tmux 示例
   tmux new -s scan
   ./check.sh -t AS206300 -p 443 -s 8000
   # 按 Ctrl+B 再按 D 脱离会话
   ```
4. **扫描策略**：待测 IP 超过 5 万时建议拆分网段分批扫描，避免超时。
