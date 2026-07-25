#!/usr/bin/env bash
#
# 在 WSL 里用官方客户端的 libZIMEDataEngine.so 跑 ZIME native bridge probe。
#
# 为什么需要 WSL：.so 是 Linux ELF，Windows 的 ctypes 加载不了，只能在
# Linux 环境（WSL / Linux 机器 / 容器）里跑。
#
# 用法（在 Windows Git Bash 里执行）：
#   ./scripts/run-zime-probe-wsl.sh                    # 默认 --inspect-only（只看导出符号/结构体，安全）
#   ./scripts/run-zime-probe-wsl.sh --run              # --allow-native-run（真正调 native，会发包）
#   ./scripts/run-zime-probe-wsl.sh --run --remote-host 1.2.3.4 --remote-port 8000
#   ./scripts/run-zime-probe-wsl.sh -- --inspect-only --lib-path /other/path.so
#
# 脚本做：
#   1. 在 docs/ 下自动找 libZIMEDataEngine.so（deb 解压出来的官方客户端）
#   2. 把 Windows 路径转成 WSL 路径（/mnt/d/...）
#   3. 在 WSL 里 pip install -e . 装好项目（首次或更新后）
#   4. 设 CMCC_ZIME_LIB 并运行 python -m cmcc_cloud_alive zime-native-bridge ...
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---------- 1. 找 .so ----------
SO="$(find "$ROOT/docs" -name "libZIMEDataEngine.so" -type f 2>/dev/null | head -1 || true)"
if [[ -z "$SO" ]]; then
    echo "错误：在 $ROOT/docs 下找不到 libZIMEDataEngine.so" >&2
    echo "       请确认已把官方客户端 deb 解压到 docs/ 下。" >&2
    exit 1
fi
echo "找到 .so：$SO"

# ---------- 2. 检查 WSL ----------
if ! command -v wsl.exe >/dev/null 2>&1; then
    echo "错误：找不到 wsl.exe，本脚本需在 Windows 上跑、通过 WSL 执行 Linux .so。" >&2
    exit 1
fi

# 默认 WSL 发行版（可用 WSL_DIST 环境变量覆盖）
WSL_DIST="${WSL_DIST:-}"

# ---------- 3. 解析本脚本参数 ----------
INSPECT_ONLY=1
PASS_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --run) INSPECT_ONLY=0; shift ;;
        --) shift; PASS_ARGS+=("$@"); break ;;
        *) PASS_ARGS+=("$1"); shift ;;
    esac
done

# ---------- 4. 构造 WSL 调用 ----------
# 把本脚本收到的路径转成 WSL 路径。Git Bash 下 $ROOT 通常是 MSYS 风格
# /d/path，也可能收到 Windows 风格 D:\path 或 D:/path。统一转成 /mnt/d/path。
wslpath() {
    local p="$1"
    # 反斜杠 -> 正斜杠
    p="${p//\\//}"
    # MSYS 风格 /d/path -> /mnt/d/path
    if [[ "$p" =~ ^/([a-zA-Z])/(.*)$ ]]; then
        local drive="${BASH_REMATCH[1]}"
        local rest="${BASH_REMATCH[2]}"
        printf '/mnt/%s/%s' "$(echo "$drive" | tr 'A-Z' 'a-z')" "$rest"
        return
    fi
    # Windows 风格 D:/path 或 D:\path(已转正斜杠)-> /mnt/d/path
    if [[ "$p" =~ ^([a-zA-Z]):/(.*)$ ]]; then
        local drive="${BASH_REMATCH[1]}"
        local rest="${BASH_REMATCH[2]}"
        printf '/mnt/%s/%s' "$(echo "$drive" | tr 'A-Z' 'a-z')" "$rest"
        return
    fi
    # 其它(已是 WSL 风格或相对)原样返回
    printf '%s' "$p"
}

WSL_ROOT="$(wslpath "$ROOT")"
WSL_SO="$(wslpath "$SO")"

# 注意：不用 wsl.exe --cd，某些 WSL 版本对 --cd 长路径报 ERROR_PATH_NOT_FOUND。
# 改在 WSL 内部脚本里 cd。
WSL_ARGS=(-u root)
if [[ -n "$WSL_DIST" ]]; then
    WSL_ARGS=(-d "$WSL_DIST" -u root)
fi

# 在 WSL 里：装依赖 + 设 CMCC_ZIME_LIB + 跑命令
# pip install 静默（已装就跳过），CMCC_ZIME_LIB 指向 .so
# 把 CMD 数组里的元素逐个安全地拼进 WSL 内部脚本（单引号转义）
py_args=()
if [[ $INSPECT_ONLY -eq 1 ]]; then
    py_args+=(--inspect-only)
else
    py_args+=(--allow-native-run)
fi
py_args+=("${PASS_ARGS[@]}")

# 单引号转义每个参数，供 WSL 内 bash 安全重组
escaped_args=()
for a in "${py_args[@]}"; do
    escaped_args+=("'${a//\'/\'\"\'\"\'}'")
done
ARGS_LITERAL="${escaped_args[*]}"

# 用 base64 把 WSL 内部脚本传进去，彻底避开 Git Bash → wsl.exe → bash 的
# 多层引号/命令替换转义陷阱（$(...) 会被外层 shell 提前求值）。
inner_script='set -e
cd "'"$WSL_ROOT"'"
PY="$(command -v python3 || command -v python)"
if [ -z "$PY" ]; then
    echo "错误：WSL 里找不到 python3，请先在 WSL 里安装 Python 3.10+。" >&2
    exit 1
fi
if ! "$PY" -c "import cmcc_cloud_alive" 2>/dev/null; then
    echo "[setup] 首次运行，pip install -e . ..."
    "$PY" -m pip install -e . -q
fi
export CMCC_ZIME_LIB="'"$WSL_SO"'"
export PYTHONUNBUFFERED=1
echo "[run] CMCC_ZIME_LIB='"$WSL_SO"'"
echo "[run] python=$PY  zime-native-bridge '"$ARGS_LITERAL"'"
echo "---"
exec "$PY" -m cmcc_cloud_alive zime-native-bridge '"$ARGS_LITERAL"'
'

# base64 编码（-w0 不换行；macOS 的 base64 不支持 -w，用 tr 兜底）
B64="$(printf '%s' "$inner_script" | base64 -w0 2>/dev/null | tr -d '\n' || printf '%s' "$inner_script" | base64 | tr -d '\n')"

echo "[wsl] 发行版：${WSL_DIST:-默认}"
echo "[wsl] 仓库：$WSL_ROOT"
echo ""
wsl.exe "${WSL_ARGS[@]}" bash -lc "echo '$B64' | base64 -d | bash"
