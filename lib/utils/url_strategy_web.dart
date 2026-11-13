import 'package:flutter_web_plugins/url_strategy.dart';

/// Web implementation to remove `#` from the URL.
void configureUrlStrategy() {
  usePathUrlStrategy();
}
