// TEMPORARY: sends perf results to a local collector. Lives only in perf/* branches.
export 'perf_report_stub.dart'
    if (dart.library.js_interop) 'perf_report_web.dart';
