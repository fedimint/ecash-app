import 'package:ecashapp/models.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/widgets/addresses.dart';
import 'package:ecashapp/widgets/gateways.dart';
import 'package:ecashapp/widgets/note_summary.dart';
import 'package:flutter/material.dart';

Future<void> showPaymentTypeSheet({
  required BuildContext context,
  required PaymentType paymentType,
  required FederationSelector fed,
  VoidCallback? onAddressesUpdated,
}) {
  Widget content;
  switch (paymentType) {
    case PaymentType.lightning:
      content = GatewaysList(fed: fed);
    case PaymentType.onchain:
      content = OnchainAddressesList(
        fed: fed,
        updateAddresses: onAddressesUpdated ?? () {},
      );
    case PaymentType.ecash:
      content = NoteSummary(fed: fed);
  }

  return showModalBottomSheet(
    context: context,
    backgroundColor: Theme.of(context).bottomSheetTheme.backgroundColor,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (context) {
      return SafeArea(
        child: FractionallySizedBox(
          heightFactor: 0.8,
          child: Column(
            children: [
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.grey[700],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: content,
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
