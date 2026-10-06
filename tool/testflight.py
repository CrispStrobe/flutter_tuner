#!/usr/bin/env python3
"""Put one CrispTuner build on TestFlight: notes, groups, Beta App Review.

    python3 tool/testflight.py --platform IOS --build 10            # dry run
    python3 tool/testflight.py --platform IOS --build 10 --apply    # do it

Runs in CI (.github/workflows/testflight.yml), where the App Store Connect key
lives; see tool/asc.py for the credentials it reads.

What it does to the build, in order — and, without --apply, only prints:

  1. waits for Apple's processing to finish (--wait-minutes);
  2. answers export compliance if the upload left it open;
  3. writes the "What to Test" notes from testflight/whats-new.<locale>.txt
     for every locale that has a file — PATCHing the localisation Apple
     creates on processing, since POSTing a second one 409s;
  4. adds the build to every beta group of the app;
  5. submits it for Beta App Review when an external group exists.

Before any of it, it prints the notes the previous build carried, so a dry run
is also the way to read what testers were last told.

Reads that exist only for the report warn and carry on; the exit status
belongs to the writes (appstore.md, "A verification step must not be able to
fail the run it verifies").
"""
import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from asc import APP_ID, call, get  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NOTES_DIR = os.path.join(ROOT, "testflight")


def notes_files():
    out = {}
    for name in sorted(os.listdir(NOTES_DIR)):
        if name.startswith("whats-new.") and name.endswith(".txt"):
            locale = name[len("whats-new."):-len(".txt")]
            with open(os.path.join(NOTES_DIR, name), encoding="utf-8") as f:
                text = f.read().strip()
            if len(text) > 4000:
                sys.exit(f"{name}: {len(text)} characters; TestFlight allows 4000")
            out[locale] = text
    if not out:
        sys.exit(f"no whats-new.<locale>.txt in {NOTES_DIR}")
    return out


def find_build(platform, number):
    status, body = get(
        f"/v1/builds?filter[app]={APP_ID}&filter[version]={number}"
        f"&filter[preReleaseVersion.platform]={platform}&include=preReleaseVersion")
    if status != 200:
        sys.exit(f"build lookup failed: {status} {body}")
    data = body.get("data", [])
    return data[0] if data else None


def previous_notes(platform, number):
    """The notes the newest build before this one carried, for the report."""
    status, body = get(
        f"/v1/builds?filter[app]={APP_ID}"
        f"&filter[preReleaseVersion.platform]={platform}&sort=-uploadedDate&limit=5")
    if status != 200:
        print(f"  (could not list earlier builds: {status})")
        return
    for b in body.get("data", []):
        if b["attributes"]["version"] == str(number):
            continue
        st, locs = get(f"/v1/builds/{b['id']}/betaBuildLocalizations")
        print(f"  previous build {b['attributes']['version']}:")
        if st != 200 or not locs.get("data"):
            print("    (no notes)")
        for loc in locs.get("data", []):
            text = (loc["attributes"].get("whatsNew") or "").strip()
            print(f"    [{loc['attributes']['locale']}]")
            for line in text.splitlines() or ["(empty)"]:
                print(f"      {line}")
        return


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--platform", required=True, choices=["IOS", "MAC_OS"])
    ap.add_argument("--build", required=True, help="CFBundleVersion, e.g. 10")
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--wait-minutes", type=int, default=0,
                    help="poll this long for the upload to appear and finish processing")
    args = ap.parse_args()
    act = args.apply
    tag = "" if act else "[dry run] "
    notes = notes_files()

    print(f"{args.platform} build {args.build}")
    previous_notes(args.platform, args.build)

    deadline = time.time() + 60 * args.wait_minutes
    while True:
        build = find_build(args.platform, args.build)
        state = build["attributes"]["processingState"] if build else "NOT_UPLOADED"
        if state == "VALID" or time.time() >= deadline:
            break
        print(f"  processing: {state}; waiting")
        time.sleep(60)
    if not build or state != "VALID":
        sys.exit(f"build {args.build} is {state}; nothing to do yet")
    bid = build["id"]
    print(f"  build id {bid}, processing {state}")

    failures = []

    # 2. Export compliance. The plist answers it (ITSAppUsesNonExemptEncryption
    # = false), but an upload that predates that key would sit here forever.
    if build["attributes"].get("usesNonExemptEncryption") is None:
        print(f"  {tag}set usesNonExemptEncryption=false")
        if act:
            st, body = call("PATCH", f"/v1/builds/{bid}", {"data": {
                "type": "builds", "id": bid,
                "attributes": {"usesNonExemptEncryption": False}}})
            if st != 200:
                failures.append(f"export compliance: {st} {body}")

    # 3. What to Test, per locale.
    st, body = get(f"/v1/builds/{bid}/betaBuildLocalizations")
    existing = {d["attributes"]["locale"]: d["id"] for d in body.get("data", [])} \
        if st == 200 else {}
    for locale, text in notes.items():
        print(f"  {tag}notes [{locale}], {len(text)} characters")
        if not act:
            for line in text.splitlines():
                print(f"      {line}")
            continue
        if locale in existing:
            st, body = call("PATCH", f"/v1/betaBuildLocalizations/{existing[locale]}",
                            {"data": {"type": "betaBuildLocalizations",
                                      "id": existing[locale],
                                      "attributes": {"whatsNew": text}}})
            ok = st == 200
        else:
            st, body = call("POST", "/v1/betaBuildLocalizations", {"data": {
                "type": "betaBuildLocalizations",
                "attributes": {"locale": locale, "whatsNew": text},
                "relationships": {"build": {"data": {"type": "builds", "id": bid}}}}})
            ok = st == 201
        if not ok:
            failures.append(f"notes [{locale}]: {st} {body}")

    # 4. Groups. Internal groups that see every build refuse an explicit add;
    # that is not a failure.
    st, body = get(f"/v1/apps/{APP_ID}/betaGroups?limit=50")
    groups = body.get("data", []) if st == 200 else []
    if st != 200:
        failures.append(f"listing beta groups: {st} {body}")
    external = False
    for g in groups:
        a = g["attributes"]
        kind = "internal" if a.get("isInternalGroup") else "external"
        external |= kind == "external"
        if a.get("isInternalGroup") and a.get("hasAccessToAllBuilds"):
            print(f"  group {a['name']} ({kind}) already sees every build")
            continue
        print(f"  {tag}add to group {a['name']} ({kind})")
        if act:
            st, body = call("POST", f"/v1/betaGroups/{g['id']}/relationships/builds",
                            {"data": [{"type": "builds", "id": bid}]})
            if st not in (200, 204):
                failures.append(f"group {a['name']}: {st} {body}")

    # 5. Beta App Review, which is what lets external testers install it.
    if external:
        print(f"  {tag}submit for Beta App Review")
        if act:
            st, body = call("POST", "/v1/betaAppReviewSubmissions", {"data": {
                "type": "betaAppReviewSubmissions",
                "relationships": {"build": {"data": {"type": "builds", "id": bid}}}}})
            if st == 201:
                print(f"    state: {body['data']['attributes'].get('betaReviewState')}")
            else:
                detail = " ".join(e.get("detail", "") for e in body.get("errors", []))
                if "already" in detail.lower():
                    print(f"    already submitted: {detail}")
                else:
                    failures.append(f"beta review submission: {st} {detail or body}")

    if failures:
        print("\nFAILED:\n  " + "\n  ".join(failures))
        return 1
    print("\ndone" if act else "\ndry run only; re-run with --apply")
    return 0


if __name__ == "__main__":
    sys.exit(main())
