"""Hands an uploaded TestFlight build to the public testers (run by Scripts/testflight-upload.sh).

For the iPhone/iPad and Apple TV apps: waits until App Store Connect has processed <version> (<build>),
copies What to Test from the version's previous build, adds the build to the public "Cloud Drive Browsing"
group and submits it for Beta App Review. Apple often approves a later build of an approved version at
once; otherwise it waits for review while testers keep the previous build.

usage: uv run --with 'pyjwt[crypto]' --with requests Scripts/testflight-publish.py <version> <build> [--dry-run | --announce]
--dry-run only reads: the builds of <version>, the group and its public link.
--announce, once the build is live on the public link: sets "testflight" in website/public/releases.json to it, so
TestFlight builds of the app announce the release (deploy the website afterwards). A platform whose build isn't
live yet keeps its previous build.
"""

import os
import json
import re
import sys
import time
from pathlib import Path

import jwt
import requests

KEY_ID = "JFADGLA7XZ"
ISSUER = "cc097225-575e-4c18-837b-b44d6f57024f"
API = "https://api.appstoreconnect.apple.com/v1"
GROUP = "Cloud Drive Browsing"
APPS = {"iOS": "6825717102", "tvOS": "6825717931"}
# TF_PLATFORMS="tvOS" (as testflight-upload.sh takes it) limits this to the platforms uploaded.
if os.environ.get("TF_PLATFORMS"):
    APPS = {k: v for k, v in APPS.items() if k in os.environ["TF_PLATFORMS"].split()}
FEED_KEYS = {"iOS": "ios", "tvOS": "tvos"}  # ReleaseFeed.platform
FEED = Path(__file__).resolve().parent.parent / "website/public/releases.json"
LIVE = ("IN_BETA_TESTING", "BETA_APPROVED")  # com.jo32.yingxia.ios / .tv


def call(path, method="GET", data=None, ok=()):
    key = (Path.home() / f".appstoreconnect/private_keys/AuthKey_{KEY_ID}.p8").read_text()
    now = int(time.time())
    token = jwt.encode({"iss": ISSUER, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"}, key, algorithm="ES256", headers={"kid": KEY_ID, "typ": "JWT"})
    r = requests.request(method, API + path, headers={"Authorization": f"Bearer {token}"}, json=data, timeout=60)
    if r.status_code in ok:
        return {"status": r.status_code, "errors": r.json().get("errors", [])}
    if not r.ok:
        raise RuntimeError(f"{method} {path}: {r.status_code} {r.text}")
    return r.json() if r.content else {}


def builds(app, version):
    """The version's builds, newest first, with their beta details."""
    res = call(f"/builds?filter[app]={app}&filter[preReleaseVersion.version]={version}&sort=-uploadedDate&limit=50&include=buildBetaDetail")
    details = {i["id"]: i["attributes"] for i in res.get("included", []) if i["type"] == "buildBetaDetails"}
    for b in res["data"]:
        b["beta"] = details.get(b["relationships"]["buildBetaDetail"]["data"]["id"], {})
    return res["data"]


def wait_processed(platform, app, version, build):
    for _ in range(120):  # up to an hour
        match = [b for b in builds(app, version) if b["attributes"]["version"] == build]
        state = match[0]["attributes"]["processingState"] if match else "NOT_YET_LISTED"
        if state == "VALID":
            return match[0]
        if state in ("FAILED", "INVALID"):
            raise RuntimeError(f"{platform} {version} ({build}) processing {state}")
        print(f"   {platform}: {state}, waiting", flush=True)
        time.sleep(30)
    raise RuntimeError(f"{platform} {version} ({build}) not processed after an hour")


def what_to_test(previous, version, build):
    """What to Test of the newest earlier build that has one, per locale, with its build number updated."""
    for b in previous:
        locs = call(f"/builds/{b['id']}/betaBuildLocalizations")["data"]
        notes = {l["attributes"]["locale"]: l["attributes"]["whatsNew"] for l in locs if l["attributes"].get("whatsNew")}
        if notes:
            old = re.escape(f"{version} ({b['attributes']['version']})")
            return {loc: re.sub(old, f"{version} ({build})", text) for loc, text in notes.items()}, b["attributes"]["version"]
    return {}, None


def public_group(platform, app):
    group = next((g for g in call(f"/apps/{app}/betaGroups")["data"] if g["attributes"]["name"] == GROUP), None)
    if not group:
        raise RuntimeError(f"{platform}: no beta group named {GROUP}")
    return group


def announce(version, build):
    """Records <build> as the one testers can install, per platform where it is in the group and live."""
    feed = json.loads(FEED.read_text())
    if not any(r.get("build") == build for r in feed["releases"]):
        print(f"   note: no release in releases.json has build {build}; testers only hear of releases with builds up to it")
    testflight = feed.get("testflight", {})
    for platform, app in APPS.items():
        group = public_group(platform, app)
        in_group = {b["id"] for b in call(f"/betaGroups/{group['id']}/builds?limit=200")["data"]}
        b = next((b for b in builds(app, version) if b["attributes"]["version"] == str(build)), None)
        state = b["beta"].get("externalBuildState") if b else "NOT_UPLOADED"
        key, before = FEED_KEYS[platform], testflight.get(FEED_KEYS[platform], {}).get("build")
        if not b or b["id"] not in in_group or state not in LIVE:
            print(f"== {platform}: {version} ({build}) is {state}" + ("" if b and b["id"] in in_group else f", not in {GROUP}") + f"; keeping {before}")
        elif before and before > build:
            print(f"== {platform}: releases.json already has build {before}; keeping it")
        else:
            testflight[key] = {"build": build, "link": group["attributes"]["publicLink"]}
            print(f"== {platform}: {version} ({build}) {state}, announced (was {before})")
    feed["testflight"] = testflight
    FEED.write_text(json.dumps(feed, indent=2, ensure_ascii=False) + "\n")
    print(f"   wrote {FEED}; commit it and deploy the website")


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    dry = "--dry-run" in sys.argv
    if len(args) != 2:
        sys.exit(__doc__)
    version, build = args
    if "--announce" in sys.argv:
        return announce(version, int(build))
    for platform, app in APPS.items():
        group = public_group(platform, app)
        print(f"== {platform}: {GROUP} {group['attributes'].get('publicLink')}")
        if dry:
            for b in builds(app, version):
                print(f"   {version} ({b['attributes']['version']}) {b['attributes']['processingState']} {b['beta'].get('externalBuildState')}")
            continue

        b = wait_processed(platform, app, version, build)
        previous = [p for p in builds(app, version) if p["id"] != b["id"]]

        # Export compliance normally comes from ITSAppUsesNonExemptEncryption in Info.plist.
        if b["beta"].get("externalBuildState") == "MISSING_EXPORT_COMPLIANCE":
            call(f"/builds/{b['id']}", "PATCH", {"data": {"type": "builds", "id": b["id"], "attributes": {"usesNonExemptEncryption": False}}})

        notes, source = what_to_test(previous, version, build)
        have = {l["attributes"]["locale"]: l["id"] for l in call(f"/builds/{b['id']}/betaBuildLocalizations")["data"]}
        for locale, text in notes.items():
            if locale in have:
                call(f"/betaBuildLocalizations/{have[locale]}", "PATCH", {"data": {"type": "betaBuildLocalizations", "id": have[locale], "attributes": {"whatsNew": text}}})
            else:
                call("/betaBuildLocalizations", "POST", {"data": {"type": "betaBuildLocalizations", "attributes": {"locale": locale, "whatsNew": text}, "relationships": {"build": {"data": {"type": "builds", "id": b["id"]}}}}})
        print(f"   What to Test: {', '.join(notes) or 'none found'}" + (f" (from build {source})" if source else ""))

        # Adding to a group and submitting for review need an App Manager or Admin key; JFADGLA7XZ (2026-10) gets
        # 403 for both, so then it's one step in App Store Connect (adding the build to the group submits it).
        added = call(f"/betaGroups/{group['id']}/relationships/builds", "POST", {"data": [{"type": "builds", "id": b["id"]}]}, ok=(403, 409))
        sub = call("/betaAppReviewSubmissions", "POST", {"data": {"type": "betaAppReviewSubmissions", "relationships": {"build": {"data": {"type": "builds", "id": b["id"]}}}}}, ok=(403, 409, 422))
        if added.get("status") == 403 or sub.get("status") == 403:
            print(f"   MANUAL STEP (this API key may not manage groups or submit): add {version} ({build}) to {GROUP} > Builds > +")
            print(f"   https://appstoreconnect.apple.com/apps/{app}/testflight/groups/{group['id']}")
        else:
            print(f"   added to {GROUP}; " + (f"review: {sub['errors'][0].get('detail') or sub['errors'][0].get('title')}" if sub.get("errors") else "submitted for Beta App Review"))

        time.sleep(10)
        state = next(x for x in builds(app, version) if x["id"] == b["id"])["beta"].get("externalBuildState")
        meaning = {"BETA_APPROVED": "approved, live on the public link", "IN_BETA_TESTING": "live on the public link", "WAITING_FOR_BETA_REVIEW": "waiting for Beta App Review (testers keep the previous build meanwhile)", "IN_BETA_REVIEW": "in Beta App Review"}
        print(f"   {version} ({build}): {state}, {meaning.get(state, 'check App Store Connect')}")
    print(f"Once both builds are live, tell TestFlight builds of the app: {sys.argv[0]} {version} {build} --announce, then deploy the website.")


if __name__ == "__main__":
    main()
