#!/usr/bin/env python3
"""Report CrispTuner's App Store and TestFlight review states.

Exits 0 always; prints a human summary, and writes `changed=true|false` plus a
`summary` to $GITHUB_OUTPUT when running in Actions. "Changed" means something
has left review — i.e. there is news worth waking a human for.
"""
import json, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from asc import get, APP_ID

# States that mean "still waiting"; anything else is news.
QUIET_APPSTORE = {"WAITING_FOR_REVIEW", "IN_REVIEW", "PREPARE_FOR_SUBMISSION",
                  "DEVELOPER_REMOVED_FROM_SALE", "READY_FOR_SALE"}
QUIET_BETA = {"WAITING_FOR_BETA_REVIEW", "IN_BETA_REVIEW", "PROCESSING",
              "READY_FOR_BETA_SUBMISSION", "IN_BETA_TESTING", "BETA_APPROVED"}


def main() -> int:
    news, lines = [], []

    for v in get(f"/v1/apps/{APP_ID}/appStoreVersions?limit=10")[1].get("data", []):
        a = v["attributes"]
        state, plat, ver = a["appStoreState"], a["platform"], a["versionString"]
        lines.append(f"App Store {plat} {ver}: {state}")
        if state not in QUIET_APPSTORE:
            news.append(f"App Store {plat} {ver} is now {state}")
        # READY_FOR_SALE is quiet in general, but not for a version we were
        # watching go through review.
        if state == "PENDING_DEVELOPER_RELEASE":
            news.append(f"App Store {plat} {ver} is approved and awaiting release")

    for platform in ("IOS", "MAC_OS"):
        builds = get(f"/v1/builds?filter[app]={APP_ID}"
                     f"&filter[preReleaseVersion.platform]={platform}"
                     f"&limit=3&sort=-uploadedDate")[1].get("data", [])
        if not builds:
            continue
        b = builds[0]
        d = get(f"/v1/builds/{b['id']}/buildBetaDetail")[1].get("data", {}).get("attributes", {})
        ext = d.get("externalBuildState")
        lines.append(f"TestFlight {platform} build {b['attributes']['version']}: {ext}")
        if ext and ext not in QUIET_BETA:
            news.append(f"TestFlight {platform} build "
                        f"{b['attributes']['version']} is now {ext}")

    summary = "\n".join(lines)
    print(summary)
    if news:
        print("\nNEWS:\n  " + "\n  ".join(news))

    out = os.environ.get("GITHUB_OUTPUT")
    if out:
        with open(out, "a") as f:
            f.write(f"changed={'true' if news else 'false'}\n")
            f.write("summary<<EOF\n" + summary + "\n")
            if news:
                f.write("\nNews:\n- " + "\n- ".join(news) + "\n")
            f.write("EOF\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
