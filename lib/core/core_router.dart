import 'package:go_router/go_router.dart';

import '../data/models/bot_history_entry.dart';
import '../data/models/grid_bot.dart';
import '../data/models/preview_grid_pair.dart';
import '../screens/app/bot_details_screen.dart';
import '../screens/app/bot_history_details_screen.dart';
import '../screens/app/controls_screen.dart';
import '../screens/app/dashboard_screen.dart';
import '../screens/app/history_screen.dart';
import '../screens/app/logs_screen.dart';
import '../screens/app/pair_preview_details_screen.dart';
import '../screens/app/pnl_pair_summary_screen.dart';
import '../screens/app/settings_screen.dart';
import '../screens/app/splash_screen.dart';
import '../widgets/reuse_nav_shell.dart';

/// go_router setup: a splash route, then a persistent nav shell
/// (dashboard/controls/logs/settings) built with StatefulShellRoute so each
/// tab keeps its own scroll/state when switching.
class CoreRouter {
  CoreRouter._();

  static final router = GoRouter(
    initialLocation: '/splash',
    routes: [
      GoRoute(
        path: '/splash',
        builder: (context, state) => const SplashScreen(),
      ),
      GoRoute(
        path: '/bot-details',
        builder: (context, state) =>
            BotDetailsScreen(bot: state.extra! as GridBot),
      ),
      GoRoute(
        path: '/pair-preview',
        builder: (context, state) =>
            PairPreviewDetailsScreen(preview: state.extra! as PreviewGridPair),
      ),
      GoRoute(
        path: '/history-details',
        builder: (context, state) =>
            BotHistoryDetailsScreen(entry: state.extra! as BotHistoryEntry),
      ),
      GoRoute(
        path: '/pnl-summary',
        builder: (context, state) => const PnlPairSummaryScreen(),
      ),
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            ReuseNavShell(navigationShell: navigationShell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/dashboard',
                builder: (context, state) => const DashboardScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/controls',
                builder: (context, state) => const ControlsScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/history',
                builder: (context, state) => const HistoryScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/logs',
                builder: (context, state) => const LogsScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/settings',
                builder: (context, state) => const SettingsScreen(),
              ),
            ],
          ),
        ],
      ),
    ],
  );
}
