#!/usr/bin/env python3
"""Isolated Mac preparation. Sampling is admission control, not an OS quota.

No SSH, Cargo builds, global installation or automatic retry. A failed stage is
terminal and requires diagnosis; install never resumes a partly installed prefix.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import selectors
import signal
import stat
import subprocess
import sys
import tarfile
import time
import urllib.parse
import urllib.request

GIB = 1024 ** 3
ORDINARY, CARGO, TOTAL = 3 * GIB // 2, GIB, 5 * GIB // 2
ROOT = '/Users/szk/Library/Caches/Kagayoi/UnLhaRe/goal-restore-20261019'
BOOTSTRAP = ROOT + '-bootstrap'
BOOTSTRAP_RESERVE = 1024 * 1024
LOG_LIMIT = 1024 * 1024


class Refusal(RuntimeError):
    pass


def require(ok, message):
    if not ok:
        raise Refusal(message)


def validate_profile(profile):
    require(profile['schema'] == 1 and profile['root'] == ROOT and
            profile['rust_version'] == '1.99.1', 'wrong immutable profile')
    require(profile['manifest_url'] == 'https://static.rust-lang.org/dist/channel-rust-1.99.1.toml', 'manifest URL')
    require([p['package'] for p in profile['rust']] ==
            ['rustc', 'cargo', 'rust-std', 'rustfmt-preview', 'clippy-preview'], 'component list')
    for p in profile['rust']:
        name = p['package'].replace('-preview', '')
        require(p['url'] == 'https://static.rust-lang.org/dist/2026-10-15/%s-1.99.1-aarch64-apple-darwin.tar.xz' % name,
                'component URL')
    require(profile['sevenzip']['url'] == 'https://github.com/ip7z/7zip/releases/download/26.05/7z2605-mac.tar.xz', '7zip URL')
    for p in profile['rust'] + [profile['sevenzip']]:
        require(re.fullmatch('[0-9a-f]{64}', p['sha256']) is not None, 'hash format')
        require(0 < p['download_max'] <= 150*1024**2 and 0 < p['expanded_max'] <= 550*1024**2, 'component bounds')


def admit_values(ordinary, cargo, extra_ordinary, extra_cargo, free):
    require(min(ordinary, cargo, extra_ordinary, extra_cargo) >= 0, 'negative accounting')
    require(ordinary + extra_ordinary <= ORDINARY, 'ordinary cap')
    require(cargo + extra_cargo <= CARGO, 'Cargo cap')
    require(ordinary + cargo + extra_ordinary + extra_cargo <= TOTAL, 'total cap')
    require(free >= 5*GIB + extra_ordinary + extra_cargo, 'free-space reserve')


def child_environment(root, inherited=None):
    # Allowlist prevents Cargo config/environment overrides and wrappers escaping.
    source = os.environ if inherited is None else inherited
    env = {k: source[k] for k in ('HOME', 'USER', 'LOGNAME', 'LANG') if k in source}
    env.update({'PATH': str(root / 'tools/rust/bin') + ':/usr/bin:/bin:/usr/sbin:/sbin',
                'TMP': str(root/'tmp'), 'TEMP': str(root/'tmp'), 'TMPDIR': str(root/'tmp'),
                'CARGO_HOME': str(root/'cargo-home'), 'CARGO_TARGET_DIR': str(root/'cargo-target'),
                'RUSTUP_HOME': str(root/'rustup-home'), 'PYTHONDONTWRITEBYTECODE': '1'})
    return env


def validate_manifest(text, profile):
    # Only exact target tables are interpreted; no TOML dependency on Python 3.9.
    for component in profile['rust']:
        header = '[pkg.%s.target.aarch64-apple-darwin]' % component['package']
        require(text.splitlines().count(header) == 1, 'missing/duplicate target table')
        body = text.split(header, 1)[1].split('\n[', 1)[0]
        for field, expected in [('available', 'true'), ('xz_url', '"'+component['url']+'"'),
                                ('xz_hash', '"'+component['sha256']+'"')]:
            values = re.findall(r'^' + field + r'\s*=\s*(.*?)\s*$', body, re.M)
            require(values == [expected], 'manifest pin mismatch: ' + component['package'] + '/' + field)


def validate_members(members, limit):
    require(len(members) <= 50000, 'tar entry bound')
    seen, total = set(), 0
    for m in members:
        path = PurePosixPath(m.name)
        require(m.name and not path.is_absolute() and '..' not in path.parts and
                '\\' not in m.name and path.parts, 'unsafe tar name')
        name = str(path)
        require(name not in seen, 'duplicate tar name')
        seen.add(name)
        # Reject links entirely: package layout requiring links needs explicit review.
        require(m.isfile() or m.isdir(), 'tar link/device/special member')
        require(not m.mode & 0o6000 and not getattr(m, 'sparse', None), 'privileged/sparse member')
        total += m.size
        require(0 <= m.size <= limit and total <= limit, 'tar expanded bound')
    return total


def validate_acl_output(output):
    lines = output.splitlines()
    require(bool(lines), 'missing ACL listing')
    entries = [line.strip() for line in lines[1:]]
    require(entries in ([], [b'0: group:everyone deny delete']),
            'unknown or granting extended ACL requires review')


def checked_path(path, private=False):
    path = Path(path)
    require(path.is_absolute(), 'absolute path required')
    for item in list(reversed(path.parents)) + [path]:
        if not item.exists() and not item.is_symlink():
            continue
        s = item.lstat()
        require(not stat.S_ISLNK(s.st_mode), 'symlink: ' + str(item))
        require(s.st_uid in (0, os.getuid()), 'foreign owner: ' + str(item))
        require(not s.st_mode & 0o022, 'writable ancestor: ' + str(item))
        # The user's home/Library/Caches have this harmless delete-denial ACL.
        # Every other ACL needs review; never modify the operating system ACLs.
        acl = subprocess.run(['/bin/ls', '-lde', str(item)], capture_output=True, timeout=10, check=True).stdout
        validate_acl_output(acl)
    if private:
        s = path.lstat()
        require(s.st_uid == os.getuid() and s.st_mode & 0o077 == 0, 'private owned path required')
    require(str(path.resolve()) == str(path), 'noncanonical path')


def validate_link_groups(rows):
    groups = {}
    for row in rows:
        groups.setdefault(row[1], []).append(row)
    for group in groups.values():
        _, _, links, size, category = group[0]
        require(all(row[2:] == (links, size, category) for row in group), 'changing/cross-boundary aliases')
        require(len(group) == links, 'external/missing hardlink alias')
        require(links == 1 or category in ('cargo-home', 'cargo-target'), 'ordinary hardlink forbidden')


def count_snapshot(root):
    try:
        metadata = os.lstat(str(root))
    except OSError as error:
        raise Refusal('accounting root unavailable: ' + str(error)) from error
    require(stat.S_ISDIR(metadata.st_mode) and metadata.st_uid == os.getuid() and
            metadata.st_mode & 0o077 == 0, 'accounting root must be private, owned, existing directory')
    def walk_error(error):
        raise Refusal('accounting walk failed: ' + str(error)) from error
    ordinary = cargo = 0
    rows = []
    for directory, dirs, files in os.walk(str(root), followlinks=False, onerror=walk_error):
        for name in dirs + files:
            p = Path(directory)/name
            s = p.lstat()
            require(not stat.S_ISLNK(s.st_mode) and s.st_uid == os.getuid() and
                    not s.st_mode & 0o022, 'unexpected/writable object: '+str(p))
            require(stat.S_ISDIR(s.st_mode) or stat.S_ISREG(s.st_mode), 'special object')
            if stat.S_ISREG(s.st_mode):
                category = p.relative_to(root).parts[0]
                rows.append((str(p), (s.st_dev, s.st_ino), s.st_nlink, s.st_size, category))
                if category in ('cargo-home', 'cargo-target'):
                    cargo += s.st_size
                else:
                    ordinary += s.st_size
    validate_link_groups(rows)
    for path, key, links, size, _ in rows:
        if links > 1:
            current = os.lstat(path)
            require((current.st_dev, current.st_ino, current.st_nlink, current.st_size) ==
                    (*key, links, size), 'hardlink changed during accounting')
    return ordinary, cargo


def counts(root):
    # Cargoの内部hardlink公開中は再走査し、不確かな計上は受け入れない。
    for attempt in range(3):
        try:
            return count_snapshot(root)
        except (OSError, Refusal):
            if attempt == 2:
                raise


def admit(root, extra=0):
    ordinary, cargo = counts(root)
    fs = os.statvfs(str(root))
    admit_values(ordinary + BOOTSTRAP_RESERVE, cargo, extra, 0,
                 fs.f_bavail * fs.f_frsize)
    return {'root_actual_ordinary_bytes': ordinary,
            'bootstrap_reserved_bytes': BOOTSTRAP_RESERVE,
            'ordinary': ordinary + BOOTSTRAP_RESERVE, 'cargo': cargo,
            'total': ordinary+cargo+BOOTSTRAP_RESERVE}


def validate_bootstrap(source):
    require(str(source.parent) == BOOTSTRAP, 'unexpected bootstrap source path')
    checked_path(source.parent, private=True)
    expected = {'mac-native-setup.py', 'mac-native-tools.json',
                'test-mac-native-setup.py'}
    entries = list(source.parent.iterdir())
    require({p.name for p in entries} == expected, 'unexpected bootstrap files')
    total = 0
    for path in entries:
        checked_path(path)
        meta = path.lstat()
        require(stat.S_ISREG(meta.st_mode) and meta.st_uid == os.getuid() and
                meta.st_nlink == 1, 'unexpected bootstrap object')
        total += meta.st_size
    require(total <= BOOTSTRAP_RESERVE, 'bootstrap transfer exceeds reservation')


def new_json(path, data):
    encoded = (json.dumps(data, sort_keys=True)+'\n').encode()
    require(len(encoded) < 65536, 'journal bound')
    with path.open('xb') as out:
        out.write(encoded)
        out.flush()
        os.fsync(out.fileno())


class Supervisor:
    def __init__(self, root):
        self.root = root
        self.parent = os.getppid()
        self.process = None
        self.interrupted = False
        self.sequence = 0
        self.last_output = b''

    def stop(self, *_):
        self.interrupted = True
        if self.process is not None:
            try:
                os.killpg(self.process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

    def run(self, args, timeout=120, cwd=None, simulate_hup=False, simulate_parent_loss=False):
        require(Path(args[0]).is_absolute(), 'absolute executable required')
        checked_path(args[0])
        self.process = None
        self.last_output = b''
        old = {s: signal.signal(s, self.stop) for s in (signal.SIGHUP, signal.SIGTERM, signal.SIGINT)}
        self.interrupted = False
        output = bytearray()
        self.sequence += 1
        log_path = self.root/'journal'/('process-%d.log' % time.time_ns())
        admit(self.root, LOG_LIMIT + 65536)
        selector = selectors.DefaultSelector()
        start = time.monotonic()
        try:
            self.process = subprocess.Popen(args, cwd=str(cwd or self.root),
                env=child_environment(self.root), stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                start_new_session=True, close_fds=True)
            selector.register(self.process.stdout, selectors.EVENT_READ)
            while True:
                require(not self.interrupted, 'interrupted')
                require(not simulate_parent_loss and os.getppid() == self.parent and self.parent != 1, 'parent lost')
                require(time.monotonic()-start < timeout, 'process timeout')
                admit(self.root)
                if simulate_hup:
                    simulate_hup = False
                    os.kill(os.getpid(), signal.SIGHUP)
                    continue
                for key, _ in selector.select(0.1):
                    chunk = os.read(key.fileobj.fileno(), 65536)
                    if chunk:
                        output.extend(chunk)
                        require(len(output) <= LOG_LIMIT, 'process output bound')
                    else:
                        selector.unregister(key.fileobj)
                if self.process.poll() is not None and not selector.get_map():
                    require(self.process.returncode == 0, 'process failed: '+str(self.process.returncode))
                    return bytes(output).decode('utf-8', 'replace')
        finally:
            self.stop()
            try:
                if self.process is not None:
                    self.process.wait(timeout=10)
                    self.process.stdout.close()
                    # Successful direct children can leave descendants in their group.
                    deadline = time.monotonic()+3
                    while True:
                        try:
                            os.killpg(self.process.pid, 0)
                        except ProcessLookupError:
                            break
                        require(time.monotonic() < deadline, 'owned process group still present; state uncertain')
                        time.sleep(0.05)
            finally:
                selector.close()
                for s, handler in old.items():
                    signal.signal(s, handler)
                with log_path.open('xb') as log:
                    log.write(output[:LOG_LIMIT])
                self.last_output = bytes(output[:LOG_LIMIT])


def redirect_allowed(provider, url):
    parsed = urllib.parse.urlsplit(url)
    try:
        port = parsed.port
    except ValueError:
        return False
    hosts = {'rust': ('static.rust-lang.org',),
             'sevenzip': ('github.com', 'release-assets.githubusercontent.com')}
    return (parsed.scheme == 'https' and parsed.hostname in hosts.get(provider, ()) and
            port in (None, 443) and parsed.username is None and parsed.password is None)


class RestrictedRedirect(urllib.request.HTTPRedirectHandler):
    def __init__(self, provider):
        super().__init__()
        self.provider = provider

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        require(redirect_allowed(self.provider, newurl), 'cross-provider/unapproved redirect')
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def download(root, url, destination, maximum, digest=None):
    admit(root, maximum)
    provider = {'static.rust-lang.org': 'rust', 'github.com': 'sevenzip'}.get(urllib.parse.urlsplit(url).hostname)
    require(redirect_allowed(provider, url), 'network provider')
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), RestrictedRedirect(provider))
    start, total, h = time.monotonic(), 0, hashlib.sha256()
    with opener.open(url, timeout=20) as response, destination.open('xb') as out:
        length = response.headers.get('Content-Length')
        require(length is not None and 0 < int(length) <= maximum, 'download length')
        while True:
            require(time.monotonic()-start < 180, 'download deadline')
            block = response.read(min(65536, maximum-total+1))
            if not block:
                break
            total += len(block)
            require(total <= maximum, 'download bound')
            out.write(block)
            h.update(block)
            admit(root)
    require(total == int(length), 'truncated download')
    if digest:
        require(h.hexdigest() == digest, 'download SHA256')
    return h.hexdigest()


def extract(root, archive, target, limit):
    with tarfile.open(str(archive), 'r:xz') as tar:
        members, running_size = [], 0
        for member in tar:
            members.append(member)
            running_size += member.size
            require(len(members) <= 50000 and 0 <= member.size <= limit and
                    running_size <= limit, 'tar scan bound')
        size = validate_members(members, limit)
        admit(root, size + 16*1024**2)
        target.mkdir(mode=0o700)
        for m in members:
            p = target.joinpath(*PurePosixPath(m.name).parts)
            p.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            if m.isdir():
                p.mkdir(mode=0o700, exist_ok=True)
            else:
                with tar.extractfile(m) as source, p.open('xb') as out:
                    left = m.size
                    while left:
                        block = source.read(min(65536, left))
                        require(bool(block), 'truncated tar member')
                        out.write(block)
                        left -= len(block)
                p.chmod(0o700 if m.mode & 0o111 else 0o600)
    return size


def remove_owned_stage(root, stage):
    # Exact stage only, after version validation; never the workspace root.
    require(stage.parent == root/'staging' and stage.name in
            ('rustc', 'cargo', 'rust-std', 'rustfmt-preview', 'clippy-preview'), 'cleanup scope')
    checked_path(stage, private=True)
    admit(root)
    for directory, dirs, files in os.walk(str(stage), topdown=False, followlinks=False):
        for name in files:
            p = Path(directory)/name
            require(p.is_file() and not p.is_symlink() and p.stat().st_nlink == 1, 'cleanup file')
            p.unlink()
        for name in dirs:
            (Path(directory)/name).rmdir()
    stage.rmdir()


def native(supervisor, executable, version_arg, expected):
    description = supervisor.run(['/usr/bin/file', '-b', str(executable)])
    require('arm64' in description and 'Mach-O' in description, 'native ARM64 executable required')
    output = supervisor.run([str(executable), version_arg], timeout=30)
    require(expected in output, 'unexpected executable version')
    return output[:4096]


def sandbox_command(root):
    # /dev/null is the sole nonpersistent stdio exception outside the owned root.
    policy = ('(version 1)(allow default)(deny file-write*)'
              '(allow file-write* (subpath "%s") (literal "/dev/null"))'
              '(deny network*)(deny signal)') % root
    return ['/usr/bin/sandbox-exec', '-p', policy]


def sandbox_probe(root, supervisor):
    outside = Path(__file__).absolute()
    require(root not in outside.parents, 'sandbox probe requires transferred source outside root')
    checked_path(outside)
    metadata = outside.lstat()
    require(stat.S_ISREG(metadata.st_mode) and metadata.st_uid == os.getuid() and
            metadata.st_mode & stat.S_IWUSR and metadata.st_nlink == 1,
            'outside probe source must be an owned writable regular file')
    # Open without O_TRUNC/O_CREAT and close without writing: source stays intact.
    baseline = 'import os,sys; fd=os.open(sys.argv[1],os.O_WRONLY); os.close(fd); print("outside-open-baseline-ok")'
    result = supervisor.run(['/usr/bin/python3', '-I', '-B', '-c', baseline, str(outside)], timeout=10)
    require('outside-open-baseline-ok' in result, 'outside probe baseline')
    code = ('import os,sys,errno\n'
            'with open(sys.argv[1],"xb") as out: out.write(b"owned sandbox probe\\n")\n'
            'with open("/dev/null","wb") as out: out.write(b"stdio probe\\n")\n'
            'try:\n'
            ' fd=os.open(sys.argv[2],os.O_WRONLY)\n'
            'except OSError as error:\n'
            ' assert error.errno in (errno.EPERM,errno.EACCES),str(error)\n'
            'else:\n'
            ' os.close(fd); raise RuntimeError("sandbox allowed outside write-open")\n'
            'print("sandbox-owned-stdio-devnull-ok-outside-denied")\n')
    result = supervisor.run(sandbox_command(root) + ['/usr/bin/python3', '-I', '-B', '-c', code,
                            str(root/'tmp/sandbox-probe-owned'), str(outside)], timeout=10)
    require('sandbox-owned-stdio-devnull-ok-outside-denied' in result, 'sandbox integration probe')


def validate_installer_text(text):
    require(re.search(r'^valopt\s+prefix\s', text, re.M) is not None and
            re.search(r'^opt\s+ldconfig\s+1\s', text, re.M) is not None,
            'installer options unavailable')
    require(not re.search(r'^\s*(sudo|chown|launchctl|defaults|killall|pkill)\b', text, re.M),
            'installer contains unapproved global action')


def validate_options_repair(failure, identity, prefix_exists, downloads):
    require(failure == dict(identity, error='installer options unavailable'),
            'repair requires exact original pre-execution failure')
    require(not prefix_exists, 'repair cannot resume an installed/partial prefix')
    require(set(downloads) == {'channel.toml', 'channel.sha256', 'rustc.tar.xz'},
            'repair requires original pre-execution downloads only')


def validate_std_finish(failure, identity, components, downloads, stages, std_exists):
    expected = dict(identity, error='tar scan bound',
                    original_failure_sha256='fdb817119cf4d15488cba2c6c04b7207ff4ae3925b2b998288ff262c6f162e4f',
                    setup_sha256='47fe5ad1c88d0ae655e83fd29a431bb0f8055986351b03a0f986c8dff3d64c20')
    require(failure == expected, 'finish requires exact observed std scan failure')
    require(components == ['rustc', 'cargo'] and not stages and not std_exists,
            'finish requires exact installed component boundary')
    require(set(downloads) == {'channel.toml', 'channel.sha256', 'channel-repair-1.toml',
                              'channel-repair-1.sha256', 'rustc.tar.xz', 'cargo.tar.xz',
                              'rust-std.tar.xz'}, 'finish download boundary')


def verify_cached_archive(archive, package):
    require(archive.is_file() and not archive.is_symlink() and archive.stat().st_nlink == 1 and
            0 < archive.stat().st_size <= package['download_max'], 'cached archive bound')
    require(hashlib.sha256(archive.read_bytes()).hexdigest() == package['sha256'], 'cached archive SHA256')


def installed_file_names(text):
    names = set()
    for line in text.splitlines():
        require(line.startswith('file:'), 'unsupported installed manifest entry')
        name = line[5:]
        path = PurePosixPath(name)
        require(name and str(path) == name and not path.is_absolute() and '..' not in path.parts and
                '\\' not in name and name != 'manifest.in' and name not in names,
                'unsafe/duplicate installed manifest entry')
        names.add(name)
    require(bool(names), 'empty installed manifest')
    return names


def verify_installed_component(root, package):
    archive = root/'downloads'/(package['package']+'.tar.xz')
    verify_cached_archive(archive, package)
    prefix = root/'tools/rust'
    with tarfile.open(str(archive), 'r:xz') as tar:
        members = tar.getmembers()
        validate_members(members, package['expanded_max'])
        controls = [m for m in members if m.isfile() and
                    m.name.endswith('/'+package['package']+'/manifest.in')]
        require(len(controls) == 1 and controls[0].size < 65536, 'installed manifest missing/bound')
        with tar.extractfile(controls[0]) as source:
            expected = installed_file_names(source.read().decode('utf-8'))
        payload = {str(PurePosixPath(m.name).relative_to(PurePosixPath(controls[0].name).parent)): m
                   for m in members if m.isfile() and m.name.startswith(str(PurePosixPath(controls[0].name).parent)+'/')
                   and m.name != controls[0].name}
        require(set(payload) == expected, 'installed manifest/archive payload mismatch')
        files = 0
        for name, member in payload.items():
            target = prefix.joinpath(*PurePosixPath(name).parts)
            require(target.is_file() and not target.is_symlink() and
                    target.stat().st_size == member.size, 'installed component file missing/length')
            with tar.extractfile(member) as source, target.open('rb') as installed:
                while True:
                    block = source.read(65536)
                    require(installed.read(len(block)) == block, 'installed component bytes mismatch')
                    if not block:
                        break
            files += 1
        require(files > 0, 'empty installed component proof')
    return files


def install(root, profile, supervisor, repair=False, finish=False):
    require(finish or not (root/'tools/rust').exists(), 'partial/existing Rust prefix; no blind retry')
    channel = 'channel-repair-1' if repair else 'channel'
    if finish:
        channel = 'channel-repair-1'
    manifest, checksum = root/'downloads'/(channel+'.toml'), root/'downloads'/(channel+'.sha256')
    actual = hashlib.sha256(manifest.read_bytes()).hexdigest() if finish else download(
        root, profile['manifest_url'], manifest, 2*1024**2)
    if not finish:
        download(root, profile['manifest_url']+'.sha256', checksum, 4096)
    require(re.fullmatch(r'[0-9a-f]{64}\s+\*?channel-rust-1\.99\.1\.toml\s*', checksum.read_text()) is not None,
            'manifest checksum syntax')
    require(checksum.read_text().split()[0] == actual, 'manifest checksum mismatch')
    validate_manifest(manifest.read_text(), profile)
    versions = {}
    packages = [dict(p) for p in profile['rust']]
    if finish:
        for p in packages[:2]:
            files = verify_installed_component(root, p)
            versions[p['package']] = native(supervisor, root/'tools/rust/bin'/p['package'], '--version', '1.99.1')
            new_json(root/'journal'/(p['package']+'-installed-proof.json'), {'files': files, 'archive_sha256': p['sha256']})
        packages = packages[2:]
        require(packages[0]['sha256'] == 'fe79d6ab5a0321de26463999d8c112b8ad3eafbcbcf822d66a2300b45dde1031',
                'std exception pin')
        packages[0]['expanded_max'] = 160*1024**2
        # Inspect every remaining input before executing any additional installer.
        for p in packages + [dict(profile['sevenzip'], package='7zip')]:
            archive = root/'downloads'/(p['package']+'.tar.xz')
            if p['package'] != 'rust-std':
                download(root, p['url'], archive, p['download_max'], p['sha256'])
            verify_cached_archive(archive, p)
            with tarfile.open(str(archive), 'r:xz') as tar:
                members = tar.getmembers()
                size = validate_members(members, p['expanded_max'])
            new_json(root/'journal'/(p['package']+'-preflight.json'), {
                'sha256': p['sha256'], 'expanded_bytes': size,
                'expanded_max': p['expanded_max'], 'members': len(members)})
    for p in packages:
        package = p['package']
        archive = root/'downloads'/(package+'.tar.xz')
        stage = root/'staging'/package
        if finish:
            verify_cached_archive(archive, p)
        elif repair and package == 'rustc':
            require(archive.is_file() and not archive.is_symlink() and
                    archive.stat().st_nlink == 1 and 0 < archive.stat().st_size <= p['download_max'],
                    'repair archive bound')
            require(hashlib.sha256(archive.read_bytes()).hexdigest() == p['sha256'],
                    'repair archive SHA256')
            remove_owned_stage(root, stage)
        else:
            download(root, p['url'], archive, p['download_max'], p['sha256'])
        size = extract(root, archive, stage, p['expanded_max'])
        entries = list(stage.iterdir())
        require(len(entries) == 1 and entries[0].is_dir(), 'Rust archive layout')
        script = entries[0]/'install.sh'
        require(script.is_file(), 'installer missing')
        text = script.read_text()
        validate_installer_text(text)
        # Keep the exact script and inspection digest in the immutable stage record.
        new_json(root/'journal'/(package+'-script.json'), {
            'sha256': hashlib.sha256(script.read_bytes()).hexdigest(),
            'global_action_lines': [line[:400] for line in text.splitlines()
                                    if re.search(r'ldconfig|/usr/local|/etc/|sudo|chown', line)][:100]})
        # Authenticated upstream shell still gets OS-enforced write confinement.
        # No fallback if Apple's built-in sandbox is unavailable or rejects this.
        shell = sandbox_command(root) + ['/bin/bash', str(script)]
        help_text = supervisor.run(shell + ['--help'], cwd=entries[0])
        require('--prefix' in help_text and '--disable-ldconfig' in help_text, 'installer help mismatch')
        # Admission includes compressed archive + extraction + installed duplicate.
        admit(root, size + 16*1024**2)
        supervisor.run(shell + ['--prefix='+str(root/'tools/rust'),
                               '--disable-ldconfig'], timeout=180, cwd=entries[0])
        exe, arg = {'rustc': ('rustc', '--version'), 'cargo': ('cargo', '--version'),
                    'rust-std': ('rustc', '--version'), 'rustfmt-preview': ('rustfmt', '--version'),
                    'clippy-preview': ('clippy-driver', '--version')}[package]
        expected = {'rustfmt-preview': '1.10.0', 'clippy-preview': '0.1.99'}.get(package, '1.99.1')
        versions[package] = native(supervisor, root/'tools/rust/bin'/exe, arg, expected)
        if package == 'rust-std':
            library = root/'tools/rust/lib/rustlib/aarch64-apple-darwin/lib'
            require(library.is_dir() and any(library.glob('libstd-*.rlib')), 'installed ARM64 standard library missing')
        remove_owned_stage(root, stage)
    p = profile['sevenzip']
    archive = root/'downloads/7zip.tar.xz'
    if finish:
        verify_cached_archive(archive, p)
    else:
        download(root, p['url'], archive, p['download_max'], p['sha256'])
    extract(root, archive, root/'tools/7zip', p['expanded_max'])
    versions['7zip'] = native(supervisor, root/'tools/7zip/7zz', '-h', '26.05')
    return versions


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('stage', choices=('prepare', 'self-test', 'install', 'finish-verified-tools', 'status'))
    parser.add_argument('--self-test-supervision', action='store_true')
    parser.add_argument('--repair-installer-options', action='store_true')
    args = parser.parse_args()
    require(not args.repair_installer_options or
            (args.stage == 'install' and not args.self_test_supervision), 'repair is install-only')
    require(platform.system() == 'Darwin' and platform.machine() == 'arm64', 'Mac ARM64 only')
    os.umask(0o077)
    source_path = Path(__file__).absolute()
    checked_path(source_path)
    validate_bootstrap(source_path)
    profile_path = source_path.with_name('mac-native-tools.json')
    profile_bytes = profile_path.read_bytes()
    require(len(profile_bytes) < 65536, 'profile bound')
    profile = json.loads(profile_bytes)
    validate_profile(profile)
    identity = {'profile_sha256': hashlib.sha256(profile_bytes).hexdigest(), 'uid': os.getuid(), 'root': ROOT}
    root = Path(ROOT)
    checked_path(root)
    if args.stage == 'prepare':
        require(not root.exists(), 'prepare requires a new root')
        # Parent must reserve this exact root in the shared Windows ledger first.
        require(root.parent.is_dir(), 'parent must pre-provision the verified private parent')
        fs = os.statvfs(str(root.parent))
        require(fs.f_bavail*fs.f_frsize >= 5*GIB + TOTAL, 'initial free-space reserve')
        root.mkdir(mode=0o700)
        new_json(root/'ownership.json', identity)
        for name in ('tmp', 'cargo-home', 'cargo-target', 'rustup-home', 'tools', 'downloads', 'staging', 'journal'):
            (root/name).mkdir(mode=0o700)
        new_json(root/'journal/prepare-done.json', identity)
        print(json.dumps({'stage': 'prepared', **identity, **admit(root)}))
        return
    checked_path(root, private=True)
    require(json.loads((root/'ownership.json').read_text()) == identity, 'ownership/profile mismatch')
    require((root/'journal/prepare-done.json').is_file(), 'prepare incomplete')
    supervisor = Supervisor(root)
    if args.stage == 'status':
        versions = {}
        completed_stage = None
        if (root/'journal/install-done.json').is_file():
            versions = json.loads((root/'journal/install-done.json').read_text()).get('versions', {})
            completed_stage = 'install'
        if (root/'journal/install-options-repair-done.json').is_file():
            repair_done = json.loads((root/'journal/install-options-repair-done.json').read_text())
            versions = repair_done.get('versions', {})
            completed_stage = 'install-options-repair'
        if (root/'journal/finish-verified-tools-done.json').is_file():
            versions = json.loads((root/'journal/finish-verified-tools-done.json').read_text()).get('versions', {})
            completed_stage = 'finish-verified-tools'
        print(json.dumps({**identity, **admit(root), 'versions_recorded': versions,
                          'completed_stage': completed_stage,
                          'journals': sorted(p.name for p in (root/'journal').iterdir())}))
        return
    stage = 'self-test' if args.stage == 'self-test' or args.self_test_supervision else args.stage
    stage_identity = dict(identity)
    require(not args.self_test_supervision or args.stage != 'finish-verified-tools', 'finish cannot run self-test')
    if stage == 'finish-verified-tools':
        admit(root)
        journal = root/'journal'
        require(not any(journal.glob(stage+'-*.json')) and
                not (journal/'install-options-repair-done.json').exists() and
                not (journal/'install-done.json').exists(), 'finish previously attempted/completed')
        failure_bytes = (journal/'install-options-repair-failed.json').read_bytes()
        prefix = root/'tools/rust/lib/rustlib'
        validate_std_finish(json.loads(failure_bytes), identity,
                            (prefix/'components').read_text().splitlines(),
                            {p.name for p in (root/'downloads').iterdir()},
                            list((root/'staging').iterdir()),
                            (prefix/'manifest-rust-std-aarch64-apple-darwin').exists() or
                            (prefix/'aarch64-apple-darwin/lib').exists())
        require((journal/'rustc-script.json').is_file() and (journal/'cargo-script.json').is_file(),
                'installed script evidence missing')
        stage_identity.update({'prior_failure_sha256': hashlib.sha256(failure_bytes).hexdigest(),
                               'setup_sha256': hashlib.sha256(source_path.read_bytes()).hexdigest(),
                               'std_expanded_max': 160*1024**2, 'observed_std_expanded_bytes': 152290621})
    if args.repair_installer_options:
        admit(root)
        journal = root/'journal'
        require(json.loads((journal/'install-started.json').read_text()) == identity and
                not (journal/'install-done.json').exists(), 'repair original start/completion mismatch')
        failure_bytes = (journal/'install-failed.json').read_bytes()
        validate_options_repair(json.loads(failure_bytes), identity,
                                (root/'tools/rust').exists(),
                                {p.name for p in (root/'downloads').iterdir()})
        require({p.name for p in (root/'staging').iterdir()} == {'rustc'} and
                not list(journal.glob('*-script.json')), 'repair installer may already have run')
        stage = 'install-options-repair'
        require(not any(journal.glob(stage+'-*.json')), 'repair already attempted')
        stage_identity.update({'original_failure_sha256': hashlib.sha256(failure_bytes).hexdigest(),
                               'setup_sha256': hashlib.sha256(source_path.read_bytes()).hexdigest()})
    require(not (root/'journal'/(stage+'-started.json')).exists(), 'stage already attempted; inspect diagnostics')
    if stage in ('install', 'install-options-repair', 'finish-verified-tools'):
        require((root/'journal/self-test-done.json').is_file(), 'supervision self-test required')
    new_json(root/'journal'/(stage+'-started.json'), stage_identity)
    try:
        if stage == 'self-test':
            # Timeout case includes a grandchild in the owned process group.
            descendant = ('import subprocess,time; '
                          'child=subprocess.Popen(["/usr/bin/python3","-I","-B","-c","import time; time.sleep(60)"]); '
                          'print("grandchild:"+str(child.pid),flush=True); time.sleep(60)')
            for failure in ('timeout', 'hup', 'parent-loss'):
                try:
                    supervisor.run(['/usr/bin/python3', '-I', '-B', '-c',
                                    descendant if failure == 'timeout' else 'import time; time.sleep(60)'],
                                   timeout=2, simulate_hup=failure == 'hup',
                                   simulate_parent_loss=failure == 'parent-loss')
                    raise Refusal('self-test child unexpectedly completed')
                except Refusal as error:
                    expected = {'timeout': 'process timeout', 'hup': 'interrupted', 'parent-loss': 'parent lost'}[failure]
                    require(str(error) == expected, 'unexpected self-test failure: '+str(error))
                    require(supervisor.process.poll() is not None, 'self-test child not reaped')
                    if failure == 'timeout':
                        require(b'grandchild:' in supervisor.last_output, 'grandchild never started')
            sandbox_probe(root, supervisor)
            versions = {'supervision': 'timeout with grandchild, simulated SIGHUP and parent-loss: owned group absent, child reaped',
                        'sandbox': 'owned write, stdout and /dev/null succeeded; existing writable outside source write-open denied'}
        else:
            versions = install(root, profile, supervisor, repair=args.repair_installer_options,
                               finish=stage == 'finish-verified-tools')
        new_json(root/'journal'/(stage+'-done.json'), {**stage_identity, 'versions': versions})
        print(json.dumps({'stage': stage+'-done', **admit(root), 'versions': versions}))
    except BaseException as error:
        new_json(root/'journal'/(stage+'-failed.json'), {**stage_identity, 'error': str(error)[:4096]})
        raise


if __name__ == '__main__':
    try:
        main()
    except (Refusal, OSError, ValueError, subprocess.SubprocessError) as error:
        print(json.dumps({'error': str(error)[:4096]}), file=sys.stderr)
        sys.exit(1)
