#!/usr/bin/env python3
"""芝士虎整 · 用户数据备份 / 恢复（macOS / Windows）。

用法：
    python3 backup_userdata.py --list
    python3 backup_userdata.py --yes
    python3 backup_userdata.py --restore <备份.zip> --target <用户目录> --yes

说明：
  · 备份的是 Rime 用户目录里的个人数据：自造词、反查调频、开关记忆、自学习记录、
    输入统计、击键计数、主题配置、用户词典（*.userdb）；
  · 不含方案文件（lua/ 除外统计文件）、build/、sync/、大模型，备份体积通常只有几 MB；
  · 每个识别到的前端各自打一个 zip，文件名带日期；zip 根目录为 userdata/；
  · 备份前建议退出输入法，避免 LevelDB 正在写入时拷贝；
  · 恢复会覆盖目标目录中的同名文件，需显式 --yes。
"""

import argparse
import json
import os
import platform
import shutil
import sys
import time
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from update_desktop import detect_profiles, read_local_version  # noqa: E402

ROOT_FILES = (
    "custom_phrase.txt",
    "reverse_freq.txt",
    "user.yaml",
)
ROOT_GLOBS = (
    "*.options.yaml",
    "自学习-*.txt",
    "squirrel.custom.yaml",
)
LUA_FILES = (
    "lua/kc_count.txt",
    "lua/kc_total.txt",
    "lua/kc_last.txt",
    "lua/quote.txt",
)
LUA_GLOBS = ("lua/input_stats_*.lua",)
CACHE_DIR = "lua/replacer.userdb"
MANIFEST = "BACKUP.json"


def human(size):
    for unit in ("B", "KB", "MB", "GB"):
        if size < 1024 or unit == "GB":
            return f"{size:.0f}{unit}" if unit != "B" else f"{size}B"
        size /= 1024
    return f"{size:.1f}GB"


def collect(target, with_userdb=True, with_cache=False):
    """返回 [(绝对路径, 包内相对路径)]。"""
    items = []
    seen = set()

    def add(path):
        path = Path(path)
        if path in seen or not path.exists():
            return
        seen.add(path)
        items.append((path, path.relative_to(target).as_posix()))

    for name in ROOT_FILES:
        add(target / name)
    for pattern in ROOT_GLOBS:
        for path in sorted(target.glob(pattern)):
            add(path)
    for name in LUA_FILES:
        add(target / name)
    for pattern in LUA_GLOBS:
        for path in sorted(target.glob(pattern)):
            add(path)

    if with_cache:
        add(target / CACHE_DIR)
    if with_userdb:
        for path in sorted(target.glob("*.userdb")):
            add(path)

    return items


def dir_size(path):
    if path.is_file():
        return path.stat().st_size
    total = 0
    for root, _dirs, files in os.walk(path):
        for name in files:
            try:
                total += (Path(root) / name).stat().st_size
            except OSError:
                pass
    return total


def safe_label(label):
    keep = "".join(c if c.isalnum() or c in "-_." else "_" for c in label)
    return keep or "rime"


def make_backup(profile, out_dir, dry_run, with_userdb, with_cache):
    target = profile["path"]
    items = collect(target, with_userdb, with_cache)
    if not items:
        print("  ⚠ 没有找到用户数据，跳过")
        return None

    total = sum(dir_size(p) for p, _ in items)
    print(f"  待备份 {len(items)} 项，约 {human(total)}")
    for path, rel in items:
        print(f"    {rel}  ({human(dir_size(path))})")

    stamp = time.strftime("%Y%m%d-%H%M%S")
    name = f"cheese-tiger-userdata-{safe_label(profile['label'])}-{stamp}.zip"
    out = Path(out_dir) / name
    if dry_run:
        print(f"  预演：将写入 {out}")
        return None

    out.parent.mkdir(parents=True, exist_ok=True)
    manifest = {
        "project": "芝士虎整",
        "created": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "host": platform.node(),
        "frontend": profile["label"],
        "source": str(target),
        "version": read_local_version(target),
        "files": [rel for _, rel in items],
    }
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as zf:
        for path, rel in items:
            arc = "userdata/" + rel
            if path.is_dir():
                for root, _dirs, files in os.walk(path):
                    for fname in files:
                        full = Path(root) / fname
                        zf.write(full, "userdata/" + full.relative_to(target).as_posix())
            else:
                zf.write(path, arc)
        zf.writestr("userdata/" + MANIFEST, json.dumps(manifest, ensure_ascii=False, indent=2))
    print(f"  完成：{out}  ({human(out.stat().st_size)})")
    return out


def restore(zip_path, target, assume_yes):
    zip_path = Path(zip_path).expanduser()
    if not zip_path.is_file():
        sys.exit(f"✗ 找不到备份文件：{zip_path}")
    with zipfile.ZipFile(zip_path) as zf:
        names = zf.namelist()
        manifest_name = next((n for n in names if n.endswith("/" + MANIFEST)), None)
        if not manifest_name:
            sys.exit("✗ 不是本工具生成的备份（缺少 BACKUP.json）")
        manifest = json.loads(zf.read(manifest_name))

        entries = [n for n in names if n.startswith("userdata/") and not n.endswith("/")]
        print(f"备份来源：{manifest.get('source')}（{manifest.get('frontend')}，{manifest.get('created')}）")
        print(f"恢复到：{target}")
        print(f"将写入 {len(entries)} 个文件")
        if not assume_yes and sys.stdin.isatty():
            if input("继续？[y/N] ").strip().lower() not in ("y", "yes"):
                return

        target = Path(target).expanduser()
        target.mkdir(parents=True, exist_ok=True)
        for name in entries:
            rel = name[len("userdata/"):]
            if rel == MANIFEST:
                continue
            dst = target / rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            with zf.open(name) as src, open(dst, "wb") as out:
                shutil.copyfileobj(src, out)
        print("  ✓ 恢复完成，请重新部署输入法")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--list", action="store_true", help="只列出会备份的文件")
    parser.add_argument("--out", default=str(Path.home() / "Desktop" / "芝士虎整备份"),
                        help="备份输出目录（默认 ~/Desktop/芝士虎整备份）")
    parser.add_argument("--target", action="append", default=[], help="手动指定用户目录（可重复）")
    parser.add_argument("--restore", help="从备份 zip 恢复")
    parser.add_argument("--no-userdb", action="store_true", help="不备份 *.userdb 用户词典")
    parser.add_argument("--with-cache", action="store_true", help="同时备份可重建的 lua/replacer.userdb")
    parser.add_argument("--dry-run", action="store_true", help="只打印，不写文件")
    parser.add_argument("--yes", action="store_true", help="不询问确认")
    args = parser.parse_args()

    if args.restore:
        targets = [Path(t).expanduser() for t in args.target]
        if not targets:
            sys.exit("✗ 恢复需要 --target 指定用户目录")
        restore(args.restore, targets[0], args.yes)
        return

    if args.target:
        profiles = [{"label": Path(t).expanduser().name, "path": Path(t).expanduser(), "kind": "unknown"}
                    for t in args.target]
    else:
        profiles = detect_profiles()
    if not profiles:
        sys.exit("✗ 没有找到 Rime 用户目录；用 --target 手动指定")

    for profile in profiles:
        print(f"\n[{profile['label']}] {profile['path']}")
        if not profile["path"].is_dir():
            print("  ⚠ 目录不存在，跳过")
            continue
        make_backup(profile, args.out, args.dry_run or args.list,
                    not args.no_userdb, args.with_cache)

    if not (args.dry_run or args.list):
        print(f"\n备份目录：{args.out}")
        print("提示：恢复时用 --restore <zip> --target <用户目录> --yes，恢复后重新部署输入法。")


if __name__ == "__main__":
    main()
