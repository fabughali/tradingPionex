import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/core_layout.dart';
import '../../core/core_spacing.dart';
import '../../core/core_theme.dart';
import '../../core/core_typography.dart';
import '../../data/logging/app_logger.dart';
import '../../data/providers/app_providers.dart';
import '../../l10n/app_localizations.dart';
import '../../utilities/util_log.dart';
import '../../widgets/reuse_empty_state.dart';
import '../../widgets/reuse_error.dart';
import '../../widgets/reuse_loading_indicator.dart';

class LogsScreen extends ConsumerWidget {
  const LogsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final linesAsync = ref.watch(logTailProvider);
    final trading = context.tradingColors;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.logsTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: l10n.logsRefresh,
            onPressed: () => ref.invalidate(logTailProvider),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: l10n.logsClear,
            onPressed: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: Text(l10n.logsClear),
                  content: const Text(
                    'Delete all engine log files? This cannot be undone.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: Text(l10n.logsClear),
                    ),
                  ],
                ),
              );
              if (ok == true) {
                AppLogger(ref.read(storageProvider)).clearLogs();
                ref.invalidate(logTailProvider);
              }
            },
          ),
        ],
      ),
      body: linesAsync.when(
        loading: () => const ReuseLoadingIndicator(),
        error: (err, st) => ReuseError(message: '$err'),
        data: (lines) {
          if (lines.isEmpty)
            return ReuseEmptyState(
              message: l10n.logsEmpty,
              icon: Icons.article_outlined,
            );
          return LayoutBuilder(
            builder: (context, constraints) => ListView.builder(
              padding: CoreLayout.edgeMargin(constraints, base: CoreSpacing.sm),
              reverse: true,
              itemCount: lines.length,
              itemBuilder: (context, index) {
                final line = lines[lines.length - 1 - index];
                final parsed = ParsedLogLine.parse(line);
                final color = switch (parsed.level) {
                  'CRITICAL' => trading.loss,
                  'ERROR' => trading.loss,
                  _ => Theme.of(context).colorScheme.onSurface,
                };
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 1),
                  child: SelectableText(
                    line,
                    style: CoreTypography.logLine(textTheme, color: color),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}
