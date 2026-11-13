import 'package:flutter/material.dart';

import 'app_route.dart';

class AppRouteInformationParser extends RouteInformationParser<AppRoute> {
  const AppRouteInformationParser();

  @override
  Future<AppRoute> parseRouteInformation(
    RouteInformation routeInformation,
  ) async {
    final uri = routeInformation.uri;
    final pathSegments = uri.pathSegments;

    if (pathSegments.isEmpty) {
      return const HomeRoute();
    }

    if (pathSegments.length == 1) {
      switch (pathSegments.first) {
        case '':
          return const HomeRoute();
        case 'second':
          return SecondRouteTest();
      }
    }

    return const UnknownRoute();
  }

  @override
  RouteInformation? restoreRouteInformation(AppRoute configuration) {
    // TODO: Возможно стоит сразу в роуте писать, заодно перегонять в ключ тоже
    return switch (configuration) {
      HomeRoute() => RouteInformation(uri: Uri.parse('/')),
      UnknownRoute() => RouteInformation(uri: Uri.parse('/404')),
      SecondRouteTest() => RouteInformation(uri: Uri.parse('/second')),
    };
  }
}
