/// Events the band pushes on `fee0/0x0010` — protocol-mb6.md §12.
///
/// Pure Dart so the parser is testable without BLE. Codes are Gadgetbridge's
/// `HuamiDeviceEvent` constants verbatim (`HuamiDeviceEvent.java:20-38`); the
/// payload offsets follow `HuamiSupport.handleDeviceEvent`
/// (`HuamiSupport.java:1705-1842`).
enum BandEventKind {
  fellAsleep(0x01),
  wokeUp(0x02),
  stepsGoalReached(0x03),
  buttonPressed(0x04),
  startNonWear(0x06),
  callReject(0x07),
  findPhoneStart(0x08),
  callIgnore(0x09),
  alarmToggled(0x0a),
  buttonPressedLong(0x0b),
  tick30Min(0x0e),
  findPhoneStop(0x0f),
  silentMode(0x10),
  workoutStarting(0x14),
  mtuRequest(0x16),
  alarmChanged(0x1a),
  musicControl(0xfe),
  unknown(-1);

  const BandEventKind(this.code);
  final int code;

  static BandEventKind fromCode(int c) =>
      BandEventKind.values.firstWhere((k) => k.code == c,
          orElse: () => BandEventKind.unknown);
}

/// One decoded event. [raw] is kept so unknown codes can be logged in full.
class BandEvent {
  const BandEvent({
    required this.kind,
    required this.at,
    required this.raw,
    this.silentModeOn,
    this.musicAction,
    this.mtu,
    this.workoutType,
    this.workoutNeedsGps,
  });

  final BandEventKind kind;
  final DateTime at;
  final List<int> raw;

  /// `value[1] == 1` for [BandEventKind.silentMode].
  final bool? silentModeOn;

  /// `value[1]` for [BandEventKind.musicControl]: 0 play, 1 pause, 3 next,
  /// 4 previous, 5 volume up, 6 volume down, 0xe0 app opened, 0xe1 closed.
  final int? musicAction;

  /// uint16 LE at `value[1..2]` for [BandEventKind.mtuRequest].
  final int? mtu;

  /// `value[3]` for [BandEventKind.workoutStarting]; `value[2] == 1` = GPS.
  final int? workoutType;
  final bool? workoutNeedsGps;

  /// Parses one notification. Returns null for an empty frame.
  static BandEvent? parse(List<int> v, {DateTime? at}) {
    if (v.isEmpty) return null;
    final kind = BandEventKind.fromCode(v[0]);
    final now = at ?? DateTime.now();
    switch (kind) {
      case BandEventKind.silentMode:
        return BandEvent(
            kind: kind, at: now, raw: v, silentModeOn: v.length > 1 && v[1] == 1);
      case BandEventKind.musicControl:
        return BandEvent(
            kind: kind, at: now, raw: v, musicAction: v.length > 1 ? v[1] : null);
      case BandEventKind.mtuRequest:
        return BandEvent(
            kind: kind,
            at: now,
            raw: v,
            mtu: v.length > 2 ? ((v[2] & 0xff) << 8) | (v[1] & 0xff) : null);
      case BandEventKind.workoutStarting:
        return BandEvent(
            kind: kind,
            at: now,
            raw: v,
            workoutType: v.length > 3 ? v[3] : null,
            workoutNeedsGps: v.length > 2 ? v[2] == 1 : null);
      default:
        return BandEvent(kind: kind, at: now, raw: v);
    }
  }

  /// True for the events worth persisting as sleep/wear boundaries.
  bool get isSleepBoundary =>
      kind == BandEventKind.fellAsleep ||
      kind == BandEventKind.wokeUp ||
      kind == BandEventKind.startNonWear;

  Map<String, dynamic> toJson() => {
        't': at.millisecondsSinceEpoch,
        'k': kind.code,
      };

  static BandEvent fromJson(Map<String, dynamic> j) => BandEvent(
        kind: BandEventKind.fromCode(j['k'] as int),
        at: DateTime.fromMillisecondsSinceEpoch(j['t'] as int),
        raw: const [],
      );
}

/// The find-phone acknowledgement the band expects on `0x0003` when it starts
/// a find-phone request (GB `AmazfitBipService.COMMAND_ACK_FIND_PHONE_IN_PROGRESS`,
/// `ENDPOINT_DISPLAY = 0x06`). protocol-mb6.md §12.2.
const List<int> kFindPhoneAck = [0x06, 0x14, 0x00, 0x00];
