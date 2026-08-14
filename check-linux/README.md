# Cloudflare 优选 IP 扫描 - Linux 版

基于 [Selected-by-Monte-Carlo](https://github.com/yu-929/Selected-by-Monte-Carlo) 仓库 `check/` 目录改造的 Linux 一键脚本。

## 文件结构

| 文件 | 说明 |
|------|------|
| `check.sh` | Linux 一键脚本（bash），自动处理环境检查、文件描述符、参数传递 |
| `check_cf_asn.py` | 扫描器：三阶段筛选（TLS 证书匹配 -> HTTP 301/302 校验 -> 自定义域名校验） |
| `validate.py` | 校验器：调用第三方 API 查询节点国家/城市/ASN 信息 |
| `requirements.txt` | 依赖声明（asyncio 为标准库，无需安装） |

## 快速开始

```bash
# 1. 赋予执行权限
chmod +x check.sh

# 2. 安装为系统命令 ck（之后直接运行 ck 即可）
./check.sh --install

# 3. 交互模式：直接运行，按向导提示输入目标/端口/域名/并发等
ck

# 4. 参数模式：按 ASN 扫描
ck -t AS206300 -p 443

# 5. 指定目标与多端口
ck -t "AS206300 AS13335" -p "443,13720"

# 6. 按 CIDR 网段扫描并启用第三阶段域名校验
ck -t 16.162.0.0/16 -p 443 -d example.com

# 7. 扫描后自动校验节点信息
ck -t targets.txt -p 443 -v
```

> 未安装时也可以直接 `./check.sh`，效果相同。`--install` 会在 `/usr/local/bin` 创建 `ck` 软链，全局可用。

## CLI 交互设计

脚本支持两种运行模式：

**交互模式**：无参数运行或 `-i` 强制进入，按引导向导依次配置：
- 目标输入（支持 ASN / CIDR / 单 IP / 文件，可混合）
- 端口列表
- 是否启用自定义域名校验（第三阶段）
- 并发数
- 下载服务端口（默认 8000）
- 开始前显示配置汇总并二次确认

默认自动执行节点信息校验并启动 HTTP 下载服务（nohup 后台常驻，脚本/SSH 退出后仍可下载）。
所有输入项均带默认值，直接回车使用默认配置，适合不熟悉参数的用户。

**参数模式**：通过命令行参数直接指定，适合脚本自动化与定时任务。

## 参数说明

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `-i, --interactive` | 强制进入交互式引导向导 | 无参数时自动进入 |
| `-t, --target` | 目标：ASN / CIDR / IP / `.txt` 文件，可混合，空格或逗号分隔 | `AS206300` |
| `-p, --ports` | 端口列表，空格或逗号分隔 | `443` |
| `-d, --domain` | 自定义 CF 域名，启用第三阶段域名校验 | 空（跳过） |
| `-c, --concurrency` | 阶段一并发数 | `2000` |
| `-o, --output` | 结果输出目录 | `history` |
| `-v, --validate` | 扫描后自动运行 `validate.py` | 关闭 |
| `-s, --serve <端口>` | 扫描完成后启动 HTTP 下载服务 | 关闭 |
| `-h, --help` | 帮助 | - |

支持环境变量：`TARGET_LIST`、`ASN_LIST`、`CUSTOM_CF_DOMAIN`、`OUTPUT_DIR`、`SCAN_CONCURRENCY`、`SCAN_TIMEOUT`、`SCAN_TIMEOUT_STAGE2`、`SCAN_CONCURRENCY_STAGE2`。

## 性能优化说明

针对 masscan 速度差距做了以下优化，探测阶段吞吐显著提升：

| 优化点 | 说明 |
|--------|------|
| 默认并发 3000 | `SCAN_CONCURRENCY` 可调，Linux 下配合 `ulimit` 自动提升文件描述符上限 |
| 独立阶段二并发 | 阶段二/三使用 `STAGE2_CONCURRENCY = 阶段一 × 2`，候选少时不再被阶段一并发限制 |
| 快速关闭连接 | 用 `transport.abort()` 替代优雅 TLS 关闭握手，避免大量连接 `wait_closed()` 堆积 0.5s |
| 减少无效重试 | 仅 TCP 连接超时重试一次，TLS 握手超时直接判定失败，不可达 IP 耗时不再翻倍 |
| 超时可调 | `SCAN_TIMEOUT`（阶段一，默认 0.8s）/ `SCAN_TIMEOUT_STAGE2`（阶段二，默认 2.0s），延迟高的网络可调大以提高准确率 |

## 延迟优选与诊断

扫描时测量每个节点的 TCP + TLS 握手延迟，提供：

- **按延迟排序**：最终结果按延迟升序排列，顶部即为最快节点；扫描结束打印延迟最快的 10 个节点
- **延迟明细文件**：`history/<目标>_latency.txt`，格式 `IP:PORT 延迟ms`
- **CSV 延迟列**：`Delay(ms)` 列展示每个节点延迟
- **错误统计**：第一阶段结束输出分类汇总（超时 / 拒绝 / 重置 / 非CF证书 / 其他），便于诊断目标网络质量

```text
[1/3 结果] 通过 5 | 超时 224 | 拒绝 0 | 重置 2 | 非CF证书 21 | 其他 2
```

> 说明：该脚本每次目标都要建立完整 TCP + TLS 握手做应用层验证，单机吞吐仍低于 masscan 的 raw SYN 无状态扫描。面向全量 IP 库时建议先用 masscan 粗筛开放端口，再交给本脚本深度验证。

## 扫描流程

1. 第一阶段（TLS 探测）：并发 TLS 握手，匹配 Cloudflare 证书（SNI: `www.cloudflare.com`）
2. 第二阶段（HTTP 校验）：严格校验 301/302 重定向 + `Location` 头（Host: `crypto.cloudflare.com`）
3. 第三阶段（自定义域名校验，可选）：验证目标域名是否支持自定义托管

结果保存到 `history/<目标名>.txt`，格式为 `IP:PORT` 每行一条。扫描完成后自动生成同名 `.csv` 汇总文件，按你的需求定义为 9 列：

| 列 | 来源 |
|----|------|
| IP地址 | 扫描结果 |
| 端口 | 扫描结果 |
| TLS | TLS 握手是否成功（TRUE / FALSE） |
| 数据中心 | Cloudflare PoP 编码（如 HKG） |
| 地区 | 国家/地区代码（如 HK） |
| 城市 | 城市名 |
| 网络延迟(ms) | 扫描端实测 TCP+TLS 握手延迟 |
| ASN机构 | 运营商机构名 |
| ASN编号 | AS 编号 |

CSV 使用 UTF-8 BOM 编码，Excel 直接打开中文表头不乱码。辅助文件：`history/<目标>_meta.txt`（延迟+TLS版本）、`history/<目标>_valid.txt`（节点信息明细）。

## 居中对齐表格

扫描完成后除 `.csv` 外，还会生成同名 `.xlsx`（`history/<目标>.xlsx`），所有单元格**水平和垂直居中对齐**，表头加粗并自适应列宽，Excel 打开即居中，无需手动调整。

```bash
# 下载服务同时提供两种格式的链接
[+] CSV 下载链接:  http://127.0.0.1:8000/AS206300.csv
[+] XLSX 下载链接: http://127.0.0.1:8000/AS206300.xlsx
```

依赖 `openpyxl`（Python 库），缺失时自动回退生成 HTML 表格 `.xls`（Excel 可打开且居中）。安装：`pip install openpyxl`。

## CSV 下载服务

启用 `-s <端口>`（交互模式中也有对应选项）后，扫描完成自动启动 HTTP 下载服务，并输出 CSV 下载链接：

```bash
./check.sh -t AS206300 -p 443 -v -s 8000

# 输出示例
[*] 下载服务已启动 (PID 845):
[+]   本机访问: http://127.0.0.1:8000/
[+]   局域网访问: http://192.168.1.10:8000/
[+] CSV 下载链接: http://127.0.0.1:8000/AS206300.csv
[!] 停止服务: kill $(cat .http_server.pid)
```

浏览器打开下载链接即可直接下载 CSV。停止服务：`kill $(cat .http_server.pid)`。

## 依赖

- Python 3.8+（使用标准库 `asyncio`/`ssl`/`ipaddress`/`resource`，无需 pip 安装额外包）
- Linux 系统（脚本使用 `ulimit` 提升文件描述符上限，高并发扫描需要）

## 注意事项

- 待测 IP 超过 5 万个时程序会提示，建议拆分小网段分批扫描
- 脚本会自动尝试将文件描述符上限提升至 `并发数×2+512`，如无权限则并发数被系统自动约束
- 扫描占用大量网络连接，请确认服务商策略允许
