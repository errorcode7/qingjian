#!/usr/bin/env bash
# //! 把打好的 deb 在目标发行版里真装一遍再卸掉：验 apt 能不能自己解开依赖、postinst 有没有把青简
# //! 写进调用者的输入法列表、装完的二进制与插件认不认得出全部动态库、卸载干不干净。
# //! 静态的落位、权限与图标尺寸在 apps/linux/tests/deb.py 里查，这里不重复。
# //!
# //! 必须在**干净的**目标发行版里跑（CI 里是一个只装了 git 与 curl 的容器）：编译依赖已经躺在环境里
# //! 的话，apt 就不用自己去拉 fcitx5，「依赖声明对不对」这件事就验不出来了。
# //!
# //! 只验「装」不验「用」：容器里没有桌面会话，中文上屏、托盘图标、环境变量注入没法在这里验。
# //!
# //!   apps/linux/tests/deb-install.sh <deb 目录或 .deb 文件…> [--sample]
# //! 需要 root（CI 的容器里就是）与能把依赖装上的 apt 源。
set -euo pipefail

sample=false
targets=()
for argument in "$@"; do
  case "$argument" in
    --sample) sample=true ;;
    --help) echo '用法：deb-install.sh <deb 目录或 .deb 文件…> [--sample]'; exit 0 ;;
    -*) echo "未知参数：$argument" >&2; exit 2 ;;
    *) targets+=("$argument") ;;
  esac
done
((${#targets[@]})) || { echo '要给出 deb 目录或 .deb 文件' >&2; exit 2; }

fail() { printf '安装验证失败：%s\n' "$1" >&2; exit 1; }
installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }

debs=()
for target in "${targets[@]}"; do
  if [[ -d $target ]]; then
    while IFS= read -r file; do debs+=("$(realpath -- "$file")"); done < <(find "$target" -maxdepth 1 -name '*.deb' | sort)
  else
    debs+=("$(realpath -- "$target")")
  fi
done

# 一次只装一个发行版的一套包：同一目录里混进两份的话，后面的断言说不清验的是谁。
main_deb=''
data_deb=''
for file in "${debs[@]}"; do
  case "$(basename "$file")" in
    qingjian-data-*)
      [[ -z $data_deb ]] || fail "有不止一个数据包：$(basename "$data_deb") 与 $(basename "$file")"
      data_deb=$file ;;
    qingjian-*)
      [[ -z $main_deb ]] || fail "有不止一个本体包：$(basename "$main_deb") 与 $(basename "$file")"
      main_deb=$file ;;
  esac
done
[[ -n $main_deb && -n $data_deb ]] || { echo "需要本体包与数据包，现在只看到：${debs[*]:-（空）}" >&2; exit 1; }

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo '需要 root：装包与卸载都要写系统目录（CI 的容器里以 root 跑）' >&2
  exit 1
fi

# postinst 只认调用者（SUDO_USER / PKEXEC_UID）的家目录，容器里这两个变量都没有、它什么都不写，
# 所以造一个用户并把 SUDO_USER 递给 apt（环境变量会一路传到 postinst）。
tester=qingjian-tester
id -u "$tester" >/dev/null 2>&1 || useradd --create-home --shell /bin/bash "$tester"
tester_home=$(getent passwd "$tester" | cut -d: -f6)
[[ -d $tester_home ]] || fail "测试用户 $tester 没有家目录"
profile="$tester_home/.config/fcitx5/profile"

# --no-install-recommends：Recommends 里的前端包在这台机器上没有意义（不测图形输入），
# 但 Depends 必须自己解开——要验的就是这个。
install_packages() {
  SUDO_USER="$tester" DEBIAN_FRONTEND=noninteractive \
    apt-get install -y --no-install-recommends "$main_deb" "$data_deb"
}

echo '── 场景一：全新安装（输入法列表还不存在）'
rm -rf "$tester_home/.config/fcitx5"
install_packages

installed qingjian || fail 'qingjian 没装上'
installed qingjian-data || fail 'qingjian-data 没装上'
# Depends 里写的是 fcitx5 而不是 libfcitx5core7：后者只是库，不带框架进程与 addon 管理器，
# 只声明库依赖的话用户装完一个输入法都看不到。这一条就是守这个。
installed fcitx5 || fail 'Depends 里的 fcitx5 没有被 apt 自动装上'

for path in /usr/bin/qingjian-linux-server /usr/bin/qingjian-settings; do
  [[ -x $path ]] || fail "少了可执行文件 $path"
done
for path in /usr/lib/*/fcitx5/qingjian.so /usr/share/fcitx5/addon/qingjian.conf \
            /usr/share/fcitx5/inputmethod/qingjian.conf /usr/share/applications/qingjian-settings.desktop \
            /etc/xdg/autostart/qingjian-fcitx5.desktop /etc/xdg/autostart/qingjian-server.desktop \
            /etc/environment.d/50-qingjian-im.conf /usr/share/licenses/qingjian/LICENSE; do
  [[ -e $path ]] || fail "装完少了 $path"
done
# 资源根是 /usr/share/qingjian/resources，里面直接是 data/ 与 assets/（运行时 paths::resource_root()
# 就是这个根，词库再拼 data/generated、模型拼 data/models/<模型>），不是把仓库的 data/ 前缀剥掉。
resources=/usr/share/qingjian/resources
if ! $sample; then
  [[ -e $resources/data/generated/dict.qj ]] || fail '数据包没有把词库铺开'
  [[ -e $resources/data/generated/lm.qj ]] || fail '数据包没有把语言模型铺开'
  [[ -e $resources/data/models/hanzhang-zhiwei/hanzhang-zhiwei-small.qjm ]] || fail '数据包没有把含章·知微铺开'
else
  # 样例包不带 data/generated，运行时会回落到 assets/sample/dict.tsv（main.rs）。
  [[ -e $resources/assets/sample/dict.tsv ]] || fail '样例包没有带 assets/sample/dict.tsv'
fi

# 装完的文件必须与包里的 md5sums 一致，否则是 postinst 或别的什么把包内文件改坏了。
if ! drift=$(dpkg -V qingjian); then fail 'dpkg -V 跑不起来'; fi
[[ -z $drift ]] || fail "包内文件与校验和不符：$drift"

# 插件的库靠 Depends 拉进来，缺一个就是「装上了却加载不了」。
for binary in /usr/bin/qingjian-linux-server /usr/bin/qingjian-settings /usr/lib/*/fcitx5/qingjian.so; do
  if missing=$(ldd "$binary" 2>/dev/null | grep 'not found'); then
    fail "$binary 缺动态库：$missing"
  fi
done
command -v fcitx5 >/dev/null || fail 'fcitx5 不在 PATH 里'
fcitx5 --version >/dev/null 2>&1 || fail 'fcitx5 这个二进制起不来'

# postinst 的效果：列表不存在时整份预置，并把青简设为默认。
[[ -f $profile ]] || fail 'postinst 没有写输入法列表'
grep -q '^Name=qingjian$' "$profile" || fail '预置的列表里没有青简'
grep -q '^DefaultIM=qingjian$' "$profile" || fail '预置的列表没把青简设为默认输入法'
[[ $(stat -c '%U' "$profile") == "$tester" ]] || fail "输入法列表的属主不是 $tester，桌面会话里读不到"

echo '── 场景二：卸载（remove，conffiles 与用户数据都该留下）'
DEBIAN_FRONTEND=noninteractive apt-get remove -y qingjian qingjian-data

if installed qingjian; then fail 'remove 之后 qingjian 还装着的'; fi
if [[ -e /usr/bin/qingjian-linux-server ]]; then fail 'remove 之后可执行文件还在'; fi
if [[ -e /usr/share/qingjian/resources ]]; then fail 'remove 之后程序资源还在'; fi
# conffiles 归 dpkg 管：remove 保留（用户可能改过），purge 才删。
if [[ ! -e /etc/environment.d/50-qingjian-im.conf ]]; then fail 'remove 把 conffiles 删了，应当留给 purge'; fi
# 用户数据不归包管，装的时候写进去的输入法列表卸载时不该动。
if [[ ! -f $profile ]]; then fail '卸载动了用户的输入法列表'; fi
grep -q '^Name=qingjian$' "$profile" || fail '卸载改动了用户的输入法列表'

# 不用 apt 的 --reinstall 造「再装一次」：包已经卸干净了，直接再装一遍就是用户重装/升级的样子。
echo '── 场景三：列表里已经有别的输入法（再装一次，只该追加一项）'
cat > "$profile" <<'PROFILE'
[Groups/0]
# Group Name
Name=默认
# Layout
Default Layout=us
# Default Input Method
DefaultIM=pinyin

[Groups/0/Items/0]
# Name
Name=keyboard-us
# Layout
Layout=

[Groups/0/Items/1]
# Name
Name=pinyin
# Layout
Layout=

[GroupOrder]
0=默认
PROFILE
chown "$tester" "$profile"
install_packages

grep -q '^Name=pinyin$' "$profile" || fail '原有的输入法被删了'
grep -q '^DefaultIM=pinyin$' "$profile" || fail '原有的默认输入法被改了'
grep -q '^Name=qingjian$' "$profile" || fail '青简没有被追加进列表'
items=$(grep -c '^\[Groups/0/Items/[0-9][0-9]*\]$' "$profile")
[[ $items -eq 3 ]] || fail "输入法项数不对：原来的 2 项加青简 1 项应当是 3，实际 $items"
[[ $(stat -c '%U' "$profile") == "$tester" ]] || fail "追加之后的列表属主不是 $tester，桌面会话里读不到"

echo '── 场景四：purge（conffiles 也一起走）'
DEBIAN_FRONTEND=noninteractive apt-get purge -y qingjian qingjian-data
if [[ -e /etc/environment.d/50-qingjian-im.conf ]]; then fail 'purge 之后 conffiles 还在'; fi

echo "deb 安装验证通过：$(basename "$main_deb") 与 $(basename "$data_deb")（全新安装 / 卸载 / 追加列表 / purge）"
