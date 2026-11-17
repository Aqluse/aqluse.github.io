import 'dart:js_interop';

@JS('fetch')
external JSPromise<JSAny?> _fetch(JSString url, JSAny init);

const String _kPerfCollectorUrl = 'http://127.0.0.1:8765/perf';

/// Fire-and-forget POST of a result line; errors (collector not running) are ignored.
void reportPerfResult(String text) {
  try {
    _fetch(
      _kPerfCollectorUrl.toJS,
      {'method': 'POST', 'body': text}.jsify()!,
    ).toDart.catchError((_) => null);
  } catch (_) {}
}
