// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class SEn extends S {
  SEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Aqluse';

  @override
  String get homeTagline =>
      'Qualified Flutter & Android enthusiast\nDriven by sound technical expertise';

  @override
  String get themeSwitchToLight => 'Switch to Light Theme';

  @override
  String get themeSwitchToDark => 'Switch to Dark Theme';
}
