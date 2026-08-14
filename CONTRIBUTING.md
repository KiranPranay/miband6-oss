# Contributing

Thanks for considering it. This project has a few rules that are stricter than
usual, and they exist because the app shows people health numbers about
themselves. Please read the first section even if you skip the rest.

---

## The two rules

### 1. Every byte written to the band needs a cited source

Before any new command reaches the hardware, its layout goes in
[`docs/reverse-engineering/protocol-mb6.md`](docs/reverse-engineering/protocol-mb6.md)
with a citation:

- `GB` — Gadgetbridge, as `ClassName.java:line`
- `NOTIFY` — decompiled `com.mc.miband1`, as `class/method`
- `MIFIT` — decompiled `com.xiaomi.hm.health`
- `CAPTURE` — bytes observed from the band, with the log line

"It works on my band" is not a source. Write it down first, then write the code.

### 2. Never claim a measurement you cannot make

If the sensor data is not there, **omit the metric and say why**. Do not
interpolate a gap, do not substitute a population average for a personal one,
do not round a missing value to zero.

Concretely, all of these have been enforced in review:

- A gap in wear is **not** a calm hour, and not a zero on the chart — the hour
  is absent.
- A day with too little data is **not** reported, rather than reported short.
- A perfectly flat heart rate yields **no** stress score, not a middling one:
  there is no personal range to position within.
- A number the band could not have measured — because it was off the wrist —
  does not get shown because the band's own flag happened to say otherwise.

If you find yourself writing `?? 0`, stop and think about whether absent and
zero really mean the same thing to the person reading the screen.

### And when they conflict: hardware wins

If the documentation says one thing and the band does another, the band is
right and the document is wrong. Fix the document, record the disagreement in a
findings file, and add a probe to
[`pending-hardware-verification.md`](docs/reverse-engineering/pending-hardware-verification.md).

Do **not** quietly code around it.

---

## Getting set up

```bash
flutter pub get
flutter analyze     # must print: No issues found!
flutter test        # must be all green
```

If Gradle fails with a confusing cache or metadata error, check `JAVA_HOME`
points at a JDK with a compiler, not a JRE:

```bash
export JAVA_HOME=/opt/android-studio/jbr
```

### Working without a band

Plenty is testable without hardware. The analysis engines are pure Dart with no
Flutter imports, so they run under `dart run` and are directly unit-testable.
The offline harness replays a real capture through the shipping code:

```bash
dart run tool/analyze_capture.dart activity.json hr.json
```

If you have a capture, that is the fastest way to find a real bug. Several of
the findings documents started exactly there.

---

## What good looks like

### Tests

- **Unit tests prove internal consistency. They do not prove correctness.**
  A round-trip test that encodes with the same layout it decodes will pass no
  matter what the hardware actually sends — there are such tests in this repo,
  and they are labelled as specifications rather than evidence.
- Prefer a test built from **captured bytes** over a synthetic fixture.
- Write the **negative** test. "This buffer must produce zero readings" has
  caught more here than any happy path.
- If you fix a bug, add the test that would have caught it, and say in the test
  *why* — a `reason:` string that explains the failure mode is worth more than
  the assertion.

### Comments

Explain **why**, not what. The valuable comments in this codebase record the
thing that is not obvious from the code: which approach was tried and rejected,
what the data actually said, which assumption turned out to be false. If you
remove a workaround, say what made it unnecessary.

### Commits

Explain the reasoning, not just the change. If you fixed something subtle,
include the evidence — the numbers, the byte sequence, the log line. Several
commits here are long because the *why* was long; that is fine.

---

## Findings documents

Substantial investigations get their own `docs/reverse-engineering/findings-NN.md`.

- **Never overwrite an existing one.** They are a record of what was known when,
  including the parts that turned out to be wrong. Add a new file.
- Include what you **refuted**, not only what you found. A dead end you do not
  write down is a dead end someone re-walks.
- Say plainly what is still unresolved, and add the probe that would resolve it.
- Index the new file in
  [`00-INDEX.md`](docs/reverse-engineering/00-INDEX.md).

---

## Touching the band

Anything that writes to the hardware needs a gate in
`lib/core/hardware_test_session.dart` and an entry in the verification ledger.

Be careful with the authentication path. The sign-key (ECDH) handshake in
`huami2021_auth.dart` and `ecdh_b163.dart` is the one thing that must never
break — if it regresses, the app cannot talk to the band at all, and it is
tedious to debug. Changes there need a hardware run showing
`2021 SIGN-KEY AUTHENTICATION SUCCESS` before merge.

---

## Licence and provenance

This project is **AGPL-3.0-or-later**, because parts of it are direct
translations of AGPL Gadgetbridge code. By contributing you agree your
contribution ships under the same licence.

**Do not commit:**

- Decompiled application code or resources from Notify, Mi Fit/Zepp, or any
  other proprietary app. Cite them in findings; never paste them in.
- APKs, decompiler output, or the Gadgetbridge checkout. `ref_apks/`, `tools/`
  and `gadgetbridge/` are in `.gitignore` — keep it that way.
- Your auth key, MAC address, or raw health data. Findings quote the specific
  bytes that matter, not whole captures.

If you port code from Gadgetbridge (rather than just reading it for facts), it
must carry the original copyright header and be listed in
[NOTICE.md](NOTICE.md).

---

## Reporting bugs

Please include:

- Band model and firmware version
- Android version and phone
- What you expected and what happened
- The relevant log lines — the app's Debug Console (Profile → Debug Console)
  or `adb logcat | grep flutter`

For anything protocol-related, the raw bytes are worth more than a description
of them.

**Do not paste your auth key or MAC address into an issue.**

Security issues go to [SECURITY.md](SECURITY.md), not the public tracker.

---

## Code of conduct

Participation is covered by [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
