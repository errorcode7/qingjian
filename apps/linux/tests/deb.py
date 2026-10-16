#!/usr/bin/env python3
# //! 发行版包（deb）验收：控制区字段与依赖、文件落位与权限、图标尺寸、清单与 files.py 一致。
# //! 用法：deb.py [--sample] <deb 或装 deb 的目录>…
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[3]

def field(package, name):
    return subprocess.run(['dpkg-deb', '-f', str(package), name], capture_output=True, text=True, check=True).stdout.strip()

def extract(package, into):
    """解出数据区；返回 {包内绝对路径: 本地路径}，只含文件。"""
    subprocess.run(['dpkg-deb', '-x', str(package), str(into)], check=True)
    base = Path(into)
    return {f'/{item.relative_to(base)}': item for item in base.rglob('*') if item.is_file()}

def control_area(package, into):
    subprocess.run(['dpkg-deb', '-e', str(package), str(into)], check=True)
    return Path(into)

def png_size(path):
    header = path.read_bytes()[:24]
    assert header[:8] == b'\x89PNG\r\n\x1a\n', f'{path} 不是 PNG'
    return struct.unpack('>II', header[16:24])

def check_order(version):
    """带预发布后缀的版本必须排在同号正式版之前，否则正式版装不上去。"""
    if '~' not in version:
        return
    release = version.split('~')[0]
    result = subprocess.run(['dpkg', '--compare-versions', version, 'lt', release])
    assert result.returncode == 0, f'{version} 没有排在正式版 {release} 之前'

def check_main(package, sample):
    version = field(package, 'Version')
    assert field(package, 'Package') == 'qingjian'
    assert field(package, 'Architecture') not in ('all', ''), '本体包不能是体系结构无关的'
    depends = field(package, 'Depends')
    # 只声明 libfcitx5core7 这类库依赖时，用户装上了也没有 Fcitx5 框架可用（没有任何输入法）。
    assert 'fcitx5' in [item.split()[0] for item in depends.split(',')], f'Depends 里没有硬依赖 fcitx5：{depends}'
    assert 'qingjian-data (= ' in depends, f'Depends 没有钉住配套的数据包：{depends}'
    assert 'fcitx5-frontend-gtk' in field(package, 'Recommends')
    check_order(version)

    with tempfile.TemporaryDirectory(prefix='qingjian-deb-') as temporary:
        files = extract(package, Path(temporary) / 'data')
        control = control_area(package, Path(temporary) / 'control')

        plugins = [path for path in files if path.endswith('/fcitx5/qingjian.so')]
        assert len(plugins) == 1, f'插件不在 Fcitx5 的 addon 目录里：{plugins}'
        plugin = plugins[0]
        assert plugin.startswith('/usr/lib/'), f'插件要装进 /usr/lib/<multiarch>：{plugin}'
        assert plugin.endswith('/fcitx5/qingjian.so'), f'插件路径不对：{plugin}'
        # 共享库按发行版惯例不带执行位；两个可执行文件必须带。
        assert files[plugin].stat().st_mode & 0o111 == 0, f'插件不该带执行位：{plugin}'
        assert files['/usr/bin/qingjian-linux-server'].stat().st_mode & 0o111, '服务没有执行位'
        assert files['/usr/bin/qingjian-settings'].stat().st_mode & 0o111, '设置程序没有执行位'

        # addon 配置与桌面项保持相对名：装到 /usr 之后 fcitx5 用标准路径找库、/usr/bin 在 PATH 里，
        # 写成绝对路径只有用户目录安装才需要（files.py install 会改写，deb 不走那条路）。
        addon = files['/usr/share/fcitx5/addon/qingjian.conf'].read_text()
        assert 'Library=qingjian\n' in addon, f'addon 的 Library 应当是相对名：{addon}'
        assert 'Library=/' not in addon, 'addon 的 Library 被改写成绝对路径了'
        desktop = files['/usr/share/applications/qingjian-settings.desktop'].read_text()
        assert 'Exec=qingjian-settings\n' in desktop, f'桌面项的 Exec 应当是相对名：{desktop}'
        assert files['/usr/share/fcitx5/inputmethod/qingjian.conf'].is_file()

        # 托盘按名义尺寸挑图，目录名与像素必须一致：1024px 源图塞进 128x128 会让不缩放的托盘显示巨图（#547）。
        for size in (16, 22, 24, 32, 48, 64, 128, 256):
            icon = files[f'/usr/share/icons/hicolor/{size}x{size}/apps/qingjian.png']
            assert png_size(icon) == (size, size), f'{icon} 实际尺寸 {png_size(icon)}'

        assert '/usr/share/licenses/qingjian/LICENSE' in files
        # 卸载交 dpkg，不装用户目录那套清单文件。
        assert not [path for path in files if path.endswith('install-manifest.json')], 'deb 里不该有 install-manifest.json'

        assert (control / 'postinst').stat().st_mode & 0o111, 'postinst 没有执行位'
        conffiles = sorted((control / 'conffiles').read_text().split())
        assert conffiles == ['/etc/environment.d/50-qingjian-im.conf',
                             '/etc/xdg/autostart/qingjian-fcitx5.desktop',
                             '/etc/xdg/autostart/qingjian-server.desktop'], f'conffiles 不对：{conffiles}'
        autostart = files['/etc/xdg/autostart/qingjian-fcitx5.desktop'].read_text()
        # GNOME 46 起不再支持这两个键，带上会让这一条被静默跳过、Fcitx5 永远起不来；
        # 只看真正的键，注释里提到它们不算（见 docs/notes/linux-fcitx5.md）。
        keys = {line.split('=', 1)[0] for line in autostart.splitlines() if '=' in line and not line.startswith('#')}
        assert 'X-GNOME-Autostart-Phase' not in keys and 'X-GNOME-Autostart-Delay' not in keys, f'桌面项里有 GNOME 已废弃的键：{sorted(keys)}'
        assert 'Exec=/usr/bin/fcitx5' in autostart, '桌面项要用绝对路径拉起 Fcitx5'
        assert files['/etc/xdg/autostart/qingjian-server.desktop'].is_file()
        environment = files['/etc/environment.d/50-qingjian-im.conf'].read_text()
        variables = {line.split('=', 1)[0]: line.split('=', 1)[1] for line in environment.splitlines() if '=' in line and not line.startswith('#')}
        # 三个变量缺一不可；设了 GTK_IM_MODULE 反而把 GNOME 的 GTK3 应用推回 X11 通道。
        assert variables.get('XMODIFIERS') == '@im=fcitx', f'XMODIFIERS 不对：{variables}'
        assert variables.get('QT_IM_MODULE') == 'fcitx', f'QT_IM_MODULE 不对：{variables}'
        assert variables.get('QT_IM_MODULES') == 'wayland;fcitx', f'QT_IM_MODULES 不对：{variables}'
        assert 'GTK_IM_MODULE' not in variables, f'不该设 GTK_IM_MODULE：{sorted(variables)}'

        resources = sorted(path for path in files if path.startswith('/usr/share/qingjian/resources/'))
        assert not resources, f'本体包里不该有程序资源，它们归 qingjian-data：{resources[:3]}'
        return files


def check_data(package, sample):
    version = field(package, 'Version')
    assert field(package, 'Package') == 'qingjian-data'
    # 与体系结构无关，各发行版共用同一份。
    assert field(package, 'Architecture') == 'all', '数据包应当是与体系结构无关的'
    check_order(version)
    with tempfile.TemporaryDirectory(prefix='qingjian-deb-') as temporary:
        files = extract(package, Path(temporary) / 'data')
        control = control_area(package, Path(temporary) / 'control')
        assert not (control / 'postinst').exists(), '数据包不该有 postinst'
        resources = [path for path in files if path.startswith('/usr/share/qingjian/resources/')]
        assert resources, '数据包里没有程序资源'
        assert [path for path in files if path.startswith('/usr/bin/')] == [], '数据包不该装可执行文件'
        if not sample:
            names = {Path(path).name for path in resources}
            for wanted in ('dict.qj', 'lm.qj', 'english.tsv',
                           'hanzhang-zhiwei-small.qjm', 'hanzhang-tongbian-small.qjm'):
                assert wanted in names, f'数据包里缺少 {wanted}'
        return files


def check_plan(main_files, data_files, sample):
    """包里的文件集合必须与 files.py 的清单一致：两条安装路径说到底是一份清单。"""
    plugin = next(path for path in main_files if path.endswith('/fcitx5/qingjian.so'))
    libdir = plugin.removesuffix('/fcitx5/qingjian.so')
    plan = subprocess.run(
        ['python3', str(root / 'apps/linux/scripts/files.py'), 'plan', '/usr', '--plugin-dir', libdir,
         '--data-home', '/usr/share', '--config-home', '/etc', str(root),
         '/usr/bin/qingjian-linux-server', '/usr/bin/qingjian-settings', plugin,
         'true' if sample else 'false', 'fcitx5'],
        capture_output=True, text=True, check=True).stdout
    planned = {line.split('\t')[0] for line in plan.splitlines()}
    in_packages = set(main_files) | set(data_files)
    session = {'/etc/environment.d/50-qingjian-im.conf',
               '/etc/xdg/autostart/qingjian-fcitx5.desktop',
               '/etc/xdg/autostart/qingjian-server.desktop'}
    assert planned == in_packages - session, (
        f'包里的文件与 files.py 清单不一致\n  清单多了：{sorted(planned - (in_packages - session))}\n'
        f'  包里多了：{sorted((in_packages - session) - planned)}')


def main():
    arguments = [item for item in sys.argv[1:] if item != '--sample']
    sample = '--sample' in sys.argv[1:]
    targets = []
    for argument in arguments:
        path = Path(argument)
        if path.is_dir():
            targets += sorted(path.glob('*.deb'))
        else:
            targets.append(path)
    main_package = next(path for path in targets if not path.name.startswith('qingjian-data-'))
    data_package = next(path for path in targets if path.name.startswith('qingjian-data-'))
    main_files = check_main(main_package, sample)
    data_files = check_data(data_package, sample)
    check_plan(main_files, data_files, sample)
    print(f'deb 验收通过：{main_package.name}（{len(main_files)} 个文件）与 {data_package.name}（{len(data_files)} 个文件）')


if __name__ == '__main__':
    main()
