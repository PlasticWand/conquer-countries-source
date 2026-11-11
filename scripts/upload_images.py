"""Upload PNGs as Roblox images through Open Cloud (Bruno approves each upload).

Usage, from the project root:
    python scripts/upload_images.py [--openfront] <png> [<png> ...]

--openfront marks the images as containing OpenFront resources (CC BY-SA 4.0,
credit "OpenFront") in their Roblox description.

Reads the API key from the user environment variable ROBLOX_API_KEY (never
printed). Uploads to Bruno's account World_Echo (the Conquest owner) and prints
{file name: image id}; the ids go in src/client/Ui/UiAssets.luau. Open Cloud makes
a Decal, so the image id (what an ImageLabel needs) is read out of the decal.
"""
import gzip, json, os, re, sys, time, uuid, urllib.error, urllib.request, winreg

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


def image_id(decal_id):
    status, meta = call("GET", f"https://apis.roblox.com/asset-delivery-api/v1/assetId/{decal_id}")
    if status != 200 or "location" not in meta:
        return None
    with urllib.request.urlopen(meta["location"]) as r:
        data = r.read()
    if data.startswith(bytes([0x1F, 0x8B])):  # gzip
        data = gzip.decompress(data)
    found = re.search(rb"asset/\?id=(\d+)", data)
    return int(found.group(1)) if found else None


def upload(path):
    name = os.path.splitext(os.path.basename(path))[0]
    request = {"assetType": "Decal", "displayName": f"Conquest {name}", "description": DESCRIPTION,
               "creationContext": {"creator": {"userId": CREATOR_USER_ID}}}
    boundary = uuid.uuid4().hex
    with open(path, "rb") as f:
        image = f.read()
    body = (f'--{boundary}\r\nContent-Disposition: form-data; name="request"\r\n\r\n{json.dumps(request)}\r\n'.encode()
            + f'--{boundary}\r\nContent-Disposition: form-data; name="fileContent"; filename="{os.path.basename(path)}"\r\n'
              "Content-Type: image/png\r\n\r\n".encode() + image + f"\r\n--{boundary}--\r\n".encode())
    status, op = call("POST", f"{BASE}/assets", body, f"multipart/form-data; boundary={boundary}")
    if status != 200:
        return {"status": status, **op}
    for _ in range(30):
        if op.get("done"):
            response = op.get("response", {})
            if "assetId" not in response:
                return op
            decal = int(response["assetId"])
            return {"image": image_id(decal), "decal": decal}
        time.sleep(2)
        status, op = call("GET", f"{BASE}/{op['path']}")
        if status != 200:
            return {"status": status, **op}
    return {"pending": op.get("path")}


args = sys.argv[1:]
DESCRIPTION = "Conquest UI art (original, code-drawn)"
if args[:1] == ["--openfront"]:
    args = args[1:]
    DESCRIPTION = 'Conquest UI art. Contains OpenFront resources, CC BY-SA 4.0, credit "OpenFront".'
if not args:
    sys.exit(__doc__)
print(json.dumps({os.path.basename(p): upload(p) for p in args}, indent=1))
