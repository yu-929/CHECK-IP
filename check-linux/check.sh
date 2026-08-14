#!/usr/bin/env bash
# ============================================================
# Cloudflare 优选 IP 扫描 - Linux CLI
# 基于 check_cf_asn.py + validate.py
# 支持两种模式:
#   * 交互模式: 无参数运行 或 -i 强制进入引导向导
#   * 参数模式: 直接命令行传参，适合脚本自动化
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------- 颜色与样式 ----------------
C_RESET='\033[0m'
C_BOLD='\033[1m'
C_DIM='\033[2m'
C_RED='\033[31m'
C_GREEN='\033[32m'
C_YELLOW='\033[33m'
C_BLUE='\033[34m'
C_CYAN='\033[36m'

log()  { echo -e "${C_GREEN}[*]${C_RESET} $1"; }
info() { echo -e "${C_CYAN}[>]${C_RESET} $1"; }
warn() { echo -e "${C_YELLOW}[!]${C_RESET} $1"; }
err()  { echo -e "${C_RED}[!]${C_RESET} $1" >&2; }
ok()   { echo -e "${C_GREEN}[+]${C_RESET} $1"; }
banner() { echo -e "${C_BOLD}${C_CYAN}$1${C_RESET}"; }

# ---------------- 默认配置 ----------------
TARGET="${TARGET_LIST:-${ASN_LIST:-AS206300}}"
PORTS="${DEFAULT_PORTS:-443}"
DOMAIN="${CUSTOM_CF_DOMAIN:-}"
CONCURRENCY="${SCAN_CONCURRENCY:-3000}"
OUTPUT_DIR="${OUTPUT_DIR:-history}"
RUN_VALIDATE=0
INTERACTIVE=0
SERVE_PORT=""

# ---------------- 帮助 ----------------
usage() {
    cat <<EOF
用法: ./check.sh [选项]

${C_BOLD}Cloudflare 优选 IP 扫描（Linux CLI）${C_RESET}

选项:
  -i, --interactive    强制进入交互式引导向导（无参数运行时也会自动进入）
  -t, --target <目标>  目标: ASN / CIDR / IP / .txt 文件，可混合，空格或逗号分隔 (默认: AS206300)
  -p, --ports <端口>   端口列表，空格或逗号分隔 (默认: 443)
  -d, --domain <域名>  自定义 CF 域名，启用第三阶段域名校验
  -c, --concurrency <N> 阶段一并发数 (默认: 2000)
  -o, --output <目录>  结果输出目录 (默认: history)
  -v, --validate       扫描后自动运行 validate.py 校验节点信息
  -s, --serve <端口>   扫描完成后启动 HTTP 下载服务，提供 CSV 下载链接
  -h, --help           显示帮助

环境变量: TARGET_LIST / ASN_LIST / CUSTOM_CF_DOMAIN / OUTPUT_DIR / SCAN_CONCURRENCY

示例:
  ./check.sh                              # 进入交互模式
  ./check.sh -t AS206300 -p 443           # 参数模式，按 ASN 扫描
  ./check.sh -t "AS206300 AS13335" -p "443,13720" -c 5000
  ./check.sh -t 16.162.0.0/16 -p 443 -d example.com -v -s 8000
EOF
}

# ---------------- 参数解析 ----------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -i|--interactive) INTERACTIVE=1; shift ;;
        -t|--target) TARGET="$2"; shift 2 ;;
        -p|--ports) PORTS="$2"; shift 2 ;;
        -d|--domain) DOMAIN="$2"; shift 2 ;;
        -c|--concurrency) CONCURRENCY="$2"; shift 2 ;;
        -o|--output) OUTPUT_DIR="$2"; shift 2 ;;
        -v|--validate) RUN_VALIDATE=1; shift ;;
        -s|--serve) SERVE_PORT="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) err "未知参数: $1"; usage; exit 1 ;;
    esac
done

# 无参数且 stdin 是终端时自动进入交互模式
if [[ "$INTERACTIVE" -eq 0 && $# -eq 0 && -t 0 ]]; then
    INTERACTIVE=1
fi

# ---------------- 交互式引导向导 ----------------
read_input() {
    local prompt="$1" default="$2" answer
    if [[ -n "$default" ]]; then
        read -r -p "$(info "${prompt} ${C_DIM}[${default}]${C_RESET} ")" answer
        echo "${answer:-$default}"
    else
        read -r -p "$(info "${prompt} ")" answer
        echo "$answer"
    fi
}

ask_yesno() {
    local prompt="$1" default="$2" answer
    read -r -p "$(info "${prompt} ${C_DIM}[${default}]${C_RESET} ")" answer
    answer="${answer:-$default}"
    [[ "$answer" == "y" || "$answer" == "Y" || "$answer" == "yes" ]]
}

run_interactive() {
    banner ""
    banner "=============================================="
    banner " Cloudflare 优选 IP 扫描 - 交互式向导"
    banner "=============================================="
    echo ""

    info "目标支持以下格式（可混合多个，空格/逗号分隔）:"
    info "  ASN:   AS206300 | 网段: 16.162.0.0/16 | 单 IP: 1.2.3.4 | 文件: targets.txt"
    echo ""

    TARGET="$(read_input "请输入目标 (ASN/CIDR/IP/文件)" "$TARGET")"
    PORTS="$(read_input "请输入端口列表" "$PORTS")"

    if ask_yesno "是否启用自定义域名校验（第三阶段）?" "n"; then
        DOMAIN="$(read_input "请输入自定义 CF 域名" "")"
    else
        DOMAIN=""
    fi

    CONCURRENCY="$(read_input "请输入并发数" "$CONCURRENCY")"

    RUN_VALIDATE=1
    SERVE_PORT="$(read_input "请输入下载服务端口" "8000")"

    echo ""
    banner "-------- 配置确认 --------"
    info "目标:       ${C_BOLD}${TARGET}${C_RESET}"
    info "端口:       ${C_BOLD}${PORTS}${C_RESET}"
    [[ -n "$DOMAIN" ]] && info "自定义域名: ${C_BOLD}${DOMAIN}${C_RESET}" || info "自定义域名: ${C_DIM}(未启用)${C_RESET}"
    info "并发数:     ${C_BOLD}${CONCURRENCY}${C_RESET}"
    info "输出目录:   ${C_BOLD}${OUTPUT_DIR}${C_RESET}"
    info "自动校验:   ${C_BOLD}$([[ "$RUN_VALIDATE" -eq 1 ]] && echo 是 || echo 否)${C_RESET}"
    info "下载服务:   ${C_BOLD}$([[ -n "$SERVE_PORT" ]] && echo "端口 ${SERVE_PORT}" || echo 否)${C_RESET}"
    banner "--------------------------"
    echo ""

    if ! ask_yesno "确认开始扫描?" "y"; then
        warn "已取消。"
        exit 0
    fi
}

# ---------------- CSV 生成 ----------------
gen_csv() {
    local src="$1" dst="$2" valid="$3" meta="$4"
    python3 - "$src" "$dst" "$valid" "$meta" <<'PYEOF'
import csv, os, sys

src, dst, valid, meta = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

info = {}
if valid and os.path.isfile(valid):
    for line in open(valid, encoding='utf-8'):
        line = line.strip()
        if not line:
            continue
        addr, _, fields = line.partition('#')
        if fields and fields != 'timeout':
            parts = fields.split('|')
            info[addr] = parts

meta_info = {}
if meta and os.path.isfile(meta):
    for line in open(meta, encoding='utf-8'):
        line = line.strip()
        if not line:
            continue
        parts = line.split()
        addr = parts[0]
        delay = parts[1] if len(parts) > 1 else ''
        tls = parts[2] if len(parts) > 2 else ''
        meta_info[addr] = (delay, tls)

rows = []
for line in open(src, encoding='utf-8'):
    line = line.strip()
    if not line:
        continue
    ip, _, port = line.partition(':')
    meta_fields = meta_info.get(line, ('', ''))
    valid_fields = info.get(line, [])
    fields = [None] * 5
    for i, v in enumerate(valid_fields[:5]):
        fields[i] = v
    country, city, asn, org, colo = fields
    rows.append([ip, port, meta_fields[1], colo, country, city, meta_fields[0], org, asn])

with open(dst, 'w', newline='', encoding='utf-8-sig') as f:
    w = csv.writer(f)
    w.writerow(['IP地址', '端口', 'TLS', '数据中心', '地区', '城市', '网络延迟(ms)', 'ASN机构', 'ASN编号'])
    w.writerows(rows)

print(f'[{len(rows)} 行] {dst}')
PYEOF
}

# ---------------- XLSX 生成（全部单元格居中对齐） ----------------
gen_xlsx() {
    local src="$1" dst="$2"
    python3 - "$src" "$dst" <<'PYEOF'
import csv, os, sys

src, dst = sys.argv[1], sys.argv[2]

try:
    import openpyxl
    from openpyxl.styles import Alignment, Font
except ImportError:
    fallback = os.path.splitext(dst)[0] + '.xls'
    html = ['<html><head><meta charset="utf-8"></head><body>',
            '<table border="1" style="text-align:center;border-collapse:collapse;width:100%">']
    for row in csv.reader(open(src, encoding='utf-8-sig')):
        cells = ''.join(f'<td>{c}</td>' for c in row)
        html.append('<tr>' + cells + '</tr>')
    html.append('</table></body></html>')
    with open(fallback, 'w', encoding='utf-8-sig') as f:
        f.write(''.join(html))
    print(f'[回退] 未安装 openpyxl，已生成 HTML 表格(Excel可打开，居中): {fallback}')
    sys.exit(0)

center = Alignment(horizontal='center', vertical='center')
wb = openpyxl.Workbook()
ws = wb.active

for row in csv.reader(open(src, encoding='utf-8-sig')):
    ws.append(row)

for row in ws.iter_rows():
    for cell in row:
        cell.alignment = center

for cell in ws[1]:
    cell.font = Font(bold=True)

for col in ws.columns:
    max_len = max((len(str(c.value)) for c in col if c.value is not None), default=8)
    ws.column_dimensions[col[0].column_letter].width = max_len + 4

wb.save(dst)
print(f'[xlsx] 已生成全部居中对齐表格: {dst}')
PYEOF
}

# ---------------- HTTP 下载服务 ----------------
start_download_server() {
    local port="$1" dir="$2"
    if ! command -v python3 >/dev/null 2>&1; then
        err "启动下载服务需要 python3"
        return 1
    fi
    (cd "$dir" && exec nohup python3 -m http.server "$port" --bind 0.0.0.0) >/dev/null 2>&1 < /dev/null &
    SERVER_PID=$!
    sleep 1
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        err "下载服务启动失败，端口 ${port} 可能被占用"
        return 1
    fi
    echo "$SERVER_PID" > "$SCRIPT_DIR/.http_server.pid"
    LOCAL_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
    log "下载服务已启动 (PID ${SERVER_PID}):"
    ok "  本机访问: http://127.0.0.1:${port}/"
    [[ -n "$LOCAL_IP" ]] && ok "  局域网访问: http://${LOCAL_IP}:${port}/"
    return 0
}

stop_download_server() {
    local pidfile="$SCRIPT_DIR/.http_server.pid"
    if [[ -f "$pidfile" ]]; then
        kill "$(cat "$pidfile")" 2>/dev/null || true
        rm -f "$pidfile"
        info "下载服务已停止。"
    fi
}

# ---------------- 运行前检查 ----------------
if ! command -v python3 >/dev/null 2>&1; then
    err "未找到 python3，请先安装:"
    err "  Debian/Ubuntu: sudo apt-get install -y python3"
    err "  CentOS/RHEL:   sudo yum install -y python3"
    exit 1
fi

python3 -c "import asyncio, ssl, ipaddress, resource" 2>/dev/null \
    || { err "Python 缺少必要标准库，请检查 Python 安装"; exit 1; }

# 提升文件描述符上限（Linux 并发扫描需要大量 socket）
CURRENT_LIMIT="$(ulimit -n)"
DESIRED_LIMIT=$((CONCURRENCY * 2 + 512))
if [[ "$CURRENT_LIMIT" -lt "$DESIRED_LIMIT" ]]; then
    if ulimit -n "$DESIRED_LIMIT" 2>/dev/null; then
        log "文件描述符上限已提升: ${CURRENT_LIMIT} -> $(ulimit -n)"
    else
        ulimit -n 65535 2>/dev/null && log "文件描述符上限已提升: ${CURRENT_LIMIT} -> 65535" \
            || warn "无法提升文件描述符上限 (当前 ${CURRENT_LIMIT})，并发数将被自动约束"
    fi
else
    log "当前文件描述符上限: ${CURRENT_LIMIT}"
fi

# ---------------- 运行交互向导 ----------------
if [[ "$INTERACTIVE" -eq 1 ]]; then
    run_interactive
fi

# ---------------- 执行扫描 ----------------
banner ""
banner "============================================"
banner " Cloudflare 优选 IP 扫描"
banner "============================================"
info "目标:     ${C_BOLD}${TARGET}${C_RESET}"
info "端口:     ${C_BOLD}${PORTS}${C_RESET}"
[[ -n "$DOMAIN" ]] && info "域名:     ${C_BOLD}${DOMAIN}${C_RESET}"
info "并发数:   ${C_BOLD}${CONCURRENCY}${C_RESET}"
info "输出目录: ${C_BOLD}${SCRIPT_DIR}/${OUTPUT_DIR}${C_RESET}"
banner "============================================"
echo ""

cd "$SCRIPT_DIR"

EXPORT_ENV=()
[[ -n "$DOMAIN" ]] && EXPORT_ENV+=("CUSTOM_CF_DOMAIN=$DOMAIN")
EXPORT_ENV+=("OUTPUT_DIR=$OUTPUT_DIR")
EXPORT_ENV+=("SCAN_CONCURRENCY=$CONCURRENCY")
[[ -n "${SCAN_TIMEOUT:-}" ]] && EXPORT_ENV+=("SCAN_TIMEOUT=$SCAN_TIMEOUT")
[[ -n "${SCAN_TIMEOUT_STAGE2:-}" ]] && EXPORT_ENV+=("SCAN_TIMEOUT_STAGE2=$SCAN_TIMEOUT_STAGE2")
[[ -n "${SCAN_CONCURRENCY_STAGE2:-}" ]] && EXPORT_ENV+=("SCAN_CONCURRENCY_STAGE2=$SCAN_CONCURRENCY_STAGE2")

log "开始扫描..."
if [[ ${#EXPORT_ENV[@]} -gt 0 ]]; then
    env "${EXPORT_ENV[@]}" python3 check_cf_asn.py "$TARGET" "$PORTS"
else
    python3 check_cf_asn.py "$TARGET" "$PORTS"
fi

# 定位最新生成的扫描结果
LATEST_FILE="$(ls -t "$OUTPUT_DIR"/*.txt 2>/dev/null | head -n1 || true)"
if [[ -z "$LATEST_FILE" ]]; then
    warn "未找到扫描结果文件，退出。"
    exit 1
fi
ok "扫描结果: ${C_BOLD}$LATEST_FILE${C_RESET}"

# 可选：运行 validate.py 校验节点信息
VALID_FILE=""
if [[ "$RUN_VALIDATE" -eq 1 ]]; then
    VALID_FILE="${LATEST_FILE%.txt}_valid.txt"
    log "正在调用第三方 API 校验节点信息，输出到 $VALID_FILE ..."
    if ! python3 validate.py "$LATEST_FILE" "$VALID_FILE"; then
        err "校验失败，请检查网络或稍后重试"
        exit 1
    fi
    ok "校验完成: ${C_BOLD}$VALID_FILE${C_RESET}"
fi

# 生成 CSV 文件
CSV_FILE="${LATEST_FILE%.txt}.csv"
META_FILE="${LATEST_FILE%.txt}_meta.txt"
log "正在生成 CSV 汇总文件..."
gen_csv "$LATEST_FILE" "$CSV_FILE" "$VALID_FILE" "$META_FILE"
ok "CSV 文件: ${C_BOLD}$CSV_FILE${C_RESET}"

# 生成居中 XLSX（依赖 openpyxl，缺省时回退为 HTML .xls）
XLSX_FILE="${LATEST_FILE%.txt}.xlsx"
log "正在生成居中对齐的 Excel 表格..."
gen_xlsx "$CSV_FILE" "$XLSX_FILE"

# 可选：启动 HTTP 下载服务
if [[ -n "$SERVE_PORT" ]]; then
    echo ""
    banner "-------- 下载服务 --------"
    if start_download_server "$SERVE_PORT" "$SCRIPT_DIR/$OUTPUT_DIR"; then
        ok "CSV 下载链接:  ${C_BOLD}http://127.0.0.1:${SERVE_PORT}/$(basename "$CSV_FILE")${C_RESET}"
        ok "XLSX 下载链接: ${C_BOLD}http://127.0.0.1:${SERVE_PORT}/$(basename "$XLSX_FILE")${C_RESET}"
        [[ -n "$LOCAL_IP" ]] && ok "局域网下载:   ${C_BOLD}http://${LOCAL_IP}:${SERVE_PORT}/$(basename "$XLSX_FILE")${C_RESET}"
        warn "停止服务: kill \$(cat $SCRIPT_DIR/.http_server.pid)"
    fi
    banner "--------------------------"
fi

ok "全部完成。"
