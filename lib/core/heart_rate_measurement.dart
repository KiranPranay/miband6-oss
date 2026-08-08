/// A decoded BLE Heart Rate Measurement (`0x2A37`) notification.
///
/// Layout, per the Bluetooth SIG Heart Rate Service specification:
///
/// ```
/// byte 0 : flags
///          bit 0  : 0 = HR is uint8, 1 = HR is uint16 LE
///          bits1-2: sensor contact  (0b00/0b01 unsupported,
///                                    0b10 not detected, 0b11 detected)
///          bit 3  : energy expended present (uint16 LE, kJ)
///          bit 4  : RR intervals present (N × uint16 LE, units of 1/1024 s)
/// byte 1+: heart rate, then the optional fields in the order above
/// ```
///
/// ## Why this exists
///
/// Both our HR listeners previously did `data[1] & 0xFF` after a length check,
/// ignoring the flags byte entirely. That is *accidentally* correct for this
/// firmware — all 34 captured notifications are exactly 2 bytes with flags
/// `0x00` — but it fails silently in two ways: a uint16 heart rate would be
/// read as its low byte (looking plausible), and RR intervals would never be
/// noticed. Gadgetbridge has the same blind spot on the Huami path
/// (`HuamiSupport.handleHeartrate` hard-guards `length == 2 && value[0] == 0`),
/// even though it ships a correct parser in `HeartRateProfile` for other
/// devices.
///
/// RR intervals are what real HRV needs, so noticing them is the difference
/// between "we cannot compute HRV" and "we can". See `StressAnalyzer`.
class HeartRateMeasurement {
  const HeartRateMeasurement({
    required this.bpm,
    required this.isUint16,
    required this.sensorContact,
    required this.energyExpended,
    required this.rrIntervalsMs,
  });

  final int bpm;

  /// True when the heart rate was transmitted as uint16 (flags bit 0).
  final bool isUint16;

  /// `null` when the device does not report contact status.
  final bool? sensorContact;

  /// Kilojoules, when flags bit 3 is set.
  final int? energyExpended;

  /// Beat-to-beat intervals in **milliseconds**, converted from the spec's
  /// 1/1024-second units. Empty when flags bit 4 is clear.
  final List<double> rrIntervalsMs;

  /// Parses one notification, or returns null if it is malformed.
  ///
  /// Truncated packets are rejected rather than partially decoded — a short
  /// read here would produce a confident wrong number.
  static HeartRateMeasurement? parse(List<int> data) {
    if (data.length < 2) return null;

    final flags = data[0] & 0xFF;
    final isUint16 = (flags & 0x01) != 0;
    final contactSupported = (flags & 0x04) != 0;
    final contactDetected = (flags & 0x02) != 0;
    final hasEnergy = (flags & 0x08) != 0;
    final hasRr = (flags & 0x10) != 0;

    var offset = 1;
    int bpm;
    if (isUint16) {
      if (data.length < offset + 2) return null;
      bpm = (data[offset] & 0xFF) | ((data[offset + 1] & 0xFF) << 8);
      offset += 2;
    } else {
      bpm = data[offset] & 0xFF;
      offset += 1;
    }

    int? energy;
    if (hasEnergy) {
      if (data.length < offset + 2) return null;
      energy = (data[offset] & 0xFF) | ((data[offset + 1] & 0xFF) << 8);
      offset += 2;
    }

    final rr = <double>[];
    if (hasRr) {
      while (offset + 1 < data.length) {
        final raw = (data[offset] & 0xFF) | ((data[offset + 1] & 0xFF) << 8);
        // Spec unit is 1/1024 s.
        rr.add(raw * 1000.0 / 1024.0);
        offset += 2;
      }
    }

    return HeartRateMeasurement(
      bpm: bpm,
      isUint16: isUint16,
      sensorContact: contactSupported ? contactDetected : null,
      energyExpended: energy,
      rrIntervalsMs: rr,
    );
  }
}
