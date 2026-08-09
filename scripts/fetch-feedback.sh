#!/usr/bin/env bash
#
# Pull session feedback out of Firestore and file it into the expectation
# pages, so a sweep of notes written on a phone becomes something to work
# from at a desk.
#
#   scripts/fetch-feedback.sh
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
