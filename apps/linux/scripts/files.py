#!/usr/bin/env python3
# //! 安装文件清单与校验；不管理桌面服务、系统文件或用户数据。
# //! install / uninstall 是用户目录安装（install.sh）；plan 只打印清单，供发行版包按 /usr 落位，
# //! 两条安装路径共用同一份清单，装的文件集合不会漂移。
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys
import tarfile


def digest(path):
    with path.open('rb') as stream:
        return digest_stream(stream)


def digest_stream(stream):
    value = hashlib.sha256()
    for chunk in iter(lambda: stream.read(1024 * 1024), b''):
        value.update(chunk)
    return value.hexdigest()


def file_plan(root, prefix, data, config, plugin_dir, server, settings, plugin, sample, flavor):
    """目标路径 → 源文件。

    prefix 是安装前缀；data / config 是 $XDG_DATA_HOME 与 $XDG_CONFIG_HOME（发行版包传
    /usr/share 与 /etc）；plugin_dir 是放库的目录，下面的 fcitx5/ 与 fcitx/ 由清单自己拼
    （用户目录安装传 prefix/lib，deb 传 /usr/lib/<multiarch>）。这里只管文件放哪，不管
    addon 配置里的 Library= 与桌面项的 Exec= 要不要写成绝对路径——那是用户目录安装特有的，
    见 install()。"""
    root = Path(root)
    files = {prefix / 'share/licenses/qingjian/LICENSE': root / 'LICENSE',
             prefix / 'share/licenses/qingjian/LICENSE-CNS11643.txt': root / 'assets/stroke/LICENSE-CNS11643.txt',
             prefix / 'bin/qingjian-linux-server': Path(server),
             prefix / 'bin/qingjian-settings': Path(settings),
             data / 'applications/qingjian-settings.desktop': root / 'apps/settings/linux/qingjian-settings.desktop'}
    # 托盘按名义尺寸挑图，目录名与像素必须一致：源图 1024px 不能直接装进 128x128（#547）。
    for size in (16, 22, 24, 32, 48, 64, 128, 256):
        files[data / f'icons/hicolor/{size}x{size}/apps/qingjian.png'] = (
            root / f'assets/icon/linux/hicolor/{size}x{size}/apps/qingjian.png')
    if flavor == 'fcitx4':
        icon = root / 'assets/icon/fcitx4.png'
        files[plugin_dir / 'fcitx/fcitx-qingjian.so'] = Path(plugin)
        files[config / 'fcitx/addon/fcitx-qingjian.conf'] = root / 'apps/linux/fcitx4/data/addon/fcitx-qingjian.conf'
        files[config / 'fcitx/imicon/qingjian.png'] = icon
        files[data / 'icons/hicolor/48x48/apps/fcitx-qingjian.png'] = icon
    else:
        files[plugin_dir / 'fcitx5/qingjian.so'] = Path(plugin)
        for kind in ('addon', 'inputmethod'):
            files[data / f'fcitx5/{kind}/qingjian.conf'] = root / f'apps/linux/fcitx5/data/{kind}/qingjian.conf'
    resources = prefix / 'share/qingjian/resources'
    for kind in ('sample', 'glossary', 'levels', 'emoji'):
        for source in (root / 'assets' / kind).rglob('*'):
            if source.is_file():
                files[resources / source.relative_to(root)] = source
    if sample != 'true':
        generated = root / 'data/generated'
        dictionary = generated / 'dict.qj'
        archive = root / 'target/release-data/qingjian-data.tar.gz'
        lock = dict(line.strip().split(' = ', 1) for line in (root / 'tools/release/data.lock').read_text().splitlines() if ' = ' in line)
        if not dictionary.is_file() or not archive.is_file():
            raise SystemExit('缺少产品数据，请先运行 tools/release/data-fetch.sh，或用 --sample 体验样例词库')
        if digest(archive) != lock.get('qingjian-data.tar.gz'):
            raise SystemExit('产品数据包与 tools/release/data.lock 校验值不符')
        verified = {}
        with tarfile.open(archive) as bundle:
            for member in bundle.getmembers():
                if not member.isfile():
                    continue
                source = (root / member.name).resolve()
                if not source.is_relative_to((root / 'data').resolve()):
                    raise SystemExit('数据包路径越界')
                checksum = digest_stream(bundle.extractfile(member))
                if not source.is_file() or digest(source) != checksum:
                    raise SystemExit(f'产品数据校验失败：{member.name}')
                verified[source] = checksum
        wanted = ('dict.qj', 'lm.qj', 'lm-unigram.tsv', 'lm-bigram.tsv', 'english.tsv')
        for source in generated.rglob('*'):
            if source.is_file() and not source.name.startswith('._') and (source.name in wanted or source.name.startswith('glossary-') or source.parent.name in ('dicts', 'codes')):
                if source.resolve() not in verified:
                    raise SystemExit(f'产品数据没有校验记录：{source}')
                files[resources / source.relative_to(root)] = source
        model = root / 'data/models/hanzhang-zhiwei/hanzhang-zhiwei-small.qjm'
        if not model.is_file():
            raise SystemExit('缺少含章·知微 hanzhang-zhiwei-small.qjm，请先运行 tools/release/data-fetch.sh，或用 --sample 体验样例词库')
        if verified.get(model.resolve()) != digest(model):
            raise SystemExit('含章·知微不在已校验的数据包中')
        files[resources / model.relative_to(root)] = model
        p2c_model = root / 'data/models/hanzhang-tongbian/hanzhang-tongbian-small.qjm'
        if not p2c_model.is_file() or verified.get(p2c_model.resolve()) != digest(p2c_model):
            raise SystemExit('含章·通变缺失或不在已校验的数据包中')
        files[resources / p2c_model.relative_to(root)] = p2c_model
    return files


def document_arguments(action, args):
    """install / plan 共用的五个文件参数与可选的框架版本。"""
    if len(args) not in (5, 6):
        raise SystemExit(f'{action} 需要仓库、服务、设置程序、插件、样例标记及可选框架版本')
    root, server, settings, plugin, sample = args[:5]
    flavor = args[5] if len(args) == 6 else 'fcitx5'
    if flavor not in ('fcitx4', 'fcitx5'):
        raise SystemExit('框架版本必须是 fcitx4 或 fcitx5')
    return root, server, settings, plugin, sample, flavor


def install_prefix(prefix_text):
    prefix = Path(prefix_text)
    if not prefix.is_absolute() or prefix == Path('/'):
        raise SystemExit('需要非根绝对安装路径')
    return prefix.resolve()


def absolute_env(name, default):
    value = Path(os.environ.get(name, default))
    if not value.is_absolute():
        raise SystemExit(f'{name} 必须是绝对路径')
    return value


def install(prefix_text, args):
    prefix = install_prefix(prefix_text)
    manifest = prefix / 'share/qingjian/install-manifest.json'
    old = json.loads(manifest.read_text()) if manifest.is_file() else {}
    root, server, settings, plugin, sample, flavor = document_arguments('install', args)
    data = absolute_env('XDG_DATA_HOME', str(Path.home() / '.local/share'))
    # config 只有 Fcitx4 的 addon 配置与图标用得上：Fcitx5 下不读它，也就不校验（与原有行为一致）。
    config = os.environ.get('XDG_CONFIG_HOME', str(Path.home() / '.config'))
    config = absolute_env('XDG_CONFIG_HOME', config) if flavor == 'fcitx4' else Path(config)
    files = file_plan(root, prefix, data, config, prefix / 'lib', server, settings, plugin, sample, flavor)
    # 安装前先检查所有目标，避免覆盖其他来源的同名文件。
    for target in files:
        if target.is_symlink() or (target.exists() and (str(target) not in old or digest(target) != old[str(target)])):
            raise SystemExit(f'目标已存在且不属于本次安装：{target}')
    installed = {}
    for target, source in files.items():
        target.parent.mkdir(parents=True, exist_ok=True)
        temporary = target.with_name(target.name + '.qingjian-tmp')
        shutil.copy2(source, temporary)
        # 用户目录安装把 addon 与桌面项指到本次安装的绝对路径；系统级包用各自的固定位置，不走这里。
        if target == data / 'fcitx5/addon/qingjian.conf':
            temporary.write_text(temporary.read_text().replace('Library=qingjian\n', f'Library={prefix}/lib/fcitx5/qingjian\n'))
        elif flavor == 'fcitx4' and target == config / 'fcitx/addon/fcitx-qingjian.conf':
            temporary.write_text(temporary.read_text().replace('Library=fcitx-qingjian.so\n', f'Library={prefix}/lib/fcitx/fcitx-qingjian.so\n'))
        if target == data / 'applications/qingjian-settings.desktop':
            temporary.write_text(temporary.read_text().replace('Exec=qingjian-settings\n', f'Exec={prefix}/bin/qingjian-settings\n'))
        temporary.replace(target)
        installed[str(target)] = digest(target)
    for filename, checksum in old.items():
        path = Path(filename)
        if filename not in installed and path.is_file() and not path.is_symlink() and digest(path) == checksum:
            path.unlink()
    manifest.parent.mkdir(parents=True, exist_ok=True)
    manifest.write_text(json.dumps(installed, ensure_ascii=False, indent=2) + '\n')


def uninstall(prefix_text):
    prefix = install_prefix(prefix_text)
    manifest = prefix / 'share/qingjian/install-manifest.json'
    old = json.loads(manifest.read_text()) if manifest.is_file() else {}
    for filename, checksum in old.items():
        path = Path(filename)
        if path.is_file() and not path.is_symlink() and digest(path) == checksum:
            path.unlink()
        elif path.exists():
            print(f'保留已修改文件：{path}')
    manifest.unlink(missing_ok=True)


def plan(args):
    """打印「目标路径<TAB>源文件」的清单，供发行版包按 /usr 落位。"""
    prefix_text, *rest = args
    options = {'--plugin-dir': None, '--data-home': None, '--config-home': None}
    positional = []
    while rest:
        head = rest.pop(0)
        if head in options:
            if not rest:
                raise SystemExit(f'{head} 需要路径')
            options[head] = Path(rest.pop(0))
        else:
            positional.append(head)
    prefix = install_prefix(prefix_text)
    root, server, settings, plugin, sample, flavor = document_arguments('plan', positional)
    data = options['--data-home'] or absolute_env('XDG_DATA_HOME', str(Path.home() / '.local/share'))
    config = options['--config-home'] or Path('/etc')
    plugin_dir = options['--plugin-dir'] or prefix / 'lib'
    for path in (data, config, plugin_dir):
        if not path.is_absolute():
            raise SystemExit('data / config / plugin-dir 必须是绝对路径')
    files = file_plan(root, prefix, data, config, plugin_dir, server, settings, plugin, sample, flavor)
    for target in sorted(files, key=str):
        print(f'{target}\t{files[target]}')


def main():
    action, *rest = sys.argv[1:]
    if action == 'install':
        prefix_text, *args = rest
        install(prefix_text, args)
    elif action == 'uninstall':
        uninstall(rest[0])
    elif action == 'plan':
        plan(rest)
    else:
        raise SystemExit('用法：files.py install|uninstall <前缀> …，或 plan <前缀> [--plugin-dir 路径] … <仓库 服务 设置程序 插件 样例 [框架]>')


if __name__ == '__main__':
    main()
