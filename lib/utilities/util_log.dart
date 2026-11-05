/// Parses one `[ISO-timestamp] [LEVEL] message` engine log line (see
/// lib/data/logging/app_logger.dart) for display in the logs screen.
class ParsedLogLine {
  const ParsedLogLine({
    required this.level,
    required this.message,
    this.timestamp,
  });

  final String level;
  final String message;
  final DateTime? timestamp;

  static final _pattern = RegExp(r'^\[([^\]]+)\]\s\[([A-Z]+)\]\s(.*)$');

  factory ParsedLogLine.parse(String line) {
    final match = _pattern.firstMatch(line);
    if (match == null) return ParsedLogLine(level: 'INFO', message: line);
    return ParsedLogLine(
      level: match.group(2) ?? 'INFO',
      message: match.group(3) ?? line,
      timestamp: DateTime.tryParse(match.group(1) ?? ''),
    );
  }
}
