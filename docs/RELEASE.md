# Before a submission

What to check on a real wrist, and why the simulator cannot.

## Why this page exists

On 2026-09-11 a rider's phone reported, in HealthKit's own words, that the
watch's workout session had never started: a swimming location was set on a
surfing configuration and HealthKit refused it. The failure was caught and
written to `os_log`, and nothing else. Every watch recording the app had ever
made ran without a workout underneath it — no heart rate, no Water Lock, no
entry in Health, the sensors alive only because background GPS runs on its
own. The track looked healthy for an hour. Nobody knew for weeks.

None of that is visible in the simulator, which has no barometer, no
HealthKit workout, no Water Lock and no wrist. So each of the checks below is
something only a person can do, and each one exists because a specific fault
got past everything else.

## The wrist, one session

Install a Release build on a paired watch and phone. Outdoors, open sky.

1. **Open the watch app.** It should come up water-locked within a few
   seconds. watchOS grants Water Lock only during a workout or location
   session; the start screen's GPS warm-up is one, which Apple does not
   document and a wrist confirmed on 2026-09-11. If it does not lock, the
   warm-up did not start — check the GPS line on the start screen.
2. **Tap a sport.** Within a few seconds the Water Lock drop should appear
   beside the clock. This one is guaranteed: it is asked for the moment
   HealthKit reports the workout running, and checked. If it does not appear,
   the workout is not running, and the phone will say why at step 6.
3. **The heart.** A dash and a pulsing heart for the first seconds; then a
   number and a still heart. "Off" after forty seconds is the sensor's
   verdict, and step 6 explains it.
4. **Stand still sixty seconds, then walk.** GPS quality should read
   Excellent on the phone afterwards.
5. **Pause, walk thirty seconds, resume, walk thirty more.** The clock
   should stop and start; the Water Lock drop and the heart should survive
   the resume. Since 2026-09-26 the receiver keeps running through a pause
   and the fixes are kept, so what gets checked at step 7 is that the
   paused walk is *cut*, not lost and not counted.
6. **Stop, and let the watch hand the session over.**
7. **Phone → the session → Analysis.** Read three rows:
   - **Heart rate** — a number. Any orange text under it is the recorder's
     own account of a fault (`Session.recordingIssues`), and it names the
     API that refused. Do not ship with orange text here.
   - **GPS quality** — Excellent.
   - **Airtime → the Barometer line** — "Absolute altimeter: N new values over
     M fixes" with N close to M. The relative barometer will show about a
     third as many; that is expected and it is not used. "No readings" with
     every other channel present means Motion & Fitness: the altimeter needs
     it and the accelerometer does not. The prompt is asked at launch; check
     Settings ▸ Privacy & Security ▸ Motion & Fitness ▸ openWater on the watch.
   - **GPS quality → "Paused once"** with the pause's length, and on the
     Map tab the paused walk drawn as a hole with a cut in Trim behind it.
     Deleting the cut should put the walk back.
8. **Fitness app on the phone.** The session should be there as a workout
   with a map, and the map should stop where the pause began — the paused
   walk is kept out of the Health route too. If the workout is not there,
   the watch's start screen will show an orange notice next time it opens —
   Health failures land there because they happen after the session is
   already saved.
9. **Open the watch app again.** No orange notice on the start screen.

## The phone in a pocket, one session

The phone's live screen stays lit while recording, and its Pause, Resume and
End controls fire on a hold since 2026-09-26, after a wetsuit paused a
rider's session for seventy-one minutes. Record on the phone alone:

1. **Hold Pause.** The fill should run across the control for most of a
   second before it fires; a tap should do nothing. Same for Resume and End.
2. **Pocket it, screen on, and walk.** The proximity sensor should blank
   the display at once. Take it out after a minute: still recording, not
   paused, and the walk on the live map.
3. **End, and open the session.** No "Paused" line under GPS quality.

## What the app now tells you, so you do not have to guess

- A workout that could not start, would not collect, failed mid-run, or never
  reached running — on the session, on the phone.
- A workout that ran and delivered no heart rate anyway — on the session.
- A Health refusal at launch — on the next session.
- A motion channel or altimeter that recorded nothing — on the session.
- A crash log that could not be created, or fixes it could not write — on the
  session.
- A Health save or route failure — on the watch's start screen, since the
  session was already safe on the phone when it happened.

If any of those appear during the checks above, the sentence is the
diagnosis. It is written by the code that failed.

## The rest, unchanged

- `EXCLUDED_SOURCE_FILE_NAMES = "*.openwater"` keeps every recording in
  `openWater/DevSeed/` out of Release. Check it is still set on the Release
  configuration; there are riders' own sessions in that folder.
- The App Privacy answers and the store metadata — see the notes from the
  2.3.7 rejection in `Marketing/AppStore-Metadata.txt`.
- The analysis version. If a detector changed, `SessionSummary.currentVersion`
  must have moved, or existing sessions keep their old numbers.
