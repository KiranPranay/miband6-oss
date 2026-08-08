import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/logger.dart';

/// Developer log view (Settings → Advanced).
///
/// Reads the logger's bounded ring buffer. The buffer notifies at ~4 Hz rather
/// than per line, and `ListView.builder` keeps only the visible rows alive, so
/// a fast burst of BLE traffic no longer drives the frame budget. Newest lines
/// are shown first via `reverse: true` + reversed indexing — that avoids
/// materialising a reversed copy of the buffer on every rebuild.
class DebugConsole extends StatelessWidget {
  const DebugConsole({super.key});

  @override
  Widget build(BuildContext context) {
    final logger = context.watch<BLELogger>();
    final entries = logger.entries;
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text('Debug Console  (${entries.length}/${logger.maxLines})'),
        actions: [
          IconButton(
            icon: Icon(logger.verbose ? Icons.visibility : Icons.visibility_off),
            tooltip: logger.verbose
                ? 'Verbose packet logging ON'
                : 'Verbose packet logging OFF',
            onPressed: () =>
                context.read<BLELogger>().verbose = !logger.verbose,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () => context.read<BLELogger>().clearLogs(),
            tooltip: 'Clear logs',
          ),
        ],
      ),
      body: entries.isEmpty
          ? const Center(child: Text('No log lines yet.'))
          : ListView.builder(
              reverse: true,
              itemCount: entries.length,
              padding: const EdgeInsets.all(8),
              itemBuilder: (context, index) {
                final entry = entries[entries.length - 1 - index];
                final color = switch (entry.level) {
                  LogLevel.error => scheme.error,
                  LogLevel.info => scheme.primary,
                  LogLevel.debug => scheme.onSurfaceVariant,
                };
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    entry.toString(),
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      color: color,
                    ),
                  ),
                );
              },
            ),
    );
  }
}
