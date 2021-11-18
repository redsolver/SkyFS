// make the dart library JS-interoperable
@JS()
library interop;

// required imports
import 'dart:async';
import 'dart:html';
import 'dart:js_util';

import 'package:js/js.dart';
import 'package:sodium/sodium.dart';

// declare a JavaScript type that will provide the callback for the loaded
// sodium JavaScript object.
@JS()
@anonymous
class SodiumBrowserInit {
  external void Function(dynamic sodium) get onload;

  external factory SodiumBrowserInit({void Function(dynamic sodium) onload});
}

Future<Sodium> loadSodiumInBrowser() async {
  // create a completer that will wait for the library to be loaded
  final completer = Completer<dynamic>();

  // Set the global `sodium` property to our JS type, with the callback beeing
  // redirected to the completer
  setProperty(
      window,
      'sodium',
      SodiumBrowserInit(
        onload: allowInterop(completer.complete),
      ));

  // Load the sodium.js into the page by appending a `<script>` element
  final script = ScriptElement();
  script
    ..type = 'text/javascript'
    ..async = true
    ..src =
        '/js/sodium.js'; // use the path where you put the file on your server
  document.head!.append(script);

  // await the completer
  final dynamic sodiumJS = await completer.future;

  // initialize the sodium APIs
  return SodiumInit.init(sodiumJS);
}
