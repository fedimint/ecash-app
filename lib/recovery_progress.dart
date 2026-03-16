import 'dart:async';
import 'dart:math';

import 'package:ecashapp/lib.dart';
import 'package:ecashapp/models.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

class RecoveryStatus extends StatefulWidget {
  final PaymentType paymentType;
  final FederationSelector fed;
  final double initialProgress;

  const RecoveryStatus({
    super.key,
    required this.paymentType,
    required this.fed,
    required this.initialProgress,
  });

  @override
  State<RecoveryStatus> createState() => _RecoveryStatusState();
}

class _RecoveryStatusState extends State<RecoveryStatus> {
  late double _progress;

  late final StreamSubscription<(int, int)> _progressSubscription;

  @override
  void initState() {
    super.initState();

    _progress = widget.initialProgress;

    final progressEvents =
        subscribeRecoveryProgress(
          federationId: widget.fed.federationId,
          moduleId: getModuleIdForPaymentType(widget.paymentType),
        ).asBroadcastStream();
    _progressSubscription = progressEvents.listen((e) {
      if (e.$2 > 0) {
        double rawProgress = e.$1.toDouble() / e.$2.toDouble();
        setState(() => _progress = rawProgress.clamp(0.0, 1.0));
        AppLogger.instance.info(
          "${widget.paymentType.name} progress: $_progress complete: ${e.$1} total: ${e.$2}",
        );
      }
    });
  }

  @override
  void dispose() {
    _progressSubscription.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final moduleName =
        '${widget.paymentType.name[0].toUpperCase()}${widget.paymentType.name.substring(1)}';

    return Center(
      child: Animate(
        effects: [
          ScaleEffect(duration: 600.ms, curve: Curves.easeOutBack),
          FadeEffect(duration: 600.ms, curve: Curves.easeIn),
        ],
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: _progress),
              duration: const Duration(milliseconds: 300),
              builder: (context, value, child) {
                return Container(
                  width: 220,
                  height: 220,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        theme.colorScheme.primary.withOpacity(0.12),
                        theme.colorScheme.primary.withOpacity(0.04),
                        Colors.transparent,
                      ],
                      stops: const [0.0, 0.5, 1.0],
                    ),
                  ),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      SizedBox(
                        width: 180,
                        height: 180,
                        child: CustomPaint(
                          painter: _ProgressRingPainter(
                            progress: value,
                            color: theme.colorScheme.primary,
                            trackColor: Colors.white.withOpacity(0.08),
                            strokeWidth: 12,
                          ),
                        ),
                      ),
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '${(value * 100).toStringAsFixed(0)}%',
                            style: TextStyle(
                              fontSize: 36,
                              fontWeight: FontWeight.bold,
                              color: theme.colorScheme.primary,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'complete',
                            style: TextStyle(
                              fontSize: 13,
                              color: Colors.white54,
                              letterSpacing: 1.0,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                );
              },
            ),
            const SizedBox(height: 32),
            Animate(
              onPlay: (controller) => controller.repeat(reverse: true),
              effects: [
                FadeEffect(
                  begin: 0.5,
                  end: 1.0,
                  duration: 1500.ms,
                  curve: Curves.easeInOut,
                ),
              ],
              child: Text(
                'Recovering wallet...',
                style: theme.textTheme.bodyLarge?.copyWith(
                  fontSize: 16,
                  color: Colors.white70,
                  letterSpacing: 0.5,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '$moduleName module',
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 13,
                color: theme.colorScheme.secondary.withOpacity(0.6),
                letterSpacing: 1.0,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProgressRingPainter extends CustomPainter {
  final double progress;
  final Color color;
  final Color trackColor;
  final double strokeWidth;

  _ProgressRingPainter({
    required this.progress,
    required this.color,
    required this.trackColor,
    required this.strokeWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.width - strokeWidth) / 2;

    // Draw track
    final trackPaint =
        Paint()
          ..color = trackColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth
          ..strokeCap = StrokeCap.round;
    canvas.drawCircle(center, radius, trackPaint);

    // Draw progress arc
    if (progress > 0) {
      final progressPaint =
          Paint()
            ..color = color
            ..style = PaintingStyle.stroke
            ..strokeWidth = strokeWidth
            ..strokeCap = StrokeCap.round;
      final sweepAngle = 2 * pi * progress;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        -pi / 2, // Start from top
        sweepAngle,
        false,
        progressPaint,
      );
    }
  }

  @override
  bool shouldRepaint(_ProgressRingPainter oldDelegate) =>
      oldDelegate.progress != progress;
}
