"""Upload FBX models to Roblox through Open Cloud, as World_Echo.

Usage, from the project root:
    python scripts/upload_model.py <fbx> [<fbx> ...]

Reads the API key from the user environment variable ROBLOX_API_KEY (never
printed) and prints {file name: model asset id}. The server loads a model with
InsertService:LoadAsset, which works because the game's owner owns the asset.
List each upload in docs/design/store-items.md.
"""
import json, os, sys, time, uuid, urllib.error, urllib.request, winreg

CREATOR_USER_ID = 1642763318  # World_Echo, owner of Conquest (universe 10772018194)
BASE = "https://apis.roblox.com/assets/v1"

with winreg.OpenKey(winreg.HKEY_CURRENT_USER, "Environment") as env:
    KEY = winreg.QueryValueEx(env, "ROBLOX_API_KEY")[0]


def call(method, url, body=None, content_type=None):
    req = urllib.request.Request(url, data=body, method=method, headers={"x-api-key": KEY})
    if content_type:
        req.add_header("Content-Type", content_type)
    try:
        with urllib.request.urlopen(req) as r:
            return r.status, json.loads(r.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        return e.code, {"error": e.read().decode()[:400]}


def upload(path):
    name = os.path.splitext(os.path.basename(path))[0]
    request = {"assetType": "Model", "displayName": f"Conquest {name}",
               "description": "Conquest supply crate (original, made in Blender)",
               "creationContext": {"creator": {"userId": CREATOR_USER_ID}}}
    boundary = uuid.uuid4().hex
    with open(path, "rb") as f:
        data = f.read()
    body = (f'--{boundary}\r\nContent-Disposition: form-data; name="request"\r\n\r\n{json.dumps(request)}\r\n'.encode()
            + f'--{boundary}\r\nContent-Disposition: form-data; name="fileContent"; filename="{os.path.basename(path)}"\r\n'
              "Content-Type: model/fbx\r\n\r\n".encode() + data + f"\r\n--{boundary}--\r\n".encode())
    status, op = call("POST", f"{BASE}/assets", body, f"multipart/form-data; boundary={boundary}")
    if status != 200:
        return {"status": status, **op}
    for _ in range(60):
        if op.get("done"):
            response = op.get("response", {})
            return {"model": int(response["assetId"])} if "assetId" in response else op
        time.sleep(2)
        status, op = call("GET", f"{BASE}/{op['path']}")
        if status != 200:
            return {"status": status, **op}
    return {"pending": op.get("path")}


if not sys.argv[1:]:
    sys.exit(__doc__)
print(json.dumps({os.path.basename(p): upload(p) for p in sys.argv[1:]}, indent=1))
