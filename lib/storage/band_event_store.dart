import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../core/device_events.dart';

/// Persists the band's own sleep and wear boundaries (`fee0/0x0010`
/// FELL_ASLEEP / WOKE_UP / START_NONWEAR — protocol-mb6.md §12).
///
/// Kept apart from [ActivityStore] on purpose: these are rare, tiny, and come
/// from a different source (the band's live determination, not its minute log).
/// A separate small file means they can never be lost to a fault in the large
/// store's save path, and the large store's format needs no migration.
///
/// They are recorded as evidence, not yet used to drive session detection —
/// P12.3 in the ledger is the probe that decides whether they should be.
class BandEventStore {
  static const _file = 'band_events.json';

  /// Cap on stored events. A few per day; a year is a few thousand.
  static const int maxEvents = 5000;

  final List<BandEvent> _events = [];
  List<BandEvent> get events => List.unmodifiable(_events);

  bool _loaded = false;

  Future<File> _path() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_file');
  }

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final f = await _path();
      if (!await f.exists()) return;
      final raw = jsonDecode(await f.readAsString());
      if (raw is List) {
        _events
          ..clear()
          ..addAll(raw.map((e) => BandEvent.fromJson(e as Map<String, dynamic>)));
      }
    } catch (_) {
      // A corrupt events file is not worth a crash; it is evidence, not data
      // the UI depends on. Start empty.
      _events.clear();
    }
  }

  Future<void> add(BandEvent e) async {
    await load();
    _events.add(e);
    if (_events.length > maxEvents) {
      _events.removeRange(0, _events.length - maxEvents);
    }
    try {
      final f = await _path();
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(jsonEncode(_events.map((x) => x.toJson()).toList()));
      await tmp.rename(f.path);
    } catch (_) {}
  }

  /// Events since [since], newest last.
  Future<List<BandEvent>> since(DateTime since) async {
    await load();
    return _events.where((e) => !e.at.isBefore(since)).toList();
  }
}
