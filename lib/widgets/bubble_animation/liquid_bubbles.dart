import 'dart:collection';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

part 'objects.dart';
part 'paint_manager.dart';
part 'painter.dart';

const double? _kDebugBubbleRadius = null; //100;
const bool _kDebugModeDrawBridgeOnTop = false;
const bool _kDebugModeHighlightMaskPoints = false;

const int _kPixelsPerOneBubble = 30_000; //75_000; //30_000; //100_000;

void main() => runApp(const MaterialApp(home: LiquidBubbles(child: null)));

class LiquidBubbles extends StatefulWidget {
  const LiquidBubbles({super.key, required this.child});

  final Widget? child;

  @override
  State<LiquidBubbles> createState() => _LiquidBubblesState();
}

class _LiquidBubblesState extends State<LiquidBubbles>
    with SingleTickerProviderStateMixin {
  final _PaintManager _manager = _PaintManager();
  late final _Painter _painter;
  late Ticker _ticker;

  Duration? _lastElapsed;
  double? _smoothedTimeDelta;

  double processTimeDelta(double timeDelta) {
    // Clamp delta time to prevent sudden jumps when the tab is minimized
    final double safeDelta = timeDelta.clamp(0, 0.1);

    return _smoothedTimeDelta = _smoothedTimeDelta == null
        ? safeDelta
        : ui.lerpDouble(_smoothedTimeDelta, safeDelta, 0.2)!;
  }

  @override
  void initState() {
    super.initState();
    _painter = _Painter(manager: _manager);

    _ticker = createTicker((elapsed) {
      final lastElapsed = _lastElapsed;
      _lastElapsed = elapsed;

      if (lastElapsed == null || elapsed == lastElapsed) {
        return;
      }

      const microsecondsInSecond = 1_000_000;
      final timeDelta =
          (elapsed - lastElapsed).inMicroseconds / microsecondsInSecond;

      _manager.onTick(processTimeDelta(timeDelta));
    })..start();
    SchedulerBinding.instance.addPostFrameCallback((_) => _manager.init());
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _manager.updateSize(Size(constraints.maxWidth, constraints.maxHeight));
        return GestureDetector(
          onTapDown: (d) => _manager.handleTap(d.localPosition),
          child: _CustomPaint(painter: _painter, child: widget.child),
        );
      },
    );
  }
}

class _CustomPaint extends StatelessWidget {
  const _CustomPaint({super.key, required this.painter, required this.child});

  final _Painter painter;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        painter: painter,
        child: child ?? const SizedBox.expand(),
      ),
    );
  }
}
