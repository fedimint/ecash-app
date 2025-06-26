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

  @override
  void initState() {
    super.initState();
    _loadProgress();
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
    double rawProgress = 0.0;
    if (progress.$2 > 0) {
      rawProgress = progress.$1.toDouble() / progress.$2.toDouble();
      setState(() => _progress = rawProgress.clamp(0.0, 1.0));
    }

    AppLogger.instance.info("${widget.paymentType.name} progress: $_progress");
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
