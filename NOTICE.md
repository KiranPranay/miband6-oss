# Third-party notices and attributions

This project is licensed under the **GNU Affero General Public License v3.0 or
later** (see [`LICENSE`](LICENSE)). That is not a preference — it is required,
because parts of this codebase are derived from AGPL-licensed work, as set out
below.

---

## Gadgetbridge — AGPL-3.0-or-later

<https://codeberg.org/Freeyourgadget/Gadgetbridge>
Copyright © Andreas Shimokawa and the Gadgetbridge contributors.

Gadgetbridge is the reference this project's protocol work is built on. Two
kinds of debt, kept distinct because they are legally different:

### Direct translations (derivative works)

These files are line-by-line ports of Gadgetbridge source into Dart. They carry
the original copyright notice in their headers and are covered by the AGPL:

| File | Ported from |
|---|---|
| `lib/core/ecdh_b163.dart` | `ECDH_B163.java` |
| `lib/core/huami2021_chunked.dart` | `Huami2021ChunkedEncoder.java`, `Huami2021ChunkedDecoder.java`, `CheckSums.getCRC32` |

Gadgetbridge's `ECDH_B163.java` is itself a port of
[tiny-ECDH-c](https://github.com/kokke/tiny-ECDH-c) by Kokke, released into the
public domain (Unlicense).

### Protocol facts learned from their source

Byte layouts, opcodes, characteristic UUIDs and command sequences throughout
`lib/core/` were determined by reading Gadgetbridge, and every one of them is
cited class-and-line in
[`docs/reverse-engineering/protocol-mb6.md`](docs/reverse-engineering/protocol-mb6.md).

Facts about how a third-party device behaves are not themselves copyrightable,
and the implementations here are independently written. The attribution is given
because it is owed regardless: without Gadgetbridge this project would not
exist.

`lib/core/huami2021_auth.dart` is an independent implementation of the
handshake that `InitOperation2021` performs, written from their source.

---

## Decompiled applications — reference only, never redistributed

Two proprietary Android applications were decompiled locally and read as
cross-references while reconstructing the protocol:

- **Notify & Fitness for Amazfit** (`com.mc.miband1`)
- **Mi Fit / Zepp Life** (`com.xiaomi.hm.health`)

**No code, resources or assets from either application appear in this
repository**, and neither is redistributed here. They are cited in the findings
documents (as `NOTIFY` and `MIFIT`) purely as evidence for statements about
byte layouts — for example, that the Mi Band 6 needs a keep-alive ping on the
heart-rate control characteristic, which Gadgetbridge does not send but Notify
does.

The decompilation directories (`ref_apks/`, `tools/`, `gadgetbridge/`) are
listed in [`.gitignore`](.gitignore) and must never be committed. If you are
contributing, keep them out.

Whether decompiling an application you have lawfully installed is permitted
depends on your jurisdiction. In the EU, Directive 2009/24/EC Article 6 allows
decompilation for interoperability, which is exactly what this is. Check your
own position before doing the same.

---

## Published research

The health analysis is built on published methods rather than invented ones.
Each is cited at the point of use in the source; collected here for convenience:

| Work | Used for |
|---|---|
| Cole RJ, Kripke DF, Gruen W, Mullaney DJ, Gillin JC. *Automatic sleep/wake identification from wrist activity.* Sleep. 1992;15(5):461-9. | Actigraphy sleep/wake scoring |
| Chinoy ED, Cuellar JA, Huwa KE, et al. *Performance of seven consumer sleep-tracking devices compared with polysomnography.* PLOS ONE. 2020;15(9):e0238464. | The Huami-validated wake threshold this app scores against |
| Phillips AJK, Clerx WM, O'Brien CS, et al. *Irregular sleep/wake patterns are associated with poorer academic performance.* Sci Rep. 2017;7:3216. | Sleep Regularity Index |
| Windred DP, Burns AC, Lane JM, et al. *Sleep regularity is a stronger predictor of mortality risk than sleep duration.* Sleep. 2023;47(1):zsad253. | SRI population reference values |
| Hirshkowitz M, Whiton K, Albert SM, et al. *National Sleep Foundation's sleep time duration recommendations.* Sleep Health. 2015;1(1):40-43. | Sleep duration norms |
| Speed C, Arneil T, Harle R, et al. *Measure by measure: Resting heart rate across the 24-hour cycle.* PLOS Digital Health. 2023;2(4):e0000236. | Circadian baselines for resting HR and the stress estimate |
| Task Force of the ESC and NASPE. *Heart rate variability: standards of measurement.* Eur Heart J. 1996;17(3):354-81. | HRV definitions (implemented, not fed — see below) |
| Shaffer F, Ginsberg JP. *An overview of heart rate variability metrics and norms.* Front Public Health. 2017;5:258. | HRV reference ranges |
| Baevsky RM, Berseneva AP. *Methodical recommendations: use of Kardivar system.* 2008. | Stress index formulation |

The HRV metrics are implemented and unit-tested but receive no data: this
firmware sends no RR intervals, so nothing HRV-derived is displayed. See
[`findings-20`](docs/reverse-engineering/findings-20.md).

---

## Flutter packages

Runtime dependencies are declared in [`pubspec.yaml`](pubspec.yaml) with their
own licences, resolved by `flutter pub get`. Notable ones:

| Package | Licence | Used for |
|---|---|---|
| `flutter_blue_plus` | BSD-3-Clause | BLE transport |
| `pointycastle` | MIT | AES-ECB for the legacy handshake |
| `fl_chart` | MIT | Charts |
| `flutter_foreground_task` | MIT | Keeping the connection alive in the background |
| `flutter_secure_storage` | BSD-3-Clause | Auth-key storage |
| `google_fonts` | Apache-2.0 | Manrope typeface (SIL OFL 1.1) |

Run `flutter pub deps` for the full resolved tree.

---

## Trademarks

*Xiaomi*, *Mi Band*, *Mi Fit* and *Zepp* are trademarks of their respective
owners. This project is not affiliated with, endorsed by, or connected to
Xiaomi, Huami/Zepp Health, or the authors of any application named above.
