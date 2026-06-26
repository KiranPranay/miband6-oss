import 'dart:async';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'activity_sample.dart';
import 'logger.dart';

/// Implements the Huami activity data fetch protocol for Mi Band 6.
class ActivityFetcher {
  final BLELogger _logger;
  final BluetoothDevice _device;

  BluetoothCharacteristic? _activityControl; // fee0/0x0004
  BluetoothCharacteristic? _activityData; // fee0/0x0005

  StreamSubscription<List<int>>? _controlSub;
  StreamSubscription<List<int>>? _dataSub;

  final List<int> _dataBuffer = [];
  DateTime? _fetchStartTime;
  // Mi Band 6 stores one 8-byte activity sample per minute (fixed device
  // property — see protocol-mb6.md §5). Older bands use 4 bytes.
  static const int _sampleSize = 8;
  Completer<List<int>>? _fetchCompleter;
  Timer? _fetchTimeout;

  ActivityFetcher(this._logger, this._device);

  /// Read-only view of the most recently accumulated raw fetch payload.
  /// Used by the hardware test session to hex-dump bytes when parsing fails.
  List<int> get lastRawBuffer => List.unmodifiable(_dataBuffer);

  Future<bool> init() async {
    try {
      final services = await _device.discoverServices();
      for (final svc in services) {
        if (svc.uuid.str.toLowerCase().contains('fee0')) {
          _logger.d("FEE0 Service found. Characteristics:");
          for (final c in svc.characteristics) {
            final cu = c.uuid.str.toLowerCase();
            _logger.d("  - $cu");
            if (cu.contains('0004')) _activityControl = c;
            if (cu.contains('0005')) _activityData = c;
          }
        }
      }

      if (_activityControl == null || _activityData == null) {
        _logger.e('ActivityFetcher: missing characteristics');
        return false;
      }

      _logger.d('ActivityFetcher: Control properties: '
          'read=${_activityControl!.properties.read}, '
          'write=${_activityControl!.properties.write}, '
          'writeWithoutResponse=${_activityControl!.properties.writeWithoutResponse}, '
          'notify=${_activityControl!.properties.notify}, '
          'indicate=${_activityControl!.properties.indicate}');

      _logger.d('ActivityFetcher: Data properties: '
          'read=${_activityData!.properties.read}, '
          'write=${_activityData!.properties.write}, '
          'writeWithoutResponse=${_activityData!.properties.writeWithoutResponse}, '
          'notify=${_activityData!.properties.notify}, '
          'indicate=${_activityData!.properties.indicate}');

      // Do NOT enable `_activityData` notify yet. Gadgetbridge enables it later!
      _dataSub = _activityData!.onValueReceived.listen(_onDataReceived);

      await _activityControl!.setNotifyValue(true);
      _controlSub =
          _activityControl!.onValueReceived.listen(_onControlReceived);

      // NEW: Send preliminary ACK to clear any stuck state on the band
      _logger.i('ActivityFetcher: sending cleanup ACK (0x03)');
      await _sendAck();

      _logger.i('ActivityFetcher: initialized OK');
      return true;
    } catch (e) {
      _logger.e('ActivityFetcher init failed: $e');
      return false;
    }
  }

  Future<List<int>> fetchRawData(int type, DateTime since) async {
    if (_activityControl == null) return [];

    _dataBuffer.clear();
    _fetchStartTime = since;
    _fetchCompleter = Completer<List<int>>();

    _logger.i('ActivityFetcher: requesting data type 0x${type.toRadixString(16)} since $since');
    final cmd = _buildFetchCommand(type, since);
    _logger.d('ActivityFetcher: cmd = ${_hexStr(cmd)}');

    try {
      await _activityControl!.write(cmd, withoutResponse: true);
      _logger.i('ActivityFetcher: fetch command sent');
    } catch (e) {
      _logger.e('ActivityFetcher: fetch command failed: $e');
      return [];
    }

    _fetchTimeout = Timer(const Duration(seconds: 60), () {
      if (!_fetchCompleter!.isCompleted) {
        _logger.e('ActivityFetcher: fetch timed out (60s) waiting for response');
        _sendAck();
        _fetchCompleter!.complete([]);
      }
    });

    return _fetchCompleter!.future;
  }

  Future<List<ActivitySample>> fetchActivityData(DateTime since) async {
    await fetchRawData(0x01, since);
    return _parseActivityData();
  }

  Future<List<Spo2Reading>> fetchSpo2(DateTime since) async {
    // SpO2 fetch type = 0x25 (37). NOTE: 0x12 is STRESS and 0x0D is SLEEP —
    // both were wrong in the earlier code (see findings-02.md §3). The SpO2
    // sample layout is still UNVERIFIED; this is a best-effort parse.
    await fetchRawData(0x25, since);
    return _parseSpo2Data();
  }

  /// HR history is embedded in the activity stream (byte 3 of each 8-byte
  /// sample), so we fetch activity data and extract HR from it.
  Future<List<HeartRateReading>> fetchHeartRateHistory(DateTime since) async {
    final samples = await fetchActivityData(since);
    return heartRatesFromSamples(samples);
  }

  List<int> _buildFetchCommand(int type, DateTime since) {
    // Format confirmed from decompiled Notify app (x5/e.java):
    // [0x01, type, year_lo, year_hi, month(1-based), day, hour, minute, 0x00, tzQuarters]
    final year = since.year;
    final month = since.month;      // 1-based, Calendar.get(2)+1
    final day = since.day;          // day of month
    final hour = since.hour;
    final minute = since.minute;
    final tzQuarters = since.timeZoneOffset.inMinutes ~/ 15;

    return [
      0x01,
      type,
      year & 0xFF,
      (year >> 8) & 0xFF,
      month,
      day,
      hour,
      minute,
      0x00,
      tzQuarters & 0xFF,
    ];
  }

  void _onControlReceived(List<int> data) async {
    if (data.isEmpty) return;
    _logger.i('ActivityFetcher CTRL notified: ${_hexStr(data)}');

    if (data.length >= 3 && data[0] == 0x10) {
      if (data[1] == 0x01) {
        // Step 1 response: Metadata
        if (data[2] == 0x01) {
          _logger.i('ActivityFetcher: band accepted fetch request');
          if (data.length >= 7) {
            // Bytes 3,4,5,6 are the expected data length (number of bytes to receive)
            int expectedLen =
                data[3] | (data[4] << 8) | (data[5] << 16) | (data[6] << 24);
            _logger.i('ActivityFetcher: expected data length = $expectedLen');
            if (expectedLen == 0) {
              _logger.i('ActivityFetcher: No new data to fetch.');
              await _sendAck();
              _completeFetch();
              return;
            }

            // NOTE: bytes[7..14] are the echoed start timestamp, NOT a sample
            // size. The sample size is a fixed device property (8 for Mi Band 6
            // — see protocol-mb6.md §5 / findings-02.md §3), not transmitted.
          }
          await _sendFetchDataCommand();
        } else {
          _logger.e(
              'ActivityFetcher: band rejected date (code 0x${data[2].toRadixString(16)})');
          await _sendAck();
          if (!_fetchCompleter!.isCompleted) _fetchCompleter!.complete([]);
        }
      } else if (data[1] == 0x02 || data[1] == 0x0B) {
        // Step 2 response: Transfer finished or Chunks done (0x0B)
        if (data[2] == 0x01) {
          _logger.i('ActivityFetcher: band says fetch complete (0x${data[1].toRadixString(16)})');
          await _sendAck();
          _completeFetch();
        } else {
          _logger.e(
              'ActivityFetcher: fetch ended with error 0x${data[2].toRadixString(16)}');
          _completeFetch();
        }
      }
    } else {
      _logger.d('ActivityFetcher CTRL unexpected: ${_hexStr(data)}');
    }
  }

  Future<void> _sendFetchDataCommand() async {
    try {
      _logger.i(
          'ActivityFetcher: enabling data notify (0x0005) before fetch stream');
      await _activityData!.setNotifyValue(true);

      _logger.i('ActivityFetcher: sending 0x02 (fetch data)');
      await _activityControl!.write([0x02], withoutResponse: true);
    } catch (e) {
      _logger.e('ActivityFetcher: failed to send 0x02: $e');
    }
  }

  Future<void> _sendAck() async {
    if (_activityControl == null) return;
    try {
      _logger.i('ActivityFetcher: sending 0x03 (ACK)');
      await _activityControl!.write([0x03], withoutResponse: true);
    } catch (e) {
      _logger.e('ActivityFetcher: failed to send ACK: $e');
    }
  }

  /*
  Future<void> _sendStopCommand() async {
    if (_activityControl == null) return;
    try {
      await _activityControl!.write([0x03], withoutResponse: true);
    } catch (_) {}
  }
  */

  void _onDataReceived(List<int> data) {
    if (data.isEmpty) return;
    _fetchTimeout?.cancel();
    _fetchTimeout = Timer(const Duration(seconds: 15), () {
      if (_fetchCompleter != null && !_fetchCompleter!.isCompleted) {
        _logger.e('ActivityFetcher: data stream stalled');
        _completeFetch();
      }
    });

    final payload = data.sublist(1);
    _dataBuffer.addAll(payload);
    _logger
        .d('ActivityFetcher DATA: ${data.length} bytes (counter: ${data[0]})');
    // NOTE: No per-chunk ACK is sent here.
    // The band streams all data continuously after the single [0x02] trigger.
    // Sending [0x02] per packet would confuse the protocol and restart the transfer.
  }

  void _completeFetch() {
    _fetchTimeout?.cancel();
    _logger.i('ActivityFetcher: fetch complete, buffer size: ${_dataBuffer.length}');
    if (_fetchCompleter != null && !_fetchCompleter!.isCompleted) {
      _fetchCompleter!.complete(List.from(_dataBuffer));
    }
  }

  List<ActivitySample> _parseActivityData() =>
      parseActivitySamples(_dataBuffer, _fetchStartTime);

  /// Parse the Mi Band 6 8-byte activity samples (one per minute):
  ///   [0] category/kind  [1] intensity  [2] steps (single byte 0-255)
  ///   [3] heart rate     [4] unknown1   [5] sleep  [6] deepSleep  [7] remSleep
  /// (Byte-for-byte identical to Gadgetbridge createExtendedSample() and Notify
  ///  helper b.s(); see protocol-mb6.md §5 / findings-02.md §3.)
  ///
  /// Static + pure so it can be unit-tested without a BLE connection.
  static List<ActivitySample> parseActivitySamples(
    List<int> data,
    DateTime? startTime, {
    int sampleSize = _sampleSize,
  }) {
    if (data.isEmpty || startTime == null) return [];
    final sampleCount = data.length ~/ sampleSize;
    final samples = <ActivitySample>[];

    for (var i = 0; i < sampleCount; i++) {
      final offset = i * sampleSize;
      if (offset + sampleSize > data.length) break;
      final ts = startTime.add(Duration(minutes: i));

      final hr = data[offset + 3];
      samples.add(ActivitySample(
        timestamp: ts,
        category: data[offset],
        intensity: data[offset + 1],
        steps: data[offset + 2], // per-minute step count (0-255)
        // Treat 0/255 as "no reading" (cleanHeartValue in the reference apps).
        heartRate: (hr >= 7 && hr <= 249) ? hr : 0,
        sleep: data[offset + 5],
        deepSleep: data[offset + 6],
        remSleep: data[offset + 7],
      ));
    }
    return samples;
  }

  /// Heart-rate history is embedded in the per-minute activity samples (byte 3),
  /// so we derive it from the activity fetch rather than a separate request.
  static List<HeartRateReading> heartRatesFromSamples(
      List<ActivitySample> samples) {
    return samples
        .where((s) => s.heartRate >= 7 && s.heartRate <= 249)
        .map((s) => HeartRateReading(timestamp: s.timestamp, value: s.heartRate))
        .toList();
  }

  /// Parse SpO2 history (fetch type 0x25 = SPO2_NORMAL).
  ///
  /// Layout (Gadgetbridge FetchSpo2NormalOperation, verified by hand-decoding
  /// real bytes — see findings-08.md):
  ///   [0]  version byte (== 2)
  ///   then N records of 65 bytes each:
  ///     [rec+0..3]  uint32 LE Unix-seconds timestamp
  ///     [rec+4]     spo2 — value = byte & 0x7F (high bit = auto measurement)
  ///     [rec+5..64] padding
  List<Spo2Reading> _parseSpo2Data() {
    final data = _dataBuffer;
    const recSize = 65;
    if (data.length < 1 + recSize) return [];
    if (data[0] != 2) {
      _logger.e('SpO2: unexpected version ${data[0]} (len ${data.length})');
      return [];
    }

    final readings = <Spo2Reading>[];
    for (var off = 1; off + recSize <= data.length; off += recSize) {
      final tsSec = data[off] |
          (data[off + 1] << 8) |
          (data[off + 2] << 16) |
          (data[off + 3] << 24);
      final value = data[off + 4] & 0x7F; // strip the auto/manual flag bit
      // Drop padding records (zero timestamp) and non-physiological values.
      if (tsSec > 0 && value >= 70 && value <= 100) {
        readings.add(Spo2Reading(
          timestamp: DateTime.fromMillisecondsSinceEpoch(tsSec * 1000),
          value: value,
        ));
      }
    }
    return readings;
  }

  void dispose() {
    _controlSub?.cancel();
    _dataSub?.cancel();
    _fetchTimeout?.cancel();
  }

  String _hexStr(List<int> data) =>
      data.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
}
