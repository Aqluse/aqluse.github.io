import 'package:flutter/material.dart';

import 'generated/localization/localizations.dart';
import 'navigation/app_route_information_parser.dart';
import 'navigation/app_router_delegate.dart';
import 'theme/app_theme.dart';
import 'theme/theme_controller.dart';
import 'theme/theme_toggle_button.dart';
import 'utils/url_strategy.dart';

void main() {
  configureUrlStrategy();
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  late final AppRouterDelegate _routerDelegate;
  final AppRouteInformationParser _routeInformationParser =
      const AppRouteInformationParser();
  late final ThemeNotifier _themeController;

  @override
  void initState() {
    super.initState();
    _routerDelegate = AppRouterDelegate();
    _themeController = ThemeNotifier(ThemeMode.system);
  }

  @override
  void dispose() {
    _routerDelegate.dispose();
    _themeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ThemeScope(
      controller: _themeController,
      child: ValueListenableBuilder<ThemeMode>(
        valueListenable: _themeController,
        builder: (context, themeMode, _) {
          return MaterialApp.router(
            onGenerateTitle: (context) => S.of(context).appTitle,
            localizationsDelegates: S.localizationsDelegates,
            supportedLocales: S.supportedLocales,
            themeMode: themeMode,
            theme: AppTheme.lightTheme,
            darkTheme: AppTheme.darkTheme,
            routerDelegate: _routerDelegate,
            routeInformationParser: _routeInformationParser,
            builder: (context, child) {
              return Overlay(
                initialEntries: [
                  // Overlay.initialEntries is read only on the first build, so this entry
                  // keeps the `child` captured from the first build. Fine for now since Router
                  // preserves its state, but revisit once it's decided how this overlay is
                  // provided (e.g. a StatefulWidget that owns the entry and calls markNeedsBuild).
                  OverlayEntry(
                    builder: (context) => Material(
                      color: Colors.transparent,
                      child: Stack(
                        children: [
                          ?child,
                          const Positioned(
                            top: 16,
                            right: 16,
                            child: SafeArea(child: ThemeToggleButton()),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}
