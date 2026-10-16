#!/usr/bin/env bash
# publish job：把各平台传上来的 SHA256SUMS-<平台> / build-info-<平台>.json 合成一份 SHA256SUMS 与 build-info.json，删掉片段，草稿转正。
#
#   tools/release/finish-release.sh <标签> <版本> <输出目录>
#
# build-info.json 顶层的 commit / built_at / toolchain / data_* 是 releases_json.py 读的（built_at 取最晚的平台），各平台的构建机在 platforms 里。
set -euo pipefail

TAG="$1"
VERSION="$2"
OUT="$3"
mkdir -p "$OUT"
gh release download "$TAG" --pattern 'SHA256SUMS-*' --pattern 'build-info-*.json' --dir "$OUT" --clobber
cat "$OUT"/SHA256SUMS-* | sort -k2 | tee "$OUT/SHA256SUMS"
# 顶层这几个字段是整次发布的、不分平台，谁有值取谁的：deb 的片段由不下载产品数据的 job 传上来
# （只上传容器矩阵的产物），按文件名排序还可能排在前面，不能直接取 .[0]。
jq -s --arg version "$VERSION" --arg tag "$TAG" \
  'def first_nonempty(field): ([.[] | field | select(. != "")] + [""]) | first;
   {version: $version, tag: $tag, commit: first_nonempty(.commit), built_at: (map(.built_at) | max), toolchain: first_nonempty(.toolchain),
    data_tag: first_nonempty(.data_tag), data_sha256: first_nonempty(.data_sha256), model_sha256: first_nonempty(.model_sha256),
    p2c_model_sha256: first_nonempty(.p2c_model_sha256),
    platforms: (map({(.platform): {built_at, runner}}) | add)}' \
  "$OUT"/build-info-*.json | tee "$OUT/build-info.json"
gh release upload "$TAG" "$OUT/SHA256SUMS" "$OUT/build-info.json" --clobber
for fragment in "$OUT"/SHA256SUMS-* "$OUT"/build-info-*.json; do
  gh release delete-asset "$TAG" "$(basename "$fragment")" --yes
done
# 预发布（0.1.4-beta.1）不抢 GitHub 的 latest
LATEST=(--latest); [[ "$VERSION" == *-* ]] && LATEST=(--latest=false)
gh release edit "$TAG" --draft=false "${LATEST[@]}"
