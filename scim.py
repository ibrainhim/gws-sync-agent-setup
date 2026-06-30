#!/usr/bin/env python3
"""Quick SCIM client for manual testing. Reads SCIM_BASE_URL and SCIM_TOKEN from env."""

import json
import os
import sys
import urllib.request
import urllib.error

BASE_URL = os.environ.get("SCIM_BASE_URL", "").rstrip("/")
TOKEN    = os.environ.get("SCIM_TOKEN", "")

if not BASE_URL or not TOKEN:
    print("ERROR: set SCIM_BASE_URL and SCIM_TOKEN in your environment")
    sys.exit(1)


def req(method, path, body=None):
    url = f"{BASE_URL}/{path.lstrip('/')}"
    data = json.dumps(body).encode() if body else None
    r = urllib.request.Request(url, data=data, method=method, headers={
        "Authorization": f"Bearer {TOKEN}",
        "Content-Type":  "application/scim+json",
        "Accept":        "application/scim+json",
    })
    try:
        with urllib.request.urlopen(r) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        print(f"HTTP {e.code}: {e.read().decode()}")
        return None


def list_users(count=50):
    result = req("GET", f"Users?count={count}")
    if not result:
        return
    total = result.get("totalResults", 0)
    print(f"Total users: {total}\n")
    for u in result.get("Resources", []):
        active = "active" if u.get("active") else "inactive"
        print(f"  {u['userName']:<40} {active:<10} externalId={u.get('externalId','—')}")


def get_user(identifier):
    # Try by ID first, then search by userName
    result = req("GET", f"Users/{identifier}")
    if result:
        print(json.dumps(result, indent=2))
        return
    result = req("GET", f"Users?filter=userName+eq+\"{identifier}\"")
    if result and result.get("Resources"):
        print(json.dumps(result["Resources"][0], indent=2))
    else:
        print("Not found")


def create_user(username, given, family, external_id):
    body = {
        "schemas": [
            "urn:ietf:params:scim:schemas:core:2.0:User",
            "urn:ietf:params:scim:schemas:extension:enterprise:2.0:User"
        ],
        "userName":   username,
        "name":       {"givenName": given, "familyName": family},
        "emails":     [{"value": username, "type": "work", "primary": True}],
        "active":     True,
        "externalId": external_id,
    }
    result = req("POST", "Users", body)
    if result:
        print(f"Created: {result.get('id')} — {result.get('userName')}")


def patch_user(user_id, **fields):
    ops = [{"op": "replace", "path": k, "value": v} for k, v in fields.items()]
    body = {"schemas": ["urn:ietf:params:scim:api:messages:2.0:PatchOp"], "Operations": ops}
    result = req("PATCH", f"Users/{user_id}", body)
    if result is not None:
        print(f"Patched: {user_id}")


def delete_user(user_id):
    req("DELETE", f"Users/{user_id}")
    print(f"Deleted: {user_id}")


def disable_user(user_id):
    patch_user(user_id, active=False)
    print(f"Disabled: {user_id}")


USAGE = """
Usage:
  python3 scim.py list
  python3 scim.py get <id-or-username>
  python3 scim.py create <username> <givenName> <familyName> <externalId>
  python3 scim.py patch <id> active=false department=Engineering
  python3 scim.py disable <id>
  python3 scim.py delete <id>
"""

if __name__ == "__main__":
    args = sys.argv[1:]
    if not args:
        print(USAGE); sys.exit(0)

    cmd, *rest = args

    if cmd == "list":
        list_users(int(rest[0]) if rest else 50)

    elif cmd == "get":
        get_user(rest[0])

    elif cmd == "create":
        if len(rest) < 4:
            print("create requires: <username> <givenName> <familyName> <externalId>")
            sys.exit(1)
        create_user(*rest[:4])

    elif cmd == "patch":
        if len(rest) < 2:
            print("patch requires: <id> key=value [key=value ...]")
            sys.exit(1)
        user_id = rest[0]
        fields = {}
        for kv in rest[1:]:
            k, _, v = kv.partition("=")
            if v.lower() == "true":  v = True
            elif v.lower() == "false": v = False
            fields[k] = v
        patch_user(user_id, **fields)

    elif cmd == "disable":
        disable_user(rest[0])

    elif cmd == "delete":
        delete_user(rest[0])

    else:
        print(USAGE)
