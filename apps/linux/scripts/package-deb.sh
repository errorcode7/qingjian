#!/usr/bin/env bash
# //! 打发行版包，出两个 deb：qingjian（二进制、Fcitx5 插件、桌面项、图标、许可与会话集成）
# //! 与 qingjian-data（词库、含章模型与程序资源，与体系结构无关）。
# //! 落位 /usr，卸载交 dpkg（不写 files.py 的 install-manifest.json）；文件清单与用户目录安装
# //! 共用 files.py plan，两条路径装的文件集合不会漂移。
# //!
# //! 要在目标发行版的环境里跑：插件链接构建机的 Fcitx5，跨发行版不通用（构建最低 API 5.1.8，
# //! Ubuntu 24.04 自带的 5.1.7 不满足）。需要 dpkg-deb 与 dpkg-dev（dpkg-architecture 定 multiarch
# //! 库目录、dpkg-shlibdeps 算库依赖；缺 dpkg-dev 时退回按已装库反查包名，拿不到版本下限）。
# //!
# //!   apps/linux/scripts/package-deb.sh [--distro ubuntu-26.04] [--arch amd64] [--version 0.2.2] [--sample] [--no-build]
# //!
# //! 一次只出构建机自己的体系结构：bin/ 下的二进制就是这台机器编的，--arch 只用来声明并核对
# //! （对不上直接失败），不做交叉编译；与体系结构无关的 qingjian-data 固定是 Architecture: all。
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
cd "$root"

maintainer='青简 <cherrypeel@mewpaz.com>'
homepage=https://qingjian.app
distro=''
requested_arch=''
requested_version=''
sample=false
build=true
while (($#)); do
  case "$1" in
    --distro) distro=${2:?--distro 需要发行版标识}; shift 2 ;;
    --arch) requested_arch=${2:?--arch 需要 deb 架构名}; shift 2 ;;
    --version) requested_version=${2:?--version 需要版本号}; shift 2 ;;
    --sample) sample=true; shift ;;
    --no-build) build=false; shift ;;
    --help) echo '用法：package-deb.sh [--distro ubuntu-26.04] [--arch amd64] [--version 0.2.2] [--sample] [--no-build]'; exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done

if [[ -z $distro ]]; then
  if [[ ! -r /etc/os-release ]]; then
    echo '读不到 /etc/os-release，请用 --distro 指定发行版标识' >&2
    exit 1
  fi
  id=$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')
  version_id=$(sed -n 's/^VERSION_ID=//p' /etc/os-release | tr -d '"')
  distro="$id${version_id:+-$version_id}"
fi
[[ $distro =~ ^[a-z0-9][a-z0-9.-]*$ ]] || { echo "发行版标识不合法：$distro" >&2; exit 2; }

if [[ -n $requested_version ]]; then
  # --version 是本地验包用的覆盖值：给了就按原样用，不再自动缀 -dev<commit>
  version=$requested_version
else
  version=$(sed -n 's/^version = "\(.*\)"/\1/p' apps/linux/server/Cargo.toml | head -1)
  [[ -n $version ]] || { echo '读不到 apps/linux/server/Cargo.toml 的版本号' >&2; exit 1; }
  if [[ $version == *-dev ]]; then
    commit=$(git rev-parse --short=7 HEAD 2>/dev/null) || {
      echo '读不到 git 提交号：开发版号要缀提交号才排得进 deb 的版本顺序。' >&2
      echo '工作区属主不是当前用户时 git 会以 dubious ownership 拒绝，先 git config --global --add safe.directory <仓库目录>；也可以用 --version 直接指定版本号。' >&2
      exit 1
    }
    version+="-$commit"
    git diff --quiet HEAD || version+='+'
  fi
fi
# deb 版本里 - 是修订号分隔符：留着会让 0.2.2-dev 排到正式版 0.2.2 之后，正式版反而装不上去。
deb_version=${version//-/\~}

# 只出构建机自己的架构：bin/ 下的二进制就是这台机器编的，标成别的架构会装出问题。
deb_arch=$(dpkg --print-architecture)
if [[ -n $requested_arch && $requested_arch != "$deb_arch" ]]; then
  printf '构建机是 %s，不能打成 %s：包里的二进制是构建机的架构。\n要 %s 的包，就在那个架构的机器或容器里跑。\n' \
    "$deb_arch" "$requested_arch" "$requested_arch" >&2
  exit 1
fi
case "$(uname -m)" in
  x86_64) cpu=x86_64 ;;
  aarch64 | arm64) cpu=arm64 ;;
  *) cpu=$(uname -m) ;;
esac
multiarch=''
if command -v dpkg-architecture >/dev/null 2>&1; then
  multiarch=$(dpkg-architecture -qDEB_HOST_MULTIARCH)
fi
if [[ -z $multiarch ]] && command -v cc >/dev/null 2>&1; then
  multiarch=$(cc -print-multiarch 2>/dev/null || true)
fi
if [[ -z $multiarch ]]; then
  case "$deb_arch" in
    amd64) multiarch=x86_64-linux-gnu ;;
    arm64) multiarch=aarch64-linux-gnu ;;
    armhf) multiarch=arm-linux-gnueabihf ;;
    *) echo '定不了 multiarch 库目录，请安装 dpkg-dev' >&2; exit 1 ;;
  esac
fi

cargo_output=$(realpath -m -- "${CARGO_TARGET_DIR:-$root/target}")
cmake_output="$root/target/fcitx5-package"
server="$cargo_output/release/qingjian-linux-server"
settings="$cargo_output/release/qingjian-settings"
plugin="$cmake_output/qingjian.so"
if $build; then
  cargo build --release --locked -p qingjian-linux-server -p qingjian-settings --target-dir "$cargo_output"
  cmake -S apps/linux/fcitx5 -B "$cmake_output" -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF
  cmake --build "$cmake_output" --parallel "${CMAKE_PARALLEL_LEVEL:-2}"
fi

work="$root/target/deb"
outs="$work/out"
main_root="$work/qingjian-root"
data_root="$work/qingjian-data-root"
rm -rf "$work"
mkdir -p "$main_root/DEBIAN" "$data_root/DEBIAN" "$outs"

plan="$work/plan.tsv"
python3 apps/linux/scripts/files.py plan /usr \
  --plugin-dir "/usr/lib/$multiarch" --data-home /usr/share --config-home /etc \
  "$root" "$server" "$settings" "$plugin" "$sample" fcitx5 > "$plan"

# 程序资源归数据包（与体系结构无关、体积几乎全在这里），其余归本体包。
while IFS=$'\t' read -r target source; do
  tree="$main_root"
  case "$target" in
    /usr/share/qingjian/resources/*) tree="$data_root" ;;
  esac
  mode=644
  case "$target" in
    /usr/bin/*) mode=755 ;;
  esac
  install -Dm"$mode" "$source" "$tree$target"
done < "$plan"

install -Dm644 apps/linux/packaging/deb/50-qingjian-im.conf "$main_root/etc/environment.d/50-qingjian-im.conf"
install -Dm644 apps/linux/packaging/deb/qingjian-fcitx5.desktop "$main_root/etc/xdg/autostart/qingjian-fcitx5.desktop"
install -Dm644 apps/linux/packaging/deb/qingjian-server.desktop "$main_root/etc/xdg/autostart/qingjian-server.desktop"
install -Dm755 apps/linux/packaging/deb/postinst "$main_root/DEBIAN/postinst"
install -Dm644 apps/linux/packaging/deb/conffiles "$main_root/DEBIAN/conffiles"

# 库依赖优先让 dpkg-shlibdeps 算：它会把插件对 Fcitx5 的符号版本绑成 (>= 5.1.x)，正好对上
# 「插件与构建机版本绑定」这件事。算不出来时退回按已装库反查包名，不会漏依赖、但没有版本下限。
shlibs=''
if command -v dpkg-shlibdeps >/dev/null 2>&1; then
  shlibs=$(dpkg-shlibdeps -O \
    -e "$main_root/usr/bin/qingjian-linux-server" \
    -e "$main_root/usr/bin/qingjian-settings" \
    -e "$main_root/usr/lib/$multiarch/fcitx5/qingjian.so" 2>/dev/null \
    | sed -n 's/^shlibs:Depends=//p') || shlibs=''
fi
if [[ -z $shlibs ]]; then
  libraries=''
  for binary in "$main_root/usr/bin/qingjian-linux-server" "$main_root/usr/bin/qingjian-settings" "$main_root/usr/lib/$multiarch/fcitx5/qingjian.so"; do
    # ldd 读不了要明说：下面是 set -e 加 pipefail 下的管道，静静失败时一句提示都打不出来。
    if ! resolved=$(ldd "$binary" 2>&1); then
      printf 'ldd 读不了 %s，定不了库依赖：\n%s\n' "$binary" "$resolved" >&2
      exit 1
    fi
    libraries+=$(printf '%s\n' "$resolved" | awk '/=> \//{print $3}')$'\n'
  done
  shlibs=$(
    printf '%s\n' "$libraries" | sort -u | while read -r library; do
      [[ -n $library ]] || continue
      # dpkg -S 对不属于任何包的库返回非零（本机自编的库）：剔除掉，但要说一声，别静悄悄地漏依赖。
      if ! owner=$(dpkg -S "$library" 2>/dev/null | head -1 | cut -d: -f1) || [[ -z $owner ]]; then
        printf '警告：%s 不属于任何已装的包，没算进依赖\n' "$library" >&2
        continue
      fi
      printf '%s\n' "$owner"
    done | sort -u | paste -sd, -
  )
fi

# fcitx5 必须是硬依赖：libfcitx5core7 只是库，不带框架自己的进程与 addon 管理器，
# 只声明库依赖会出现「包装上了却没有任何输入法」。
main_size=$(du -sk --exclude=DEBIAN "$main_root" | cut -f1)
data_size=$(du -sk --exclude=DEBIAN "$data_root" | cut -f1)

cat > "$main_root/DEBIAN/control" <<EOF
Package: qingjian
Version: $deb_version
Architecture: $deb_arch
Maintainer: $maintainer
Depends: qingjian-data (= $deb_version), fcitx5${shlibs:+, $shlibs}
Recommends: fcitx5-frontend-gtk3, fcitx5-frontend-gtk4, fcitx5-frontend-qt6, fcitx5-config-qt
Homepage: $homepage
Section: utils
Priority: optional
Installed-Size: $main_size
Description: 青简输入法（Fcitx5 引擎与设置程序）
 青简在候选词旁显示正在学习语言的译词，支持整句输入、双拼、拼写纠错和
 本地整句重排，转换与学习都在本机完成。
 .
 本包装二进制、Fcitx5 插件、桌面项、图标与许可，并让 Fcitx5 与青简后端
 随桌面会话启动；词库与本地整句模型在 qingjian-data 里，两个包要一起装。
 .
 输入法环境变量（XMODIFIERS、QT_IM_MODULE）只能在会话启动时注入，装完
 需要注销重新登录一次。
EOF

cat > "$data_root/DEBIAN/control" <<EOF
Package: qingjian-data
Version: $deb_version
Architecture: all
Maintainer: $maintainer
Homepage: $homepage
Section: utils
Priority: optional
Installed-Size: $data_size
Description: 青简输入法的词库、本地整句模型与程序资源
 词库、n-gram 语言模型与释义表，以及候选面板和设置程序用的样例、等级与
 emoji 数据。与体系结构无关，各发行版共用同一份。
EOF

# dpkg -V 是拿包里的 DEBIAN/md5sums 与磁盘上的文件比对：手搓 deb 不会自己生成这份文件，
# 不写它，「装完之后文件有没有被改坏」就永远验不出来（dpkg -V 直接没得比，一声不响地过）。
# 条目只列普通文件，路径相对包根、不带前导斜杠；conffiles 也在里面（dpkg 自己也这么记）。
make_md5sums() {
  local tree=$1
  (
    cd "$tree"
    find . -path ./DEBIAN -prune -o -type f -print0 \
      | LC_ALL=C sort -z \
      | xargs -0 -r md5sum \
      | sed 's|  \./|  |'
  ) > "$tree/DEBIAN/md5sums"
}
make_md5sums "$main_root"
make_md5sums "$data_root"

compression=(-Zzstd)
if ! dpkg-deb --help 2>&1 | grep -qi zstd; then
  compression=(-Zxz)
fi
main_deb="$outs/qingjian-$version-linux-$distro-$cpu.deb"
data_deb="$outs/qingjian-data-$version-linux-all.deb"
dpkg-deb --build --root-owner-group "${compression[@]}" "$main_root" "$main_deb"
dpkg-deb --build --root-owner-group "${compression[@]}" "$data_root" "$data_deb"

echo "已打包：$main_deb"
echo "已打包：$data_deb"
echo '安装时两个包要一起交给 apt，否则 qingjian-data 这个依赖解不开：'
echo "  sudo apt install ./$(basename "$main_deb") ./$(basename "$data_deb")"
