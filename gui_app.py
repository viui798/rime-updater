#!/usr/bin/env python3
"""芝士虎整 · 更新器图形界面。

本地 Web UI，只用 Python 标准库：启动后浏览器打开界面，可以检查更新、
一键更新、查看实时日志、修改设置、按快照回滚。

    python3 gui_app.py                 # 打开界面
    python3 gui_app.py --port 8765     # 指定端口
    python3 gui_app.py --no-browser    # 不自动打开浏览器
"""

import argparse
import json
import os
import platform
import threading
import time
import traceback
import urllib.request
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

import update_desktop as core

APP_DIR = Path(__file__).resolve().parent
WEB_DIR = APP_DIR / "web"

DEFAULT_SETTINGS = {
    "repo": core.REPO,
    "proxy": "",
    "token": "",
    "cache_dir": "",
    "deploy": True,
    "restart": False,
    "snapshot": True,
}


def settings_path():
    system = platform.system()
    if system == "Windows":
        base = os.environ.get("LOCALAPPDATA") or str(Path.home())
        return Path(base) / "cheese-tiger" / "updater-settings.json"
    if system == "Darwin":
        return Path.home() / "Library" / "Application Support" / "CheeseTigerUpdater" / "settings.json"
    return Path.home() / ".config" / "cheese-tiger" / "updater-settings.json"


def load_settings():
    settings = dict(DEFAULT_SETTINGS)
    path = settings_path()
    if path.exists():
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            settings.update({k: v for k, v in data.items() if k in DEFAULT_SETTINGS})
        except (OSError, ValueError):
            pass
    return settings


def save_settings(data):
    settings = load_settings()
    settings.update({k: data[k] for k in DEFAULT_SETTINGS if k in data})
    path = settings_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(settings, ensure_ascii=False, indent=2), encoding="utf-8")
    return settings


def token_of(settings):
    return settings.get("token") or os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")


class Job:
    """一次可观测的后台任务：日志、进度、结果。"""

    def __init__(self, kind, title):
        self.id = str(int(time.time() * 1000))
        self.kind = kind
        self.title = title
        self.lines = []
        self.done = False
        self.ok = False
        self.error = ""
        self.percent = 0
        self.result = {}
        self.lock = threading.Lock()

    def log(self, text):
        with self.lock:
            self.lines.append(str(text))
            if len(self.lines) > 4000:
                del self.lines[:2000]

    def set_percent(self, value):
        with self.lock:
            self.percent = max(0, min(100, int(value)))

    def snapshot(self):
        with self.lock:
            return {
                "id": self.id,
                "kind": self.kind,
                "title": self.title,
                "lines": list(self.lines),
                "done": self.done,
                "ok": self.ok,
                "error": self.error,
                "percent": self.percent,
                "result": self.result,
            }


class Runner:
    def __init__(self):
        self.job = None
        self.lock = threading.Lock()

    def start(self, kind, title, task):
        with self.lock:
            if self.job and not self.job.done:
                raise core.UpdateError("已有任务在进行，请等待完成")
            job = Job(kind, title)
            self.job = job
        threading.Thread(target=self._run, args=(job, task), daemon=True).start()
        return job

    def _run(self, job, task):
        try:
            job.result = task(job.log, job) or {}
            job.ok = True
            job.log("✓ 完成")
        except core.UpdateError as exc:
            job.error = str(exc)
            job.log(f"✗ {exc}")
        except Exception as exc:  # noqa: BLE001 - 后台任务需要把异常交给界面
            job.error = f"{exc.__class__.__name__}: {exc}"
            job.log(traceback.format_exc())
            job.log(f"✗ {job.error}")
        finally:
            with job.lock:
                job.done = True


RUNNER = Runner()


def selected_profiles(paths):
    profiles = core.detect_profiles()
    if not paths:
        return profiles
    wanted = {str(Path(p).expanduser()) for p in paths}
    picked = [p for p in profiles if str(p["path"]) in wanted]
    if not picked:
        raise core.UpdateError("指定的用户目录不存在或不含 Rime 配置")
    return picked


def resolve_package(settings, log, job=None):
    """返回 (zip 路径, 期望 sha256, 版本, 资产名, 是否增量包)。"""
    token = token_of(settings)
    opener = core.make_opener(settings.get("proxy") or None)
    cache_dir = (Path(settings["cache_dir"]).expanduser() if settings.get("cache_dir")
                 else core.default_cache_dir())
    cache_dir.mkdir(parents=True, exist_ok=True)

    try:
        release = core.github_release(None, token, settings.get("repo") or core.REPO)
    except Exception as exc:  # noqa: BLE001
        raise core.UpdateError(
            f"无法访问 GitHub Release：{exc}\n"
            "若为 API 限流，可在设置里填写 token，或检查网络/代理") from exc

    asset, is_delta = core.pick_asset(release)
    version = (release.get("tag_name") or "unknown").lstrip("v")
    log(f"远端最新：v{version}，使用 {asset['name']}")

    assets = release.get("assets") or []
    expected = None
    sha_asset = next((a for a in assets if a.get("name") == asset["name"] + ".sha256"), None)
    if sha_asset:
        sha_path = cache_dir / sha_asset["name"]
        if not sha_path.exists():
            log(f"下载 {sha_asset['name']} ...")
            if not core.download(sha_asset["browser_download_url"], token, str(sha_path), opener):
                raise core.UpdateError("SHA256 文件下载失败")
        expected = core.read_sha256(sha_path)

    out = cache_dir / asset["name"]
    if out.exists():
        if expected and core.verify_hash(out, expected, log):
            log(f"复用缓存 {out}")
            return str(out), expected, version, asset["name"], is_delta
        if not expected and asset.get("size") and out.stat().st_size == asset["size"]:
            log(f"复用缓存 {out}（尺寸一致）")
            return str(out), expected, version, asset["name"], is_delta
        out.unlink(missing_ok=True)

    log(f"下载 {asset['name']} ...")

    def progress(percent):
        if job:
            job.set_percent(percent)

    zip_path = core.download(asset["browser_download_url"], token, str(out), opener,
                             expected, on_progress=progress)
    if not zip_path:
        raise core.UpdateError("下载或校验失败")
    return zip_path, expected, version, asset["name"], is_delta


def full_package(settings, log, job):
    """增量包要求完整包时，改下完整包。"""
    token = token_of(settings)
    opener = core.make_opener(settings.get("proxy") or None)
    cache_dir = (Path(settings["cache_dir"]).expanduser() if settings.get("cache_dir")
                 else core.default_cache_dir())
    release = core.github_release(None, token, settings.get("repo") or core.REPO)
    full = [a for a in (release.get("assets") or [])
            if a.get("name", "").endswith(".zip") and "-update" not in a.get("name", "")]
    if not full:
        raise core.UpdateError("Release 里没有完整包")
    asset = full[0]
    sha_asset = next((a for a in (release.get("assets") or [])
                      if a.get("name") == asset["name"] + ".sha256"), None)
    expected = None
    if sha_asset:
        sha_path = cache_dir / sha_asset["name"]
        if not sha_path.exists():
            core.download(sha_asset["browser_download_url"], token, str(sha_path), opener)
        expected = core.read_sha256(sha_path)
    out = cache_dir / asset["name"]
    if not (out.exists() and expected and core.verify_hash(out, expected, log)):
        log(f"下载完整包 {asset['name']} ...")
        core.download(asset["browser_download_url"], token, str(out), opener, expected,
                      on_progress=(job.set_percent if job else None))
    version = (release.get("tag_name") or "unknown").lstrip("v")
    return str(out), expected, version


def check_task(settings):
    def task(log, job):
        token = token_of(settings)
        try:
            release = core.github_release(None, token, settings.get("repo") or core.REPO)
        except Exception as exc:  # noqa: BLE001
            raise core.UpdateError(
                f"无法访问 GitHub Release：{exc}\n"
                "若为 API 限流，可在设置里填写 token，或检查网络/代理") from exc
        asset, is_delta = core.pick_asset(release)
        version = (release.get("tag_name") or "unknown").lstrip("v")
        log(f"远端最新：v{version}（{asset['name']}）")
        log(f"包类型：{'增量包' if is_delta else '完整包'}，"
            f"大小 {round((asset.get('size') or 0) / 1024 / 1024, 1)}MB")
        return {"version": version, "asset": asset["name"], "delta": is_delta}
    return task


def update_task(settings, dry_run, paths):
    def task(log, job):
        profiles = selected_profiles(paths)
        zip_path, expected, version, _name, _is_delta = resolve_package(settings, log, job)
        log(f"准备更新 {len(profiles)} 个用户目录（{'预演' if dry_run else '正式'}）")

        results = []
        for profile in profiles:
            log("")
            log(f"[{profile['label']}] {profile['path']}")
            current_zip, current_expected, current_version = zip_path, expected, version
            try:
                stats = core.apply_zip(
                    current_zip, profile["path"], current_version, dry_run,
                    current_expected, log=log,
                    snapshot=bool(settings.get("snapshot")) and not dry_run,
                    on_progress=lambda done, total, rel: job.set_percent(done * 100 / max(total, 1)),
                )
            except core.FullPackageRequired as exc:
                log(f"  ! {exc}")
                log("  自动改用完整包…")
                current_zip, current_expected, current_version = full_package(settings, log, job)
                stats = core.apply_zip(
                    current_zip, profile["path"], current_version, dry_run,
                    current_expected, log=log,
                    snapshot=bool(settings.get("snapshot")) and not dry_run,
                    on_progress=lambda done, total, rel: job.set_percent(done * 100 / max(total, 1)),
                )
            results.append({
                "label": profile["label"],
                "path": str(profile["path"]),
                "copied": stats["copied"],
                "skipped": stats["skipped"],
                "backup": stats["backup"],
            })
            if settings.get("deploy") and not dry_run:
                core.deploy(profile, False, bool(settings.get("restart")), log)

        return {"version": version, "asset": _name, "delta": _is_delta,
                "dry_run": dry_run, "targets": results}

    return task


def rollback_task(settings, items):
    def task(log, job):
        if not items:
            raise core.UpdateError("没有选择要回滚的备份")
        results = []
        for item in items:
            target = Path(item["path"]).expanduser()
            log(f"\n[{item.get('label') or target.name}] {target}")
            data = core.rollback(target, item["stamp"], log)
            results.append({"stamp": item["stamp"], "previous": data.get("previous_version")})
            if settings.get("deploy"):
                profile = {"label": item.get("label") or target.name,
                           "path": target, "kind": item.get("kind", "unknown")}
                core.deploy(profile, False, bool(settings.get("restart")), log)
        job.set_percent(100)
        return {"items": results}
    return task


def build_state():
    settings = load_settings()
    profiles = []
    for profile in core.detect_profiles():
        profiles.append({
            "label": profile["label"],
            "path": str(profile["path"]),
            "kind": profile["kind"],
            "current": core.read_local_version(profile["path"]),
            "backups": core.list_backups(profile["path"])[:10],
        })
    job = RUNNER.job.snapshot() if RUNNER.job else None
    return {"profiles": profiles, "settings": settings, "job": job}


class Handler(BaseHTTPRequestHandler):
    server_version = "CheeseTigerUpdater/1.0"

    def log_message(self, fmt, *args):  # 静音访问日志
        pass

    def _send(self, body, content_type, status=200):
        if isinstance(body, bytes):
            data = body
        else:
            data = json.dumps(body, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def _json(self, payload, status=200):
        self._send(payload, "application/json; charset=utf-8", status)

    def _error(self, message, status=400):
        self._json({"error": str(message)}, status)

    def do_GET(self):
        url = urlparse(self.path)
        if url.path == "/api/state":
            self._json(build_state())
            return
        if url.path == "/api/job":
            job = RUNNER.job
            if not job:
                self._json({"job": None})
                return
            self._json({"job": job.snapshot()})
            return
        self._static(url.path)

    def _static(self, path):
        rel = "index.html" if path == "/" else path.lstrip("/")
        candidate = (WEB_DIR / rel).resolve()
        if WEB_DIR.resolve() not in candidate.parents and candidate != WEB_DIR.resolve():
            self._error("not found", 404)
            return
        if not candidate.exists() or candidate.is_dir():
            self._error("not found", 404)
            return
        types = {".html": "text/html; charset=utf-8",
                 ".css": "text/css; charset=utf-8",
                 ".js": "application/javascript; charset=utf-8",
                 ".svg": "image/svg+xml",
                 ".png": "image/png"}
        self._send(candidate.read_bytes(), types.get(candidate.suffix, "application/octet-stream"))

    def do_POST(self):
        url = urlparse(self.path)
        try:
            length = int(self.headers.get("Content-Length") or 0)
            payload = json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            self._error("请求内容不是合法 JSON")
            return

        try:
            if url.path == "/api/settings":
                self._json({"settings": save_settings(payload)})
                return
            if url.path == "/api/run":
                self._run(payload)
                return
            if url.path == "/api/quit":
                self._json({"ok": True})
                threading.Timer(0.3, self.server.shutdown).start()
                return
        except core.UpdateError as exc:
            self._error(exc)
            return
        self._error("not found", 404)

    def _run(self, payload):
        settings = load_settings()
        action = payload.get("action")
        dry_run = bool(payload.get("dry_run"))
        paths = payload.get("targets") or []
        if action == "check":
            job = RUNNER.start("check", "检查更新", check_task(settings))
        elif action == "update":
            job = RUNNER.start("update", "仅预演" if dry_run else "更新中",
                               update_task(settings, dry_run, paths))
        elif action == "rollback":
            job = RUNNER.start("rollback", "回滚", rollback_task(settings, payload.get("items") or []))
        else:
            raise core.UpdateError(f"未知操作：{action}")
        self._json({"job": job.snapshot()})


def already_running(port):
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/api/state", timeout=1) as resp:
            return resp.status == 200 and b"profiles" in resp.read()
    except Exception:  # noqa: BLE001
        return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--no-browser", action="store_true")
    args = parser.parse_args()

    port = args.port
    if already_running(port):
        url = f"http://127.0.0.1:{port}/"
        print(f"更新器已在运行：{url}")
        if not args.no_browser:
            webbrowser.open(url)
        return

    server = None
    for offset in range(10):
        try:
            server = ThreadingHTTPServer(("127.0.0.1", port + offset), Handler)
            port += offset
            break
        except OSError:
            continue
    if not server:
        raise SystemExit("没有可用端口，无法启动界面")

    url = f"http://127.0.0.1:{port}/"
    print(f"芝士虎整 · 更新器：{url}")
    print("关闭窗口或按 Ctrl+C 退出。")
    if not args.no_browser:
        threading.Timer(1.0, lambda: webbrowser.open(url)).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n已退出。")


if __name__ == "__main__":
    main()
