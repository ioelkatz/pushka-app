// Picks the right Firebase config based on the ENV dart-define.
// Run with `--flavor dev --dart-define=ENV=dev` for the test backend,
// or with `--flavor prod` (defaults to ENV=prod) for production.
import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;

import 'firebase_options_dev.dart';
import 'firebase_options_prod.dart';

class DefaultFirebaseOptions {
  static const String _env =
      String.fromEnvironment('ENV', defaultValue: 'prod');

  static bool get isDev => _env == 'dev';

  static FirebaseOptions get currentPlatform => isDev
      ? DevFirebaseOptions.currentPlatform
      : ProdFirebaseOptions.currentPlatform;
}
