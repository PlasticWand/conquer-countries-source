"""Check that a published place version runs exactly our code.

    python scripts/verify_publish.py <placeVersion> [commit]

Downloads the version through Open Cloud asset delivery (the API key comes
from the user environment variable ROBLOX_API_KEY and is never printed),
builds `commit` (default HEAD) with Rojo, and compares every script's source
by full path: same, differs, missing or extra. Run after each publish, before
export_source.py and the place-v<N> tag (docs/LICENSING_PLAN.md).
"""
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import urllib.request
import winreg
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PLACE = 72476092124564
LUNE = Path.home() / ".luau-tools" / "lune.exe"

DUMP = r'''
local fs = require("@lune/fs")
local roblox = require("@lune/roblox")
local process = require("@lune/process")
local game = roblox.deserializePlace(fs.readFile(process.args[1]))
local out = {}
for _, d in game:GetDescendants() do
	if d:IsA("LuaSourceContainer") then
		out[d:GetFullName() .. " [" .. d.ClassName .. "]"] = d.Source
	end
end
fs.writeFile(process.args[2], require("@lune/serde").encode("json", out))
'''


def key() -> str:
    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, "Environment") as env:
        return winreg.QueryValueEx(env, "ROBLOX_API_KEY")[0]


def download(version: int, dest: Path):
    url = f"https://apis.roblox.com/asset-delivery-api/v1/assetId/{PLACE}/version/{version}"
    req = urllib.request.Request(url, headers={"x-api-key": key()})
    meta = json.loads(urllib.request.urlopen(req, timeout=60).read())
    loc = meta.get("location")
    if not loc:
        raise SystemExit(f"no download location for version {version}: {meta}")
    with urllib.request.urlopen(loc, timeout=300) as r:
        dest.write_bytes(r.read())


def dump(place: Path, tmp: Path) -> dict:
    script = tmp / "dump.luau"
    script.write_text(DUMP, encoding="utf-8")
    out = tmp / (place.stem + ".json")
    subprocess.run([str(LUNE), "run", str(script), str(place), str(out)], check=True)
    return json.loads(out.read_text(encoding="utf-8"))


def build(commit: str, tmp: Path) -> Path:
    tree = tmp / "src"
    subprocess.run(["git", "worktree", "add", "--detach", str(tree), commit], cwd=ROOT, check=True, capture_output=True)
    try:
        out = tmp / "built.rbxl"
        subprocess.run(["rojo", "build", "-o", str(out)], cwd=tree, check=True, capture_output=True)
        return out
    finally:
        subprocess.run(["git", "worktree", "remove", "--force", str(tree)], cwd=ROOT, capture_output=True)


def main():
    version = int(sys.argv[1])
    commit = sys.argv[2] if len(sys.argv) > 2 else "HEAD"
    sha = subprocess.run(["git", "rev-parse", "--short", commit], cwd=ROOT, capture_output=True, text=True, check=True).stdout.strip()
    with tempfile.TemporaryDirectory() as t:
        tmp = Path(t)
        live = tmp / f"v{version}.rbxl"
        download(version, live)
        ours = dump(build(commit, tmp), tmp)
        theirs = dump(live, tmp)
    h = lambda s: hashlib.sha256(s.encode("utf-8")).hexdigest()
    # Rojo builds only the synced trees; compare scripts under them.
    roots = ("ReplicatedStorage.Shared", "ServerScriptService.Server", "StarterPlayer.StarterPlayerScripts.Client")
    mine = {k: v for k, v in ours.items() if k.startswith(roots)}
    live_s = {k: v for k, v in theirs.items() if k.startswith(roots)}
    differs = sorted(k for k in mine if k in live_s and h(mine[k]) != h(live_s[k]))
    missing = sorted(k for k in mine if k not in live_s)
    extra = sorted(k for k in live_s if k not in mine)
    same = len(mine) - len(differs) - len(missing)
    print(f"V{version} vs {sha}: {same} same, {len(differs)} differ, {len(missing)} missing, {len(extra)} extra (of {len(mine)} built)")
    for label, items in (("DIFFERS", differs), ("MISSING", missing), ("EXTRA", extra)):
        for k in items[:20]:
            print(f"  {label}: {k}")
    sys.exit(0 if not (differs or missing or extra) else 1)


if __name__ == "__main__":
    main()
