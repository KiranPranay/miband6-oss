# findings-08 — SpO2 parser fix (type 0x25, 65-byte records)

**Date:** 2026-06-26
**Symptom:** the Sleep/Today UI showed impossible SpO2 values — `2`, `25`, `45`,
`60`, `69` % (the metric was removed from the redesign because of this). SpO2 is
physiologically ~94–100 % awake.

## Root cause

The fetch *type* was already correct (`0x25` = `SPO2_NORMAL`), but the **record
layout was never decoded** — the old parser read one byte every **2** bytes:

```dart
const sampleSize = 2;                  // wrong
final spo2Value = _dataBuffer[i * 2];  // reads version byte then stride-2 junk
```

So the very first "reading" was the payload's **version byte** (`0x02` → "2 %")
and the rest were arbitrary bytes of a 65-byte record read at the wrong stride.

## Reference (clean-room): Gadgetbridge

`service/devices/huami/operations/fetch/FetchSpo2NormalOperation.java`
(`HuamiFetchDataType.SPO2_NORMAL(0x25)`), `handleActivityData`:

```java
if ((bytes.length - 1) % 65 != 0) { /* error */ }      // 1 version byte + N*65
final int version = buf.get() & 0xff;                  // must be 2
while (buf.position() < bytes.length) {
    final long timestampSeconds = buf.getInt();        // uint32 LE seconds
    final byte spo2raw = buf.get();
    final boolean autoMeasurement = (spo2raw < 0);     // high bit = auto
    final byte spo2 = (byte)(spo2raw < 0 ? spo2raw + 128 : spo2raw); // = raw & 0x7F
    final byte[] unknown = new byte[60]; buf.get(unknown);
}
```

So a record is **65 bytes**: `[0..3]` uint32-LE Unix-seconds, `[4]` spo2
(`value = raw & 0x7F`, high bit = auto vs manual), `[5..64]` padding.

## Hand-decode of the REAL bytes (evidence)

Captured over adb after clearing the sync cursor to force a full re-fetch
(`SPO2RAW` log added temporarily to `fetchSpo2`):

```
len=131  hex=
02 | 12 2d 3c 6a 62 45 00 00 00 19 00 69 7a 3c 6a e0 68 2d 2a 68 7a 3c 6a 00*… (60B)
   | f9 ed 3d 6a 63 52 00 00 00 19 00 50 3b 3e 6a fd 36 af 2d 4e 3b 3e 6a 00*… (60B)
```

- `(131 − 1) / 65 = 2` records — divides exactly ✓
- byte[0] = `0x02` = **version 2** ✓
- **Record 1** @1: ts = `12 2d 3c 6a` (LE) = `0x6a3c2d12` = 1 782 537 490 s →
  Jun 2026 ✓ ; spo2 byte = `0x62` → `0x62 & 0x7F` = **98 %** ✓
- **Record 2** @66: ts = `f9 ed 3d 6a` = `0x6a3dedf9` = 1 782 611 449 s ✓ ;
  spo2 byte = `0x63` → **99 %** ✓

Both values physiological. The data was always correct; the parser was reading
the wrong bytes.

## Fix

`activity_fetcher.dart::_parseSpo2Data` rewritten to: require byte[0]==2, then
walk 65-byte records, take `data[off+4] & 0x7F` as the value and the per-record
uint32-LE seconds as the timestamp (no longer derived from `_fetchStartTime`).
Implausible values (< 70 %) and zero-timestamp padding records are dropped.

The SpO2 metric is restored in the Sleep screen now that values are real.

## Validation

On hardware (Pixel 9a + MB6): `SPO2 fetch: got 2 readings` → **98 %, 99 %**
(was 14 junk readings). No BLE/auth/fetch-transport code changed — only the
byte interpretation in the parser.
