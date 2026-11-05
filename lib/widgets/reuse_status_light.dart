import 'package:flutter/material.dart';

import '../core/core_theme.dart';
import '../data/control/engine_control_repository.dart';
import '../data/models/engine_status.dart';

enum StatusLightColor { green, red, orange, grey }

typedef StatusEvaluation = ({
  StatusLightColor color,
  String label,
  bool blinking,
  bool urgent,
});

/// Power and Auto each get their own, deliberately separate, health
/// evaluation - painted as the short status word next to each switch.
/// Splitting these out (rather than one combined light) is what fixed the
/// original problem: a single evaluation rooted in status.paused made
/// Power's own indicator flip red/wrong the moment Auto went off, even
/// though Power itself hadn't changed.
class ReuseStatusLight {
  ReuseStatusLight._();

  /// Power: is the engine PROCESS alive and are its two external
  /// connections (Pionex, TradingView) healthy - nothing here reads
  /// status.paused/killSwitch, that's Auto's concern entirely.
  ///
  /// - red "Off" = the process isn't running
  /// - grey "Starting…" = process just came up, no status.json yet / stale
  /// - orange "Pionex" = Pionex not configured or unreachable
  /// - orange "TradingView" = TradingView/CDP not connected
  /// - blinking green "Checking"/fast "Waiting" = a cycle is actively
  ///   running (fast+"Waiting" specifically means stuck on the per-pair
  ///   indicator wait-ladder - the one place a single bad pair can stall
  ///   everything)
  /// - green "On" = process alive, both integrations healthy, idle
  static StatusEvaluation evaluatePower(
    StatusReport status, {
    required bool isEngineProcessAlive,
    required bool pionexConfigured,
  }) {
    if (!isEngineProcessAlive) {
      return (
        color: StatusLightColor.red,
        label: 'Off',
        blinking: false,
        urgent: false,
      );
    }
    final engine = status.engineStatus;
    if (engine.state == EngineRunState.stopped && engine.updatedAtMs == 0 ||
        engine.isStale(const Duration(seconds: 30))) {
      return (
        color: StatusLightColor.grey,
        label: 'Starting…',
        blinking: false,
        urgent: false,
      );
    }
    if (!pionexConfigured || !engine.pionexHealthy) {
      return (
        color: StatusLightColor.orange,
        label: 'Pionex',
        blinking: false,
        urgent: false,
      );
    }
    if (!engine.cdpHealthy) {
      return (
        color: StatusLightColor.orange,
        label: 'TradingView',
        blinking: false,
        urgent: false,
      );
    }
    // Per the user (2026-09-10): `engine.busy`/`engine.urgent` are ALSO
    // true for the entire duration of a full Red-list sweep's per-pair
    // loop (Check Now/Start) - routine pair-by-pair scanning, not a
    // connectivity event. Without excluding that, Power kept blinking
    // "Checking"/"Waiting" (the per-pair indicator wait-ladder) for the
    // whole sweep, which is Check Now's business, not Power's - the exact
    // same "power toggle showing pair check status" complaint this
    // already got fixed for once (the detail TEXT line), just showing up
    // again via the LABEL/blink instead. `checkupPairTotal > 0` is the
    // same signal already trusted elsewhere (e.g. the Check Now button's
    // own loading state) to mean "a sweep's pair loop is genuinely
    // running right now" - excluding it here means Power still correctly
    // blinks for its own real connectivity phases (connecting, syncing
    // bot memory, checking balance, verifying indicators at Power-on)
    // since those all happen before checkupPairTotal is set, but goes
    // quiet the moment the sweep starts iterating pairs.
    if (engine.busy && engine.checkupPairTotal == 0) {
      return (
        color: StatusLightColor.green,
        label: engine.urgent ? 'Waiting' : 'Checking',
        blinking: true,
        urgent: engine.urgent,
      );
    }
    return (
      color: StatusLightColor.green,
      label: 'On',
      blinking: false,
      urgent: false,
    );
  }

  /// Auto: purely the pause/activity state - deliberately no Pionex/
  /// TradingView branches here, those belong to Power only.
  ///
  /// - red "Off" = paused (or kill-switched)
  /// - grey "Not running" = NOT paused (so the switch itself shows on) but
  ///   the engine process is dead - e.g. a hard crash/force-restart, which
  ///   leaves PAUSE untouched but also leaves status.json as a stale
  ///   snapshot from before the crash. Without this check, a status.json
  ///   that happened to say `busy: true` at the exact moment of the crash
  ///   would report "blinking, actively checking" forever, since nothing is
  ///   left running to ever write a fresher value - confirmed live after a
  ///   force-restart with Auto left on.
  /// - blinking green "Checking" = yours (just pressed a category switch)
  ///   or one of the 3 category engines' own checkups is actively running
  /// - green "On" = resumed, idle
  ///
  /// Deliberately reads each category's OWN `busy` flag
  /// (`engineStatus.autoCategories`), never `engineStatus.busy` - that
  /// field belongs to the full Checkup track (Check Now/Start, whole Red
  /// list), a separate process. Reading it here was a real bug (found
  /// 2026-09-09): it made Auto blink in lockstep with Power every time a
  /// full sweep ran, even though Auto itself had nothing running.
  static StatusEvaluation evaluateAuto(
    StatusReport status, {
    required bool isEngineProcessAlive,
    bool actionInProgress = false,
  }) {
    if (status.paused || status.killSwitchPresent) {
      return (
        color: StatusLightColor.red,
        label: 'Off',
        blinking: false,
        urgent: false,
      );
    }
    if (!isEngineProcessAlive) {
      return (
        color: StatusLightColor.grey,
        label: 'Not running',
        blinking: false,
        urgent: false,
      );
    }
    if (actionInProgress) {
      return (
        color: StatusLightColor.green,
        label: 'Checking',
        blinking: true,
        urgent: false,
      );
    }
    final anyCategoryBusy = status.engineStatus.autoCategories.values.any(
      (c) => c.busy,
    );
    if (anyCategoryBusy) {
      return (
        color: StatusLightColor.green,
        label: 'Checking',
        blinking: true,
        urgent: false,
      );
    }
    return (
      color: StatusLightColor.green,
      label: 'On',
      blinking: false,
      urgent: false,
    );
  }

  static Color colorFor(BuildContext context, StatusLightColor color) {
    final trading = context.tradingColors;
    final scheme = Theme.of(context).colorScheme;
    return switch (color) {
      StatusLightColor.green => trading.profit,
      StatusLightColor.red => trading.loss,
      StatusLightColor.orange => trading.warning,
      StatusLightColor.grey => scheme.onSurfaceVariant,
    };
  }
}
