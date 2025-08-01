import 'dart:async';

import 'package:ecashapp/lib.dart';
import 'package:ecashapp/models.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/utils.dart';
import 'package:flutter/material.dart';

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
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            '${widget.paymentType.name[0].toUpperCase()}${widget.paymentType.name.substring(1)} module progress',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 24),
          TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0, end: _progress),
            duration: const Duration(milliseconds: 300),
            builder: (context, value, child) {
              return Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox(
                    width: 180,
                    height: 180,
                    child: CircularProgressIndicator(
                      value: value,
                      strokeWidth: 12, // Thicker stroke
                    ),
                  ),
                  Text(
                    '${(value * 100).toStringAsFixed(0)}%',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
