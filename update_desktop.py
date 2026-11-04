#!/usr/bin/env python3
"""芝士虎整 · 桌面端一键更新（macOS / Windows）。

用法：
    python3 tools/update_desktop.py --list-profiles
    python3 tools/update_desktop.py --check
    python3 tools/update_desktop.py --source /path/to/cheese-tiger-vX.Y.Z-update.zip --yes
    python3 tools/update_desktop.py --source /path/to/full.zip --deploy --restart --yes

说明：
  · 自动识别鼠须管、fcitx5（小企鹅）、元书（Cobra）、小狼毫，并扫描 Windows
    下其他含 tiger 方案的 Rime 用户目录（例如虎韵）；
  · 优先使用 Release 里的增量包（*-update.zip），没有则用完整包；
  · 不会覆盖用户数据：*.userdb、*.options.yaml、user.yaml、installation.yaml、
    reverse_freq.txt、custom_phrase.txt、build/、sync/、统计文件等；
  · 完整包里的 405MB 模型若目标目录已有同尺寸文件，会跳过复制；
  · 默认只复制文件；--deploy 执行部署，--restart 重启前端。

默认从 GitHub latest release 下载；方案仓库是公开的，通常无需 token，
设置 GITHUB_TOKEN/GH_TOKEN 只用于避开匿名 API 限流，或用 --source 指定本地 zip / URL。
"""

import argparse
import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path, PurePosixPath

REPO = "viui798/viui-tiger-sentense"
MARKER = ".cheese-tiger-version"
BACKUP_DIR = ".cheese-tiger-backup"

RUNTIME_DIRS = ("lua/", "opencc/", "models/", "dicts/", "tiger_dicts/", "zuci/")
EXCLUDE_DIRS = ("tools/", "docs/", "sync/", "validation/", "手机精简版/", "build/")
EXCLUDE_NAMES = {
    "AGENTS.md", "README.md", "CHANGELOG.md", "LICENSE", "安装说明.txt",
    "安装与更新说明.txt", "RELEASE.json", "SHA256SUMS.txt",
    "SOURCE_BASELINE.md", "RIME_CORRECTNESS.md", "IOS_TEST_README.md",
}
USER_DATA_FILES = {"user.yaml", "installation.yaml", "reverse_freq.txt", "custom_phrase.txt"}
USER_DATA_SUFFIXES = (".userdb", ".options.yaml", ".log", ".md", ".zip", ".sha256")
USER_DATA_LUA = {"kc_count.txt", "kc_total.txt"}
BIG_MODEL = "models/sentence-fivegram-mobile.bin"
BACKUP_MAX_BYTES = 32 * 1024 * 1024


class UpdateError(Exception):
    """可在界面里直接展示的更新错误。"""


class FullPackageRequired(UpdateError):
    """增量包声明 full_required，必须改用完整包。"""
    pass


class DeltaBaseMismatch(FullPackageRequired):
    """增量包的基座版本与已装版本不一致，必须改用完整包。"""
    pass


def posix(path):
    return str(path).replace(os.sep, "/")


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_sha256(path):
    text = Path(path).read_text(encoding="utf-8", errors="ignore").split()
    return text[0].lower() if text else None


def verify_hash(path, expected, log=print):
    if not expected:
        return True
    actual = sha256_file(path)
    if actual.lower() != expected.lower():
        log(f"  ✗ SHA256 不匹配：期望 {expected}，实际 {actual}")
        return False
    log("  ✓ SHA256 校验通过")
    return True


def make_opener(proxy):
    handlers = []
    if proxy:
        handlers.append(urllib.request.ProxyHandler({"http": proxy, "https": proxy}))
    return urllib.request.build_opener(*handlers) if handlers else urllib.request.build_opener()


def default_cache_dir():
    system = platform.system()
    if system == "Windows":
        base = os.environ.get("LOCALAPPDATA") or tempfile.gettempdir()
        return Path(base) / "cheese-tiger" / "cache"
    if system == "Darwin":
        return Path.home() / "Library" / "Caches" / "cheese-tiger"
    return Path.home() / ".cache" / "cheese-tiger"


def should_copy(rel, size=None, target=None):
    p = PurePosixPath(rel)
    if str(p).startswith(EXCLUDE_DIRS):
        return False
    if p.name in EXCLUDE_NAMES:
        return False
    if any(part.endswith(".userdb") for part in p.parts):
        return False
    if p.name in USER_DATA_FILES or p.name.endswith(USER_DATA_SUFFIXES):
        return False
    if p.parent == PurePosixPath("lua") and p.name.startswith("input_stats_") and p.suffix == ".lua":
        return False
    if p.parent == PurePosixPath("lua") and p.name in USER_DATA_LUA:
        return False
    if p.suffix == ".md":
        return False
    if str(p).startswith(RUNTIME_DIRS):
        if rel == BIG_MODEL and size and target:
            existing = target / BIG_MODEL
            if existing.exists() and existing.stat().st_size == size:
                return False
        return True
    return p.suffix in {".yaml", ".txt", ".json", ".lua"}


def looks_like_rime_dir(path):
    return any((path / name).exists() for name in
               ("tiger_sentence.schema.yaml", "tiger.schema.yaml", "default.custom.yaml", "rime.lua"))


def find_windows_profiles():
    found = []
    bases = [Path(os.environ.get("APPDATA", ""))] if os.environ.get("APPDATA") else []
    local = os.environ.get("LOCALAPPDATA")
    if local:
        bases.append(Path(local))
    for base in bases:
        if not base.is_dir():
            continue
        for root, dirs, files in os.walk(base):
            depth = len(Path(root).relative_to(base).parts)
            if depth > 4:
                dirs[:] = []
                continue
            p = Path(root)
            if looks_like_rime_dir(p):
                found.append(p)
            # 不深入明显非 Rime 的目录
            dirs[:] = [d for d in dirs if d not in {"Cache", "Code Cache", "GPUCache", "logs"}]
    return found


def detect_profiles():
    profiles = []
    home = Path.home()
    seen = set()

    def add(label, path, kind):
        path = path.expanduser()
        if path.is_dir() and looks_like_rime_dir(path) and path not in seen:
            seen.add(path)
            profiles.append({"label": label, "path": path, "kind": kind})

    system = platform.system()
    if system == "Darwin":
        add("鼠须管", home / "Library/Rime", "squirrel")
        add("小企鹅", home / ".local/share/fcitx5/rime", "fcitx5")
        add("元书", home / "Library/Application Support/com.ihsiao.inputmethod.Cobra/RimeUserData", "cobra")
    elif system == "Windows":
        appdata_env = os.environ.get("APPDATA")
        if appdata_env:
            add("小狼毫", Path(appdata_env) / "Rime", "weasel")
        for p in find_windows_profiles():
            add(p.name or "Rime", p, "unknown")
    return profiles


def read_local_version(path):
    marker = path / MARKER
    if marker.exists():
        return marker.read_text(encoding="utf-8").strip().lstrip("v") or None
    changelog = path / "CHANGELOG.md"
    if changelog.exists():
        for line in changelog.read_text(encoding="utf-8", errors="ignore").splitlines():
            if line.startswith("## v"):
                return line[3:].split("（")[0].strip().lstrip("v")
    return None


def github_release(version, token, repo=None):
    api = f"https://api.github.com/repos/{repo or REPO}/releases"
    url = f"{api}/tags/{version}" if version else f"{api}/latest"
    headers = {"Accept": "application/vnd.github+json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


def pick_assets(release):
    """把 Release 资产分成 delta / nomodel / full 三类。

    无模型版（*-nomodel.zip）：不含 405MB 模型、其余与完整包一致，
    供「落后几版但模型没变」的设备更新（MODEL.json 指纹比对）。
    """
    assets = release.get("assets") or []
    updates = [a for a in assets if a.get("name", "").endswith("-update.zip")]
    nomodels = [a for a in assets if a.get("name", "").endswith("-nomodel.zip")]
    full = [a for a in assets if a.get("name", "").endswith(".zip")
            and "-update" not in a.get("name", "")
            and "-nomodel" not in a.get("name", "")]
    if not full:
        raise UpdateError("Release 里没有可用的完整 zip 资产")
    return {"delta": updates[0] if updates else None,
            "nomodel": nomodels[0] if nomodels else None,
            "full": full[0]}


def pick_asset(release):
    assets = pick_assets(release)
    if assets["delta"]:
        return assets["delta"], True
    return assets["full"], False


def download(url, token, dest, opener=None, expected=None, log=print, on_progress=None):
    headers = {"Accept": "application/octet-stream"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, headers=headers)
    open_fn = opener.open if opener else urllib.request.urlopen
    with open_fn(req, timeout=60) as resp, open(dest, "wb") as fh:
        total = resp.headers.get("Content-Length")
        total = int(total) if total else 0
        done = 0
        last = 0
        while True:
            chunk = resp.read(1024 * 1024)
            if not chunk:
                break
            fh.write(chunk)
            done += len(chunk)
            if total and done * 100 // total >= last + 5:
                last = done * 100 // total
                log(f"  下载 {last}%")
                if on_progress:
                    on_progress(last)
    if not verify_hash(dest, expected, log):
        try:
            os.unlink(dest)
        except OSError:
            pass
        return None
    return dest


def zip_prefix(zf):
    names = [n for n in zf.namelist() if not n.endswith("/")]
    if not names:
        return ""
    first = names[0]
    if first.startswith("update/"):
        return "update/"
    top = first.split("/")[0]
    return top + "/"


def backup_file(src, backup_root, rel, manifest, log=print):
    """覆盖前把旧文件复制进备份目录；过大文件只记录，不复制。"""
    if src.stat().st_size > BACKUP_MAX_BYTES:
        manifest["too_big"].append(rel)
        log(f"  ! {rel} 超过 {BACKUP_MAX_BYTES // (1024 * 1024)}MB，未纳入备份")
        return
    dst = backup_root / rel
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)
    manifest["overwritten"].append(rel)


def apply_zip(zip_path, target, version, dry_run, expected=None, log=print,
              snapshot=False, on_progress=None):
    """把包应用到 target，返回 {copied, skipped, backup}。"""
    if not verify_hash(zip_path, expected, log):
        raise UpdateError("安装包 SHA256 校验失败，已停止")
    with zipfile.ZipFile(zip_path) as zf:
        prefix = zip_prefix(zf)
        delta = None
        delta_name = prefix + "DELTA.json"
        if delta_name in zf.namelist():
            delta = json.loads(zf.read(delta_name))
        if delta and delta.get("full_required"):
            raise FullPackageRequired("该增量包要求完整包（模型有变更），请改用完整 zip")
        if delta and delta.get("from"):
            # 基座校验：增量包只覆盖 from->to 的差异，底子不对就必须完整包。
            # 已装版本未知（首次安装/无标记）也一律走完整包，宁重勿缺。
            local = (read_local_version(target) or "").lstrip("v").strip()
            base = str(delta["from"]).lstrip("v").strip()
            if not local or local != base:
                raise DeltaBaseMismatch(
                    f"增量包基座 {base} 与已装版本 {local or '未知'} 不一致，"
                    "请改用完整 zip")

        stamp = time.strftime("%Y%m%d-%H%M%S")
        backup_root = target / BACKUP_DIR / stamp
        manifest = {
            "stamp": stamp,
            "version": version,
            "previous_version": read_local_version(target),
            "target": str(target),
            "overwritten": [],
            "created": [],
            "deleted": [],
            "too_big": [],
        }

        entries = [i for i in zf.infolist()
                   if not i.is_dir() and i.filename.startswith(prefix)]
        total = sum(1 for i in entries if should_copy(i.filename[len(prefix):], i.file_size, target))
        done = copied = skipped = 0
        for info in entries:
            rel = info.filename[len(prefix):]
            if rel == "DELTA.json" or not should_copy(rel, info.file_size, target):
                skipped += 1
                continue
            dst = target / rel
            existed = dst.exists()
            if dry_run:
                log(f"  会更新 {rel}")
                copied += 1
            else:
                if existed and (snapshot or rel.endswith(".custom.yaml")):
                    bak = backup_root / rel
                    bak.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(dst, bak)
                    if snapshot:
                        manifest["overwritten"].append(rel)
                elif snapshot and not existed:
                    manifest["created"].append(rel)
                dst.parent.mkdir(parents=True, exist_ok=True)
                with zf.open(info) as src, open(dst, "wb") as out:
                    shutil.copyfileobj(src, out)
                copied += 1
            done += 1
            if on_progress:
                on_progress(done, total, rel)

        if delta:
            for rel in delta.get("deletions") or []:
                if not should_copy(rel):
                    continue
                dst = target / rel
                if not dst.exists():
                    continue
                log(f"  删除 {rel}" if dry_run else f"  已删除 {rel}")
                if dry_run:
                    continue
                if snapshot:
                    backup_file(dst, backup_root, rel, manifest, log)
                    manifest["deleted"].append(rel)
                dst.unlink()

    backup = None
    if not dry_run:
        (target / MARKER).write_text(version + "\n", encoding="utf-8")
        if snapshot and any(manifest[k] for k in ("overwritten", "created", "deleted", "too_big")):
            (backup_root / "manifest.json").write_text(
                json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
            backup = stamp
    log(f"  {'预演' if dry_run else '完成'}：更新 {copied} 个文件，跳过 {skipped} 个")
    return {"copied": copied, "skipped": skipped, "backup": backup}


def list_backups(target):
    root = target / BACKUP_DIR
    if not root.is_dir():
        return []
    items = []
    for d in sorted(root.iterdir(), reverse=True):
        if not d.is_dir():
            continue
        info = {"stamp": d.name, "version": None, "previous_version": None,
                "overwritten": 0, "created": 0, "deleted": 0}
        man = d / "manifest.json"
        if man.exists():
            try:
                data = json.loads(man.read_text(encoding="utf-8"))
                info["version"] = data.get("version")
                info["previous_version"] = data.get("previous_version")
                for key in ("overwritten", "created", "deleted"):
                    info[key] = len(data.get(key) or [])
            except (OSError, ValueError):
                pass
        items.append(info)
    return items


def rollback(target, stamp, log=print):
    """按快照恢复：删除新增文件、恢复被覆盖与被删除的文件。"""
    root = target / BACKUP_DIR / stamp
    man = root / "manifest.json"
    if not man.exists():
        raise UpdateError(f"备份 {stamp} 没有 manifest.json，只能手动恢复")
    data = json.loads(man.read_text(encoding="utf-8"))

    for rel in data.get("created") or []:
        dst = target / rel
        if dst.exists():
            dst.unlink()
            log(f"  移除新增 {rel}")
    for rel in data.get("overwritten") or []:
        src = root / rel
        if src.exists():
            dst = target / rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dst)
            log(f"  恢复 {rel}")
    for rel in data.get("deleted") or []:
        src = root / rel
        if src.exists():
            dst = target / rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dst)
            log(f"  恢复已删除 {rel}")
    for rel in data.get("too_big") or []:
        log(f"  ! {rel} 体积过大未备份，无法恢复")

    previous = data.get("previous_version")
    marker = target / MARKER
    if previous:
        marker.write_text(str(previous) + "\n", encoding="utf-8")
    elif marker.exists():
        marker.unlink()
    log(f"  回滚完成，当前版本：{previous or '未知'}")
    return data


def run(cmd, dry_run, log=print):
    log("  $ " + " ".join(str(c) for c in cmd))
    if not dry_run:
        try:
            subprocess.run(cmd, check=False)
        except OSError as exc:
            log(f"  ⚠ {exc}")


def windows_registry_value(key, value):
    try:
        out = subprocess.run(["reg", "query", key, "/v", value],
                             capture_output=True, text=True, check=False).stdout
    except OSError:
        return None
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[0].lower() == value.lower():
            return " ".join(parts[2:])
    return None


def windows_weasel():
    root = windows_registry_value(r"HKLM\SOFTWARE\WOW6432Node\Rime\Weasel", "WeaselRoot")
    server = windows_registry_value(r"HKLM\SOFTWARE\WOW6432Node\Rime\Weasel", "ServerExecutable")
    if root and server:
        server_path = Path(root) / server
        return server_path, server_path.with_name("WeaselDeployer.exe")
    local = os.environ.get("LOCALAPPDATA")
    if local:
        base = Path(local) / "Programs/Rime/weasel-x64"
        if (base / "WeaselServer.exe").exists():
            return base / "WeaselServer.exe", base / "WeaselDeployer.exe"
    return None, None


def deploy(profile, dry_run, restart, log=print):
    kind = profile["kind"]
    path = profile["path"]
    system = platform.system()
    if kind == "squirrel" and system == "Darwin":
        squirrel = Path("/Library/Input Methods/Squirrel.app/Contents/MacOS/Squirrel")
        if squirrel.exists():
            run([str(squirrel), "--reload"], dry_run, log)
        else:
            shared = "/Library/Input Methods/Squirrel.app/Contents/SharedSupport"
            deployer = "/Library/Input Methods/Squirrel.app/Contents/MacOS/rime_deployer"
            if Path(deployer).exists():
                run([deployer, "--build", str(path), shared], dry_run, log)
        return
    if kind == "fcitx5" and system == "Darwin":
        curl = Path("/Library/Input Methods/Fcitx5.app/Contents/bin/fcitx5-curl")
        if curl.exists():
            run([str(curl), "/config/addon/rime/deploy", "-X", "POST", "-d", "{}"], dry_run, log)
        elif restart:
            run(["killall", "Fcitx5"], dry_run, log)
            run(["open", "/Library/Input Methods/Fcitx5.app"], dry_run, log)
        else:
            log("  提示：未找到 fcitx5-curl，请手动重新部署")
        return
    if kind == "cobra" and system == "Darwin":
        if restart:
            run(["killall", "Cobra"], dry_run, log)
            run(["open", "/Library/Input Methods/Cobra.app"], dry_run, log)
        else:
            log("  提示：元书需要重新部署，或加 --restart")
        return
    if kind == "weasel" and system == "Windows":
        server, deployer = windows_weasel()
        if server and server.exists():
            run([str(server), "/q"], dry_run, log)
            if not dry_run:
                time.sleep(0.5)
        if deployer and deployer.exists():
            run([str(deployer), "/deploy"], dry_run, log)
        else:
            log("  提示：未找到 WeaselDeployer.exe，请手动重新部署")
        if server and server.exists():
            if not dry_run:
                time.sleep(0.5)
                subprocess.Popen([str(server)])
            log(f"  $ {server}")
        return
    log("  提示：未知前端，请手动重新部署")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", help="本地 zip 或下载 URL")
    parser.add_argument("--version", help="指定 tag（默认 latest）")
    parser.add_argument("--target", action="append", default=[], help="手动指定用户目录（可重复）")
    parser.add_argument("--check", action="store_true", help="只检查版本，不下载")
    parser.add_argument("--list-profiles", action="store_true", help="列出识别到的用户目录")
    parser.add_argument("--deploy", action="store_true", help="执行部署命令")
    parser.add_argument("--restart", action="store_true", help="重启前端（配合 --deploy）")
    parser.add_argument("--dry-run", action="store_true", help="只打印动作")
    parser.add_argument("--yes", action="store_true", help="不询问确认")
    parser.add_argument("--proxy", help="HTTP/SOCKS5 代理，例如 socks5://127.0.0.1:1080")
    parser.add_argument("--cache-dir", help="下载缓存目录")
    parser.add_argument("--no-cache", action="store_true", help="不使用缓存")
    parser.add_argument("--snapshot", action="store_true", help="更新前完整快照，支持 --rollback")
    parser.add_argument("--rollback", metavar="时间戳", help="回滚到指定备份（如 20261104-141300）")
    args = parser.parse_args()

    profiles = []
    if args.target:
        for item in args.target:
            p = Path(item).expanduser()
            kind = "unknown"
            if p.is_dir() and looks_like_rime_dir(p):
                profiles.append({"label": p.name, "path": p, "kind": kind})
    else:
        profiles = detect_profiles()
    if not profiles:
        sys.exit("✗ 没有找到 Rime 用户目录；用 --target 手动指定")

    if args.list_profiles:
        for p in profiles:
            print(f"{p['label']:<8} {p['path']}  当前={read_local_version(p['path']) or '未知'}")
            for b in list_backups(p["path"])[:5]:
                print(f"  备份 {b['stamp']}  v{b['previous_version'] or '?'} → v{b['version'] or '?'}")
        return

    if args.rollback:
        for p in profiles:
            print(f"\n[{p['label']}] {p['path']}")
            try:
                rollback(p["path"], args.rollback)
            except UpdateError as exc:
                print(f"  ✗ {exc}")
                continue
            if args.deploy:
                deploy(p, args.dry_run, args.restart)
        return

    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    opener = make_opener(args.proxy)
    cache_dir = Path(args.cache_dir).expanduser() if args.cache_dir else default_cache_dir()
    if not args.no_cache:
        cache_dir.mkdir(parents=True, exist_ok=True)

    release = None
    asset = None
    version = args.version
    zip_path = None
    expected = None

    if not args.source:
        try:
            release = github_release(version, token)
        except Exception as exc:
            sys.exit(f"✗ 无法访问 GitHub Release：{exc}\n  若为 API 限流，可设置 GITHUB_TOKEN/GH_TOKEN，或用 --source 指定 zip")
        assets_map = pick_assets(release)
        asset = assets_map["delta"] or assets_map["nomodel"] or assets_map["full"]
        version = (release.get("tag_name") or version).lstrip("v")

    if args.check:
        print("识别到的用户目录：")
        for p in profiles:
            print(f"  {p['label']:<8} 当前={read_local_version(p['path']) or '未知'}  {p['path']}")
        if release:
            print(f"远端最新：v{version}（{asset['name']}）")
        return

    if args.source:
        src = Path(args.source).expanduser()
        if src.exists():
            zip_path = str(src)
            sidecar = Path(str(src) + ".sha256")
            if sidecar.exists():
                expected = read_sha256(sidecar)
            else:
                print("⚠ 本地包旁边没有 .sha256，跳过哈希校验")
        else:
            name = Path(urllib.parse.urlparse(args.source).path).name or "download.zip"
            out = cache_dir / name
            print(f"下载 {args.source} ...")
            zip_path = download(args.source, token, str(out), opener)
            if not zip_path:
                sys.exit("✗ 下载或校验失败")
    else:
        # 阶梯：无增量包可用时，设备模型与本版一致则直接用无模型版
        if assets_map["delta"] is None and assets_map["nomodel"] is not None:
            expected_model = fetch_model_manifest()
            if device_model_matches(expected_model):
                print("  设备模型与本版一致，使用无模型版更新 ...")
                asset = assets_map["nomodel"]
        assets = release.get("assets") or []
        sha_asset = next((a for a in assets if a.get("name") == asset["name"] + ".sha256"), None)
        if sha_asset:
            sha_path = cache_dir / sha_asset["name"]
            if not sha_path.exists():
                print(f"下载 {sha_asset['name']} ...")
                if not download(sha_asset["browser_download_url"], token, str(sha_path), opener):
                    sys.exit("✗ SHA256 文件下载失败")
            expected = read_sha256(sha_path)

        out = cache_dir / asset["name"]
        if not args.no_cache and out.exists():
            if expected and verify_hash(out, expected):
                print(f"复用缓存 {out}")
                zip_path = str(out)
            elif not expected and asset.get("size") and out.stat().st_size == asset["size"]:
                print(f"复用缓存 {out}（尺寸一致）")
                zip_path = str(out)
            else:
                out.unlink(missing_ok=True)
        if not zip_path:
            print(f"下载 {asset['name']} ...")
            zip_path = download(asset["browser_download_url"], token, str(out), opener, expected)
            if not zip_path:
                sys.exit("✗ 下载或校验失败")

    # 从包内推断版本
    if not version:
        with zipfile.ZipFile(zip_path) as zf:
            prefix = zip_prefix(zf)
            delta_name = prefix + "DELTA.json"
            if prefix.startswith("芝士虎整-v"):
                version = prefix[len("芝士虎整-v"):].strip("/")
            elif delta_name in zf.namelist():
                delta = json.loads(zf.read(delta_name))
                version = str(delta.get("to", "")).lstrip("v")
    version = (version or "unknown").lstrip("v")

    print(f"目标版本：v{version}")
    for p in profiles:
        print(f"  {p['label']:<8} {p['path']}（当前 {read_local_version(p['path']) or '未知'}）")
    if not args.yes and sys.stdin.isatty():
        if input("继续？[y/N] ").strip().lower() not in ("y", "yes"):
            return

    MODEL_FILE = "models/sentence-fivegram-mobile.bin"

    def device_model_matches(expected_sha):
        """所有目标目录的模型文件都存在且 sha256 与本版一致才可用无模型版。"""
        if not expected_sha:
            return False
        for p in profiles:
            f = Path(p["path"]) / MODEL_FILE
            if not f.exists() or sha256_file(f) != expected_sha:
                return False
        return True

    def fetch_model_manifest():
        """下载 Release 里的 MODEL.json（1KB 指纹），失败返回 None。"""
        assets = release.get("assets") or []
        meta = next((a for a in assets if a.get("name") == "MODEL.json"), None)
        if not meta:
            return None
        out = cache_dir / "MODEL.json"
        if not download(meta["browser_download_url"], token, str(out), opener):
            return None
        try:
            data = json.loads(out.read_text(encoding="utf-8"))
            return str(data.get("sha256") or "") or None
        except Exception:
            return None

    def prepare_asset(asset_obj, label):
        assets = release.get("assets") or []
        sha_asset = next((a for a in assets
                          if a.get("name") == asset_obj["name"] + ".sha256"), None)
        expected_arg = None
        if sha_asset:
            sha_path = cache_dir / sha_asset["name"]
            if not sha_path.exists():
                print(f"下载 {sha_asset['name']} ...")
                if not download(sha_asset["browser_download_url"], token,
                                str(sha_path), opener):
                    sys.exit("✗ SHA256 文件下载失败")
            expected_arg = read_sha256(sha_path)
        out = cache_dir / asset_obj["name"]
        if not args.no_cache and out.exists():
            if expected_arg and verify_hash(out, expected_arg):
                print(f"复用缓存 {out}")
                return str(out), expected_arg
            if not expected_arg and asset_obj.get("size") and \
                    out.stat().st_size == asset_obj["size"]:
                print(f"复用缓存 {out}（尺寸一致）")
                return str(out), expected_arg
            out.unlink(missing_ok=True)
        print(f"下载 {label or asset_obj['name']} ...")
        got = download(asset_obj["browser_download_url"], token, str(out), opener,
                       expected_arg)
        if not got:
            sys.exit("✗ 下载或校验失败")
        return str(out), expected_arg

    def apply_all(zip_path_arg, expected_arg):
        for p in profiles:
            print(f"\n[{p['label']}] {p['path']}")
            try:
                apply_zip(zip_path_arg, p["path"], version, args.dry_run,
                          expected_arg, snapshot=args.snapshot)
            except DeltaBaseMismatch as exc:
                raise
            except FullPackageRequired as exc:
                raise
            except UpdateError as exc:
                sys.exit(f"✗ {exc}")
            if args.deploy:
                deploy(p, args.dry_run, args.restart)

    try:
        apply_all(zip_path, expected)
    except DeltaBaseMismatch as exc:
        if not release or args.source:
            sys.exit(f"✗ {exc}")
        print(f"⚠ {exc}")
        # 无模型阶梯：设备模型与本版一致 → 只更新其余文件（14MB vs 388MB）
        assets_map = pick_assets(release)
        expected_model = fetch_model_manifest()
        if assets_map["nomodel"] and device_model_matches(expected_model):
            print("  设备模型与本版一致，自动改用无模型版 ...")
            nm_zip, nm_expected = prepare_asset(assets_map["nomodel"], "无模型版")
            apply_all(nm_zip, nm_expected)
            return
        print("  自动改用完整包 ...")
        full = next((a for a in release.get("assets") or []
                     if a.get("name", "").endswith(".zip")
                     and "-update" not in a.get("name", "")), None)
        if not full:
            sys.exit("✗ 该 Release 没有完整包资产，无法回退")
        sha_asset = next((a for a in release.get("assets") or []
                          if a.get("name") == full["name"] + ".sha256"), None)
        expected_full = None
        if sha_asset:
            sha_path = cache_dir / sha_asset["name"]
            if not sha_path.exists() and not download(
                    sha_asset["browser_download_url"], token, str(sha_path), opener):
                sys.exit("✗ SHA256 文件下载失败")
            expected_full = read_sha256(sha_path)
        out = cache_dir / full["name"]
        if not out.exists() or not (expected_full and verify_hash(out, expected_full)):
            print(f"下载 {full['name']} ...")
            got = download(full["browser_download_url"], token, str(out), opener,
                           expected_full)
            if not got:
                sys.exit("✗ 完整包下载或校验失败")
        apply_all(str(out), expected_full)


if __name__ == "__main__":
    main()
