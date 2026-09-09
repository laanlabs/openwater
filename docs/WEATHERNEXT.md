# WeatherNext: applied for, and deliberately not shipped

[WeatherNext 3](https://developers.google.com/weathernext/guides/models) is
Google DeepMind's forecast model — a generative mesh transformer rather than a
physics solver, run 24 times a day, published free on Google Cloud. For a wind
app the numbers are the right ones: hourly steps on a 0.1° (≈10 km) surface
grid, 360 hours out from the 00/06/12/18 UTC runs, and a genuine 64-member
ensemble whose spread arrives pre-reduced to six percentiles — mean, p10, p25,
p50, p75, p90.

We have applied for access. We are not putting it in the app, and the reason is
the licence rather than the engineering. This document is the record of both,
so the decision does not have to be rediscovered by whoever next reads the
model spec and gets excited.

## Why it cannot ship

The [GDM Real-Time Weather Forecasting Experimental Data Terms of
Use](https://storage.googleapis.com/weathernext-public/terms-of-use.pdf) (last
modified 3 September 2026) close the door in four steps. They are worth reading
in order, because each one alone looks survivable.

**Every forecast is real-time data.** The terms apply "to any data that relates
to a time less than 1 hour ago *and the future*". Data an hour or more old is
plain CC BY 4.0 and we may do as we like with it. A forecast is, definitionally,
the future — so nothing the app would draw ever reaches the permissive half of
the licence.

**Our three renderings are named in the carve-out.** Section 3 says material
resulting from "the colouring, formatting, compressing, fixed or arbitrary
percentage adjustment, geometric transformation, sub-setting of areas, or custom
combinations of time-steps, parameters or model runs … is considered unmodified
Real-Time Experimental Data." That list is our feature set. The wind wash is
*colouring*. A spot forecast is *sub-setting of areas*. `WindOutlookScreen` is a
*custom combination of time-steps and parameters*. None of the three becomes a
Value Added Service; all three stay raw data.

**Raw data has a named audience, and it is not ours.** A Retrievable Value Added
Service — one whose underlying data can be read back off it, which any screen
printing "18 kn" plainly is — may be shared only "to clearly identified and
known third parties, who may only use the Retrievable VAS for their own internal
purposes, and do not further share them". An anonymous App Store download is not
a clearly identified and known third party. Sharing at all would also oblige us
to ship a copy of the terms, a "Legally Binding Terms of Use" file, and a Google
copyright notice alongside it.

**And the disclaimer says it outright.** Section 6: provided without warranty of
"fitness for a particular purpose and **not intended for consumer use**", and
"intended for experimental modelling only … not intended, validated, or approved
for real world use." A rider deciding whether to drive two hours and launch is
the definition of real-world consumer use. Google's total aggregate liability is
capped at USD 500, the licence is revocable at will, and termination obliges us
to delete the data, tell recipients it is going away, and bars us from
re-applying.

None of that is a grey area to be lawyered. It is a straightforward no, and the
terms themselves point at the remedy: they twice invite anyone wanting "purposes
not currently permitted under these terms" to write to weathernext@google.com.

## The other reason, which would matter even if the licence changed

**WeatherNext has no wind gust variable.** Nineteen surface variables at 0.1°,
and gust is not among them. `gustKn` is on the favourites row, the meter badges,
the map's centre readout, the watch and the tvOS screensaver — a wind-sport app
does not quietly stop printing gusts. There is also no wave, swell, period, tide
or current data, so the marine side stays on Open-Meteo Marine and NOAA whatever
happens. Wind direction is fine: there is no direction band, but u/v components
are published and the app already works in components (`blendDirections`).

So WeatherNext was never going to be a replacement stack. At most it is a second
opinion on wind — and a very good one, because a calibrated p10–p90 fan from 64
members at 10 km is a better answer to `WindOutlookScreen`'s actual question
("do the models agree, and how much should that agreement be worth?") than five
deterministic lines drawn on top of each other.

## What we are doing instead

Using the CC BY 4.0 half. Data an hour or more old is ordinary open data —
commercial use fine, attribution only — and it is enough to answer a question
the app already asks badly: *which forecast model should we trust at this
launch?* `OpenMeteo.modelRecord(near:)` and `ModelSteadiness` already score
models against buoy observations. WeatherNext becomes another contestant in that
scoring, run offline on archive data, and what ships to riders is the **finding**
— guide metadata saying ECMWF is the steadiest model at Napeague — never Google's
data.

Planned, once access lands:

1. Subscribe the BigQuery Analytics Hub listing into the Cloud project the app
   already owns for Firestore. `bq query --dry_run` every query first; it reports
   exact bytes for free, and the 0.1° table is large enough that guessing is
   expensive. The precomputed statistics bucket
   (`gs://weathernext3_statistics_spatial/`) has Requester Pays **off** and is
   free to read, which may make BigQuery unnecessary.
2. A harness beside `scripts/audit-wind-stations.py`: for ~50 launches with a
   buoy within 30 km, pull 90 days of WeatherNext p10/p50/p90 for 10 m wind, the
   same hours from all five Open-Meteo models, and the buoy truth from
   `DataBuoyCenter.windHistory`.
3. Score in `ModelSteadiness`'s own units. Per-spot bias and MAE at 24, 48, 72
   and 120 hours — and, for the ensemble claim, whether p10–p90 actually brackets
   the observed wind 80% of the time. A fan that does not is decoration.
4. Ship the verdict as guide metadata, so `WindOutlookScreen` orders its models
   by measured skill rather than by name.

Budget: under $50, one-off. The data is free, the statistics bucket is free to
read, and BigQuery's first 1 TiB each month is free. Earth Engine is ruled out on
sight — its commercial plans start at $2,000/month.

## How "not shipped" is enforced

By structure, not by intention. `scripts/` and `docs/` are not in any of the
Xcode file-system-synchronized groups — the project syncs `openWater`,
`openWater Watch App`, `openWater TV`, `openWaterTests` and `openWaterUITests`,
and nothing else — so work that lives in `scripts/` cannot reach a build at all.

`scripts/check-weathernext-containment.py` enforces that, and
`scripts/testflight.sh` runs it before it archives anything. It is a hard rule
rather than a build flag: **no WeatherNext in any compiled directory**, not
behind `#if DEBUG`, not behind a feature switch, not commented out. A runtime
flag still ships the code and still ships the bucket URL, and "it was disabled"
is not a defence anyone wants to write down.

If Google grants permission in writing, the doc and the guard get updated
together, in the same commit as the first line of shipping code.

## The application

Submitted to the [WeatherNext data request
form](https://docs.google.com/forms/d/e/1FAIpQLSeCf1JY8G78UDWzbm0ly9kJxfSjUIJT5WyMR_HiNqCm-IHIBg/viewform)
— one form, any Google account, no paid Cloud contract required, approval
typically 5–7 business days. Access arrives across Cloud Storage, BigQuery and
Earth Engine at once.

Answers given, recorded here so a follow-up says the same things:

- **Google account:** jason@laan.com (the account that owns the Firestore
  project the app already uses).
- **Organisation:** Laan Labs.
- **Intended use:** Offline forecast-model verification. Scoring WeatherNext's
  10 m wind against ECMWF, GFS, ICON, GEM and NBM at coastal launch sites, with
  NDBC buoy observations as truth, to determine which model to trust where. Not
  redistributed; the published output is a per-site model ranking, not forecast
  data.
- **Surface:** BigQuery, and the Cloud Storage statistics Zarr.

And sent alongside it, to weathernext@google.com — because the answer is the
only thing that can change the section above, and it costs nothing to ask:

> Subject: Consumer app use of real-time WeatherNext forecasts
>
> Hello,
>
> I build openWater, a wind-sports app for iPhone, Apple Watch and Apple TV. It
> shows forecast wind at launch sites for windsurfers, wing foilers and kite
> surfers, and it is on the App Store.
>
> I have applied for WeatherNext access to do offline model verification, which
> I believe the CC BY 4.0 terms on historical data cover comfortably. My question
> is about the real-time terms.
>
> Reading them, I take it that displaying live WeatherNext forecasts to my users
> is not permitted: a forecast is always "the future" and so always Real-Time
> Experimental Data; Section 3 treats colouring a field, sub-setting an area to a
> point, and combining time-steps into a chart as unmodified data rather than a
> Value Added Service; and Section 6 says the data is not intended for consumer
> use. On that reading I am not shipping it, and the app continues to use
> Open-Meteo.
>
> Is that reading right? And if there is a path — a different licence, a
> commercial agreement, or the Google Maps Platform Weather API being the
> intended answer for this case — I would rather be told than guess.
>
> Thanks,
> Jason Laan, Laan Labs

## Sources

- [Quick start: accessing WeatherNext forecasts](https://developers.google.com/weathernext/guides/access-forecast)
- [WeatherNext 3 model spec](https://developers.google.com/weathernext/guides/models)
- [WeatherNext on BigQuery](https://developers.google.com/weathernext/guides/bigquery) ·
  [on Cloud Storage](https://developers.google.com/weathernext/guides/gcs) ·
  [Earth Engine 0.1° band list](https://developers.google.com/earth-engine/datasets/catalog/projects_gcp-public-data-weathernext_assets_weathernext_3_0_0_0p1deg)
- [Real-time terms of use (PDF, 3 September 2026)](https://storage.googleapis.com/weathernext-public/terms-of-use.pdf) ·
  [disclaimers and licensing](https://developers.google.com/weathernext/guides/disclaimers)
- Full assessment, with the cost analysis for every path:
  <https://claude.ai/code/artifact/8e22fe62-dc4d-40e2-91a8-471218879433>

Forecast data referenced here is © 2024–6 Google LLC.

## Unrelated, and more urgent

The app calls Open-Meteo's public endpoints directly from the device with no
key. That free tier is **non-commercial use only**, and openWater has been on
the App Store since 19 August 2026. This has nothing to do with WeatherNext and
is the more pressing licence question of the two: Open-Meteo's commercial plans
are about $29/month for 1M calls and $99/month for 5M, both with the multi-point
batching the wind wash depends on.
