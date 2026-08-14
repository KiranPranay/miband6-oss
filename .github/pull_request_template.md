## What this changes

<!-- And why. If it fixes a subtle bug, the evidence is worth more than the
     description — numbers, bytes, the log line. -->

## Checklist

- [ ] `flutter analyze` → No issues found
- [ ] `flutter test` → all green
- [ ] Comments explain **why**, not what

### If it writes bytes to the band

- [ ] The layout is in `protocol-mb6.md` **with a citation**, added *before* the
      first hardware write
- [ ] There is a gate in `hardware_test_session.dart`
- [ ] Added to `pending-hardware-verification.md`, or marked verified with the
      log line that proves it
- [ ] If it touches authentication: a hardware run showing
      `2021 SIGN-KEY AUTHENTICATION SUCCESS`

### If it changes what a number means

- [ ] No metric is shown that the sensor cannot support
- [ ] Missing data is **absent**, not zero and not interpolated
- [ ] If historical values shift, the PR says so — users will notice
- [ ] A findings document records the evidence, including anything refuted

### Provenance

- [ ] No decompiled proprietary code, APKs, or vendored upstream checkouts
- [ ] Any code ported from Gadgetbridge carries its original copyright header
      and is listed in `NOTICE.md`
- [ ] I agree to license my contribution under **AGPL-3.0-or-later**
