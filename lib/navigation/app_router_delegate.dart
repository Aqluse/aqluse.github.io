import 'package:flutter/material.dart';

import 'app_route.dart';

class AppRouterDelegate extends RouterDelegate<AppRoute>
    with ChangeNotifier, PopNavigatorRouterDelegateMixin<AppRoute> {
  AppRouterDelegate() : navigatorKey = GlobalKey<NavigatorState>();

  @override
  final GlobalKey<NavigatorState> navigatorKey;

  AppRoute _currentRoute = const HomeRoute();

  AppRoute get currentRoute => _currentRoute;

  static AppRouterDelegate of(BuildContext context) {
    final delegate = Router.of(context).routerDelegate;
    assert(
      delegate is AppRouterDelegate,
      'AppRouterDelegate not found in context',
    );
    return delegate as AppRouterDelegate;
  }

  @override
  AppRoute? get currentConfiguration => _currentRoute;

  void goTo(AppRoute route) {
    if (_currentRoute != route) {
      _currentRoute = route;
      notifyListeners();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Navigator(
      key: navigatorKey,
      pages: [
        const HomeRoute(),
        if (_currentRoute is SecondRouteTest) SecondRouteTest(),
        if (_currentRoute is UnknownRoute) const UnknownRoute(),
      ],
      onDidRemovePage: (page) {
        _currentRoute = const HomeRoute();
        notifyListeners();
      },
    );
  }

  @override
  Future<void> setNewRoutePath(AppRoute configuration) async {
    _currentRoute = configuration;
    notifyListeners();
  }
}
