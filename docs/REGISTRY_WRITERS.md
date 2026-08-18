# Rules for automated writers of `windStations`

This document exists because of one night. Between 2026-08-17 and
2026-08-18 an automated writer added roughly 1,460 documents to
`windStations`: copies of NDBC's station index, copies of NWS's station
list, per-provider duplicate rows for sensors that already had documents,
and a bulk sweep of a commercial provider's residential inventory. Every
one of those shapes had been decided against, in writing, hours earlier.
All of them were deleted on 2026-08-18. If you are an automated system
about to write to this collection, these rules are for you, and they are
not advisory.

[STATIONS.md](STATIONS.md) decides where station data lives.
[WIND_STATIONS.md](WIND_STATIONS.md) specifies the schema. Read both
before writing. Where anything conflicts, STATIONS.md wins, then
WIND_STATIONS.md, then this file.

## The three hard rules

**1. Never mirror a government index.** NDBC's `activestations.xml`, the
NWS `/points` station lists, CO-OPS's station inventory — the app reads
all of these directly from NOAA, free, cached on-device, self-healing
when NOAA changes hardware. A copy in Firestore is not redundancy; it is
a second source of truth that rots, costs document reads, and fights the
app's own discovery. A government station may appear in `windStations`
**only** as a document carrying a `gov` block, and only when there is
something to say about it that the free feed cannot: a commercial
cross-link, a curated name, a hide.

**2. One physical instrument, one document.** Before creating any
document, look for an existing one describing the same hardware:

- query by every government id you know for it (`gov.nws`, `gov.ndbc`,
  `gov.coops`), case-insensitively;
- query by provider station id;
- check for any document within 250 m bearing the same display name.

If one exists, **update it** — add your provider entry to `providers`,
add your id to `gov`, improve the name — never create a sibling. Do not
write `canonicalDuplicateOf`; that field is a legacy migration marker,
and any new document carrying it is a bug by definition.

**3. Write only what somebody chose.** A document earns its place by
being at least one of:

- **gov-cross-linked** — a government sensor that a commercial provider
  also lists, recorded so the app can draw one pin with two doors;
- **spot-linked** — the nearest live provider station to a guide spot,
  carrying `spotIds`/`sourceSpotId`;
- **guest-readable** — a provider station whose current wind is visible
  without an account (`guestWindVisible: true`, or `accessTier` of
  `free`/`freemium`);
- **hand-curated** — a human decided this specific station matters and
  said so.

A provider's full inventory satisfies none of these. Discovering 181
stations in an audit is good work; publishing all 181 is not curation,
it is a mirror with extra steps. Record the inventory in the audit's
evidence file, publish the rows that qualify.

## The write checklist

Before every document write, in order:

1. Have I read STATIONS.md and WIND_STATIONS.md in their current form —
   not from memory of a previous run?
2. Is this a government index row with nothing curated to say? → do not
   write.
3. Does a document for this physical instrument already exist (rule 2's
   three lookups)? → update it, never create.
4. Does this row qualify under rule 3? → if not, do not write.
5. Is the `name` something a rider can read — "Fort Point", never
   "102428 — WX", never a provider's internal id?
6. Are all eight required classification fields present
   (WIND_STATIONS.md § Required classification)?
7. Am I about to write more than ~25 documents in one run? → stop and
   ask a human first, whatever the reason.

## Deletion and correction

- Deleting somebody else's curation requires a human decision; deleting
  your own mistakes does not. When in doubt, `status: "hidden"` and ask.
- If you find the collection in a state these rules forbid — mirrors,
  duplicate rows — report it; do not "fix" it by rewriting at scale.
  Bulk corrections are run by humans from reviewed scripts, with a full
  backup taken first.

## Why this is enforced socially and not just technically

The app defends itself: presentation-level dedup collapses duplicate
rows, the registry read fetches only gov-linked documents, and readings
never come from Firestore at all. So a writer that breaks these rules
does not break the app — it just burns money and goodwill: every
uncurated document is read by every U.S. rider's session, and every
cleanup is an evening someone spends deleting your work. The 2026-08-18
curation removed 1,487 documents. Do not make a second one necessary.
