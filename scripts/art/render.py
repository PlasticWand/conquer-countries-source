"""Render a local HTML page to a PNG with headless Chrome (or Edge).

    from render import render
    render(page_path, png_path, width, height, transparent=True)

The browser sometimes keeps running after it has written the screenshot, so
this waits for the PNG to appear and stop growing, then ends the browser's
process tree. Each call uses a fresh temporary profile.
"""
import os
import subprocess
import tempfile
import time
from pathlib import Path

BROWSERS = [
    Path("C:/Program Files/Google/Chrome/Application/chrome.exe"),
    Path("C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe"),
]


def render(page: Path, out: Path, width: int, height: int, transparent: bool = True, timeout: float = 60) -> None:
    browser = next(b for b in BROWSERS if b.exists())
    out = Path(out)
    if out.exists():
        out.unlink()
    profile = tempfile.mkdtemp(prefix="conquest-render-")
    args = [str(browser), "--headless=new", "--disable-gpu", "--hide-scrollbars", "--no-first-run",
            "--no-default-browser-check", "--disable-extensions", "--force-device-scale-factor=1",
            f"--window-size={width},{height}", "--virtual-time-budget=3000", "--allow-file-access-from-files",
            f"--user-data-dir={profile}", f"--screenshot={out}", Path(page).resolve().as_uri()]
    if transparent:
        args.insert(-2, "--default-background-color=00000000")
    proc = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                            creationflags=subprocess.CREATE_NO_WINDOW)
    deadline = time.time() + timeout
    size = -1
    try:
        while time.time() < deadline:
            if out.exists():
                now = out.stat().st_size
                if now > 0 and now == size:
                    return
                size = now
            if proc.poll() is not None and out.exists() and out.stat().st_size > 0:
                return
            time.sleep(0.5)
        raise TimeoutError(f"no screenshot from {browser.name} after {timeout}s: {page}")
    finally:
        if proc.poll() is None:
            subprocess.run(["taskkill", "/PID", str(proc.pid), "/T", "/F"], capture_output=True)
