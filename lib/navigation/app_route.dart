import 'package:aqluse_website/screens/home_screen.dart';
import 'package:aqluse_website/screens/unknown_screen.dart';
import 'package:flutter/material.dart';

sealed class AppRoute<T> extends MaterialPage<T> {
  const AppRoute({required super.child});
}

class HomeRoute extends AppRoute {
  const HomeRoute() : super(child: const HomeScreen());

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is HomeRoute;

  @override
  int get hashCode => runtimeType.hashCode;
}

class SecondRouteTest extends AppRoute {
  SecondRouteTest()
    : super(
        child: Scaffold(
          appBar: AppBar(title: const Text('Second Route Test')),
          body: Center(child: Text('Second Route Test')),
        ),
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is SecondRouteTest;

  @override
  int get hashCode => runtimeType.hashCode;
}

class UnknownRoute extends AppRoute {
  const UnknownRoute() : super(child: const UnknownScreen());

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is UnknownRoute;

  @override
  int get hashCode => runtimeType.hashCode;
}
