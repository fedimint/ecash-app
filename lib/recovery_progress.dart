import 'dart:async';

import 'package:carbine/lib.dart';
import 'package:carbine/models.dart';
import 'package:carbine/multimint.dart';
import 'package:carbine/utils.dart';
import 'package:flutter/material.dart';

class RecoveryStatus extends StatefulWidget {
  final PaymentType paymentType;
  final FederationSelector fed;

  const RecoveryStatus({
    super.key,
    required this.paymentType,
    required this.fed,
  });

  @override
  State<RecoveryStatus> createState() => _RecoveryStatusState();
}

class _RecoveryStatusState extends State<RecoveryStatus> {
  double _progress = 0.0;

  late final StreamSubscription<(int, int)> _progressSubscription;

  @override
  void initState() {
    super.initState();
    _loadProgress();

    final progressEvents =
        subscribeRecoveryProgress(
          federationId: widget.fed.federationId,
          moduleId: _getModuleId(),
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

  int _getModuleId() {
    switch (widget.paymentType) {
      case PaymentType.lightning:
        return 0;
      case PaymentType.ecash:
        return 1;
      case PaymentType.onchain:
        return 2;
    }
  }

  Future<void> _loadProgress() async {
    final progress = await getModuleRecoveryProgress(
      federationId: widget.fed.federationId,
      moduleId: _getModuleId(),
    );

    if (progress.$2 > 0) {
      double rawProgress = progress.$1.toDouble() / progress.$2.toDouble();
      setState(() => _progress = rawProgress.clamp(0.0, 1.0));
    }

    AppLogger.instance.info(
      "${widget.paymentType.name} progress: $_progress complete: ${progress.$1} total: ${progress.$2}",
    );
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
          Stack(
            alignment: Alignment.center,
            children: [
              SizedBox(
                width: 100,
                height: 100,
                child: CircularProgressIndicator(
                  value: _progress,
                  strokeWidth: 8,
                ),
              ),
              Text(
                '${(_progress * 100).toStringAsFixed(0)}%',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
