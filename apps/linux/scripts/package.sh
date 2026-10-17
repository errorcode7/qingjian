#!/usr/bin/env bash
# //! 打预编译包 target/linux-package/qingjian-<版本>-linux-<cpu>.tar.gz：Server、设置程序、Fcitx5 插件、产品数据与安装脚本。
# //! 先跑 tools/release/data-fetch.sh；包里按仓库相对路径放文件，解开后的 install.sh 与源码安装共用 files.py 的清单与校验。
# //!
# //!   apps/linux/scripts/package.sh [--arch x86_64|arm64]
# //!
# //! <cpu> 取构建机的 uname -m，但 arm 上 uname 给的是 aarch64，而下载页与更新器认的是 arm64
# //! （qingjian-update 的 target.rs 也吐 arm64），所以这里做一次映射。--arch 只用来核对构建机架构
# //! （对不上直接失败），不做交叉编译。--arch 也收 deb 名（amd64 / arm64），内部换成 cpu 名再核，
# //! 与 package-deb.sh 的 --arch 保持一致：两个脚本各写各的值域，正是最容易打错包的地方。
set -euo pipefail

requested_cpu=''
while (($#)); do
  case "$1" in
    --arch) requested_cpu=${2:?--arch 需要架构名}; shift 2 ;;
    --help) echo '用法：package.sh [--arch x86_64|arm64]
--arch 也收 deb 名（amd64），内部换成 cpu 名再与构建机核对'; exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
cd "$root"
version=$(sed -n 's/^version = "\(.*\)"/\1/p' apps/linux/server/Cargo.toml | head -1)
if [[ "$version" == *-dev ]]; then
  version+="-$(git rev-parse --short=7 HEAD)"
  git diff --quiet HEAD || version+='+'
fi
case "$(uname -m)" in
  x86_64) cpu=x86_64 ;;
  aarch64 | arm64) cpu=arm64 ;;
  *) cpu=$(uname -m) ;;
esac
# --arch 收两套写法：cpu 名（文件名用）与 deb 名（dpkg 用）。归一成 cpu 名再比。
case "$requested_cpu" in
  amd64 | x86_64) requested_cpu=x86_64 ;;
  aarch64 | arm64) requested_cpu=arm64 ;;
esac
if [[ -n $requested_cpu && $requested_cpu != "$cpu" ]]; then
  printf '构建机是 %s，不能打成 %s：包里的二进制是构建机的架构。\n要 %s 的包，就在那个架构的机器上跑。\n' \
    "$cpu" "$requested_cpu" "$requested_cpu" >&2
  exit 1
fi
tools/release/data-fetch.sh --verify
[[ -f data/models/hanzhang-zhiwei/hanzhang-zhiwei-small.qjm && -f data/models/hanzhang-tongbian/hanzhang-tongbian-small.qjm && -f data/generated/dict.qj ]] || { echo '缺少产品数据或含章模型，先运行 tools/release/data-fetch.sh' >&2; exit 1; }

cargo_output=$(realpath -m -- "${CARGO_TARGET_DIR:-$root/target}")
cargo build --release --locked -p qingjian-linux-server -p qingjian-settings --target-dir "$cargo_output"
cmake_output="$root/target/fcitx5-package"
cmake -S apps/linux/fcitx5 -B "$cmake_output" -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF
cmake --build "$cmake_output" --parallel "${CMAKE_BUILD_PARALLEL_LEVEL:-2}"

name="qingjian-$version-linux-$cpu"
out="$root/target/linux-package"
stage="$out/$name"
rm -rf "$stage" "$out/$name.tar.gz"
mkdir -p "$stage/bin" "$stage/lib"
install -m 755 "$cargo_output/release/qingjian-linux-server" "$cargo_output/release/qingjian-settings" "$stage/bin/"
install -m 755 "$cmake_output/qingjian.so" "$stage/lib/"
install -m 755 apps/linux/scripts/package-install.sh "$stage/install.sh"
install -m 755 apps/linux/scripts/uninstall.sh "$stage/"
install -m 644 apps/linux/scripts/files.py "$stage/"
# 产品数据只带压缩包，install.sh 装前解开（files.py 按 data.lock 校验压缩包，再按包内摘要逐个校验解出的文件）
cp -r --parents LICENSE apps/settings/linux assets/icon/linux/hicolor assets/stroke/LICENSE-CNS11643.txt apps/linux/fcitx5/data assets/sample assets/glossary assets/levels assets/emoji \
  tools/release/data.lock target/release-data/qingjian-data.tar.gz "$stage/"
tar -C "$out" -czf "$out/$name.tar.gz" "$name"
echo "已打包：$out/$name.tar.gz"
