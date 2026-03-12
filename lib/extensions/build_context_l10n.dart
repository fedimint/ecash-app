import 'package:ecashapp/generated/app_localizations.dart';
import 'package:flutter/widgets.dart';

extension BuildContextL10n on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this);
}
