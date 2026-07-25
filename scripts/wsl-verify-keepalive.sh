#!/usr/bin/env bash
#
# 用真实账号跑一遍 login → list → 单轮 keepalive，验证指纹逻辑 + 落盘日志。
# 直接在 WSL 里跑：bash scripts/wsl-verify-keepalive.sh
#
# 密码安全：login 不传 --password 时用 getpass 隐藏输入，只在你本机终端，
# 不进 shell 历史、不进对话。本脚本不接触明文密码。
#
# 用法：
#   bash scripts/wsl-verify-keepalive.sh                  # 默认 ZTE 单轮
#   bash scripts/wsl-verify-keepalive.sh --protocol SCG   # 用 SCG
#   bash scripts/wsl-verify-keepslive.sh --account 138xxxx0000  # 预填账号，只交互输密码
#
# 跑完产物（都在 WSL 里）：
#   /tmp/cmcc-verify.log              全程日志（含异常/告警）
#   ~/.cmcc-cloud-alive/state.json    登录态（含 deviceId / deviceIdVersion）
#
set -euo pipefail

# 定位仓库根（脚本在 scripts/ 下）
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# ---------- 解析参数 ----------
PROTOCOL="ZTE"
ACCOUNT=""
ACCOUNT_ARG=()
FORCE_PROBE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --protocol) PROTOCOL="$2"; shift 2 ;;
        --account) ACCOUNT="$2"; ACCOUNT_ARG=(--username "$2"); shift 2 ;;
        --force-probe) FORCE_PROBE=1; shift ;;
        -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
        *) echo "未知参数: $1" >&2; exit 2 ;;
    esac
done

if [[ $FORCE_PROBE -eq 1 ]]; then
    export CCK_ZTE_FORCE_PROBE=1
    echo "[flag] CCK_ZTE_FORCE_PROBE=1 (忽略 sticky edge 缓存，重新探测)"
fi

case "$PROTOCOL" in
    ZTE|zte|SCG|scg) PROTOCOL=$(echo "$PROTOCOL" | tr '[:lower:]' '[:upper:]') ;;
    *) echo "错误: --protocol 只能是 ZTE 或 SCG" >&2; exit 2 ;;
esac

# ---------- 找 python ----------
PY="$(command -v python3 || command -v python || true)"
if [[ -z "$PY" ]]; then
    echo "错误：找不到 python3，请先在 WSL 里装 Python 3.10+。" >&2
    exit 1
fi

# ---------- 装项目（首次或更新后）----------
if ! "$PY" -c "import cmcc_cloud_alive" 2>/dev/null; then
    echo "[setup] 首次运行，pip install -e .（稍候）..."
    "$PY" -m pip install -e . -q
fi

export PYTHONUNBUFFERED=1
export CMCC_ALIVE_PROFILE=linux

LOG=/tmp/cmcc-verify.log
STATE="$HOME/.cmcc-cloud-alive/state.json"
: > "$LOG"   # 清空旧日志
echo "[info] 日志将写入: $LOG"
echo "[info] state 将写入: $STATE"
echo "========================================================"

run() {
    echo ""
    echo ">>> $*"
    "$@" 2>&1 | tee -a "$LOG"
}

# 1) 登录（交互输密码，getpass 隐藏；不传 --password）
echo "[step 1/3] login（提示账号/密码时请输入，密码不回显）"
run "$PY" -m cmcc_cloud_alive "${ACCOUNT_ARG[@]}" login

# 2) 拉云电脑列表（list 会自动选第一台，写入 selectedUserServiceId）
echo "[step 2/3] list（拉云电脑列表，自动选第一台）"
run "$PY" -m cmcc_cloud_alive list

# 3) 单轮保活（mode=1，只跑一轮就退出）
echo "[step 3/3] simple-keepalive 单轮（protocol=$PROTOCOL，mode=1）"
run "$PY" -m cmcc_cloud_alive simple-keepalive --protocol "$PROTOCOL" --mode 1 --traffic-seconds 60

echo ""
echo "========================================================"
echo "[done] 全部步骤完成"
echo ""

# ---------- 打印关键字段（脱敏）+ 异常扫描 ----------
echo "=== state.json 关键字段（脱敏供分析）==="
"$PY" -c "
import json, pathlib
p = pathlib.Path('$STATE')
if not p.exists():
    print('state.json 不存在（登录可能失败）'); raise SystemExit
s = json.loads(p.read_text(encoding='utf-8'))
def mask(v):
    v = str(v)
    return v[:3] + '***' + v[-2:] if len(v) > 6 else '***'
print('  username        :', mask(s.get('username') or s.get('phone') or ''))
print('  deviceId        :', s.get('deviceId') or '')
print('  deviceIdVersion :', s.get('deviceIdVersion'))
print('  sohoToken       :', mask(s.get('sohoToken') or ''))
print('  selectedUSID    :', mask(s.get('selectedUserServiceId') or ''))
print('  loginMode       :', s.get('loginMode'))
sel = s.get('selectedDesktop') or {}
print('  desktopName     :', sel.get('desktopName') or sel.get('name') or '')
print('  spuCode         :', sel.get('spuCode') or '')
"

echo ""
echo "=== 日志里的异常/告警关键词扫描 ==="
if grep -iE "error|warn|fail|exception|traceback|errno|refused|timeout|无效|失败|异常|错误" "$LOG"; then
    :
else
    echo "（无匹配，可能全部正常）"
fi

echo ""
echo "完整日志：$LOG"
echo "把上面「关键字段」和「异常扫描」两段贴给我，我帮你分析。"
