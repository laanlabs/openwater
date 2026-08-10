#!/usr/bin/env bash
#
# Pull rider feedback out of Firestore and file it into the expectation
# pages, so a sweep of notes written on a phone becomes something to work
# from at a desk.
#
#   scripts/fetch-feedback.sh
#
# Two collections, because there are two kinds of note. `sessionFeedback` is
# about a session and carries the numbers that were on screen; it is filed
# into that session's page. `appFeatureFeedback` is about a screen — sent from
# the bug button the rest of the app carries — and is printed at the end.
#
# Each note lands under "Feedback from the device" in
# openWaterTests/Expectations/test-N.md, newest first, carrying the numbers
# the app was showing when it was written. Notes for a session with no page
# go into openWaterTests/Expectations/unfiled-feedback.md rather than being
# dropped.
#
# Re-running is safe: the section is rebuilt from Firestore each time, and
# everything you wrote by hand elsewhere in the page is left alone.
#
# Some reports carry a recording the rider chose to attach; the page says so
# and gives its Storage path. That is their personal location data — pull it
# only when you are actually reproducing the problem, and do not keep it.
#
# Reading requires owner credentials — the app can only create. Authenticate
# with:  gcloud auth application-default login
set -euo pipefail
cd "$(dirname "$0")/.."

PROJECT="$(grep -oE 'project = "[^"]+"' openWater/Spots/SpotGuideStore.swift \
           | head -1 | sed -E 's/.*"([^"]+)"/\1/')"
[ -n "$PROJECT" ] || { echo "Could not read the Firebase project id"; exit 1; }

TOKEN="$(gcloud auth print-access-token 2>/dev/null || true)"
if [ -z "$TOKEN" ]; then
  cat <<'MSG'
No gcloud access token.

sessionFeedback is create-only for the app, so reading it needs owner
credentials:

    gcloud auth application-default login
    gcloud config set project <the firebase project>

MSG
  exit 1
fi

echo "==> Fetching sessionFeedback from $PROJECT"
curl -sS -H "Authorization: Bearer $TOKEN" \
  "https://firestore.googleapis.com/v1/projects/$PROJECT/databases/(default)/documents/sessionFeedback?pageSize=300" \
  -o /tmp/openwater-feedback.json

python3 scripts/file-feedback.py /tmp/openwater-feedback.json

# The other half: notes about the app rather than about a session, sent from
# the bug button that every screen carries. They have no session to file
# against, so they are printed rather than written into an expectation page —
# the screen name is the whole index.
echo
echo "==> Fetching appFeatureFeedback from $PROJECT"
curl -sS -H "Authorization: Bearer $TOKEN" \
  "https://firestore.googleapis.com/v1/projects/$PROJECT/databases/(default)/documents/appFeatureFeedback?pageSize=300" \
  -o /tmp/openwater-app-feedback.json

python3 - /tmp/openwater-app-feedback.json <<'PY'
import json, sys

docs = json.load(open(sys.argv[1])).get("documents", [])
def s(fields, key):
    return (fields.get(key) or {}).get("stringValue", "")

rows = sorted(docs, key=lambda d: s(d.get("fields", {}), "createdAt"), reverse=True)
if not rows:
    print("   nothing yet")
for doc in rows:
    f = doc.get("fields", {})
    when = s(f, "createdAt")[:16].replace("T", " ")
    head = f"[{when}] {s(f, 'type'):11} {s(f, 'title')}"
    tail = " · ".join(x for x in (s(f, "version"), s(f, "platform"), s(f, "contact")) if x)
    print(f"\n{head}\n   {tail}")
    for line in s(f, "details").splitlines():
        print(f"   {line}")
PY
