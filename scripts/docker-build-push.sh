#!/usr/bin/env bash
#
# 一键构建并推送 cmcc-cloud-alive Docker 镜像到阿里云 ACR。
#
# 用法（在仓库任意目录执行均可）：
#   ./scripts/docker-build-push.sh            # 默认打 latest + git 短 hash 双 tag
#   ./scripts/docker-build-push.sh --no-push  # 只构建，不推送
#   ./scripts/docker-build-push.sh --tag vX   # 额外加一个自定义 tag
#
# 镜像地址（固定，需要改见下方 REGISTRY / NAMESPACE / IMAGE 三个变量）：
#   registry.cn-hangzhou.aliyuncs.com/yangpf_docker/cmcc-cloud-alive
#
# 前提：
#   1. 已 docker login registry.cn-hangzhou.aliyuncs.com（脚本不负责登录）
#   2. Dockerfile 用 vendored wheels 离线安装，build 不需要外网（仅首次拉
#      python:3.11-slim 基础镜像需联网）
#   3. wheels 是 cp311 manylinux x86_64，故固定构建 linux/amd64
#
set -euo pipefail

# ---------- 配置（改这里即可） ----------
REGISTRY="registry.cn-hangzhou.aliyuncs.com"
NAMESPACE="yangpf_docker"
IMAGE="cmcc-cloud-alive"
# ----------------------------------------

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLATFORM="linux/amd64"
PUSH=1
EXTRA_TAG=""

usage() {
    cat <<EOF
用法: $0 [选项]
  --no-push       只构建，不推送到 registry
  --tag <name>    额外打一个自定义 tag（可多次使用，逗号分隔亦可）
  -h, --help      显示帮助
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-push) PUSH=0; shift ;;
        --tag)
            [[ $# -ge 2 ]] || { echo "错误: --tag 需要参数" >&2; exit 2; }
            EXTRA_TAG="$EXTRA_TAG $2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "未知参数: $1" >&2; usage >&2; exit 2 ;;
    esac
done

cd "$ROOT"

# ---------- 前置检查 ----------
if ! command -v docker >/dev/null 2>&1; then
    echo "错误: 找不到 docker 命令，请先安装并启动 Docker。" >&2
    exit 1
fi
if [[ ! -f docker/Dockerfile ]]; then
    echo "错误: 在 $ROOT/docker/Dockerfile 找不到 Dockerfile。" >&2
    exit 1
fi
if ! ls docker/wheels/*.whl >/dev/null 2>&1; then
    echo "错误: docker/wheels/ 下没有 wheel 文件，无法离线构建。" >&2
    echo "       请确认 docker/wheels/ 下的 vendored wheels 完整。" >&2
    exit 1
fi

# git 短 hash（没 git 时退化为时间戳，保证 tag 不为空）
if GIT_TAG="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null)"; then
    : # 用 git hash
else
    GIT_TAG="local-$(date +%Y%m%d%H%M%S)"
fi

FULL="${REGISTRY}/${NAMESPACE}/${IMAGE}"
TAGS=("$GIT_TAG")
# latest 默认带上（--no-push 时也打，方便本地用）
TAGS+=("latest")
for t in $EXTRA_TAG; do
    [[ -n "$t" ]] && TAGS+=("$t")
done

echo "==================== cmcc-cloud-alive 镜像构建 ===================="
echo "  镜像:      $FULL"
echo "  平台:      $PLATFORM"
echo "  tag:       ${TAGS[*]}"
echo "  推送:      $([[ $PUSH -eq 1 ]] && echo "是" || echo "否（--no-push）")"
echo "  仓库根:    $ROOT"
echo "=================================================================="

# ---------- 构建 ----------
BUILD_ARGS=(-f docker/Dockerfile)
for t in "${TAGS[@]}"; do
    BUILD_ARGS+=(-t "$FULL:$t")
done
BUILD_ARGS+=(--platform "$PLATFORM" .)

echo
echo "[1/2] docker build ..."
docker build "${BUILD_ARGS[@]}"

echo
echo "[2/2] docker push ..."
if [[ $PUSH -eq 0 ]]; then
    echo "  跳过推送（--no-push）。本地镜像："
    for t in "${TAGS[@]}"; do
        echo "    $FULL:$t"
    done
    echo
    echo "构建完成（未推送）。"
    exit 0
fi

PUSHED=0
FAILED_TAGS=()
for t in "${TAGS[@]}"; do
    echo "  -> $FULL:$t"
    if docker push "$FULL:$t"; then
        PUSHED=$((PUSHED + 1))
    else
        FAILED_TAGS+=("$t")
        echo "  !! 推送 $t 失败（登录是否过期？docker login $REGISTRY）" >&2
    fi
done

echo
echo "=================================================================="
echo "  完成。成功推送 $PUSHED/${#TAGS[@]} 个 tag。"
if [[ ${#FAILED_TAGS[@]} -gt 0 ]]; then
    echo "  失败的 tag: ${FAILED_TAGS[*]}" >&2
    echo "  常见原因: 未 docker login / token 失效 / 仓库不存在。" >&2
    echo "  排查: docker login $REGISTRY  后重跑本脚本即可。" >&2
    exit 1
fi
echo "  拉取: docker pull $FULL:latest"
echo "=================================================================="
