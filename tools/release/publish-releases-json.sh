#!/usr/bin/env bash
# 发版最后一步：从 CHANGELOG.md + GitHub Releases API + 各版本的 SHA256SUMS / build-info.json 生成 releases.json，
# 挂到本次发布上，并覆盖到 GitHub 的 latest 发布上（官网固定取 releases/latest/download/releases.json，
# 而 latest 不一定是本次：各平台版本号独立，Windows 内测版发出去时 latest 可能仍是 macOS 的那版）。
#
#   tools/release/publish-releases-json.sh <本次发布的标签> <输出目录>
#
# 需要 gh（带仓库写权限）、cargo 与 python3；签名另需环境变量 QINGJIAN_INDEX_SIGNING_KEY（SIGN_INDEX=false 可跳过，仅限调试）。
# Windows runner 上 python3 叫 python，用 PYTHON 环境变量指定。
set -euo pipefail

TAG="$1"
OUT_DIR="$2"
PYTHON="${PYTHON:-python3}"
REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY 未设}"
TMP="$(mktemp -d)"

gh api "repos/$REPO/releases" --paginate > "$TMP/releases.api.json"
META="$TMP/meta"
for tag in $(gh release list --limit 100 --json tagName --jq '.[].tagName' | grep -E '^(macos-|windows-|linux-)?v[0-9]'); do
  mkdir -p "$META/$tag"
  gh release download "$tag" --pattern SHA256SUMS --pattern build-info.json --dir "$META/$tag" || true
done
mkdir -p "$OUT_DIR"
"$PYTHON" tools/release/releases_json.py --repo "$REPO" \
  --api-json "$TMP/releases.api.json" --meta-dir "$META" --out "$OUT_DIR/releases.json"
cat "$OUT_DIR/releases.json"

# 分离签名 releases.json.sig：软件内检查更新按内置公钥验，验不过就当没查到；私钥在 QINGJIAN_INDEX_SIGNING_KEY。
# 调试流水线时把 SIGN_INDEX 设成 false 可跳过签名（产物不带 .sig，客户端当成查不到更新，不是可发版状态）。
SIGN_INDEX="${SIGN_INDEX:-true}"
files=("$OUT_DIR/releases.json")
if [[ "$SIGN_INDEX" == "true" ]]; then
  cargo run --release --locked -q -p qingjian-release-sign -- sign "$OUT_DIR/releases.json"
  cargo run --release --locked -q -p qingjian-release-sign -- verify "$OUT_DIR/releases.json"
  files+=("$OUT_DIR/releases.json.sig")
else
  echo "警告：SIGN_INDEX=$SIGN_INDEX，本次不签名。releases.json 没有 .sig，客户端会当成查不到更新，只用于调试。" >&2
  echo "::warning::releases.json 未签名（SIGN_INDEX=false），更新索引对客户端不可用。"
  # 本地重跑时目录里可能留着上一次的 .sig，内容与新索引不符，绝不能传上去。
  rm -f "$OUT_DIR/releases.json.sig"
fi

gh release upload "$TAG" "${files[@]}" --clobber
LATEST="$(gh release view --json tagName --jq .tagName)"
if [[ "$LATEST" != "$TAG" ]]; then
  echo "latest 是 $LATEST，也覆盖一份 releases.json 上去"
  gh release upload "$LATEST" "${files[@]}" --clobber
fi
