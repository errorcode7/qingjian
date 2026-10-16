#!/usr/bin/env bash
# 让官网（qingjian-team/qingjian-web，Cloudflare Workers Builds 按仓库提交自动构建）重新构建：
# 往它的 src/content/upstream.json 写一笔「本次发版的标签 / 文档提交」并推一个提交。
# 官网构建时拉最新 Release 的 releases.json，文档按记下的提交号拉主仓库 docs/user；只在发版时调用，文档只随发版更新。
#
# 用法：tools/release/bump-website.sh（在 release.yml 里跑，读 TAG 标签，没设就退回 GITHUB_REF_NAME）
# 需要环境变量 QINGJIAN_WEB_TOKEN：对 qingjian-web 有 Contents: write 的 fine-grained PAT。
set -euo pipefail

token=${QINGJIAN_WEB_TOKEN:?缺 QINGJIAN_WEB_TOKEN}
repo=${QINGJIAN_WEB_REPO:-qingjian-team/qingjian-web}
# 文档提交取检出的 HEAD：手动触发发版时 GITHUB_SHA 是分支顶端，不是被标记的那个提交。
sha=$(git rev-parse HEAD)
tag=${TAG:-${GITHUB_REF_NAME:-}}
: "${tag:?缺 TAG（版本标签）}"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
git clone -q --depth 1 "https://x-access-token:${token}@github.com/${repo}.git" "$work/web"
cd "$work/web"

file=src/content/upstream.json
mkdir -p "$(dirname "$file")"
message="同步主仓库：发版 ${tag}"
python3 - "$file" "$tag" "$sha" <<'PY'
import json, sys, datetime
path, release, sha = sys.argv[1:4]
json.dump(
    {"release": release, "docs": sha, "updated": datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%dT%H:%M:%SZ")},
    open(path, "w", encoding="utf-8"),
    ensure_ascii=False,
    indent=2,
)
open(path, "a", encoding="utf-8").write("\n")
PY
git add "$file"
if git diff --cached --quiet; then
  echo "官网仓库无需更新"
  exit 0
fi
git -c user.name="qingjian-ci" -c user.email="ci@qingjian.app" commit -q -m "$message" -m "主仓库提交 ${sha}"
git push -q origin HEAD
echo "已推送到 ${repo}：${message}"
