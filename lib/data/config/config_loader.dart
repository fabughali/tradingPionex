import 'dart:convert';

import '../../core/core_storage.dart';
import '../models/app_config.dart';

/// Loads config.json, writing the built-in default (mode: confirm, one
/// BTCUSDT $100 pair) the first time so a fresh install always has a valid,
/// inspectable file to edit rather than silently running on in-memory
/// defaults nobody can see.
AppConfig loadOrInitConfig(CoreStorage storage) {
  storage.ensureRuntimeDirs();
  final json = storage.readJsonObject(storage.configFile);
  if (json != null) return AppConfig.fromJson(json);
  const initial = AppConfig.defaultConfig;
  storage.writeString(
    storage.configFile,
    '${const JsonEncoder.withIndent('  ').convert(initial.toJson())}\n',
  );
  return initial;
}
