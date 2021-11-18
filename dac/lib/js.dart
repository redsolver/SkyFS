@JS('window')
library crypto;

import 'package:js/js.dart';

@JS('crypto.subtle.digest')
external dynamic cryptoDigest(String algorithm, dynamic data);
