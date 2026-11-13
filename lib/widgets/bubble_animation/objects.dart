part of 'liquid_bubbles.dart';

const List<Color> _kPalette = [
  Colors.purpleAccent,
  Colors.cyanAccent,
  Colors.pinkAccent,
  Colors.blueAccent,
  Colors.orangeAccent,
  Colors.greenAccent,
];

double _generateBubbleRadius(Random random) {
  return _kDebugBubbleRadius ?? (50 + random.nextDouble() * 30);
}

class _Bubble {
  _Bubble({
    required Random random,
    required this.position,
    Color? color,
    Color? colorMask,
    double? targetRadius,
    Offset? velocity,
  }) : _random = random,
       targetRadius = targetRadius ?? _generateBubbleRadius(random),
       velocity =
           velocity ??
           Offset(
             (random.nextDouble() - 0.5) / 2,
             (random.nextDouble() - 0.5) / 2,
           ) {
    final colorIndex = _random.nextInt(_kPalette.length);
    final colorMaskIndex = _random.nextInt(_kPalette.length);

    _color = color ?? _kPalette[colorIndex];
    this.color = _color;

    _colorMask =
        colorMask ??
        _kPalette[colorMaskIndex != colorIndex
            ? colorMaskIndex
            : ((colorMaskIndex + 1) % _kPalette.length)];
    this.colorMask = _colorMask;
    colorMaskWithAlpha0 = this.colorMask.withAlpha(0);
  }

  final Random _random;
  late final Color _color;
  late Color color;
  late final Color _colorMask;
  late Color colorMask;
  late Color colorMaskWithAlpha0;
  final double targetRadius;

  Offset position;
  Offset velocity;
  double radius = 0;

  double opacity = 0;
  bool visible = true;
  bool covered = false;
  bool glowCovered = false;

  bool get needsDraw => !covered && visible;

  void update(Size size, double speedFactor, {bool forceMovement = false}) {
    position += velocity * speedFactor;
    if (forceMovement) {
      updateVisibility(size);
    }

    // Growth on spawn.
    if (radius < targetRadius) {
      radius = min(
        radius + ((targetRadius - radius) * 0.2) * speedFactor,
        targetRadius,
      );
    }
    if (opacity < 1.0) {
      opacity = min(1, opacity + (0.3 * speedFactor));
      color = _color.withValues(alpha: opacity);
      colorMask = _colorMask.withValues(alpha: opacity);
      colorMaskWithAlpha0 = colorMask.withAlpha(0);
    }

    // Bounce off edges (with anti-stick protection).

    if (position.dx - radius < 0) {
      velocity = Offset(velocity.dx.abs(), velocity.dy);
    } else if (position.dx + radius > size.width) {
      velocity = Offset(-velocity.dx.abs(), velocity.dy);
    }

    if (position.dy - radius < 0) {
      velocity = Offset(velocity.dx, velocity.dy.abs());
    } else if (position.dy + radius > size.height) {
      velocity = Offset(velocity.dx, -velocity.dy.abs());
    }
  }

  void updateVisibility(Size size) {
    visible =
        position.dx + radius >= 0 &&
        position.dx - radius <= size.width &&
        position.dy + radius >= 0 &&
        position.dy - radius <= size.height;
  }

  void updateCovered({bool? covered, bool? glowCovered}) {
    this.covered = covered ?? false;
    this.glowCovered = glowCovered ?? false;
  }
}

class _BubbleBridge {
  _BubbleBridge({required this.bubble1, required this.bubble2});

  final _Bubble bubble1;
  final _Bubble bubble2;
  bool covered = false;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _BubbleBridge &&
          runtimeType == other.runtimeType &&
          ((bubble1 == other.bubble1 && bubble2 == other.bubble2) ||
              (bubble1 == other.bubble2 && bubble2 == other.bubble1));

  @override
  int get hashCode {
    return bubble1.hashCode ^ bubble2.hashCode;
  }
}

class _MaskPoint {
  _MaskPoint(this.position, {required Random random})
    : _random = random,
      angleRadians = random.nextDouble() * 2 * pi,
      speed = random.nextDouble().clamp(0.5, 1),
      radius = _generateBubbleRadius(random) * 2;

  Offset position;
  double angleRadians;
  final double speed;
  final double radius;
  bool visible = true;
  final Set<_Bubble> coveredWithinBubble = {};

  bool covered(_Bubble hostBubble) => coveredWithinBubble.contains(hostBubble);

  bool needsDraw(_Bubble hostBubble) => !covered(hostBubble) && visible;

  final Random _random;

  void update(final Size size, double speedFactor) {
    coveredWithinBubble.clear();

    const maxAngleChangeRate = 0.1;
    angleRadians +=
        ((_random.nextDouble() - 0.5) * maxAngleChangeRate) * speedFactor;

    final movement = Offset(
      cos(angleRadians) * speed,
      sin(angleRadians) * speed,
    );
    position += movement * speedFactor;

    final directionX = cos(angleRadians);
    final directionY = sin(angleRadians);

    // Bounce off edges (with anti-stick protection).

    if (position.dx < 0 && directionX < 0 ||
        position.dx > size.width && directionX > 0) {
      angleRadians = pi - angleRadians;
    }

    if (position.dy < 0 && directionY < 0 ||
        position.dy > size.height && directionY > 0) {
      angleRadians = 2 * pi - angleRadians;
    }
  }

  void updateVisibility(Size size) {
    visible =
        position.dx + radius >= 0 &&
        position.dx - radius <= size.width &&
        position.dy + radius >= 0 &&
        position.dy - radius <= size.height;
  }
}
