"""Export the game's source to the public source repository (AGPL section 13).

Bruno, 2026-11-11: a separate public repo holds only what builds the game
(code, map data, tests, build files, licences); this repo's docs, plans and
art stay private. Run after every Roblox publish:

    python scripts/export_source.py <placeVersion> <sourceRepoClone> [commit]

(placeVersion 0: an untagged snapshot.)

Copies the tracked files of `commit` (default HEAD) listed in PATHS into the
clone, replacing what was there, adds README.md, commits "place-v<N>" and tags
place-v<N> in both repositories. Pushing is left to the caller.
"""
import shutil
import subprocess
import sys
import tarfile
import io
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PATHS = ["src", "tests", "scripts", "default.project.json", ".gitattributes", "LICENSE", "NOTICE.md", "LICENSE-ASSETS.md"]
# Not part of the source: local media tooling.
EXCLUDE = ["scripts/trailer"]

README = """# Conquer Countries: source code

This is the source code of **Conquer Countries**, a Roblox game that forks
[OpenFront](https://github.com/openfrontio/OpenFrontIO) and ports parts of
[RoWorld](https://github.com/lukechatton/roworld). It is published here as the
GNU Affero General Public License requires: every published version of the
game has a tag `place-v<N>`, where N is the place version shown in the game's
Credits window.

- Code: AGPL-3.0 with OpenFront's additional terms, see [`LICENSE`](LICENSE) and [`NOTICE.md`](NOTICE.md).
- Assets: see [`LICENSE-ASSETS.md`](LICENSE-ASSETS.md). The game's own artwork is
  not in this repository and is not licensed for reuse.
- Build: [Rojo](https://rojo.space) (`rojo build -o game.rbxl`); tests run with
  [Lune](https://lune-org.github.io/docs) (`lune run tests/run`).

Conquer Countries is not affiliated with or endorsed by OpenFront Inc. or by RoWorld.
"""


def git(*args: str, cwd: Path = ROOT) -> str:
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


def main() -> None:
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    version, dest = int(sys.argv[1]), Path(sys.argv[2]).resolve()
    commit = sys.argv[3] if len(sys.argv) > 3 else "HEAD"
    sha = git("rev-parse", commit)
    tag = f"place-v{version}"
    if not (dest / ".git").exists():
        sys.exit(f"{dest} is not a git clone")
    # Clear the clone (keep .git), then unpack the exact tracked files.
    for child in dest.iterdir():
        if child.name != ".git":
            shutil.rmtree(child) if child.is_dir() else child.unlink()
    data = subprocess.run(["git", "archive", "--format=tar", sha, *PATHS], cwd=ROOT, check=True, capture_output=True).stdout
    with tarfile.open(fileobj=io.BytesIO(data)) as tar:
        members = [m for m in tar.getmembers() if not any(m.name == e or m.name.startswith(e + "/") for e in EXCLUDE)]
        tar.extractall(dest, members=members, filter="data")
    (dest / "README.md").write_text(README, encoding="utf-8", newline="\n")
    git("add", "-A", cwd=dest)
    if version == 0:
        # A snapshot not tied to a publish (the first upload, 2026-11-11): no tag.
        git("commit", "-q", "-m", f"Source snapshot at {sha[:10]}", cwd=dest)
        print(f"snapshot: exported {sha[:10]} ({len(members)} entries) to {dest}; no tag. Push it.")
        return
    git("commit", "-q", "-m", f"{tag}: source of the published place version {version}", cwd=dest)
    git("tag", tag, cwd=dest)
    git("tag", tag, sha)
    print(f"{tag}: exported {sha[:10]} ({len(members)} entries) to {dest}; tagged both repos. Push both, with tags.")


if __name__ == "__main__":
    main()
