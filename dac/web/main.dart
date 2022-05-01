import 'dart:html';
import 'dart:js_util';
import 'dart:math';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';
import 'package:filesystem_dac/dac.dart';
import 'package:filesystem_dac/js.dart';
import 'package:path/path.dart';
import 'package:pool/pool.dart';
import 'package:skynet/src/mysky_provider/web.dart';
import 'package:skynet/src/utils/base32.dart';
import 'package:skynet/src/utils/convert.dart';
import 'package:skynet/src/mysky/tweak.dart';
import 'package:skynet/src/mysky/encrypted_files.dart';

import 'package:filesystem_dac/sodium.dart';
import 'package:skynet/skynet.dart';
import 'package:skynet/src/skystandards/fs.dart';
import 'package:sodium/sodium.dart';
import 'package:skynet/src/skynet_tus_client_web.dart';
import 'package:skynet/src/encode_endian/encode_endian.dart';
import 'package:skynet/src/encode_endian/base.dart';
import 'package:stash/stash_api.dart';
import 'package:stash_hive/stash_hive.dart';

final uploadPool = Pool(4);
final downloadPool = Pool(4);

final version = '0.8.2';

// ! This Map maps resolver skylinks to their HNS domains.
// ! This is a temporary solution.
const staticSkylinkToDomainMap = {
  '0404mj7bvmsc2n1l3v6kd2g1eei6vrhmv25dqn5374b102ikrqt0m48': 'riftapp.hns',
};

void sendMessage(dynamic data) {
  window.parent?.postMessage(data, '*');
}

int? sessionId;

final urlParams = UrlSearchParams(window.location.search);

final DEBUG_ENABLED = urlParams.get('debug') == 'true';
final DEV_ENABLED = urlParams.get('dev') == 'true';

void main() {
  final dac = WebWrapper();
  if (DEBUG_ENABLED) {
    print('[fs-dac.hns] DEBUG_ENABLED');
  }
  window.addEventListener('message', (event) async {
    final e = event as MessageEvent;

    final origin = Uri.parse(e.origin);

    if (origin.host != dac.referrerHost) return;

    if (DEBUG_ENABLED) print('> dac ${e.data}');

    final type = e.data['type'];
    if (type != '@post-me') return;

    final action = e.data['action'];

    if (action == 'handshake-request') {
      sessionId = e.data['sessionId'];
      sendMessage(
        {
          'type': '@post-me',
          'action': 'handshake-response',
          'sessionId': sessionId,
        },
      );
      return;
    }
    if (sessionId == null) {
      throw 'Not initialized';
    }
    if (action == 'handshake-response') {
      return;
    }
    if (sessionId != e.data['sessionId']) throw 'Wrong sessionId';

    if (action == 'call') {
      final int requestId = e.data['requestId'];
      final String methodName = e.data['methodName'];
      final List args = e.data['args'];
      if (DEBUG_ENABLED) print('call $methodName $args');

      if (!dac.methods.containsKey(methodName)) {
        throw 'Unknown method $methodName';
      }

      dynamic value;

      try {
        if (args.isNotEmpty &&
            args.last is Map &&
            args.last['proxy'] == 'callback') {
          args.add(requestId);
        }

        // TODO Adjust pool size (do some testing)
        if (methodName == 'uploadFileData') {
          print('[FileSystem DAC] using upload pool');
          value = await uploadPool.withResource(
            () => dac.methods[methodName]!(args),
          );
        } else if (methodName == 'downloadFileData') {
          print('[FileSystem DAC] using download pool');
          value = await downloadPool.withResource(
            () => dac.methods[methodName]!(args),
          );
        } else {
          value = await dac.methods[methodName]!(args);
        }
      } catch (e) {
        value = {
          'success': false,
          'error': e,
        };
      }

      if (DEBUG_ENABLED) print('[$DATA_DOMAIN] < $methodName $value');
      final res = {
        'type': '@post-me',
        'action': 'response',
        'sessionId': sessionId,
        'requestId': requestId,
      };

      if (value != null) {
        res['result'] = value;
      }

      sendMessage(
        res,
      );

      return;
    }

    throw 'Unknown action $action';
  });
}

typedef WebDACMethod = Future Function(List<dynamic> args);

class WebWrapper {
  late Map<String, WebDACMethod> methods;

  String skapp = 'none';

  late String referrerHost;
  final skynetClient = SkynetClient();

  dynamic dartify(dynamic data) {
    return json.decode(json.encode(data));
  }

  WebWrapper() {
    print("[FileSystemDAC Web] init v${version}");

    // define API
    methods = {
      'init': init,
      'onUserLogin': onUserLogin,
      'createDirectory': createDirectory,
      'copyFile': copyFile,
      'moveFile': moveFile,
      'renameFile': renameFile,
      'getShareUriReadOnly': getShareUriReadOnly,
      'generateShareUriReadWrite': generateShareUriReadWrite,
      'createFile': createFile,
      'updateFile': updateFile,
      'uploadFileData': uploadFileData,
      'downloadFileData': downloadFileData,
      'getDirectoryIndex': getDirectoryIndex,
      'loadThumbnail': loadThumbnail,
      'mountUri': mountUri,
    };

    // extract the skappname and use it to set the filepaths
    referrerHost = Uri.parse(document.referrer).host;

    skapp = referrerHost.replaceFirst(
        RegExp('\.' + skynetClient.portalHost + r'$'), '');

    if (staticSkylinkToDomainMap.containsKey(skapp)) {
      skapp = staticSkylinkToDomainMap[skapp]!;
    }

    print('[FileSystem DAC] loaded from "$skapp"');
  }

  Future getDirectoryIndex(List args) async {
    final res = await dac.getDirectoryIndex(args[0]);
    return dartify(res);
  }

  Future createDirectory(List args) async {
    final res = await dac.createDirectory(args[0], args[1]);
    return res.toJson();
  }

  Future copyFile(List args) async {
    final res = await dac.copyFile(args[0], args[1]);
    return res.toJson();
  }

  Future moveFile(List args) async {
    final res = await dac.moveFile(args[0], args[1]);
    return res.toJson();
  }

  Future renameFile(List args) async {
    final res = await dac.renameFile(args[0], args[1]);
    return res.toJson();
  }

  Future getShareUriReadOnly(List args) async {
    final res = await dac.getShareUriReadOnly(args[0]);
    return res;
  }

  Future mountUri(List args) async {
    await dac.mountUri(args[0], Uri.parse(args[1]));
    return DirectoryOperationTaskResult(true).toJson();
  }

  Future generateShareUriReadWrite(List args) async {
    final res = await dac.generateSharedReadWriteDirectory();
    return res;
  }

  Future createFile(List args) async {
    final res = await dac.createFile(
      args[0],
      args[1],
      FileData.fromJson(args[2].cast<String, dynamic>()),
    );
    return res.toJson();
  }

  Future updateFile(List args) async {
    final res = await dac.updateFile(
      args[0],
      args[1],
      FileData.fromJson(args[2].cast<String, dynamic>()),
    );
    return res.toJson();
  }

  void _callback(dynamic requestId, dynamic callbackId, List args) {
    final res = {
      'type': '@post-me',
      'action': 'callback',
      'sessionId': sessionId,
      'requestId': requestId,
      'callbackId': callbackId,
      'args': args,
    };
    sendMessage(
      res,
    );
  }

  Future<Blob> downloadFileData(List args) async {
    final fileData = FileData.fromJson(args[0].cast<String, dynamic>());

    final String mimeType = args[1] ?? 'application/octet-stream';
    final Map? callback = args.length > 2 ? args[2] : null;
    final onProgress = (progress) {
      if (callback != null) {
        _callback(
          args.last,
          callback['callbackId'],
          [progress],
        );
      }
    };

    // TODO Using this callback is highly experimental and not recommended
    /* if (args.length > 3 && args[3] != null && args[3] is Map) {
      final Map onChunkCallback = args[3];

      // TODO Blob mime type
      await for (final chunk in await downloadAndDecryptFileWeb(
        fileData,
        onProgress: onProgress,
        client: dac.client,
        sodium: dac.sodium,
      )) {
        _callback(
          args.last,
          onChunkCallback['callbackId'],
          [chunk],
        );
      }
    } else { */

    if (fileData.encryptionType == 'libsodium_secretbox') {
      return Blob(
        await (await downloadAndDecryptFileInChunksWeb(
          fileData,
          onProgress: onProgress,
          client: dac.client,
          sodium: dac.sodium,
        ))
            .toList(),
        mimeType,
      );
    } else {
      return Blob(
        await (await downloadAndDecryptFileWebDeprecated(
          fileData,
          onProgress: onProgress,
          client: dac.client,
          sodium: dac.sodium,
        ))
            .toList(),
        mimeType,
      );
    }
    /*  } */

    /* return Blob(
        await (await downloadAndDecryptFileWeb(
          fileData,
          onProgress: onProgress,
          client: dac.client,
          sodium: dac.sodium,
        ))
            .toList(),
        mimeType); */
  }

  Future<Blob> loadThumbnail(List args) async {
    final String key = args[0];

    final bytes = await dac.loadThumbnail(key);
    return Blob([bytes ?? Uint8List(0)], 'image/jpeg');
  }

  Future uploadFileData(List args) async {
    final Blob blob = args[0];
    String? filename = args[1];
    final Map? callback = args[2];
    log('uploading ${filename}...');

    final buffer = await promiseToFuture<dynamic>(
        await callMethod(blob, 'arrayBuffer', []));

    final dig =
        await promiseToFuture<ByteBuffer>(cryptoDigest('SHA-256', buffer));

    final multihash =
        '1220${hex.encode(dig.asUint8List())}'; //await getMultiHashForFile(getStreamOfFile(buffer));

    log('uploadFileData: multihash $multihash');

    var generateMetadata = isLoggedIn &&
        filename != null &&
        metadataSupportedExtensions.contains(extension(filename)); // 20 MB

    if (generateMetadata) {
      if (supportedImageExtensions.contains(extension(filename!))) {
        if (blob.size > 900 * 1000) {
          print('! Skipping image parsing because the file is too large.');
          // TODO Improve image parsing performance on web
          generateMetadata = false;
        }
      }
    }

    final fileData = await dac.uploadFileData(
      multihash,
      blob.size,
      generateMetadata: generateMetadata,
      filename: filename,
      generateMetadataWrapper: generateMetadata
          ? (
              extension,
              rootPathSeed,
            ) async {
              final res = await extractMetadata([
                extension,
                buffer.asUint8List(
                  0,
                  min(
                    metadataMaxFileSize,
                    blob.size,
                  ),
                ),
                rootPathSeed,
              ]);
              return res;
            }
          : null,
      customEncryptAndUploadFileFunction: () => encryptAndUploadFileInChunks(
        getStreamOfFile(buffer),
        multihash,
        client: dac.client,
        sodium: dac.sodium,
        totalSize: blob.size,
        onProgress: (progress) {
          if (callback != null) {
            _callback(
              args.last,
              callback['callbackId'],
              [progress],
            );
          }
        },
      ),
    );

    return dartify(fileData);
  }

  late FileSystemDAC dac;

  Future<void> init(List args) async {
    try {
      log('init Sodium');

      try {
        if (skapp.length >= 54) {
          var sl = skapp;
          while (sl.length % 2 != 0) {
            sl += '=';
          }
          final bytes = base32.decode(sl);
          final base64Skylink = base64Url.encode(bytes).replaceAll('=', '');

          final datakey =
              deriveDiscoverableTweak('reverse-lookup/$base64Skylink');

          final res = await skynetClient.registry.getEntry(
            SkynetUser.fromId(
              'a73e5e56f69e025b7bde1c816311b14f141d63a7b7cbd4dda0294755f402ec21',
            ),
            '',
            hashedDatakey: hex.encode(datakey),
          );

          if (res?.entry != null) {
            skapp = encodeSkylinkToBase32(res!.entry.data);

            if (staticSkylinkToDomainMap.containsKey(skapp)) {
              skapp = staticSkylinkToDomainMap[skapp]!;
            }

            print('[FileSystem DAC] (reverse lookup) loaded from "$skapp"');
          }
        }
      } catch (_) {}

      final sodium = await loadSodiumInBrowser();

      final hiveStore = newHiveDefaultCacheStore();

      final thumbnailCache = hiveStore.cache<Uint8List>(
        name: 'thumbnailCache',
        maxEntries: 1000,
      );

      dac = FileSystemDAC(
        mySkyProvider: WebMySkyProvider(SkynetClient()),
        skapp: skapp,
        sodium: sodium,
        debugEnabled: DEBUG_ENABLED,
        thumbnailCache: thumbnailCache,
      );

      // load mysky
      await dac.init(
        devEnabled: DEV_ENABLED,
      );
    } catch (error) {
      log("Failed to load MySky, err: $error");
      rethrow;
    }
  }

  bool isLoggedIn = false;

  // onUserLogin is called by MySky when the user has logged in successfully
  Future<void> onUserLogin(List args) async {
    log('onUserLogin');
    isLoggedIn = true;

    await dac.onUserLogin();
  }

  void log(
    String message,
  ) {
    if (DEBUG_ENABLED) {
      print('[FileSystemDAC] $message');
    }
  }

  Future<String> getMultiHashForFileWithBlob(
    Blob blob,
  ) async {
    var output = AccumulatorSink<Digest>();
    var input = sha256.startChunkedConversion(output);

    final chunkSize = 16 * 1024 * 1024;

    for (int i = 0; i < blob.size; i += chunkSize) {
      final buffer = await promiseToFuture<ByteBuffer>(
        await callMethod(
          blob.slice(
            i,
            min(
              i + chunkSize,
              blob.size,
            ),
          ),
          'arrayBuffer',
          [],
        ),
      );

      input.add(buffer.asUint8List());
    }
    input.close();

    final hash = output.events.single;

    return '1220$hash';
  }

  Future<Stream<Uint8List>> downloadAndDecryptFileInChunksWeb(
    FileData fileData, {
    required Function onProgress,
    required Sodium sodium,
    required SkynetClient client,
  }) async {
    print('[download+decrypt] using libsodium_secretbox');

    final downloadChunkSize = 8 * 1000 * 1000;

    final chunkSize = fileData.chunkSize ?? maxChunkSize;
    final padding = fileData.padding ?? 0;

    onProgress(0.0);

    final totalEncSize =
        ((fileData.size / chunkSize).floor() * (chunkSize + 16)) +
            (fileData.size % chunkSize) +
            16 +
            padding;

    final streamCtrl = StreamController<Uint8List>();

    final secretKey = base64Url.decode(fileData.key!);
    final key = SecureKey.fromList(
      sodium,
      secretKey,
    );

    final url = Uri.parse(
      client.resolveSkylink(
        fileData.url,
        trusted: true, // TODO Maybe remove this
      )!,
    );
    final downloadStreamCtrl = StreamController<List<int>>();

    StreamSubscription? sub;
    int downloadedLength = 0;
    int lastProgress = 0;

    late HttpRequest req;

    void sendDownloadRequest() async {
      try {
        final completer = Completer<Blob?>();

        req = HttpRequest();
        req.withCredentials = true;

        req.open('GET', url.toString());

        final lastByteOfChunk =
            min(downloadedLength + downloadChunkSize - 1, totalEncSize - 1);

        req.setRequestHeader(
            'range', 'bytes=$downloadedLength-$lastByteOfChunk');

        req.onProgress.listen((event) {
          lastProgress = event.loaded!;
          onProgress((downloadedLength + event.loaded!) / totalEncSize);
        });

        req.responseType = 'blob';
        req.onLoadEnd.listen((event) {
          completer.complete(req.response);
        });
        req.onError.listen((event) {
          completer.complete(null);
        });

        req.send('');

        final blob = await completer.future;

        if (blob == null) {
          throw 'Chunk download failed';
        }

        final buffer = await promiseToFuture<ByteBuffer>(
            await callMethod(blob, 'arrayBuffer', []));

        downloadStreamCtrl.add(buffer.asUint8List());

        await Future.delayed(Duration(milliseconds: 20));
        sendDownloadRequest();
      } catch (e, st) {
        print(e);
        print(st);
      }
    }

    final completer = Completer<bool>();

    final List<int> data = [];
    sendDownloadRequest();

    StreamSubscription? progressSub;

    int lastProgressCache = 0;
    DateTime lastDownloadedLengthTS = DateTime.now();

    progressSub = Stream.periodic(Duration(milliseconds: 200)).listen((event) {
      final progress = downloadedLength / totalEncSize;
      // onProgress!(progress);
      if (lastProgressCache != lastProgress) {
        lastProgressCache = lastProgress;
        lastDownloadedLengthTS = DateTime.now();
      } else {
        final diff = DateTime.now().difference(lastDownloadedLengthTS);
        if (diff > Duration(seconds: 20)) {
          print('detected download issue, reconnecting...');
          req.abort();
          lastDownloadedLengthTS = DateTime.now();

          sub?.cancel();
          sendDownloadRequest();
        }
      }
    });

    int currentChunk = 0;

    final _downloadSub = downloadStreamCtrl.stream.listen(
      (List<int> newBytes) {
        data.addAll(newBytes);

        downloadedLength += newBytes.length;

        while (data.length > (chunkSize + 16)) {
          log('[download+decrypt] decrypt chunk...');

          final nonce = Uint8List.fromList(
            encodeEndian(
              currentChunk,
              sodium.crypto.secretBox.nonceBytes,
              endianType: EndianType.littleEndian,
            ) as List<int>,
          );

          final r = sodium.crypto.secretBox.openEasy(
            cipherText: Uint8List.fromList(
              data.sublist(0, chunkSize + 16),
            ),
            nonce: nonce,
            key: key,
          );
          streamCtrl.add(r);

          currentChunk++;

          data.removeRange(0, chunkSize + 16);
        }

        if (downloadedLength == totalEncSize) {
          log('[download+decrypt] decrypt final chunk...');

          final nonce = Uint8List.fromList(
            encodeEndian(
              currentChunk,
              sodium.crypto.secretBox.nonceBytes,
              endianType: EndianType.littleEndian,
            ) as List<int>,
          );

          final r = sodium.crypto.secretBox.openEasy(
            cipherText: Uint8List.fromList(
              data,
            ),
            nonce: nonce,
            key: key,
          );
          if (padding > 0) {
            log('[download+decrypt] remove padding...');
            streamCtrl.add(r.sublist(0, r.length - padding));
          } else {
            streamCtrl.add(r);
          }
          downloadStreamCtrl.close();
        }
      },
      onDone: () async {
        await progressSub?.cancel();
        await streamCtrl.close();

        completer.complete(true);
      },
      onError: (e) {
        progressSub?.cancel();
        // TODO Handle error
      },
      cancelOnError: true,
    );

    return streamCtrl.stream;
  }
}

Stream<Uint8List> getStreamOfFile(ByteBuffer buffer) async* {
  int start = 0;
  while (start < buffer.lengthInBytes) {
    final end = start + maxChunkSize > buffer.lengthInBytes
        ? buffer.lengthInBytes
        : start + maxChunkSize;

    yield buffer.asUint8List(start, end - start);

    start += maxChunkSize;
  }

  return;
}

// ! Below: Custom download and upload code for web

const TUS_CHUNK_SIZE = (1 << 22) * 10; // ~ 41 MB

Stream<Blob> _downloadFileInChunks(
    Uri url, int totalSize, Function onProgress) async* {
  final downloadChunkSize = 32 * 1000 * 1000;
  for (int i = 0; i < totalSize; i += downloadChunkSize) {
    try {
      final completer = Completer<Blob?>();

      final req = HttpRequest();
      req.withCredentials = true;

      req.open('GET', url.toString());

      final lastByteOfChunk = min(i + downloadChunkSize - 1, totalSize - 1);

      req.setRequestHeader('range', 'bytes=$i-$lastByteOfChunk');

      req.onProgress.listen((event) {
        final chunkProgress = event.loaded! /
            event.total! *
            (lastByteOfChunk % downloadChunkSize);
        final totalProgress = (i + chunkProgress) / totalSize;
        onProgress(totalProgress);
      });

      req.responseType = 'blob';
      req.onLoadEnd.listen((event) {
        completer.complete(req.response);
      });
      req.onError.listen((event) {
        completer.complete(null);
      });

      /* req.onAbort.listen((event) {
        print('onAbort');
      });
      req.onTimeout.listen((event) {
        print('onTimeout');
      }); */

      req.send('');

      final blob = await completer.future;

      if (blob == null) {
        throw 'Chunk download failed';
      }

      yield blob;
    } catch (e, st) {
      print(e);
      print(st);
      i -= downloadChunkSize;
      print('Retrying...');
      await Future.delayed(Duration(seconds: 5));
    }
  }
}

Future<Stream<Blob>> downloadAndDecryptFileWebDeprecated(
  FileData fileData, {
  required Function onProgress,
  required SkynetClient client,
  required Sodium sodium,
}) async {
  print('[FileSystem DAC] [web] using new download code');

  final chunkSize = fileData.chunkSize ?? maxChunkSize;

  final encryptedLength =
      fileData.size + 24 + (fileData.size / chunkSize).ceil() * 17;

  onProgress(0);

  final streamCtrl = StreamController<SecretStreamCipherMessage>();

  final secretKey = base64Url.decode(fileData.key!);
  final transformer = sodium.crypto.secretStream
      .createPullEx(
        SecureKey.fromList(
          sodium,
          secretKey,
        ),
        requireFinalized: false,
      )
      .bind(streamCtrl.stream);

  final url = Uri.parse(
    client.resolveSkylink(
      fileData.url,
      trusted: true, // TODO Only useful for external downloads, maybe remove
    )!,
  );
  late Stream<Blob> stream;

  int totalDownloadLength = encryptedLength;

  if (totalDownloadLength > (chunkSize + 100)) {
    stream = _downloadFileInChunks(url, totalDownloadLength, onProgress);
  } else {
    final streamCtrl = StreamController<Blob>();
    stream = streamCtrl.stream;
    final req = HttpRequest();
    req.withCredentials = true;

    req.open('GET', url.toString());

    req.onProgress.listen((event) {
      totalDownloadLength = event.total!;
      onProgress(event.loaded! / event.total!);
    });
    req.responseType = 'blob';
    req.onLoadEnd.listen((event) {
      streamCtrl.add(req.response);
      streamCtrl.close();
    });
    req.send('');
  }

  int downloadedLength = 0;

  final completer = Completer<bool>();

  Blob blob = Blob([]);

  bool headerSent = false;

  StreamSubscription? progressSub;

  final _downloadSub = stream.listen(
    (Blob newBlob) async {
      downloadedLength += newBlob.size;
      blob = Blob([blob, newBlob]);

      if (!headerSent) {
        final length = 24;
        final data = blob.slice(0, length);
        blob = blob.slice(length);
        final buffer = await promiseToFuture<ByteBuffer>(
            await callMethod(data, 'arrayBuffer', []));

        streamCtrl.add(
          SecretStreamCipherMessage(
            Uint8List.fromList(
              buffer.asUint8List(),
            ),
          ),
        );
        headerSent = true;
      }
      while (blob.size >= (chunkSize + 17)) {
        final length = chunkSize + 17;
        final data = blob.slice(0, length);
        blob = blob.slice(length);
        final buffer = await promiseToFuture<ByteBuffer>(
            await callMethod(data, 'arrayBuffer', []));

        streamCtrl.add(
          SecretStreamCipherMessage(
            Uint8List.fromList(
              buffer.asUint8List(),
            ),
          ),
        );
      }

      if (downloadedLength == totalDownloadLength) {
        // Last block
        final buffer = await promiseToFuture<ByteBuffer>(
            await callMethod(blob, 'arrayBuffer', []));

        streamCtrl.add(
          SecretStreamCipherMessage(
            Uint8List.fromList(
              buffer.asUint8List(),
            ),
            // additionalData:
          ),
        );

        await progressSub?.cancel();
        await streamCtrl.close();
        completer.complete(true);
      }
    },
    onDone: () async {},
    onError: (e) {
      progressSub?.cancel();
      // TODO Handle error
    },
    cancelOnError: true,
  );

  return transformer.map((event) => Blob([event.message]));
}

Future<EncryptAndUploadResponse> encryptAndUploadFileInChunks(
  Stream<Uint8List> stream,
  String fileMultiHash, {
  required int totalSize,
  required SkynetClient client,
  required Sodium sodium,
  required Function(double) onProgress,
}) async {
  final secretKey = sodium.crypto.secretStream.keygen();

  int internalSize = 0;

  var padding = padFileSize(totalSize) - totalSize;

  final lastChunkSize = totalSize % maxChunkSize;

  if ((padding + lastChunkSize) >= maxChunkSize) {
    padding = maxChunkSize - lastChunkSize;
  }

  print('padding: $padding | ${lastChunkSize} | ${totalSize}');

  final encryptedLength =
      ((totalSize / maxChunkSize).floor() * (maxChunkSize + 16)) +
          lastChunkSize +
          16 +
          padding;

  int i = 0;

  final outStream = stream.map((event) {
    internalSize += event.length;
    final isLastChunk = internalSize == totalSize;

    final nonce = Uint8List.fromList(
      encodeEndian(i, sodium.crypto.secretBox.nonceBytes,
          endianType: EndianType.littleEndian) as List<int>,
    );
    i++;

    final res = sodium.crypto.secretBox.easy(
      message:
          isLastChunk ? Uint8List.fromList(event + Uint8List(padding)) : event,
      nonce: nonce,
      key: secretKey,
    );
    return res;
  });

  onProgress(0);

  if (encryptedLength > TUS_CHUNK_SIZE) {
    final tusClient = SkynetTusClientWeb(
      Uri.https(client.portalHost, '/skynet/tus'),
      skynetClient: client,
      maxChunkSize: TUS_CHUNK_SIZE,
      streamFileLength: encryptedLength,
      filename: 'fs-dac.hns',
      headers: client.headers,
    );

    var totalEncryptedSize = 0;
    final result = await tusClient.upload(
      outStream.map((event) {
        totalEncryptedSize += event.length;

        return Blob([event]);
      }),
      onProgress: onProgress,
    );

    return EncryptAndUploadResponse(
      blobUrl: 'sia://$result',
      secretKey: secretKey.extractBytes(),
      maxChunkSize: maxChunkSize,
      padding: padding,
      encryptionType: 'libsodium_secretbox',
    );
  } else {
    final result = await client.upload.uploadFileWithStream(
      SkyFile(
        content: Uint8List(0),
        filename: 'fs-dac.hns',
        type: 'application/octet-stream',
      ),
      encryptedLength,
      outStream,
    );
    onProgress(1);
    return EncryptAndUploadResponse(
      blobUrl: 'sia://$result',
      secretKey: secretKey.extractBytes(),
      maxChunkSize: maxChunkSize,
      padding: padding,
      encryptionType: 'libsodium_secretbox',
    );
  }
}

Future<EncryptAndUploadResponse> encryptAndUploadFileDeprecated(
  Stream<Uint8List> stream,
  String fileMultiHash, {
  required int length,
  required SkynetClient client,
  required Sodium sodium,
  required Function(double) onProgress,
}) async {
  final secretKey = sodium.crypto.secretStream.keygen();

  int internalSize = 0;

  final encryptedLength = length + 24 + (length / maxChunkSize).ceil() * 17;

  final outStream = sodium.crypto.secretStream.pushEx(
    messageStream: stream.map((event) {
      internalSize += event.length;

      return SecretStreamPlainMessage(
        event,
        tag: internalSize == length
            ? SecretStreamMessageTag.finalPush
            : SecretStreamMessageTag.message,
      );
    }),
    key: secretKey,
  );

  onProgress(0);

  if (encryptedLength > TUS_CHUNK_SIZE) {
    final tusClient = SkynetTusClientWeb(
      Uri.https(client.portalHost, '/skynet/tus'),
      skynetClient: client,
      maxChunkSize: TUS_CHUNK_SIZE,
      streamFileLength: encryptedLength,
      filename: 'fs-dac.hns',
      headers: client.headers,
    );

    int totalEncryptedSize = 0;
    final result = await tusClient.upload(
      outStream.map((event) {
        totalEncryptedSize += event.message.length;

        return Blob([event.message]);
      }),
      onProgress: onProgress,
    );

    return EncryptAndUploadResponse(
      blobUrl: 'sia://$result',
      secretKey: secretKey.extractBytes(),
      maxChunkSize: maxChunkSize,
      padding: 0,
      encryptionType: 'AEAD_XCHACHA20_POLY1305',
    );
  } else {
    final result = await client.upload.uploadFileWithStream(
      SkyFile(
        content: Uint8List(0),
        filename: 'fs-dac.hns',
        type: 'application/octet-stream',
      ),
      encryptedLength,
      outStream.map((event) {
        return event.message;
      }),
    );
    onProgress(1);
    return EncryptAndUploadResponse(
      blobUrl: 'sia://$result',
      secretKey: secretKey.extractBytes(),
      maxChunkSize: maxChunkSize,
      padding: 0,
      encryptionType: 'AEAD_XCHACHA20_POLY1305',
    );
  }
}
