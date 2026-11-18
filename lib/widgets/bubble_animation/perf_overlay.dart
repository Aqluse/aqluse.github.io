part of 'liquid_bubbles.dart';

// TEMPORARY: FPS overlay for performance measurements. Lives only in perf/* branches.

const bool _kPerfOverlay = true;

enum _PerfPhase { warmUp, measuring, done }

class _PerfOverlay extends StatefulWidget {
  const _PerfOverlay({required this.manager});

  final _PaintManager manager;

  @override
  State<_PerfOverlay> createState() => _PerfOverlayState();
}

class _PerfOverlayState extends State<_PerfOverlay>
    with SingleTickerProviderStateMixin {
  static const _warmUp = Duration(seconds: 10);
  static const _window = Duration(seconds: 30);
  static const _refresh = Duration(milliseconds: 500);
  static const _runs = 3;

  int _runIndex = 0;
  bool _startReported = false;
  static const _renderer = bool.fromEnvironment('dart.tool.dart2wasm')
      ? 'skwasm (wasm)'
      : 'canvaskit (js)';

  late final Ticker _ticker;

  _PerfPhase _phase = .warmUp;
  Duration _phaseStart = Duration.zero;
  Duration? _lastFrame;
  final List<int> _intervalsUs = [];

  Duration _liveStart = Duration.zero;
  int _liveFrames = 0;
  double _liveFps = 0;

  String? _result;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _restart() {
    _phase = .warmUp;
    _phaseStart = _lastFrame ?? Duration.zero;
    _intervalsUs.clear();
    _result = null;
    _runIndex = 0;
    setState(() {});
  }

  void _onTick(Duration elapsed) {
    final last = _lastFrame;
    _lastFrame = elapsed;
    if (last == null || elapsed == last) return;

    final intervalUs = (elapsed - last).inMicroseconds;
    _liveFrames++;

    // Early report so the setup (sizes, counts) can be checked without waiting for results.
    if (!_startReported && elapsed >= const Duration(seconds: 3)) {
      _startReported = true;
      reportPerfResult('[perf] start | ${_statsLine()}');
    }

    switch (_phase) {
      case .warmUp:
        if (elapsed - _phaseStart >= _warmUp) {
          _phase = .measuring;
          _phaseStart = elapsed;
          _intervalsUs.clear();
          widget.manager.resetSdfStats();
        }
      case .measuring:
        _intervalsUs.add(intervalUs);
        if (elapsed - _phaseStart >= _window) {
          _phase = .done;
          _result = _computeResult();
          _runIndex++;
          final line =
              '[perf] run $_runIndex/$_runs $_result | ${_statsLine()}';
          debugPrint(line);
          reportPerfResult(line);
          if (_runIndex < _runs) {
            // Next run without warm-up: the scene is already warmed up.
            _phase = .measuring;
            _phaseStart = elapsed;
            _intervalsUs.clear();
            widget.manager.resetSdfStats();
          }
        }
      case .done:
        break;
    }

    // Refresh the text at a low rate so the overlay itself barely affects the measurement.
    if (elapsed - _liveStart >= _refresh) {
      final seconds = (elapsed - _liveStart).inMicroseconds / 1e6;
      _liveFps = _liveFrames / seconds;
      _liveFrames = 0;
      _liveStart = elapsed;
      setState(() {});
    }
  }

  String _computeResult() {
    final count = _intervalsUs.length;
    final totalUs = _intervalsUs.fold<int>(0, (a, b) => a + b);
    final avgFps = count / (totalUs / 1e6);

    final sorted = [..._intervalsUs]..sort((a, b) => b.compareTo(a));
    final worstCount = max(1, (count * 0.01).round());
    final worstUs =
        sorted.take(worstCount).fold<int>(0, (a, b) => a + b) / worstCount;
    final low1Fps = 1e6 / worstUs;

    return 'avg ${avgFps.toStringAsFixed(1)} FPS · '
        '1% low ${low1Fps.toStringAsFixed(1)} FPS · '
        '$count frames';
  }

  String _statsLine() {
    final m = widget.manager;
    final size = m._canvasSizeRaw;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return 'bubbles ${m.bubbles.length} · masks ${m.maskPoints.length} · '
        'bridges ${m.bridges.length} · '
        'renderer ${_kUseSdf ? 'sdf' : 'legacy'} · '
        'tiles ${m.statSdfTiles} (splits ${m.statSdfSplits}) · '
        'max bubbles/tile ${m.statSdfMaxTileBubbles} · '
        'max spots/tile ${m.statSdfMaxTileSpots} · '
        'culled spots ${m.statSdfCulled} · '
        'dropped ${m.statSdfDropped} · '
        '${_sdfTunablesLine()} · '
        'logical ${size?.width.round()}×${size?.height.round()} · '
        'DPR $dpr · $_renderer · px/bubble $_kPixelsPerOneBubble · '
        'crossOriginIsolated $perfCrossOriginIsolated';
  }

  @override
  Widget build(BuildContext context) {
    final String phaseLine = switch (_phase) {
      .warmUp =>
        'warm-up ${(_lastFrame ?? Duration.zero).inSeconds - _phaseStart.inSeconds}'
            '/${_warmUp.inSeconds}s',
      .measuring =>
        'run ${_runIndex + 1}/$_runs: measuring '
            '${(_lastFrame ?? Duration.zero).inSeconds - _phaseStart.inSeconds}'
            '/${_window.inSeconds}s${_result == null ? '' : '\nlast: $_result'}',
      .done => '✅ ALL $_runs RUNS DONE — last: $_result (tap to restart)',
    };

    const textStyle = TextStyle(
      color: Colors.white,
      fontSize: 12,
      fontFamily: 'monospace',
      height: 1.4,
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: .circular(8),
      ),
      child: Padding(
        padding: const .all(8),
        child: Column(
          mainAxisSize: .min,
          crossAxisAlignment: .start,
          children: [
            // Only the text restarts the measurement, so dragging the slider doesn't.
            GestureDetector(
              onTap: _restart,
              child: Text(
                'live ${_liveFps.toStringAsFixed(0)} FPS\n'
                '$phaseLine\n'
                '${_statsLine()}',
                style: textStyle,
              ),
            ),
            if (_kUseSdf) ...[
              _buildSlider(
                textStyle,
                label: 'edge fade px',
                value: _sdfEdgeFade,
                min: 0.25,
                max: 6,
                step: 0.05,
                onChanged: (value) => _sdfEdgeFade = value,
              ),
              _buildSlider(
                textStyle,
                label: 'neck fade px',
                value: _sdfColorFade,
                min: 0.25,
                max: 6,
                step: 0.05,
                onChanged: (value) => _sdfColorFade = value,
              ),
              _buildSlider(
                textStyle,
                label: 'spot size',
                value: _sdfSpotSize,
                min: 0.25,
                max: 2,
                step: 0.05,
                onChanged: (value) => _sdfSpotSize = value,
              ),
              _buildSlider(
                textStyle,
                label: 'spot strength',
                value: _sdfSpotStrength,
                min: 0,
                max: 2,
                step: 0.05,
                onChanged: (value) => _sdfSpotStrength = value,
              ),
              _buildSlider(
                textStyle,
                label: 'spot core',
                value: _sdfSpotCore,
                min: 0,
                max: 0.9,
                step: 0.01,
                onChanged: (value) => _sdfSpotCore = value,
              ),
              _buildSlider(
                textStyle,
                label: 'spot falloff',
                value: _sdfSpotFalloff,
                min: 0.25,
                max: 4,
                step: 0.05,
                onChanged: (value) => _sdfSpotFalloff = value,
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Runtime tuning of a look parameter (PERF: values are read by the shader every frame).
  Widget _buildSlider(
    TextStyle textStyle, {
    required String label,
    required double value,
    required double min,
    required double max,
    required double step,
    required ValueChanged<double> onChanged,
  }) {
    return Row(
      mainAxisSize: .min,
      children: [
        SizedBox(
          width: 170,
          child: Text('$label ${value.toStringAsFixed(2)}', style: textStyle),
        ),
        SizedBox(
          width: 320,
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: ((max - min) / step).round(),
            onChanged: (v) => setState(() => onChanged(v)),
          ),
        ),
      ],
    );
  }
}
