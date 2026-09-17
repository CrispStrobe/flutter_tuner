"""Minimal App Store Connect API client — stdlib + cryptography only.

Reads credentials from the environment so it runs in CI as well as locally:

    ASC_KEY_ID, ASC_ISSUER_ID, ASC_APP_ID  and one of
    ASC_API_KEY_P8_BASE64 (base64 of the .p8) or ASC_KEY_PATH (a file).

Never print the key. Requires `cryptography`.
"""
import base64, json, os, time, urllib.request, urllib.error, urllib.parse
from cryptography.hazmat.primitives import serialization, hashes
from cryptography.hazmat.primitives.asymmetric import ec, utils as asym_utils

KEY_ID = os.environ.get("ASC_KEY_ID", "9RMU3C7422")
ISSUER_ID = os.environ.get("ASC_ISSUER_ID", "5f618ba3-98ef-42ad-835c-fbbef6c76cf5")
APP_ID = os.environ.get("ASC_APP_ID", "6798295311")
KEY_PATH = os.environ.get(
    "ASC_KEY_PATH",
    os.path.expanduser("~/.appstoreconnect/private_keys/AuthKey_%s.p8" % KEY_ID))


def _private_key_bytes() -> bytes:
    """The .p8, from a base64 env var in CI or from disk locally."""
    b64 = os.environ.get("ASC_API_KEY_P8_BASE64")
    if b64:
        return base64.b64decode(b64)
    with open(KEY_PATH, "rb") as f:
        return f.read()
BASE = "https://api.appstoreconnect.apple.com"

def _b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()

def token() -> str:
    key = serialization.load_pem_private_key(_private_key_bytes(), password=None)
    now = int(time.time())
    header = {"alg": "ES256", "kid": KEY_ID, "typ": "JWT"}
    payload = {"iss": ISSUER_ID, "iat": now, "exp": now + 900,
               "aud": "appstoreconnect-v1"}
    signing_input = f"{_b64(json.dumps(header).encode())}.{_b64(json.dumps(payload).encode())}"
    der = key.sign(signing_input.encode(), ec.ECDSA(hashes.SHA256()))
    r, s = asym_utils.decode_dss_signature(der)
    sig = r.to_bytes(32, "big") + s.to_bytes(32, "big")
    return f"{signing_input}.{_b64(sig)}"

def call(method, path, body=None, raw=False):
    url = path if path.startswith("http") else BASE + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", "Bearer " + token())
    if data:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req) as r:
            text = r.read().decode()
            return (r.status, json.loads(text) if text else {})
    except urllib.error.HTTPError as e:
        text = e.read().decode()
        try:
            return (e.code, json.loads(text) if text else {})
        except Exception:
            return (e.code, {"raw": text})

def get(path):
    return call("GET", path)

if __name__ == "__main__":
    import sys
    status, body = get(sys.argv[1] if len(sys.argv) > 1 else f"/v1/apps/{APP_ID}")
    print(status)
    print(json.dumps(body, indent=2)[:4000])
