import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/control/engine_control_repository.dart';
import '../data/models/auto_category.dart';
import '../data/models/grid_bot.dart';
import '../data/models/trade_start_event.dart';
import '../data/providers/app_providers.dart';
import '../utilities/util_responsive.dart';

/// Persistent navigation shell for the four main sections. Uses a
/// [NavigationRail] on wide (desktop) windows and a [NavigationBar] on
/// narrow (mobile) ones, wrapping go_router's [StatefulShellRoute] so each
/// tab keeps its own navigation/scroll state.
///
/// Also the single place that watches [EngineStatus.internetHealthy] and
/// surfaces a "no internet" dialog with a Retry button (2026-09-11, per the
/// user - traced a "long time to connect to chart" complaint to internet
/// outages that were only ever logged to engine.log, never shown in the
/// GUI). Living here (rather than duplicated per-screen) means it fires
/// exactly once regardless of which tab is active, since go_router's
/// IndexedStack keeps every branch mounted.
class ReuseNavShell extends ConsumerStatefulWidget {
  const ReuseNavShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  static const _destinations = [
    (
      icon: Icons.dashboard_outlined,
      selectedIcon: Icons.dashboard,
      label: 'Dashboard',
    ),
    (icon: Icons.tune_outlined, selectedIcon: Icons.tune, label: 'Controls'),
    (
      icon: Icons.history_outlined,
      selectedIcon: Icons.history,
      label: 'History',
    ),
    (icon: Icons.article_outlined, selectedIcon: Icons.article, label: 'Logs'),
    (
      icon: Icons.settings_outlined,
      selectedIcon: Icons.settings,
      label: 'Settings',
    ),
  ];

  @override
  ConsumerState<ReuseNavShell> createState() => _ReuseNavShellState();
}

class _ReuseNavShellState extends ConsumerState<ReuseNavShell> {
  bool _internetDialogOpen = false;

  // Voice-alert feature (2026-09-17, per the user: "start long XRP" /
  // "close XRP"). Baselines set on the first emission from each stream (no
  // backlog replay on launch - only events that happen while the GUI is
  // actually open should ever speak), then anything strictly newer speaks.
  DateTime? _lastStartTs;
  DateTime? _lastStopTs;

  // Push notification (2026-09-17, per the user: "along with voice, push
  // notification appears in system... same as the voice") - fires
  // alongside the voice alert, same phrase, same mute toggle. The
  // notification also carries a timestamp (per the user's explicit
  // follow-up) - the voice itself stays exactly as spoken, unchanged.
  // Per the user (2026-09-19): speak the interval too - "3 m start long
  // LTC" / "3 m close LTC" instead of leaving it out entirely. A trailing
  // space separates digit from letter (e.g. "3m" -> "3 m", "1H" -> "1 H")
  // since Piper reads the label more clearly spoken as two tokens than as
  // one run-together word.
  String _spokenCategory(AutoCategory? category) {
    if (category == null) return '';
    final spaced = category.label.replaceAllMapped(
      RegExp(r'(\d)([A-Za-z])'),
      (m) => '${m[1]} ${m[2]}',
    );
    return '$spaced ';
  }

  // Serializes every `speak` call (2026-09-20, per the user: "i feel
  // there is echo in the sound") - chaining onto this same Future means a
  // second phrase's synthesis+playback only ever starts once the previous
  // one has genuinely finished (see SoundService.speak's own doc comment
  // for the full root cause: two events landing close together, e.g. the
  // paired close+start announcement, used to launch two overlapping
  // `aplay` processes). Never awaited by the caller - a burst of several
  // events queues up and plays back-to-back instead of overlapping,
  // rather than blocking the UI.
  Future<void> _speechQueue = Future<void>.value();

  void _speak(String muteKey, String text) {
    if (ref.read(soundMuteProvider)[muteKey] == true) return;
    final sound = ref.read(soundServiceProvider);
    _speechQueue = _speechQueue.then((_) => sound.speak(text));
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp = '${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
    sound.notify('$text — $stamp');
  }

  Future<void> _showInternetDownDialog() async {
    if (_internetDialogOpen || !mounted) return;
    _internetDialogOpen = true;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.wifi_off),
        title: const Text('No internet connection'),
        content: const Text(
          'The app can\'t reach the internet right now, so it can\'t '
          'connect to the chart or Pionex. This usually clears up on its '
          'own once the connection is back - tap Retry to check again '
          'immediately.',
        ),
        actions: [
          FilledButton(
            onPressed: () {
              ref.read(controlRepositoryProvider).refreshRedList();
              Navigator.of(context).pop();
            },
            child: const Text('Retry'),
          ),
        ],
      ),
    );
    _internetDialogOpen = false;
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<StatusReport>>(statusReportProvider, (
      previous,
      next,
    ) {
      final prevHealthy =
          previous?.value?.engineStatus.internetHealthy ?? true;
      final status = next.value;
      if (status == null) return;
      if (!status.engineStatus.internetHealthy && prevHealthy) {
        _showInternetDownDialog();
      } else if (status.engineStatus.internetHealthy &&
          !prevHealthy &&
          _internetDialogOpen &&
          mounted) {
        Navigator.of(context, rootNavigator: true).maybePop();
      }
    });

    ref.listen<AsyncValue<List<TradeStartEvent>>>(tradeStartEventsProvider, (
      previous,
      next,
    ) {
      final events = next.value;
      if (events == null) return;
      final starts = events.where((e) => e.kind == TradeTriggerKind.start);
      final stops = events.where((e) => e.kind == TradeTriggerKind.stop);
      if (_lastStartTs == null || _lastStopTs == null) {
        // Baseline only - no backlog replay on launch (only events that
        // happen while the GUI is actually open should ever speak).
        _lastStartTs ??= starts.isEmpty
            ? DateTime.now()
            : starts.map((e) => e.ts).reduce((a, b) => a.isAfter(b) ? a : b);
        _lastStopTs ??= stops.isEmpty
            ? DateTime.now()
            : stops.map((e) => e.ts).reduce((a, b) => a.isAfter(b) ? a : b);
        return;
      }
      final freshStarts =
          starts.where((e) => e.ts.isAfter(_lastStartTs!)).toList()
            ..sort((a, b) => a.ts.compareTo(b.ts));
      for (final e in freshStarts) {
        final prefix = _spokenCategory(e.category);
        _speak(
          'start',
          '${prefix}start ${e.direction.wireValue} ${e.base.toUpperCase()}',
        );
      }
      if (freshStarts.isNotEmpty) _lastStartTs = freshStarts.last.ts;

      final freshStops =
          stops.where((e) => e.ts.isAfter(_lastStopTs!)).toList()
            ..sort((a, b) => a.ts.compareTo(b.ts));
      for (final e in freshStops) {
        final prefix = _spokenCategory(e.category);
        _speak('stop', '${prefix}close ${e.base.toUpperCase()}');
      }
      if (freshStops.isNotEmpty) _lastStopTs = freshStops.last.ts;
    });

    if (UtilResponsive.isCompact(context)) {
      return Scaffold(
        body: widget.navigationShell,
        bottomNavigationBar: NavigationBar(
          selectedIndex: widget.navigationShell.currentIndex,
          onDestinationSelected: (i) => widget.navigationShell.goBranch(
            i,
            initialLocation: i == widget.navigationShell.currentIndex,
          ),
          destinations: [
            for (final d in ReuseNavShell._destinations)
              NavigationDestination(
                icon: Icon(d.icon),
                selectedIcon: Icon(d.selectedIcon),
                label: d.label,
              ),
          ],
        ),
      );
    }

    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: widget.navigationShell.currentIndex,
            onDestinationSelected: (i) => widget.navigationShell.goBranch(
              i,
              initialLocation: i == widget.navigationShell.currentIndex,
            ),
            labelType: NavigationRailLabelType.all,
            leading: Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 16),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.asset(
                  'assets/icons/icon_64.png',
                  width: 32,
                  height: 32,
                ),
              ),
            ),
            destinations: [
              for (final d in ReuseNavShell._destinations)
                NavigationRailDestination(
                  icon: Icon(d.icon),
                  selectedIcon: Icon(d.selectedIcon),
                  label: Text(d.label),
                ),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: widget.navigationShell),
        ],
      ),
    );
  }
}
