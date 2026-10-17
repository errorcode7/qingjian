# Linux Fcitx5 默认面板

Linux Server 在 `[predict] enabled = true` 且密钥可用时接入共享的 `CloudPredictor`，沿现有 Poll 帧返回异步云端候选和整句补全。云端词只补第一页末尾未被用户选中的格，默认面板用 ☁ 标记词并在辅助行显示整句；会话切换、失焦和隐私边界会作废旧结果。Fcitx5 插件从有效的 `surroundingText()` 读取应用光标前后文，跳过选区并各截取最多 80 字；Server 在敏感输入中忽略它。不做云端译词兜底；`[predict]` 配置热加载会重建客户端，撤销旧请求、翻译评审与所有会话中的旧云候选。Fcitx5 的 Sensitive、Password、Disable 能力由插件上报给 Server。

第一阶段保留 Rust Server、薄插件和用户目录安装。输入模式、组句、选词、翻页、隐私和失焦提交均在 Server；
插件负责 Fcitx 事件与默认预编辑 / 候选 API。长期自绘方向不变，后续由 Server 渲染并管理 X11 窗口，或向 GNOME 扩展发送位图；本阶段不带相关源码、补丁、渲染 FFI、服务管理或 Debian 包。

## 构建与测试

需要 Rust 1.96、CMake 3.16、C++20 编译器、pkg-config，以及 OpenSSL（`libssl-dev`，云服务依赖的 TLS 绑定要它）、Fcitx5 Core/Config/Utils 和 nlohmann-json 的开发包；`install.sh` 开头会检查并列出缺的。
构建最低 API 为 Fcitx5 5.1.8，CI 使用 Ubuntu 26.04 的 Fcitx5 5.1.19；Ubuntu 24.04 自带的 5.1.7 不满足要求。
桌面运行已验证的范围见下文，构建版本门槛不代表全部桌面已验收。

```sh
cargo test -p qingjian-linux-server --locked
cargo fmt --all --check
cargo clippy --workspace --exclude qingjian-macos --all-targets --locked -- -D warnings
cargo test --workspace --exclude qingjian-macos --locked
cargo build -p qingjian-linux-server --locked
cmake -S apps/linux/fcitx5 -B target/fcitx5-stage1 -DCMAKE_BUILD_TYPE=Debug -DBUILD_TESTING=ON
cmake --build target/fcitx5-stage1 --parallel 2
env -u DBUS_SESSION_BUS_ADDRESS ctest --test-dir target/fcitx5-stage1 --output-on-failure < /dev/null
python3 apps/linux/tests/installation.py
```

CTest 的 `real-server` 实际运行 Rust Server 并通过 InputContext 输入与点击，默认二进制位置 `target/debug/qingjian-linux-server`。
自定义 Cargo target 时传 `-DQINGJIAN_SERVER_EXECUTABLE=/绝对路径/qingjian-linux-server`。
测试实例关闭所有 Fcitx addon，不依赖桌面总线；插件初始化本身也不连接 D-Bus。真实桌面测试才需要 `fcitx5-modules`、GTK / Qt 输入模块及 `dbus-run-session`。

## 协议与状态

同用户 Unix socket，长度前缀为 4 字节小端，单消息上限 16 MiB；每次插件收发共用 200 ms 截止时间。
插件只持有一条连接和一个 I/O watcher，每个 InputContext 分配独立、递增的 session ID。
每个会话先 `OpenSession` 校验共享协议版本（`PROTOCOL_VERSION`），再协商 `LinuxHello` v3，携带 session/generation/context，返回会话编号和既有预编辑设置。
首次能力确认前不接受输入；握手与能力状态逐会话保存。同一连接支持超过 64 个上下文，64 条连接的资源保护不限制单连接会话数。
Linux 的首个回包仍是含 `linux_ui` 的 `Update`，不额外发送 Windows DLL 使用的 `SessionOpened`；旧版插件的协议 7 / 8 连接会被拒绝，升级时需同时更新 Server 与插件。
旧版本或损坏响应关闭连接、清空显示并放行当前输入；重连创建全新输入状态，旧提交不会重放。
插件先交付有效上屏，再清空或更新预编辑，避免 Chromium 原生 Wayland 在这两步倒置时重复上屏（#213）。
上屏与显示回调都可能同步重入；上屏前和重画前检查上下文存活、连接代次、生命周期、显示修订号与帧身份，以及焦点和能力。
上屏回调内的新按键即使不改变生命周期，也会使旧帧失效，外层不得覆盖新组句。已交付的上屏不撤销、不重放；重入或显示失败后仍保留已接受按键的 Consumed 结果。

同一上下文停用后保留会话和中英模式；Reset 只丢弃输入。Password / Disable 关闭目标会话，恢复普通输入后分配新编号。
销毁上下文时撤销安全引用并排队 CloseSession，由事件循环延迟发送，不阻塞析构，也不关闭其他会话。
共享连接故障先让全部会话失效，再清理各自显示；清理回调期间不重连。

LinuxEvent 转发能力、按下 / 释放、焦点、停用原因、客户端预编辑事实、带帧身份的候选点击和翻页。按键事件可带应用前后文；旧插件省略此字段时 Server 仍可解析。焦点恢复与候选点击不会复用旧前后文。
选区翻译使用 `[shortcut] translate_selection`（Linux 缺省 `Alt + Shift + T`）；新插件在按键事件标记 `selection_supported`，Server 只向支持的插件返回 `RequestSelection`，兼容旧插件。插件从有效的 `surroundingText()` 读取最多 500 字选区并回 `LinuxEvent::Selection`。评审候选无预编辑，返回帧的 `translation_pending` 让插件在「翻译中…」期间轮询；提交前再次核对选区文字和光标位置。焦点、隐私、Reset、停用会取消翻译。
空能力是普通输入；Sensitive 可组句但不学习、不记输入文本；Password / Disable 优先禁用并丢弃输入。
能力先由 Server 确认，再清理可能同步重入的预编辑；Reset / 焦点变化不会丢掉能力通知，清理中重入的新按键已受新隐私状态约束。
能力变化清理组句、暂存透传、学习链与补全；能力即将改变时的 deactivate 原因也触发清理，即使框架此刻仍返回旧能力。
FocusOut 的行内预编辑由框架或声明 ClientUnfocusCommit 的客户端提交，Server 不重复返回它；仅窗口预编辑才返回原样组句。

每次候选响应绑定 generation/context/revision，revision 在整个 Server 内递增；过期或跨会话点击返回 Ignored，不改变当前会话的展示状态。
默认面板只展示第一条释义，完成面板更新后报告当前页对应的 `(候选槽位, 0)`。
隐藏、失焦、私密、无候选与过期回报不产生有效展示记录；Server 只凭已生成帧不记展示。

组句期间插件每 80 ms 发一次 `Poll`（与 Windows DLL 的轮询间隔相同），Server 先 tick 再回当前帧。
帧与该会话上次发出的相同时沿用展示身份（revision 不变），插件不重画也不重复回报；本地整句模型换了顺序才推进 revision，插件按版本号推进重画并回报。
帧为空、Reset、失焦、停用、断线时插件停表；协议版本不变。

## 本地整句模型

Server 启动时按 `[model] enabled`（缺省开）在后台线程加载模型并预热，`find_model` 优先找用户目录 `~/.local/share/qingjian/models/hanzhang-tongbian/` 与随包的 `resources/data/models/hanzhang-tongbian/`，然后回退知微；旧用户目录仍可读取。改了 `[model]` 由配置热加载在后台加载或卸载。

配置热加载在 `dispatch/reload`（对齐 Windows Server）：主循环 `tick` 每秒看一次 `config.toml` 的 mtime 与用户 `dicts/` 快照，变了就重读，重设的项与 `main.rs` 启动时一致；解析失败保持原配置。例外：`[general] preedit` 在会话握手时交给插件、`input_log` 只在装配时接，这两样改了仍要重启服务。
节拍与 Windows Server 的 `dispatch/rescore` 相同：缓冲变化后起 80 ms 防抖，到点把整句路径送去后台打分，每 20 ms 收一次，最长等 2 s；
结果到了只在用户还看着第一页、没动过高亮时重建候选布局，下一次 `Poll` 回的帧就是新顺序。主循环按 `Router::next_tick` 的绝对到点时间等消息，空闲时一秒一次落盘学习。
模型在后台接上时用户正在组句，Server 补查一次攒下整句路径再起防抖，这一轮不错过重排。前文用本会话最近上屏的字，首版不读应用光标前文。

## 路径和排错

用户安装与手动启动见 [Linux 用户说明](../user/getting-started/linux.md)。安装只登记实际绝对插件库路径，不修改系统 Fcitx5 搜索规则。
`QINGJIAN_SOCKET` 可指定绝对 socket 路径；缺省为 `$XDG_RUNTIME_DIR/qingjian.sock`，无 runtime 时用 `/tmp/qingjian-<uid>/qingjian.sock`。
父目录须归当前用户且不可被其他用户写入；socket 权限为 0600。`QINGJIAN_RESOURCES` 覆盖资源根，`QINGJIAN_DICT` 可指定测试词库。
默认数据从可执行文件旁 `../share/qingjian/resources` 找，支持源码开发目录回退。

未出候选时先确认手动 Server 在运行，再查看 `$XDG_STATE_HOME/qingjian/logs/server.*.log`（缺省 `~/.local/state`）。
输入日志由 `[general] input_log` 控制；用户配置和学习文件始终保存在 XDG 用户目录，卸载不删除。

## 发行版打包

做系统级包（deb / rpm / AUR 等）时，把 `assets/icon/linux/hicolor/` 下八档 PNG（16/22/24/32/48/64/128/256）逐档装到
`/usr/share/icons/hicolor/<尺寸>x<尺寸>/apps/qingjian.png`，文件名保持 `qingjian.png`。八档已随仓库栅格化提交，打包不依赖
ImageMagick；不要把 1024px 源图塞进尺寸目录，也不要只装 `resources/assets/` 里的程序资源副本（图标主题不读该路径），
否则不缩放的托盘会显示巨图（#547）。安装循环片段与图标缓存刷新说明见
[图标说明](../../assets/icon/README.md#linux-发行版打包)。

`apps/linux/scripts/package-deb.sh` 出两个包，都落位 `/usr`、卸载交 dpkg（不写用户目录安装那份 `install-manifest.json`）：

- `qingjian-<版本>-linux-<发行版>-<cpu>.deb`（`qingjian`）：`/usr/bin/` 下两个可执行、`/usr/lib/<multiarch>/fcitx5/qingjian.so`、八档图标、
  `/usr/share/licenses/` 与 `/usr/share/qingjian/` 下除 `resources/` 外的资源，外加 `postinst`、`conffiles` 与三份会话集成文件——
  `/etc/environment.d/50-qingjian-im.conf`（`XMODIFIERS` / `QT_IM_MODULE` / `QT_IM_MODULES`）与 `/etc/xdg/autostart/` 下 Fcitx5、青简后端两个 desktop 项。
- `qingjian-data-<版本>-linux-all.deb`（`qingjian-data`，`Architecture: all`）：词库、两份含章模型与 `/usr/share/qingjian/resources/`，各发行版共用一份。

文件名里的 `<cpu>` 取构建机的 `uname -m`（`x86_64` / `arm64`），`Architecture` 字段取 `dpkg --print-architecture`（`amd64` / `arm64`）——
两套写法在 arm 上正好同名，amd64 上一个是 `x86_64`、一个是 `amd64`。不做交叉编译：`--arch` 只核对构建机架构，对不上直接失败，
要另一个架构的包就在那个架构的机器或容器里跑（CI 里 `amd64` 用 `ubuntu-26.04`，`arm64` 用 `ubuntu-26.04-arm`）。

文件清单不另写一份：与用户目录安装共用 `files.py plan`（输出「目标路径 → 源文件」），两条路径装的文件集合不会漂移，
`apps/linux/tests/deb.py` 就把包内文件集合与 `plan` 的输出对起来查，任一侧多出或少掉都报错。

本体包的 `Depends` 里 **`fcitx5` 是硬依赖**：`libfcitx5core7` 只是库，不带框架自己的进程与 addon 管理器，只声明库依赖会出现「包装上了却没有任何输入法」。
库依赖优先交给 `dpkg-shlibdeps`，它顺带把插件对 Fcitx5 的符号版本绑成 `(>= 5.1.x)`，正好对上「插件与构建机版本绑定」这件事；
拿不到时退回按已装库反查包名（有依赖、没有版本下限）。deb 版本号要把上游的 `-dev` 转成 `~`——`-` 是 deb 的修订号分隔符，
留着会让 `0.2.2-dev` 排到正式版 `0.2.2` **之后**，正式版反而装不上去（`0.2.2~dev~c97ff2b < 0.2.2`）。

`postinst` 只为一个目的服务：装完就能用。它把青简加进调用者（`SUDO_USER` / `PKEXEC_UID`，两者都拿不到就什么都不做）的
`~/.config/fcitx5/profile`——列表不存在就整份预置（含 `DefaultIM=qingjian`），已存在就只追加一项、绝不动用户已有的分组与其它输入法。
它**不改 `Library=`**：系统级 addon 用裸名 `Library=qingjian`，库放 `/usr/lib/<multiarch>/fcitx5/` 由 Fcitx5 自动拼 `.so`；
写成绝对路径是用户目录安装特有的（那是为了不污染系统 Fcitx5 的搜索规则），见 `files.py` 的 `install()`。

两个包要在**目标发行版自己的环境**里构建，不能拿一个发行版的包往下兼容：插件链接构建机的 Fcitx5，构建最低 API 5.1.8，
Ubuntu 24.04 自带的 5.1.7 不满足。`package-deb.sh --distro <标识>` 定文件名里的发行版标识，缺省从 `/etc/os-release` 取；
CI 用容器矩阵逐发行版构建，见[发版流程](release.md#ci-与发布的-workflow)。
`--arch` 只用来声明并核对构建机的体系结构（对不上直接失败），不做交叉编译；`--version` 是本地验包时覆盖版本号用的。

安装验证分两层，都在 `.github/workflows/package-deb.yml` 里：`build` 跑 `apps/linux/tests/deb.py` 做静态验收
（落位、权限、图标尺寸、控制区字段、包内文件集合与 `files.py plan` 对账），`install-test` 再开一个**干净的**同发行版容器，
用 `apps/linux/tests/deb-install.sh` 把两个包真装一遍又卸一遍——验 apt 能不能自己把 `fcitx5` 拉进来、`postinst` 有没有把青简
写进调用者的输入法列表（列表不存在就整份预置、已存在就只追加一项）、装完的二进制与插件 `ldd` 有没有缺口、`dpkg -V` 有没有漂移、
`remove` 保留 conffiles 而 `purge` 删掉它们。「干净」是要点：编译依赖已经躺在容器里的话，apt 就不必自己去拉 `fcitx5`，
依赖声明对不对就验不出来了。这一层只验「装」不验「用」——容器里没有桌面会话，中文上屏、托盘图标、环境变量注入要到真机上验。

## 验证环境

- Ubuntu 26.04，未打补丁的 Fcitx5 5.1.19-1 / Core7 / modules，GTK4 4.22.4、Qt6 6.10.2。
- 隔离 X11（Xvfb）、私有 D-Bus：GTK4、Qt6。
- 真实桌面（2026-09-20）：GNOME 50 原生 Wayland，文本编辑器（GTK4）、FeatherPad（Qt6）、Firefox（snap）。Ubuntu 26.04 的 GNOME 已没有 X11 登录项。
  默认面板的外观与位置由 Fcitx5 决定：GTK4 应用里是输入模块自己画的黑白面板，Firefox 里是 Fcitx5 的橙色面板且与光标同一行，Fcitx5 自带拼音表现相同。
- 真实桌面（2026-09-22，本地整句模型）：CachyOS，niri（原生 Wayland），Fcitx5 5.1.22，Microsoft Edge（Chromium，`--enable-wayland-ime`）与 Konsole（Qt6）：停顿后整句候选按模型换序。
- 未验证：KDE 与其他桌面、其他发行版、GTK3 / Qt5 应用、真实 X11 桌面会话。

## PR #351 回归验证

在 Ubuntu 26.04.1 容器、Fcitx5 5.1.19-1 中，旧分支复现了 panel 与 lifecycle 用例的 13 个失败：旧帧省略可选 `kind` / `sentence` 时，渲染抛异常使连接断开，进而丢失预编辑、失焦提交和后续能力通知。修复保留旧帧测试形状，新增云字段展示和选区提交复核 / 重入用例，CTest 54 项全过（stdin 接 `/dev/null`）。

同一环境以 Xvfb、私有 D-Bus 和真实 GTK3 输入框验证：输入 `nihao` 后空格只上屏一次「你好」；把 `[predict]` 从关闭改为指向本地模拟服务，同一 Server 进程能发出云联想请求。该 GTK3 控件虽保留选中状态，传给 Fcitx5 的 surrounding text 未包含选区锚点，故本次未完成它的选区替换实测；选区复核由 CTest 覆盖。已有 Fcitx4 桌面验证见 [Fcitx4 适配](linux-fcitx4.md#本机验证)。
