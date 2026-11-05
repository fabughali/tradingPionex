import 'package:flutter/material.dart';

import '../data/models/auto_category.dart';
import '../utilities/util_string.dart';

/// Auto bots card's "waiting" row (2026-09-10, per the user) - shown below
/// the running-bots table, same wrapped-chip layout as the Available
/// pairs/Red list display elsewhere in this app. A single "Waiting:" label
/// followed by one chip per base the app is responsible for that doesn't
/// have a real running bot right now, so the next auto-checkup pass will
/// attempt to (re)open it - format "SYMBOL/CATEGORY/AMOUNT", where AMOUNT
/// is the pending recycled investment when one exists, else the pair's
/// configured default. Corrected 2026-09-10 twice: the word "waiting"
/// used to repeat on every chip (moved to a single label in front), then
/// the surrounding parentheses were dropped per the user's follow-up.
class WaitingBasesView extends StatelessWidget {
  const WaitingBasesView({
    super.key,
    required this.waiting,
    this.waitingEngineCurrentBase = '',
    this.waitingEngineIdleReason = '',
    this.onStop,
    this.onIgnite,
    this.isIgniting,
    this.anyIgniteInFlight = false,
  });

  final List<({String base, AutoCategory category, double investment})>
  waiting;

  /// Per-row "stop" toggle (2026-09-15, per the user) - called with the
  /// exact base/category of the chip that was stopped. Null hides the
  /// stop control entirely (e.g. a read-only preview context).
  final void Function(String base, AutoCategory category)? onStop;

  /// Per-row "thunder" toggle (2026-09-15, per the user: "add thunder
  /// icon... once user click on it, it is started on spot and not
  /// waiting start signal to occur") - called with the exact base/category
  /// of the chip ignited. Null hides the control entirely.
  final void Function(String base, AutoCategory category)? onIgnite;

  /// Whether THIS chip's ignite request is still in flight (2026-09-15,
  /// per the user: "once user click on thunder and it is still
  /// processing, loading indicator will appear instead of thunder") -
  /// checked per-chip so only the one actually clicked shows the spinner,
  /// every other chip's thunder stays put and tappable.
  final bool Function(String base, AutoCategory category)? isIgniting;

  /// True while ANY chip's ignite request is in flight (2026-09-15, per
  /// the user: "once user click on thunder and it start processing...
  /// all other thunders disabled with grey color") - the shared
  /// TradingView chart can only do one thing at a time, so a second
  /// ignite firing mid-request would just queue behind the first one
  /// anyway; greying every other thunder out makes that wait visible
  /// instead of looking like a dead button.
  final bool anyIgniteInFlight;

  /// "SYMBOL/CATEGORY" the waiting engine is retrying right now, empty
  /// whenever it isn't running (2026-09-11, per the user: "add status below
  /// waiting to show user what is going on now once waiting engine is
  /// running") - straight off `EngineStatus.waitingEngineCurrentBase`, the
  /// engine's own live view of its per-pair loop, same pattern the
  /// Checkup track's own "Checking $symbol..." line already uses.
  final String waitingEngineCurrentBase;

  /// Why it's idle right now, straight off `EngineStatus
  /// .waitingEngineIdleReason` - see that field's own doc for the full set
  /// of values. Only meaningful when [waitingEngineCurrentBase] is empty.
  final String waitingEngineIdleReason;

  @override
  Widget build(BuildContext context) {
    if (waiting.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 6,
            runSpacing: 6,
            children: [
              Text('Waiting:', style: Theme.of(context).textTheme.bodyMedium),
              for (final w in waiting)
                _WaitingChip(
                  label:
                      '${w.base}USDT/${w.category.label}/'
                      '${UtilString.usd(w.investment)}',
                  onStop: onStop == null ? null : () => onStop!(w.base, w.category),
                  onIgnite: onIgnite == null
                      ? null
                      : () => onIgnite!(w.base, w.category),
                  igniting: isIgniting?.call(w.base, w.category) ?? false,
                  thunderDisabled:
                      anyIgniteInFlight &&
                      !(isIgniting?.call(w.base, w.category) ?? false),
                ),
            ],
          ),
          // Per the user (2026-09-11): "i want waiting status ALWAYS visible
          // if waiting list is visible" - always shows a line whenever
          // there's a waiting list at all, switching between the two states
          // rather than disappearing in between.
          //
          // Wording fixed 2026-09-12, per the user ("nope i dont like this
          // .. i want status to reflect actual"): a single fixed idle
          // message went stale the moment a SECOND, different idle reason
          // (the one-attempt-per-cycle throttle, same day) existed - a base
          // already attempted this cycle is not the same situation as the
          // chart genuinely being busy elsewhere, and showing the same
          // wording for both was actively misleading again, the same
          // mistake the 2026-09-11 fix (see git history) was written to
          // correct for the PREVIOUS pair of reasons. Now branches on the
          // real reason from `EngineStatus.waitingEngineIdleReason`
          // instead of guessing there's only ever one possible cause.
          // Wording updated again same day, per the user ("i dont want
          // any waiting pairs"): the per-cycle throttle behind 'attempted'
          // was replaced by a short per-base cooldown - the label and text
          // changed to 'cooldown' to match.
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              waitingEngineCurrentBase.isNotEmpty
                  ? 'Waiting engine: checking $waitingEngineCurrentBase...'
                  : switch (waitingEngineIdleReason) {
                      'cooldown' =>
                        'Waiting engine: idle - every remaining base is on '
                            'its short retry cooldown; retrying resumes '
                            'within seconds.',
                      'chart_busy' =>
                        'Waiting engine: idle - the regular checkup pass has '
                            'the chart right now; retrying continues the '
                            'moment it finishes.',
                      'new_cycle' =>
                        'Waiting engine: idle - the real 3m checkup pass is '
                            'due and running now; retrying resumes right '
                            'after.',
                      'empty' => 'Waiting engine: idle - waiting list is empty.',
                      _ => 'Waiting engine: idle.',
                    },
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

/// Same pill styling `ReuseChip`'s warning tone uses, but with the stop
/// control built INSIDE the pill itself - a small circular X, separated
/// from the label by a gap (2026-09-15, per the user: "if you want to keep
/// x then make it inside each card and inside a circle with a space in
/// between", after an earlier version placed the X outside the chip).
class _WaitingChip extends StatelessWidget {
  const _WaitingChip({
    required this.label,
    this.onStop,
    this.onIgnite,
    this.igniting = false,
    this.thunderDisabled = false,
  });

  final String label;
  final VoidCallback? onStop;
  final VoidCallback? onIgnite;

  /// Shows a small spinner in place of the bolt icon while true, and
  /// disables the tap so a second click can't fire mid-request
  /// (2026-09-15, per the user).
  final bool igniting;

  /// True when SOME OTHER chip is igniting right now (2026-09-15, per the
  /// user) - greys this chip's thunder out and disables its tap, since
  /// only one ignite can actually use the shared chart at a time. Never
  /// true at the same time as [igniting] (that one shows the spinner
  /// instead).
  final bool thunderDisabled;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final foreground = scheme.onTertiaryContainer;
    return Container(
      padding: EdgeInsets.only(
        left: onIgnite == null ? 10 : 4,
        right: onStop == null ? 10 : 4,
        top: 4,
        bottom: 4,
      ),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (onIgnite != null) ...[
            Tooltip(
              message: igniting
                  ? 'Igniting...'
                  : thunderDisabled
                        ? 'Another pair is igniting - wait for it to finish.'
                        : 'Ignite now - open this base immediately, without '
                              'waiting for the normal signal confirmation.',
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: (igniting || thunderDisabled) ? null : onIgnite,
                child: Container(
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: foreground.withValues(
                      alpha: thunderDisabled ? 0.06 : 0.16,
                    ),
                  ),
                  child: igniting
                      ? SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.6,
                            color: foreground,
                          ),
                        )
                      : Icon(
                          Icons.bolt,
                          size: 12,
                          color: thunderDisabled
                              ? foreground.withValues(alpha: 0.35)
                              : foreground,
                        ),
                ),
              ),
            ),
            const SizedBox(width: 6),
          ],
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: foreground,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (onStop != null) ...[
            const SizedBox(width: 6),
            Tooltip(
              message: 'Stop this base - remove it from auto-management, '
                  'no more retry attempts.',
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: onStop,
                child: Container(
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: foreground.withValues(alpha: 0.16),
                  ),
                  child: Icon(Icons.close, size: 11, color: foreground),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
