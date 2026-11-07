/// Whether the candle that OPENED at [barTimeSec] (epoch seconds - the
/// timestamp every signal/event in this app carries) has fully closed by
/// [now], i.e. `now >= barTime + period`.
///
/// 2026-10-20, per the user (option 3 of three offered): the "immediate"
/// checks (the Power-on / technique-switch reverse-check sweep, and a
/// pair's un-pause check) skip the "survive one full extra candle" wait -
/// found live: on Power-on at 19:54 the sweep flipped a confirmed BTC SHORT
/// (SELL_OPEN1, 17:00 candle) to LONG on a ZIGZAG_BUY that was only on the
/// 20:00 candle, 2 minutes old and still forming, costing -$0.34 - while
/// the engine's own audit 20s earlier was correctly deferring that same
/// signal. Now an immediate check acts straight away only on a signal from
/// an already-closed candle; one on the still-forming candle goes through
/// the normal extra-candle wait like any other cycle.
bool isCandleClosed(int barTimeSec, Duration period, DateTime now) =>
    now.toUtc().millisecondsSinceEpoch >= (barTimeSec + period.inSeconds) * 1000;
