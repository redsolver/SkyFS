import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:filesystem_dac/cache/base.dart';
import 'package:filesystem_dac/cache/hive.dart';
import 'package:filesystem_dac/model/cached_entry.dart';
import 'package:filesystem_dac/model/utils.dart';
import 'package:hive/hive.dart';
import 'package:lib5/constants.dart';
import 'package:lib5/lib5.dart';
import 'package:lib5/registry.dart';
import 'package:lib5/src/crypto/encryption/chunk.dart';
import 'package:lib5/src/crypto/encryption/mutable.dart';
import 'package:lib5/util.dart';
import 'package:mime_type/mime_type.dart';
import 'package:minio/minio.dart';
import 'package:path/path.dart';
import 'package:pool/pool.dart';
import 'package:retry/retry.dart';
import 'package:stash/stash_api.dart';
import 'package:state_notifier/state_notifier.dart';
import 'package:universal_platform/universal_platform.dart';
import 'package:uuid/uuid.dart';
import 'package:webdav_client/webdav_client.dart' as webdav;

const DATA_DOMAIN = 'fs-dac.hns';

const maxChunkSize = 256 * 1024; // 256 KiB

const ENCRYPTION_KEY_TWEAK = 1;

// ! IMPORTANT
// ! paths allow ALL characters excluding /
// ! URIs encode characters and support specifying file versions and query parameters!

// ! This is a hard-coded list of trusted domains which get full root access to the FS DAC automatically.
// ! This list will be removed as soon as custom permissions are supported in MySky or Skynet kernel
const domainsWithRootAccess = [
  'localhost', // for testing
  'riftapp.hns', // Rift
  '0406ptsm1pe4ttrbi5mhqi10oa2he7m2g4bliqdeh3jq8ska82n7hko', // Manga and Comic Reader
  '0406e2nbv19c090gc6iegfuujhoepfo66i2tafh24t3gjf6rm8eq4e0', // SkySend v4 Beta
  '0406jckksspiqk11ivr641v1q09paul9bufdufl4svm50kjutvvjio8', // encrypted image gallery
];

// List of image extensions supported for advanced metadata extraction and thumbnail generation
const supportedImageExtensions = [
  '.jpg',
  '.jpeg',
  '.jpe',
  '.jif',
  '.jfif',
  '.jfi',
  '.png',
  '.gif',
  '.tga',
  '.icb',
  '.vda',
  '.vst',
  '.ico',
  '.bmp',
  '.dib',
  '.webp',
  '.tiff',
  '.tif',
  '.psd',
  '.exr'
];

const supportedAudioExtensionsForPlayback = [
  '.mp3',
  '.flac',
  '.m4a',
  '.wav',
  '.wave',
];

const supportedVideoExtensionsForFFmpeg = [
  '.mkv',
  '.mp4',
  '.webm',
  '.mov',
  '.avi',
  '.wmv',
];

const metadataSupportedExtensions = [
  '.mp3',
  '.flac',
  ...supportedImageExtensions,
];

// const metadataMaxFileSize = 4 * 1000 * 1000;

/* Future<List> extractMetadata(List list) async {
  String extension = list[0].toLowerCase();
  Uint8List bytes = list[1];
  String rootPathSeed = list[2];

  List more = [];

  bool hasThumbnail = true;

  Map<String, dynamic>? ext;

  if (extension == 'video-thumbnail') {
    final hash = sha256.convert(bytes);

    final key = deriveThumbnailKey(hash, rootPathSeed);

    ext ??= {};

    ext['video'] ??= {};
    ext['video']['coverKey'] ??= key;
    more.add(bytes);

    hasThumbnail = true;
  }

  if (extension == '.mp3') {
    final mp3instance = MP3Instance(bytes);

    try {
      if (mp3instance.parseTagsSync()) {
        ext = {};
        final tags = mp3instance.getMetaTags();
        ext['mp3'] = tags;
        if (tags!.containsKey('APIC')) {
          final apic = tags.remove('APIC');
          ext['mp3'].remove('APIC');
          final pictureBytes = base64.decode(apic['base64']);

          final hash = sha256.convert(pictureBytes);

          final key = deriveThumbnailKey(hash, rootPathSeed);

          ext['audio'] = {};
          ext['audio']['coverKey'] = key;
          more.add(pictureBytes);

          bytes = pictureBytes;
          hasThumbnail = true;
        }
        if (tags.containsKey('Genre')) {
          if (tags['Genre'].startsWith('(')) {
            ext['mp3']['Genre'] =
                tags['Genre'].substring(tags['Genre'].indexOf(')') + 1);
          }
        }
      }
    } catch (e, st) {
      print(e);
      print(st);
    }
  } else if (extension == '.flac') {
    var flac = FlacInfo(bytes.toList());
    try {
      var metadatas = await flac.readMetadatas();
      if (metadatas.isNotEmpty) {
        ext = {};
        ext['flac'] = {};
      }
      for (final m in metadatas) {
        if (m is VorbisComment) {
          for (final comment in m.comments) {
            final div = comment.indexOf('=');
            final key = comment.substring(0, div);
            final value = comment.substring(div + 1);
            ext!['flac'][key] = value;
          }
        } else if (m is Picture) {
          final hash = sha256.convert(m.image);

          final key = deriveThumbnailKey(hash, rootPathSeed);

          ext!['audio'] = {};
          ext['audio']['coverKey'] = key;

          more.add(m.image);

          bytes = m.image;
          hasThumbnail = true;
        }
      }
    } catch (e, st) {
      print(e);
      print(st);
    }
  }
  if (ext?['mp3'] != null) {
    final map = {
      'Title': 'title',
      'Artist': 'artist',
      'Album': 'album',
      'Track': 'track',
      'Year': 'date',
      'Genre': 'genre',
      'ISRC': 'isrc',
      // 'cover': 'cover',
    };
    ext!['audio'] ??= {};
    for (final key in map.keys) {
      if (ext['mp3'].containsKey(key)) {
        ext['audio'][map[key]] = ext['mp3'][key];
      }
    }
    if (ext['mp3'].containsKey('COMM')) {
      try {
        final Map map = ext['mp3']['COMM'];
        final String comment = map.values.first.values.first;
        ext['audio']['comment'] = comment;
      } catch (_) {}
    }
  } else if (ext?['flac'] != null) {
    final map = {
      'TITLE': 'title',
      'ARTIST': 'artist',
      'ALBUM': 'album',
      'TRACKNUMBER': 'track',
      'DATE': 'date',
      'GENRE': 'genre',
      'COMMENT': 'comment',
      'ISRC': 'isrc',
      // 'cover': 'cover',
    };
    ext!['audio'] ??= {};
    for (final key in map.keys) {
      if (ext['flac'].containsKey(key)) {
        ext['audio'][map[key]] = ext['flac'][key];
      }
    }
  }
  if (ext?['audio']?['isrc'] != null) {
    ext!['audio']['isrc'] = ext['audio']['isrc'].trim();
  }

  // TODO audio length on web (use ffmpeg)

  ext?.remove('mp3');
  ext?.remove('flac');

  if (hasThumbnail || supportedImageExtensions.contains(extension)) {
    try {
      var thumbnail = img.decodeImage(bytes);
      if (thumbnail != null) {
        ext ??= {};

        /*  if (!hasThumbnail) {
          ext['image'] = {
            'width': image.width,
            'height': image.height,
          };
        }
 */
        // Resize the image to a 200x? thumbnail (maintaining the aspect ratio).
        /*   final thumbnail = image.width > image.height
            ? img.copyResize(
                image,
                height: 200,
              )
            : img.copyResize(
                image,
                width: 200,
              ); */ // TODO Adjust, maybe use boxFit: cover

        final thumbnailBytes = img.encodeJpg(thumbnail, quality: 80);

        final hash = sha256.convert(thumbnailBytes);

        final key = deriveThumbnailKey(hash, rootPathSeed);
        ext['thumbnail'] = {
          'key': key,
          'aspectRatio': (thumbnail.width / thumbnail.height) + 0.0,
          'blurHash': BlurHash.encode(
            thumbnail,
            numCompX: 5, // TODO Aspect-ratio
            numCompY: 5,
          ).hash,
        };
        more.add(Uint8List.fromList(thumbnailBytes));
        /* try {
          if (!hasThumbnail) {
            Map<String, IfdTag> data = await readExifFromBytes(bytes);
            if (data.isNotEmpty) {
              ext['exif'] =
                  data.map((key, value) => MapEntry(key, value.printable));
            }
          }
        } catch (e) {} */
      }
    } catch (e, st) {
      print(e);
      print(st);
    }
  }

  return <dynamic>[
        json.encode(ext),
      ] +
      more;
} */

Map<String, String> temporaryThumbnailKeyPaths = {};

/* String deriveThumbnailKey(Digest hash, String rootPathSeed) {
  final path =
      '${DATA_DOMAIN}/encrypted-thumbnails-1/${base64Url.encode(hash.bytes)}';

  final pathSeed = deriveEncryptedPathSeed(
    rootPathSeed,
    path,
    false,
  );

  final key = base64Url.encode(hex.decode(pathSeed));

  if (UniversalPlatform.isWeb) {
    temporaryThumbnailKeyPaths[key] = DATA_DOMAIN + '/' + path;
  }

  return key;
} */

typedef DirectoryOperationMethod = Future Function(
  DirectoryMetadata directory,
  Uint8List writeKey,
);

class FileSystemDAC {
  final HiddenDBProvider hiddenDB;
  final S5APIProvider api;
  CryptoImplementation get crypto => api.crypto;

  late final DirectoryMetadataCache dirCache;

  // TODO Clear
  final Uint8List fsRootKey;

  late final String skapp;

  late final bool rootAccessEnabled;

  late final Box<Uint8List> deletedSkylinks;
  // late final LazyBox<Uint8List> thumbnailCache;
  late final Cache<Uint8List> thumbnailCache;

  final _fileStateChangeNotifiers = <Multihash, FileStateNotifier>{};
  final _directoryIndexChangeNotifiers =
      <Multihash, DirectoryMetadataChangeNotifier>{};

  final _uploadingFilesChangeNotifiers =
      <String, UploadingFilesChangeNotifier>{};

  final bool debugEnabled;

  late Uint8List thumbnailRootSeed;
  late Uint8List filesystemRootKey;

  FileSystemDAC({
    required this.api,
    required this.hiddenDB,
    required this.skapp,
    required this.fsRootKey,
    this.onLog,
    this.debugEnabled = false,
    required this.thumbnailCache,
  });

  Future<void> initSeed() async {
    filesystemRootKey = deriveHashBlake3Int(
      fsRootKey,
      1,
      crypto: crypto,
    );
    thumbnailRootSeed = deriveHashBlake3Int(
      fsRootKey,
      2,
      crypto: crypto,
    );
  }

  FileStateNotifier getFileStateChangeNotifier(Multihash hash) {
    // TODO Use a cross-process implementation (Not Hive)
    // TODO Permission limits when exposing to web
    if (!_fileStateChangeNotifiers.containsKey(hash)) {
      _fileStateChangeNotifiers[hash] = FileStateNotifier();
    }
    return _fileStateChangeNotifiers[hash]!;
  }

  DirectoryMetadataChangeNotifier getDirectoryMetadataChangeNotifier(
    Multihash uriHash, {
    String? path, // TODO Require this when exposed to web
  }) {
    if (path != null) {
      validateAccess(
        parsePath(path),
        read: true,
        write: false,
      );
    }
    if (!_directoryIndexChangeNotifiers.containsKey(uriHash)) {
      _directoryIndexChangeNotifiers[uriHash] =
          DirectoryMetadataChangeNotifier();
    }
    return _directoryIndexChangeNotifiers[uriHash]!;
  }

  UploadingFilesChangeNotifier getUploadingFilesChangeNotifier(
    String path,
  ) {
    validateAccess(
      parsePath(path),
      read: true,
      write: false,
    );
    if (!_uploadingFilesChangeNotifiers.containsKey(path)) {
      _uploadingFilesChangeNotifiers[path] = UploadingFilesChangeNotifier();
    }
    return _uploadingFilesChangeNotifiers[path]!;
  }

  Map<String, UploadingFilesChangeNotifier>
      getAllUploadingFilesChangeNotifiers() {
    return _uploadingFilesChangeNotifiers;
  }

  Future<void> init(
      {bool devEnabled = false, bool inMemoryOnly = false}) async {
    rootAccessEnabled =
        !UniversalPlatform.isWeb || domainsWithRootAccess.contains(skapp);
    log('rootAccessEnabled $rootAccessEnabled');
    final opts = {
      'dev': devEnabled,
    };

    // TODO Enable for web
    /* await mySkyProvider.load(
      DATA_DOMAIN,
      options: opts,
    ); */

    if (UniversalPlatform.isWeb) {
      if (inMemoryOnly) {
        dirCache = HiveDirectoryMetadataCache(await Hive.openBox<Uint8List>(
          's5fs-directory-metadata-cache',
          bytes: Uint8List(0),
        ));

        deletedSkylinks = await Hive.openBox<Uint8List>(
          's5fs-cids-to-unpin',
          bytes: Uint8List(0),
        );
      } else {
        // TODO Implement
        throw UnimplementedError();
        /*  directoryIndexCache = await Hive.openBox<CachedEntry>(
          'fs-dac-directory-index-cache',
        ); */

      }
    } else {
      dirCache = HiveDirectoryMetadataCache(await Hive.openBox<Uint8List>(
        's5fs-directory-metadata-cache',
      ));

      deletedSkylinks = await Hive.openBox<Uint8List>(
        's5fs-cids-to-unpin',
      );
    }
  }

  Future<void> onUserLogin() async {
    log('onUserLogin');

    await initSeed();

    loadMounts();

    Stream.periodic(Duration(minutes: 10)).listen((event) {
      loadMounts();
    });

    loadRemotes();

    Stream.periodic(Duration(minutes: 20)).listen((event) {
      loadRemotes();
    });

    log('createRootDirectory $skapp [skapp: $skapp]');

    await doOperationOnDirectory(
      Uri.parse('skyfs://root'),
      (directoryIndex, writeKey) async {
        bool doUpdate = false;

        if (!directoryIndex.directories.containsKey('home')) {
          directoryIndex.directories['home'] =
              await _createDirectory('home', writeKey);

          doUpdate = true;
        }

        if (!directoryIndex.directories.containsKey(skapp)) {
          directoryIndex.directories[skapp] =
              await _createDirectory(skapp, writeKey);
          doUpdate = true;
        }

        if (!directoryIndex.directories.containsKey('vup.hns')) {
          directoryIndex.directories['vup.hns'] =
              await _createDirectory('vup.hns', writeKey);
          doUpdate = true;
        }

        return doUpdate;
      },
    );

    doOperationOnDirectory(
      Uri.parse('skyfs://root/vup.hns'),
      (directoryIndex, writeKey) async {
        bool doUpdate = false;

        if (!directoryIndex.directories
            .containsKey('shared-static-directories')) {
          directoryIndex.directories['shared-static-directories'] =
              await _createDirectory('shared-static-directories', writeKey);
          doUpdate = true;
        }
        if (!directoryIndex.directories.containsKey('shared-with-me')) {
          directoryIndex.directories['shared-with-me'] =
              await _createDirectory('shared-with-me', writeKey);
          doUpdate = true;
        }

        return doUpdate;
      },
    );
  }

  Future<DirectoryReference> _createDirectory(
      String name, Uint8List writeKey) async {
    final newWriteKey = crypto.generateRandomBytes(32);

    final keys = await deriveKeysFromWriteKey(newWriteKey);

    final nonce = crypto.generateRandomBytes(24);

    final encryptedWriteKey = await crypto.encryptXChaCha20Poly1305(
      key: writeKey,
      nonce: nonce,
      plaintext: newWriteKey,
    );

    return DirectoryReference(
      created: nowTimestamp(),
      name: name,
      encryptedWriteKey: Uint8List.fromList([0x01] + nonce + encryptedWriteKey),
      publicKey: keys.keyPair.publicKey,
      encryptionKey: keys.encryptionKey,
    );
  }

  Uri parsePath(String path, {bool resolveMounted = true}) {
    Uri uri;

    if (path.startsWith('skyfs://')) {
      uri = Uri.parse(path);
    } else {
      final list = path
          .split('/')
          .map((e) => e.trim())
          .where((element) => element.isNotEmpty)
          .toList();

      uri = Uri(
        scheme: 'skyfs',
        host: 'root',
        pathSegments: list,
      );
    }
    // TODO consider additional permission checks for mounted directories
    if (resolveMounted) {
      final uriStr = uri.toString();
      for (final mount in mounts.keys) {
        final mountUri = mount;
        if (uriStr == mountUri || uriStr.startsWith(mountUri + '/')) {
          validateAccess(
            parsePath(path, resolveMounted: false),
            read: true,
            write: false,
          );
          final pathSuffix = uri.toString().substring(mountUri.length);
          final mUri = mounts[mount]!['uri'];
          return Uri.parse('$mUri$pathSuffix');
        }
      }
    }

    return uri;
  }

  final _mountsPath = 'fs-dac.hns/fs-dac.hns/mounts.json';

  late HiddenJSONResponse _lastMountsResponse;

  var mounts = <String, Map>{};

  Future<void> loadMounts() async {
    // TODO Implement
    /*  log('> loadMounts');
    try {
      _lastMountsResponse = await mySkyProvider.getJSONEncrypted(
        _mountsPath,
      );
      mounts = (_lastMountsResponse.data ?? {}).cast<String, Map>();
      // ignore: unawaited_futures
      directoryIndexCache.put(
        _mountsPath,
        CachedEntry(
          revision: _lastMountsResponse.revision,
          data: json.encode(mounts),
          skylink: _lastMountsResponse.skylink,
        ),
      );
    } catch (e, st) {
      log('[loadMounts] $e $st');
      final cached = directoryIndexCache.get(_mountsPath);
      if (cached != null) {
        mounts = json.decode(cached.data).cast<String, Map>();
      }
    }
    log('< loadMounts'); */
  }

  Future<void> saveMounts() async {
    // TODO Implement
/*     log('> saveMounts');
    await mySkyProvider.setJSONEncrypted(
      _mountsPath,
      mounts,
      _lastMountsResponse.revision + 1,
    );

    // ignore: unawaited_futures
    directoryIndexCache.put(
      _mountsPath,
      CachedEntry(
        revision: _lastMountsResponse.revision,
        data: json.encode(mounts),
        skylink: null, // TODO Store skylink
      ),
    );
    log('< saveMounts'); */
  }

  Future<void> mountUri(
    String path,
    Uri uri, {
    Map<String, dynamic> extMap = const {},
  }) async {
    final localUri = parsePath(path);
    validateAccess(
      localUri,
      read: true,
      write: true,
    );

    final localNonMountedUriStr =
        parsePath(path, resolveMounted: false).toString();

    for (final mountPoint in mounts.keys) {
      if (mountPoint == localNonMountedUriStr) {
        throw 'There is already a mount point at $mountPoint';
      }

      if (mountPoint.startsWith('$localNonMountedUriStr/')) {
        throw 'There is already a higher mount point at $mountPoint';
      }

      if (localNonMountedUriStr.startsWith('$mountPoint/')) {
        throw 'There is already a deeper mount point at $mountPoint';
      }
    }

    final localUriStr = localUri.toString();

    validateAccess(
      uri,
      read: true,
      write: false,
    );
    log('mountUri $localUri $uri');
    await loadMounts();

    if (mounts.containsKey(localUriStr))
      throw 'This path is already used as a mount point';

    mounts[localUriStr] = {
      'uri': uri.toString(),
      'created': DateTime.now().millisecondsSinceEpoch,
      'ext': extMap,
    };
    log('mounts $mounts');

    await saveMounts();
  }

  Future<void> unmountUri(String path) async {
    final localUri = parsePath(path, resolveMounted: false);
    log('unmountUri $localUri');
    validateAccess(
      localUri,
      read: true,
      write: true,
    );

    await loadMounts();

    if (!mounts.containsKey(localUri.toString()))
      throw 'This path is not used as a mount point';

    mounts.remove(localUri.toString());
    log('mounts $mounts');

    await saveMounts();
  }

  String getPathHost(String path) {
    final localUri = parsePath(
      path, /* resolveMounted: false */
    );
    validateAccess(
      localUri,
      read: true,
      write: false,
    );

    return localUri.host;
  }

  final _remotesPath = 'fs-dac.hns/fs-dac.hns/remotes.json';

  late HiddenJSONResponse _lastRemotesResponse;

  var customRemotes = <String, Map>{};

  final _webDavClientCache = <String, webdav.Client>{};

  Future<void> loadRemotes() async {
    // TODO Implement
    return;
/*     log('> loadRemotes');
    try {
      _lastRemotesResponse = await mySkyProvider.getJSONEncrypted(
        _remotesPath,
      );
      customRemotes = (_lastRemotesResponse.data ?? {}).cast<String, Map>();
      // ignore: unawaited_futures
      directoryIndexCache.put(
        _remotesPath,
        CachedEntry(
          revision: _lastRemotesResponse.revision,
          data: json.encode(customRemotes),
          skylink: _lastRemotesResponse.skylink,
        ),
      );
    } catch (e, st) {
      log('[loadRemotes] $e $st');
      final cached = directoryIndexCache.get(_remotesPath);
      if (cached != null) {
        customRemotes = json.decode(cached.data).cast<String, Map>();
      }
    }
    log('< loadRemotes'); */
  }

  Future<void> saveRemotes() async {
    // TODO Implement

    /*    log('> saveRemotes');
    await mySkyProvider.setJSONEncrypted(
      _remotesPath,
      customRemotes,
      _lastRemotesResponse.revision + 1,
    );

    // ignore: unawaited_futures
    directoryIndexCache.put(
      _remotesPath,
      CachedEntry(
        revision: _lastRemotesResponse.revision,
        data: json.encode(customRemotes),
        skylink: null, // TODO Store skylink
      ),
    );
    log('< saveRemotes'); */
  }

  void setFileState(Multihash hash, FileState state) {
    // log('setFileState $hash $state');
    // runningTasks
    getFileStateChangeNotifier(hash).updateFileState(state);
  }

  void setDirectoryState(String path, FileState state) {
    getDirectoryStateChangeNotifier(path).updateFileState(state);
  }

  FileStateNotifier getDirectoryStateChangeNotifier(String path) {
    return getFileStateChangeNotifier(
      Multihash(
        crypto.hashBlake3Sync(
          Uint8List.fromList(utf8.encode(path)),
        ),
      ),
    );
  }

  // TODO minimum delay of 200 milliseconds

  Map<Uri, Pool> directoryOperationPools = {};

  Map<Uri, List<DirectoryOperationTask>> directoryOperationsQueue = {};

  Future<DirectoryOperationTaskResult> doOperationOnDirectory(
    Uri uri,
    DirectoryOperationMethod operation,
  ) async {
    directoryOperationsQueue.putIfAbsent(uri, () => []);
    directoryOperationPools.putIfAbsent(uri, () => Pool(1));

    final completer = Completer<DirectoryOperationTaskResult>();
    directoryOperationsQueue[uri]!.add(
      DirectoryOperationTask(
        completer,
        operation,
      ),
    );
    directoryOperationPools[uri]!.withResource(
      () => doOperationsOnDirectoryInternal(
        uri,
      ),
    );

    return completer.future;
  }

  void validateFileSystemEntityName(String name) {
    if (name.contains('/')) {
      throw 'Invalid name: Contains slash';
    } else if (name.isEmpty) {
      throw 'Invalid name: Is Empty';
    }
  }

  Future<void> doOperationsOnDirectoryInternal(
    Uri uri,
  ) async {
    final uriHash = convertUriToHashForCache(uri);
    final res = await getDirectoryMetadataWithUri(uri, uriHash);

    final directoryIndex = res
        .data; /* ??
        DirectoryMetadata(
          details: DirectoryMetadataDetails({}),
          directories: {},
          files: {},
          extraMetadata: ExtraMetadata({}),
        ) */

    if (!UniversalPlatform.isWeb) {
      populateUris(uri, directoryIndex);
    }

    final tasks = <DirectoryOperationTask>[];

    while (directoryOperationsQueue[uri]!.isNotEmpty) {
      final op = directoryOperationsQueue[uri]!.removeAt(0);
      tasks.add(op);
    }

    var doUpdate = false;

    log('[dirIndex] process ${tasks.length} tasks');

    for (final task in tasks) {
      try {
        final r = await task.operation(directoryIndex, res.writeKey!);
        if (r != false) {
          doUpdate = true;
        }
      } catch (e) {
        task.completer.complete(
          DirectoryOperationTaskResult(
            false,
            error: e.toString(),
          ),
        );
      }
    }
    log('doUpdate $doUpdate');

    CID? newCID;

    var result = DirectoryOperationTaskResult(true);
    if (doUpdate) {
      final cipherText = await encryptMutableBytes(
        directoryIndex.serialize(),
        res.encryptionKey!,
        crypto: crypto,
      );

      final cid = await api.uploadRawFile(cipherText);

      if (uri.host == 'root') {
        final kp = await crypto.newKeyPairEd25519(seed: res.secretKey!);

        final sre = await signRegistryEntry(
          kp: kp,
          data: cid.toRegistryEntry(),
          revision: res.revision + 1,
          crypto: crypto,
        );

        await api.registrySet(sre);

        // TODO Check updated

        newCID = cid;

        result = DirectoryOperationTaskResult(true);
      } else {
        throw UnimplementedError();
        /*  final userInfo = uri.userInfo;

        final skynetUser = await _getSkynetUser(userInfo);
        final path = [...uri.pathSegments, 'index.json'].join('/');

        final newRes = await mysky_io_impl.setEncryptedJSON(
          skynetUser,
          path,
          directoryIndex,
          res.revision + 1,
          skynetClient: client,
        );

        newSkylink = newRes.skylink;

        result = DirectoryOperationTaskResult(true); */
      }
      if (res.cid != null) {
        deletedSkylinks.add(res.cid!.toBytes());
      }
    }
    for (final task in tasks) {
      if (!task.completer.isCompleted) {
        task.completer.complete(result);
      }
    }

    // TODO Why?
    if (uri.pathSegments.isEmpty) return;

    if (doUpdate) {
      getDirectoryMetadataChangeNotifier(
        uriHash,
      ).updateDirectoryMetadata(directoryIndex);

      dirCache.set(
        uriHash,
        CachedDirectoryMetadata(
          data: directoryIndex,
          revision: res.revision + 1,
          cid: newCID!,
        ),
      );
    }
  }

  String uriPathToMySkyPath(List<String> pathSegments) {
    return [...pathSegments, 'index.json'].join('/');
  }

  bool checkAccess(
    String path, {
    bool read = true,
    bool write = true,
  }) {
    final uri = parsePath(path);
    try {
      validateAccess(
        uri,
        read: read,
        write: write,
      );
      return true;
    } catch (_) {}
    return false;
  }

  Future<DirectoryMetadata> getAllFiles({
    String startDirectory = '',
    required bool includeFiles,
    required bool includeDirectories,
  }) async {
    validateAccess(
      parsePath(startDirectory),
      read: true,
      write: false,
    );
    /*    if (!rootAccessEnabled) {
      throw 'Permission denied';
    } */

    final result = DirectoryMetadata(
      details: DirectoryMetadataDetails({}),
      directories: {},
      files: {},
      extraMetadata: ExtraMetadata({}),
    );
    Future<void> processDirectory(String path) async {
      final dir =
          getDirectoryMetadataCached(path) ?? await getDirectoryMetadata(path);

      // print('processDirectory $path ${dir.files.keys.length}');

      for (final subDir in dir.directories.keys) {
        if (subDir.isNotEmpty) {
          final childUri = getChildUri(parsePath(path), subDir);
          await processDirectory(childUri.toString());
          if (includeDirectories) {
            result.directories[childUri.toString()] = dir.directories[subDir]!;
          }
        }
      }
      if (includeFiles) {
        for (final key in dir.files.keys) {
          final uri = getChildUri(parsePath(path), key);
          result.files[uri.toString()] = dir.files[key]!;
        }
      }
    }

    await processDirectory(startDirectory);

    return result;
  }

  void validateAccess(
    Uri uri, {
    bool read = true,
    bool write = true,
  }) {
    if (uri.host == 'root') {
      if (rootAccessEnabled) {
        return;
      }

      if (uri.pathSegments.length < 1) {
        throw 'Access denied, path too short';
      }

      /* if (uri.pathSegments[0] != DATA_DOMAIN) {
        throw 'Internal permission error';
      } */

      if (uri.pathSegments[0] != skapp) {
        throw 'Access denied.';
      }
    } else if (uri.host == 'shared-readonly') {
      if (write) {
        throw 'Can\'t write to read-only shared directories or files';
      }
    } else {
      if (uri.userInfo.startsWith('r:') || uri.host == 'remote') {
        if (write) {
          throw 'Can\'t write to read-only shared directories or files';
        }
      } else if (uri.userInfo.startsWith('rw:')) {
      } else {
        throw 'URI not supported (you might be using a deprecated format) $uri';
      }
    }
  }

  int nowTimestamp() {
    return DateTime.now().millisecondsSinceEpoch;
  }

  Multihash convertUriToHashForCache(Uri uri) {
    if (uri.pathSegments.isEmpty) {
      return Multihash(Uint8List.fromList(
        [mhashBlake3Default] +
            crypto.hashBlake3Sync(
                (Uint8List.fromList(utf8.encode(uri.toString())))),
      ));
    }
    final dir = getDirectoryMetadataCached(
      uri
          .replace(
            pathSegments:
                uri.pathSegments.sublist(0, uri.pathSegments.length - 1),
          )
          .toString(),
    );
    ;
    return Multihash(dir!.directories[uri.pathSegments.last]!.publicKey);
  }

  DirectoryMetadata? getDirectoryMetadataCached(String rawPath) {
    final uri = parsePath(rawPath);
    final uriHash = convertUriToHashForCache(uri);
    // TODO Permission checks

    if (dirCache.has(uriHash)) {
      final cachedDir = dirCache.get(uriHash)!.data;

      if (!UniversalPlatform.isWeb) {
        populateUris(uri, cachedDir);
      }

      return cachedDir;
    }
  }

  void populateUris(Uri currentUri, DirectoryMetadata di) {
    for (final key in di.files.keys) {
      di.files[key]!.key = key;

      di.files[key]!.uri ??= key.startsWith('skyfs://')
          ? key
          : getChildUri(currentUri, key).toString();
    }

    for (final key in di.directories.keys) {
      di.directories[key]!.key = key;

      di.directories[key]!.uri ??= key.startsWith('skyfs://')
          ? key
          : getChildUri(currentUri, key).toString();
    }
  }

  Future<DirectoryMetadata> getDirectoryMetadata(String path) async {
    final parsedPath = parsePath(path);
    log('getDirectoryMetadata $parsedPath');

    validateAccess(
      parsedPath,
      read: true,
      write: false,
    );

    late DirectoryMetadata di;

    if (parsedPath.queryParameters.containsKey('recursive')) {
      final type = parsedPath.queryParameters['type'] ?? '*';
      di = await getAllFiles(
        startDirectory: Uri(
          host: parsedPath.host,
          path: parsedPath.path,
          scheme: parsedPath.scheme,
          userInfo: parsedPath.userInfo,
        ).toString(),
        includeFiles: type != 'directory',
        includeDirectories: type != 'file',
      );
    } else {
      di = await _getDirectoryMetadataInternal(parsedPath);
    }

    if (parsedPath.queryParameters.isNotEmpty) {
      if (parsedPath.queryParameters.containsKey('q')) {
        // final filter = json.decode(parsedPath.queryParameters['filter']!);

        // ignore: omit_local_variable_types
        final List<List<String>> queryBy =
            (parsedPath.queryParameters['query_by'] ?? 'name')
                .split(',')
                .map((e) => e.trim().split('.').toList())
                .toList();

        log('queryBy $queryBy');

        final searchQuery = parsedPath.queryParameters['q']!
            .toLowerCase()
            .split(' ')
            .where((element) =>
                element.isNotEmpty &&
                !(element.startsWith('-') && element.length < 2))
            .toList();

        searchQuery.sort((a, b) => a.compareTo(b));

        bool shouldRemove(dynamic value) {
          for (final queryByField in queryBy) {
            dynamic val = value.toJson();
            for (final key in queryByField) {
              val = val[key] ?? {};
            }

            final newVal = val.toString().toLowerCase();

            for (final qPart in searchQuery) {
              if (qPart.startsWith('-')) {
                if (newVal.contains(qPart.substring(1))) {
                  return true;
                }
              } else {
                if (!newVal.contains(qPart)) {
                  return true;
                }
              }
            }
          }
          return false;

          // !value.name.toLowerCase().contains(searchQuery)
        }

        di.files.removeWhere(
          (key, value) => shouldRemove(value),
        );

        di.directories.removeWhere(
          (key, value) => shouldRemove(value),
        );
      }
    }

    if (!UniversalPlatform.isWeb) {
      populateUris(parsedPath, di);
    }

    return di;
  }

  String _removeTrailingSlash(String s) {
    if (s.endsWith('/')) {
      return s.substring(0, s.length - 1);
    }
    return s;
  }

  final privateKeyCache = <Uri, Uint8List>{};

  Future<Uint8List> getPrivateKeyForDirectory(Uri uri) async {
    if (uri.host != 'root') {
      throw 'Unsupported URI (host)';
    }
    if (privateKeyCache.containsKey(uri)) {
      return privateKeyCache[uri]!;
    }

    if (uri.pathSegments.isEmpty) {
      return filesystemRootKey;
    }

    final parentUri = uri.replace(
      pathSegments: uri.pathSegments.sublist(0, uri.pathSegments.length - 1),
    );

    final parentKeyBytes = await getPrivateKeyForDirectory(parentUri);
    final parentDir = await _getDirectoryMetadataInternal(parentUri);

    if (!parentDir.directories.containsKey(uri.pathSegments.last)) {
      throw 'Directory $uri does not exist';
    }

    final encryptedWriteKey =
        parentDir.directories[uri.pathSegments.last]!.encryptedWriteKey;

    if (encryptedWriteKey[0] != 0x01) {
      throw 'Unsupported encryption algorithm';
    }

    final nonce = encryptedWriteKey.sublist(1, 25);

    final key = await crypto.decryptXChaCha20Poly1305(
      ciphertext: encryptedWriteKey.sublist(25),
      nonce: nonce,
      key: parentKeyBytes,
    );

    privateKeyCache[uri] = key;

    return key;
  }

  final sharedReadKeyCache = <Uri, List<Uint8List?>>{};

  Future<List<Uint8List?>> getReadKeysForDirectory(Uri uri) async {
    if (uri.host != 'shared-readonly') {
      throw 'Unsupported URI (host)';
    }
    if (sharedReadKeyCache.containsKey(uri)) {
      return sharedReadKeyCache[uri]!;
    }

    if (uri.pathSegments.isEmpty) {
      final parts = uri.userInfo.split(':');
      return [
        base64UrlNoPaddingDecode(parts[0]),
        base64UrlNoPaddingDecode(parts[1]),
      ];
    }

    final parentUri = uri.replace(
      pathSegments: uri.pathSegments.sublist(0, uri.pathSegments.length - 1),
    );

    final parentDir = await _getDirectoryMetadataInternal(parentUri);

    if (!parentDir.directories.containsKey(uri.pathSegments.last)) {
      throw 'Directory $uri does not exist';
    }

    final dir = parentDir.directories[uri.pathSegments.last]!;
    final keys = [dir.publicKey, dir.encryptionKey];

    sharedReadKeyCache[uri] = keys;

    return keys;
  }

  Future<KeyResponse> deriveKeysFromWriteKey(Uint8List writeKey) async {
    // TODO Cache
    final keyPair = await crypto.newKeyPairEd25519(seed: writeKey);
    final encryptionKey = deriveHashBlake3Int(
      writeKey,
      ENCRYPTION_KEY_TWEAK,
      crypto: crypto,
    );

    return KeyResponse(keyPair: keyPair, encryptionKey: encryptionKey);
  }

  Future<DirectoryMetadata> _getDirectoryMetadataInternal(
      Uri parsedPath) async {
    if (parsedPath.host == 'remote') {
      final remoteId = parsedPath.userInfo.split(':').last;
      if (!customRemotes.containsKey(remoteId)) {
        throw 'Remote ${remoteId} not found';
      }
      final remote = customRemotes[remoteId]!;

      final Map remoteConfig = remote['config'] as Map;

      /*  if (remote['type'] == 'webdav') {
        if (!_webDavClientCache.containsKey(remoteId)) {
          _webDavClientCache[remoteId] = webdav.newClient(
            remoteConfig['url'] as String,
            user: remoteConfig['user'] as String,
            password: remoteConfig['pass'] as String,
            // debug: true,
          );
        }
        final webDavClient = _webDavClientCache[remoteId]!;
        final res = await webDavClient.readDir(parsedPath.path);
        final di = DirectoryMetadata(
          directories: {},
          files: {},
        );

        for (final e in res) {
          final name = e.name ?? '';
          if (e.isDir ?? false) {
            di.directories[name] = DirectoryDirectory(
              name: name,
              created: e.mTime?.millisecondsSinceEpoch ??
                  e.cTime?.millisecondsSinceEpoch ??
                  0,
            );
          } else {
            di.files[name] = DirectoryFile(
                name: name,
                created: e.cTime?.millisecondsSinceEpoch ?? 0,
                modified: e.mTime?.millisecondsSinceEpoch ?? 0,
                version: 0,
                mimeType: e.mimeType,
                file: FileData(
                  chunkSize: null,
                  encryptionType: null,
                  hash: '0000${e.eTag}',
                  key: null,
                  size: e.size ?? 0,
                  ts: e.mTime?.millisecondsSinceEpoch ?? 0,
                  url: 'remote-$remoteId:/${e.path}',
                  padding: null,
                ));
          }
        }
        return di;
      } else if (remote['type'] == 's3') {
        final client = getS3Client(remoteId, remoteConfig);
        final String bucket = remoteConfig['bucket'];

        final di = DirectoryMetadata(
          directories: {},
          files: {},
        );

        await for (final objects in client.listObjectsV2(
          bucket,
          prefix: parsedPath.pathSegments.isEmpty
              ? ''
              : parsedPath.path.substring(1) + '/',
        )) {
          for (final p in objects.prefixes) {
            final name = _removeTrailingSlash(p).split('/').last;
            di.directories[name] = DirectoryDirectory(
              name: name,
              created: 0,
            );
          }
          for (final o in objects.objects) {
            final name = o.key!.split('/').last;

            di.files[name] = DirectoryFile(
                name: name,
                created: o.lastModified?.millisecondsSinceEpoch ?? 0,
                modified: o.lastModified?.millisecondsSinceEpoch ?? 0,
                version: 0,
                file: FileData(
                  chunkSize: null,
                  encryptionType: null,
                  hash: '0000${o.eTag}',
                  key: null,
                  size: o.size ?? 0,
                  ts: o.lastModified?.millisecondsSinceEpoch ?? 0,
                  url: 'remote-$remoteId://${o.key}',
                  padding: null,
                ));
          }
        }
        return di; */
      /* } else { */
      throw 'Remote type ${remote['type']} not supported';
      /* } */
    }

    final uriHash = convertUriToHashForCache(parsedPath);

    log('getDirectoryMetadata $parsedPath');

    if (parsedPath.toString().startsWith(
          'skyfs://local/fs-dac.hns/fs-dac.hns/index/all',
        )) {
      final di = await getAllFiles(
        includeFiles: !parsedPath.toString().startsWith(
            'skyfs://local/fs-dac.hns/fs-dac.hns/index/all-directories'),
        includeDirectories: !parsedPath
            .toString()
            .startsWith('skyfs://local/fs-dac.hns/fs-dac.hns/index/all-files'),
      );

      getDirectoryMetadataChangeNotifier(uriHash).updateDirectoryMetadata(di);
      return di;
    }

    int revision;
    Map<String, dynamic>? data;

    var hasUpdate = false;

    final res = await getDirectoryMetadataWithUri(
      parsedPath,
      uriHash,
    );

    if (dirCache.has(uriHash)) {
      final existing = dirCache.get(uriHash)!;
      if (existing.revision < res.revision) {
        dirCache.set(
          uriHash,
          CachedDirectoryMetadata(
            data: res.data,
            revision: res.revision,
            cid: res.cid,
          ),
        );
        hasUpdate = true;
      }
    } else {
      dirCache.set(
        uriHash,
        CachedDirectoryMetadata(
          data: res.data,
          revision: res.revision,
          cid: res.cid,
        ),
      );

      hasUpdate = true;
    }
    revision = res.revision;
    /* if (res.data != null) {
      data = res.data as Map<String, dynamic>;
    } */

    // if (revision == -1 || data == null) {
    if (hasUpdate) {
      getDirectoryMetadataChangeNotifier(uriHash)
          .updateDirectoryMetadata(res.data);
    }
    return res.data;
    /*   }
    final directoryIndex = DirectoryMetadata.fromJson(data);

    if (hasUpdate) {
      getDirectoryMetadataChangeNotifier(uriHash)
          .updateDirectoryMetadata(directoryIndex);
    }
    return directoryIndex; */
  }

  Future<int> calculateRecursiveDirectorySize(String path) async {
    final di = await getAllFiles(
      startDirectory: path,
      includeFiles: true,
      includeDirectories: false,
    );
    return di.files.values.fold<int>(
      0,
      (previousValue, element) => previousValue + (element.file.cid.size ?? 0),
    );
  }

  Future<DirectoryOperationTaskResult> createDirectory(
      String path, String name) async {
    final uri = parsePath(path);

    validateAccess(
      uri,
      read: true,
      write: true,
    );

    validateFileSystemEntityName(name);

    log('createDirectory $uri $name [skapp: $skapp]');

    final res = await doOperationOnDirectory(
      uri,
      (directoryIndex, writeKey) async {
        if (directoryIndex.directories.containsKey(name))
          throw 'Directory already contains a subdirectory with the same name';

        directoryIndex.directories[name] =
            await _createDirectory(name, writeKey);
      },
    );

    return res;
  }

  Future<DirectoryOperationTaskResult> deleteDirectory(
    String path,
    String name,
  ) async {
    throw 'Operation not supported yet';

/*     final uri = parsePath(path);
    final dirUri = uri.replace(
      path: uri.path + '/$name',
    );

    validateAccess(
      dirUri,
      read: true,
      write: true,
    );
    validateAccess(
      uri,
      read: true,
      write: true,
    );

    validateFileSystemEntityName(name);

    log('deleteDirectory $uri $dirUri [skapp: $skapp]');

    final res = await doOperationOnDirectory(
      dirUri,
      (directoryIndex, writeKey) async {
        if (directoryIndex.directories.isNotEmpty)
          throw 'Directory still contains subdirectories';
        if (directoryIndex.files.isNotEmpty)
          throw 'Directory still contains files';
        // TODO Improve delete
        directoryIndex = DirectoryMetadata(directories: {}, files: {});
      },
    );
    if (!res.success) return res;

    final res2 = await doOperationOnDirectory(
      uri,
      (directoryIndex, writeKey) async {
        directoryIndex.directories.remove(name);
      },
    );

    return res2; */
  }

  Future<DirectoryOperationTaskResult> deleteDirectoryRecursive(
    String path, {
    bool unpinEverything = false,
  }) async {
    throw UnimplementedError();
    final uri = parsePath(path);

    validateAccess(
      uri,
      read: true,
      write: true,
    );

    log('deleteDirectoryRecursive $uri [skapp: $skapp]');

    final res = await doOperationOnDirectory(
      uri,
      (directoryIndex, writeKey) async {
        for (final name in directoryIndex.directories.keys) {
          final res = await deleteDirectoryRecursive(
            getChildUri(uri, name).toString(),
            unpinEverything: unpinEverything,
          );
          if (!res.success) {
            throw res.error!;
          }
        }
        directoryIndex.directories = {};

        if (unpinEverything) {
          for (final file in directoryIndex.files.values) {
            deleteFileSkylinks(file);
          }
        }

        directoryIndex.files = {};
      },
    );
    return res;

    /*   

    final res2 = await doOperationOnDirectory(
      uri,
      (directoryIndex) async {
        directoryIndex.directories.remove(name);
      },
    );

    return res2; */
    return DirectoryOperationTaskResult(true);
  }

  void deleteFileSkylinks(FileReference file) {
    for (final cid in <CID>[
      file.file.cid,
      ...(file.history?.values.map((e) => e.cid).toList() ?? [])
    ]) {
      deletedSkylinks.add(cid.toBytes());
    }

    // TODO Delete thumbnails
    /* for (final key in [
      file.ext?['audio']?['coverKey'],
      file.ext?['video']?['coverKey'],
      file.ext?['thumbnail']?['key'],
    ]) {
      if (key != null) {
        deletedSkylinks.add(key);
      }
    } */
  }

/*   Future<SkynetUser> _getSkynetUser(String userInfo) async {
    if (!skynetUserCache.containsKey(userInfo)) {
      final mySkySeed = base64Url.decode(
        userInfo.substring(3),
      );
      final user = await SkynetUser.fromMySkySeedRaw(mySkySeed);
      skynetUserCache[userInfo] = user;
    }
    return skynetUserCache[userInfo]!; // TODO Error handling
  } */

  Future<String> getShareUriReadOnly(String path) async {
    final uri = parsePath(path);

    validateAccess(
      uri,
      read: true,
      write: false,
    );

    if (uri.host == 'root') {
      final writeKey = await getPrivateKeyForDirectory(uri);

      final keys = await deriveKeysFromWriteKey(writeKey);
      final publicKey = keys.keyPair.publicKey;
      final encryptionKey = keys.encryptionKey;

      return 'skyfs://${base64UrlNoPaddingEncode(publicKey)}:${base64UrlNoPaddingEncode(encryptionKey)}@shared-readonly';
    } else if (uri.host == 'shared-readonly') {
      return uri.toString();
    } else {
      throw 'Sharing already shared URIs is not supported yet';
    }

    /* 

    if (uri.host != 'local') {
      final userInfo = uri.userInfo;
      if (userInfo.startsWith('rw:')) {
        final skynetUser = await _getSkynetUser(userInfo);

        final path = uri.pathSegments.join('/'); // TODO Test this

        final pathSeed = await mysky_io_impl.getEncryptedPathSeed(
          path,
          true,
          skynetUser.rawSeed,
        );

        return 'skyfs://r:${base64Url.encode(hex.decode(pathSeed))}@${skynetUser.id}';
      } else {
        return uri.toString();
      }
    }

    log('getEncryptedFileSeed ${uri.pathSegments.join('/')}');

    final pathSeed = await mySkyProvider.getEncryptedFileSeed(
        uri.pathSegments.join('/'), true);
    log('getShareUriReadOnly -> ${pathSeed.length} $pathSeed');

    return 'skyfs://r:${base64Url.encode(hex.decode(pathSeed))}@${await mySkyProvider.userId()}'; */
  }

  // TODO Better method name
  Future<String> generateSharedReadWriteDirectory() async {
    final seed = crypto.generateRandomBytes(16);

    return 'skyfs://rw:${base64Url.encode(seed)}@shared';
  }

  Future<DirectoryOperationTaskResult> createFile(
      String directoryPath, String name, FileVersion fileData,
      {String? customMimeType}) async {
    final path = parsePath(directoryPath);

    validateAccess(
      path,
      read: true,
      write: true,
    );

    validateFileSystemEntityName(name);

    log('createFile $path $name [skapp: $skapp]');

    FileReference? createdFile;

    final res = await doOperationOnDirectory(
      path,
      (directoryIndex, writeKey) async {
        if (directoryIndex.files.containsKey(name))
          throw 'Directory already contains a file with the same name';

        final file = FileReference(
          created: fileData.ts,
          modified: fileData.ts,
          name: name,
          mimeType: customMimeType ?? mimeFromExtension(name.split('.').last),
          version: 0,
          history: {},
          file: fileData,
          ext: fileData.ext,
        );
        file.file.ext = null;
        directoryIndex.files[name] = file;

        createdFile = file;
        // submitFileToIndexer(directoryPath, file);
      },
    );
    if (createdFile != null) {
      res.data = json.decode(json.encode(createdFile));
    }
    return res;
  }

  FilePathParseResponse parseFilePath(String filePath) {
    final fileName = filePath.split('/').last;

    if (fileName.length == filePath.length) {
      return FilePathParseResponse(
        '',
        filePath,
      );
    }
    if (filePath.startsWith('skyfs://')) {
      return FilePathParseResponse(
        filePath.substring(0, filePath.length - fileName.length - 1),
        Uri.decodeFull(fileName),
      );
    }

    return FilePathParseResponse(
        filePath.substring(0, filePath.length - fileName.length - 1), fileName);
  }

  Future<DirectoryOperationTaskResult> copyFile(
    String sourceFilePath,
    String targetDirectoryPath, {
    bool generatePresignedUrls = false,
  }) async {
    final source = parseFilePath(sourceFilePath);

    final sourceFileName = source.fileName;
    final sourceDirectory = parsePath(source.directoryPath);
    final targetDirectory = parsePath(targetDirectoryPath);

    validateAccess(
      sourceDirectory,
      read: true,
      write: false,
    );

    validateAccess(
      targetDirectory,
      read: true,
      write: true,
    );

    log('copyFile $sourceFileName from $sourceDirectory to $targetDirectory [skapp: $skapp]');
    final sourceDir = await getDirectoryMetadata(source.directoryPath);
    if (!sourceDir.files.containsKey(sourceFileName)) {
      throw 'Source file does not exist.';
    }

    final res = await doOperationOnDirectory(
      targetDirectory,
      (directoryIndex, writeKey) async {
        if (directoryIndex.files.containsKey(sourceFileName))
          throw 'Target directory already contains a file with the same name';

        final file = sourceDir.files[sourceFileName]!;
        /*   if (generatePresignedUrls) {
          await generatePresignedUrlsForFile(file);
        } */
        directoryIndex.files[sourceFileName] = file;
      },
    );
    return res;
  }

/*   Future<void> generatePresignedUrlsForFile(DirectoryReference df) async {
    final scheme = df.file.url.split(':').first;
    if (scheme.startsWith('remote-')) {
      final remoteId = scheme.substring(7);

      final remote = customRemotes[remoteId]!;

      final remoteConfig = remote['config'] as Map;

      if (remote['type'] == 's3') {
        final client = getS3Client(remoteId, remoteConfig);

        final res = await client.putBucketCors(
          remoteConfig['bucket'],
          '''<?xml version="1.0" encoding="UTF-8"?>
<CORSConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
   <CORSRule>
      <AllowedOrigin>*</AllowedOrigin>
      <AllowedMethod>GET</AllowedMethod>
      <AllowedMethod>HEAD</AllowedMethod>
      <MaxAgeSeconds>86400</MaxAgeSeconds>
      <AllowedHeader></AllowedHeader>
   </CORSRule>
</CORSConfiguration>''',
        );
        if (res.statusCode != 200) {
          log(
            'Could not update CORS policy: HTTP ${res.statusCode}: ${res.body}',
          );
        }

        final url = await client.presignedGetObject(
          remoteConfig['bucket'],
          'skyfs/${df.file.url.substring(scheme.length + 3)}',
        );
        df.file.url = url;
      }
    }
  } */

  final _s3ClientCache = <String, Minio>{};
  Minio getS3Client(String remoteId, Map config) {
    if (!_s3ClientCache.containsKey(remoteId)) {
      _s3ClientCache[remoteId] = Minio(
        endPoint: config['endpoint'] as String,
        accessKey: config['accessKey'] as String,
        secretKey: config['secretKey'] as String,
        useSSL: true,
      );
    }
    return _s3ClientCache[remoteId]!;
  }

  Future<DirectoryOperationTaskResult> moveFile(
    String sourceFilePath,
    String targetFilePath, {
    bool generateRandomKey = false,
  }) async {
    final source = parseFilePath(sourceFilePath);
    final target = parseFilePath(targetFilePath);

    final sourceDirectory = parsePath(source.directoryPath);
    final targetDirectory = parsePath(target.directoryPath);

    validateAccess(
      sourceDirectory,
      read: true,
      write: true,
    );

    validateAccess(
      targetDirectory,
      read: true,
      write: true,
    );

    validateFileSystemEntityName(target.fileName);

    log('moveFile $sourceFilePath to $targetFilePath');

    final res = await doOperationOnDirectory(
      sourceDirectory,
      (sourceDirIndex, writeKey) async {
        if (!sourceDirIndex.files.containsKey(source.fileName))
          throw 'Source file does not exist.';

        final res = await doOperationOnDirectory(
          targetDirectory,
          (targetDirIndex, writeKey) async {
            if (!generateRandomKey) {
              if (targetDirIndex.files.containsKey(target.fileName))
                throw 'Target directory already contains a file with the same name';
            }

            final targetKey = generateRandomKey ? Uuid().v4() : target.fileName;

            targetDirIndex.files[targetKey] =
                sourceDirIndex.files[source.fileName]!;

            targetDirIndex.files[targetKey]!.name = target.fileName;
          },
        );
        if (res.success != true) throw res.error!;
        sourceDirIndex.files.remove(source.fileName);
      },
    );
    return res;
  }

  Future<DirectoryOperationTaskResult> renameFile(
    String filePath,
    String newName,
  ) async {
    final file = parseFilePath(filePath);

    final directory = parsePath(file.directoryPath);

    validateAccess(
      directory,
      read: true,
      write: true,
    );

    validateFileSystemEntityName(newName);

    log('renameFile $filePath to $newName');

    final res = await doOperationOnDirectory(
      directory,
      (directoryIndex, writeKey) async {
        if (!directoryIndex.files.containsKey(file.fileName))
          throw 'Source file does not exist.';

        if (directoryIndex.files.containsKey(newName))
          throw 'Directory already contains a file with the new name';

        directoryIndex.files[newName] = directoryIndex.files[file.fileName]!;
        directoryIndex.files[newName]!.name = newName;

        directoryIndex.files.remove(file.fileName);
      },
    );
    return res;
  }

  Future<DirectoryOperationTaskResult> deleteFile(
    String filePath,
  ) async {
    final file = parseFilePath(filePath);

    final directory = parsePath(file.directoryPath);

    validateAccess(
      directory,
      read: true,
      write: true,
    );

    log('deleteFile $filePath');

    final res = await doOperationOnDirectory(
      directory,
      (directoryIndex, writeKey) async {
        if (!directoryIndex.files.containsKey(file.fileName))
          throw 'Source file does not exist.';

        /*  try {
          final res = await mySkyProvider.client.httpClient.delete(
            Uri.parse(
              'https://account.${mySkyProvider.client.portalHost}/user/uploads/${directoryIndex.files[file.fileName]!.file.url.substring(6)}',
            ),
          );
          print(res.statusCode);
          print(res.body);
        } catch (e, st) {
          print(e);
          print(st);
        } */
        deleteFileSkylinks(directoryIndex.files[file.fileName]!);

        directoryIndex.files.remove(file.fileName);
      },
    );
    return res;
  }

  Future<void> cloneDirectory(
    String sourceDirectoryPath,
    String targetDirectoryPath, {
    bool recursive = true,
  }) async {
    throw UnimplementedError();
    final sourceDirectory = parsePath(sourceDirectoryPath);
    final targetDirectory = parsePath(targetDirectoryPath);

    validateAccess(
      sourceDirectory,
      read: true,
      write: false,
    );

    validateAccess(
      targetDirectory,
      read: true,
      write: true,
    );

    log('cloneDirectory $sourceDirectory to $targetDirectory [skapp: $skapp]');

    final sourceDir = await getDirectoryMetadata(sourceDirectoryPath);
    // log('cloneDirectory source index: ${json.encode(sourceDir)}');
    final res = await doOperationOnDirectory(
      targetDirectory,
      (directoryIndex, writeKey) async {
        directoryIndex.directories = sourceDir.directories;
        directoryIndex.files = sourceDir.files;
      },
    );
    if (res.success != true) {
      throw res.error!;
    }

    if (recursive) {
      for (final subDir in sourceDir.directories.keys) {
        await cloneDirectory(
          getChildUri(sourceDirectory, subDir).toString(),
          getChildUri(targetDirectory, subDir).toString(),
        );
      }
    }
  }

  Uri getChildUri(Uri uri, String name) {
    return uri.replace(
      pathSegments: uri.pathSegments + [name],
      queryParameters: null,
    );
  }

  Future<DirectoryOperationTaskResult> moveDirectory(
    String sourceDirectoryPath,
    String targetDirectoryPath,
  ) async {
    throw UnimplementedError();

    final sourceDirectory = parsePath(sourceDirectoryPath);
    final targetDirectory = parsePath(targetDirectoryPath);

    validateAccess(
      sourceDirectory,
      read: true,
      write: true,
    );

    validateAccess(
      targetDirectory,
      read: true,
      write: true,
    );

    log('moveDirectory $sourceDirectory to $targetDirectory [skapp: $skapp]');

    final oldPath = parseFilePath(sourceDirectoryPath);
    final newPath = parseFilePath(targetDirectoryPath);

    validateFileSystemEntityName(newPath.fileName);

    final di = await getDirectoryMetadata(newPath.directoryPath);

    if (di.directories.containsKey(newPath.fileName)) {
      throw 'Target directory already contains a subdirectory with that name.';
    }

    await cloneDirectory(sourceDirectoryPath, targetDirectoryPath);

    await createDirectory(newPath.directoryPath, newPath.fileName);

    final res = await deleteDirectoryRecursive(
      sourceDirectoryPath,
      unpinEverything: false,
    );

    if (!res.success) return res;

    return await doOperationOnDirectory(parsePath(oldPath.directoryPath),
        (directoryIndex, writeKey) async {
      directoryIndex.directories.remove(oldPath.fileName);
    });
  }

/*   bool isIndexPath(String path) {
    final uri = parsePath(path);
    return uri.path.startsWith('/$DATA_DOMAIN/$DATA_DOMAIN/index');
  }
 */
  Future<DirectoryOperationTaskResult> updateFile(
    String directoryPath,
    String name,
    FileVersion fileData,
  ) async {
    final path = parsePath(directoryPath);

    validateAccess(
      path,
      read: true,
      write: true,
    );

    validateFileSystemEntityName(name);

    final res = await doOperationOnDirectory(
      path,
      (directoryIndex, writeKey) async {
        if (!directoryIndex.files.containsKey(name))
          throw 'Directory does not contain a file with this name, so it can\'t be updated';

        final df = directoryIndex.files[name]!;

        df.modified = fileData.ts;

        df.history ??= {};
        df.history![df.version] = df.file;

        df.version++;

        df.file = fileData;

        df.ext = fileData.ext;

        df.file.ext = null;

        directoryIndex.files[name] = df;

        // submitFileToIndexer(directoryPath, df);
      },
    );

    return res;
  }

  Future<DirectoryOperationTaskResult> updateFileExtensionData(
    String uri,
    Map<String, dynamic>? newExtData,
  ) async {
    final f = parseFilePath(uri);

    final directoryUri = parsePath(f.directoryPath);

    validateAccess(
      directoryUri,
      read: true,
      write: true,
    );

    final res = await doOperationOnDirectory(
      directoryUri,
      (directoryIndex, writeKey) async {
        if (!directoryIndex.files.containsKey(f.fileName))
          throw 'Directory does not contain a file with this name, so it can\'t be updated';

        directoryIndex.files[f.fileName]!.ext = newExtData;
      },
    );

    return res;
  }

  final _indexedExtKeys = [
    'video',
    'audio',
    'image'
  ]; // TODO Maybe Comics, books, documents

  String? _getTypeFromExtMap(Map<String, dynamic> ext) {
    for (final key in _indexedExtKeys) {
      if (ext.containsKey(key)) {
        return key;
      }
    }
  }

  final _indexedExtKeysWithThumbnail = ['video', 'audio', 'image', 'thumbnail'];

/*   Future<void> submitFileToIndexer(
      String directoryPath, DirectoryFile df) async {
    final extMap = Map.of(df.ext ?? <String, dynamic>{});

    if (extMap.isNotEmpty) {
      final type = _getTypeFromExtMap(extMap);
      if (type != null) {
        final path = 'fs-dac.hns/index/by-type/$type';
        await doOperationOnDirectory(parsePath(path), (directoryIndex) async {
          // final data = directoryIndex.index ?? <String, dynamic>{'files': []};
          // data['ts'] = DateTime.now().millisecondsSinceEpoch;
          final filePath = '$directoryPath/${df.name}';
          final uri = parsePath(filePath);

          extMap.removeWhere(
              (key, value) => !_indexedExtKeysWithThumbnail.contains(key));

          directoryIndex.files[uri.toString()] = DirectoryFile(
            created: df.created,
            modified: df.modified,
            file: df.file,
            name: df.name,
            version: df.version,
            mimeType: df.mimeType,
            ext: extMap,
          );
        });
      }
    }
  } */

// TODO Optimize
  Future<FileVersion> uploadFileData(
    Multihash hash,
    int size, {
    bool generateMetadata = false,
    String? filename,
    required Function customEncryptAndUploadFileFunction,
    Function? generateMetadataWrapper,
    Map<String, dynamic> additionalExt = const {},
    List<Multihash>? hashes,
    bool metadataOnly = false,
  }) async {
    Map<String, dynamic>? ext;

    if (generateMetadata) {
      print('trying to extract metadata...');

      final res = await generateMetadataWrapper!(
        extension(filename!),
        thumbnailRootSeed /* extractMetadata, [bytes, rootPathSeed] */,
      );

      ext = json.decode(res[0]);

/*       for (final type in ['audio', 'video']) {
        if ((ext?[type] ?? {})?['coverKey'] != null) {
          ext![type]['coverKey'] =
              (await mySkyProvider.userId()) + '/' + ext[type]['coverKey'];

          uploadThumbnail(ext[type]['coverKey'], res[index]);

          index++;
        }
      } */

      if (ext?.containsKey('thumbnail') ?? false) {
        /* ext!['thumbnail']['key'] =
            (await mySkyProvider.userId()) + '/' + ext['thumbnail']['key']; */
        uploadThumbnailDirectly(
          ext!['thumbnail']['cid'],
          res[1],
          res[2],
        );
      }
    }

    for (final key in additionalExt.keys) {
      ext ??= {};
      ext[key] ??= {};
      for (final k in additionalExt[key].keys) {
        ext[key][k] = additionalExt[key][k];
      }
    }

    if (metadataOnly) {
      return FileVersion(
        encryptedCID: null,
        /* hash: multihash,
        size: size, */
        ts: nowTimestamp(),
        ext: ext,
      );
    }

    EncryptAndUploadResponse res;

    // if (customEncryptAndUploadFileFunction != null) {
    res = await customEncryptAndUploadFileFunction();
    /*   } else {
      res = await encryptAndUploadFile(
        stream,
        multihash,
        length: size,
      );
    } */
    ext ??= {};

    ext['uploader'] = UniversalPlatform.isWeb ? 'skyfs:2' : 'vup:2';

    final fileData = FileVersion(
      encryptedCID: EncryptedCID(
          encryptionAlgorithm: encryptionAlgorithmXChaCha20Poly1305,
          padding: res.padding!,
          chunkSizeAsPowerOf2: res.chunkSizeAsPowerOf2!,
          encryptedBlobHash: res.encryptedBlobHash,
          encryptionKey: res.secretKey!,
          originalCID: CID(
            cidTypeRaw,
            hash,
            size: size,
          )),
      hashes: hashes,
      ts: nowTimestamp(),
      ext: ext,
    );
    return fileData;
  }

  final uploadThumbnailPool = Pool(2);

  Set<String> uploadingThumbnailKeys = <String>{};

  // TODO Use pool to prevent too many concurrent uploads
  Future<void> uploadThumbnailDirectly(
    String key,
    Uint8List thumbnailBytes,
    Uint8List cipherText,
  ) async {
    if (uploadingThumbnailKeys.contains(key)) {
      return;
    }
    // final existing = await loadThumbnail(key);
    if (!(await thumbnailCache.containsKey(key))) {
      uploadingThumbnailKeys.add(key);
      await thumbnailCache.put(key, thumbnailBytes);

      await uploadThumbnailPool.withResource(() async {
        log('uploading thumbnail $key');
        final r = RetryOptions(maxAttempts: 12);
        await r.retry(
          () => api.uploadRawFile(cipherText),

          /* mySkyProvider.setRawDataEncrypted(
            temporaryThumbnailKeyPaths[parts[1]] ?? '',
            bytes,
            0,
            customEncryptedFileSeed: hex.encode(
              keyInBytes,
            ),
          ), */
          // retryIf: (e) => e is Exception,
        );
      });
    }
  }

  // Map<String, Uint8List> thumbnailCache = {};

  Map<String, Completer<Uint8List?>> thumbnailCompleters = {};

  // TODO Optimization: only 1 concurrent instance / key
  Future<Uint8List?> loadThumbnail(String key) async {
    if (await thumbnailCache.containsKey(key /* .replaceFirst('/', '-') */)) {
      return thumbnailCache.get(key /* .replaceFirst('/', '-') */);
    }
    if (thumbnailCompleters.containsKey(key)) {
      return thumbnailCompleters[key]!.future;
    }
    final completer = Completer<Uint8List?>();
    thumbnailCompleters[key] = completer;
    log('loadThumbnail $key');

    try {
      final encryptedCID = EncryptedCID.decode(key.split('.').first);

      final res = await api.downloadRawFile(encryptedCID.encryptedBlobHash);

      final imageBytes = (await decryptChunk(
        ciphertext: res,
        index: 0,
        key: encryptedCID.encryptionKey,
        crypto: crypto,
      ))
          .sublist(
        0,
        res.length - (16 + encryptedCID.padding),
      );
      await thumbnailCache.put(key, imageBytes);

      completer.complete(imageBytes);

      return imageBytes;
    } catch (e) {
      completer.complete(null);
      return null;
    }
  }

  final downloadChunkSize = 4 * 1000 * 1000;

/*   Stream<List<int>> _downloadFileInChunks(
      Uri url, int totalSize, Function setTotalSize) async* {
    for (int i = 0; i < totalSize; i += downloadChunkSize) {
      final res = await client.httpClient.get(
        url,
        headers: {
          'range': 'bytes=$i-${min(i + downloadChunkSize - 1, totalSize - 1)}',
        }..addAll(
            client.headers ?? {},
          ),
      );
      log(res.headers.toString());

      final length =
          int.tryParse(res.headers['content-range']?.split('/').last ?? '');
      if (length != null) {
        setTotalSize(length);

        totalSize = length;
      }

      yield res.bodyBytes;
    }
  } */

/*   Future<Stream<Uint8List>> downloadAndDecryptFile(
    FileVersion fileData, {
    Function? onProgress,
  }) async {
    log('downloadAndDecryptFile');

    final chunkSize = fileData.encryptedCID!.chunkSize;

    onProgress ??= (double progress) {
      setFileState(
        fileData.cid.hash,
        FileState(
          type: FileStateType.downloading,
          progress: progress,
        ),
      );
    };

    onProgress(0.0);

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
      )!,
    );
    late Stream<List<int>> stream;

    int totalDownloadLength = fileData.size;

    if (UniversalPlatform.isWeb &&
        totalDownloadLength > (downloadChunkSize * 1.4)) {
      stream = _downloadFileInChunks(url, totalDownloadLength, (val) {
        totalDownloadLength = val;
      });
    } else {
      final request = http.Request('GET', url);
      request.headers.addAll(client.headers ?? {});

      final response = await client.httpClient.send(request);

      if (response.statusCode != 200) {
        throw 'HTTP ${response.statusCode}';
      }
      totalDownloadLength = response.contentLength!;
      stream = response.stream;
    }

    int downloadedLength = 0;

    final completer = Completer<bool>();

    final List<int> data = [];

    bool headerSent = false;

    StreamSubscription? progressSub;

    if (!UniversalPlatform.isWeb) {
      progressSub =
          Stream.periodic(Duration(milliseconds: 200)).listen((event) {
        final progress = downloadedLength / totalDownloadLength;
        onProgress!(progress);
      });
    }

    final _downloadSub = stream.listen(
      (List<int> newBytes) {
        data.addAll(newBytes);

        downloadedLength += newBytes.length;

        if (UniversalPlatform.isWeb) {
          onProgress!(downloadedLength / totalDownloadLength);
        }

        if (!headerSent) {
          streamCtrl.add(
            SecretStreamCipherMessage(
              Uint8List.fromList(
                data.sublist(0, 24),
              ),
            ),
          );
          data.removeRange(0, 24);
          headerSent = true;
        }
        while (data.length >= (chunkSize + 17)) {
          streamCtrl.add(
            SecretStreamCipherMessage(
              Uint8List.fromList(
                data.sublist(0, chunkSize + 17),
              ),
            ),
          );
          data.removeRange(0, chunkSize + 17);
        }

        if (downloadedLength == totalDownloadLength) {
          // Last block

          streamCtrl.add(
            SecretStreamCipherMessage(
              Uint8List.fromList(
                data.sublist(0, data.length),
              ),
              // additionalData:
            ),
          );
        }
      },
      onDone: () async {
        await progressSub?.cancel();
        await streamCtrl.close();
        setFileState(
          fileData.hash,
          FileState(
            type: FileStateType.idle,
            progress: null,
          ),
        );

        completer.complete(true);
      },
      onError: (e) {
        progressSub?.cancel();
        streamCtrl.close();
        // TODO Handle error
      },
      cancelOnError: true,
    );

    return transformer.map((event) => event.message);
  } */

  // TODO Migrate
  /* Future<Stream<Uint8List>> downloadAndDecryptFileInChunks(
    FileData fileData, {
    Function? onProgress,
    DownloadConfig? downloadConfig,
  }) async {
    log('[download+decrypt] using libsodium_secretbox');

    final chunkSize = fileData.chunkSize ?? maxChunkSize;

    final padding = fileData.padding ?? 0;

    onProgress ??= (double progress) {
      setFileState(
        fileData.hash,
        FileState(
          type: FileStateType.downloading,
          progress: progress,
        ),
      );
    };

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
      downloadConfig?.url ??
          client.resolveSkylink(
            fileData.url,
          )!,
    );
    final downloadStreamCtrl = StreamController<List<int>>();

    StreamSubscription? sub;
    int downloadedLength = 0;

    void sendDownloadRequest() async {
      try {
        final request = http.Request('GET', url);
        request.headers.addAll(client.headers ?? {});
        request.headers['range'] = 'bytes=$downloadedLength-';

        if (downloadConfig != null) {
          request.headers.addAll(downloadConfig.headers);
        }

        final response = await client.httpClient.send(request);

        if (response.statusCode != 206) {
          throw 'HTTP ${response.statusCode}';
        }
        // totalDownloadLength = response.contentLength!;
        sub = response.stream.listen(
          (value) {
            downloadStreamCtrl.add(value);
          },
          onDone: () {
            print('onDone');
          },
          onError: (e, st) {
            print('onError');
          },
        );
      } catch (e, st) {
        print(e);
        print(st);
      }
    }
    // downloadStreamCtrl.addStream(response.stream);

    final completer = Completer<bool>();

    final List<int> data = [];
    sendDownloadRequest();

    // bool headerSent = false;

    StreamSubscription? progressSub;

    int lastDownloadedLength = 0;
    DateTime lastDownloadedLengthTS = DateTime.now();

    progressSub = Stream.periodic(Duration(milliseconds: 200)).listen((event) {
      final progress = downloadedLength / totalEncSize;
      onProgress!(progress);
      if (downloadedLength != lastDownloadedLength) {
        lastDownloadedLength = downloadedLength;
        lastDownloadedLengthTS = DateTime.now();
      } else {
        final diff = DateTime.now().difference(lastDownloadedLengthTS);
        if (diff > Duration(seconds: 20)) {
          print('detected download issue, reconnecting...');
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
          log('[download+decrypt] decrypt chunk... (${data.length} ${chunkSize} ${downloadedLength})');

          final nonce = Uint8List.fromList(
            encodeEndian(
              currentChunk,
              sodium.crypto.secretBox.nonceBytes,
              endianType: EndianType.littleEndian,
            ) as List<int>,
          );

          try {
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
          } catch (e, st) {
            data.clear();
            downloadStreamCtrl.close();
            /* progressSub?.cancel();
            streamCtrl.close(); */
          }
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
        setFileState(
          fileData.hash,
          FileState(
            type: FileStateType.idle,
            progress: null,
          ),
        );

        completer.complete(true);
      },
      onError: (e) {
        progressSub?.cancel();
        streamCtrl.close();
        // TODO Handle error
      },
      cancelOnError: true,
    );

    return streamCtrl.stream;
  } */
/* 
  Future<EncryptAndUploadResponse> encryptAndUploadFile(
      Stream<Uint8List> stream, String fileMultiHash,
      {/* required String filename, */ required int length}) async {
    setFileState(
      fileMultiHash,
      FileState(
        type: FileStateType.encrypting,
        progress: 0,
      ),
    );

    final secretKey = sodium.crypto.secretStream.keygen();

    int internalSize = 0;

    final outStream = sodium.crypto.secretStream.pushEx(
      messageStream: stream.map((event) {
        internalSize += event.length;
        print(internalSize == length
            ? SecretStreamMessageTag.finalPush
            : SecretStreamMessageTag.message);
        return SecretStreamPlainMessage(
          event,
          tag: internalSize == length
              ? SecretStreamMessageTag.finalPush
              : SecretStreamMessageTag.message,
        );
      }),
      key: secretKey,
    );

    setFileState(
      fileMultiHash,
      FileState(
        type: FileStateType.uploading,
        progress: 0,
      ),
    );

    final result = await client.upload.uploadFileWithStream(
      SkyFile(
        content: Uint8List.fromList([]),
        filename: 'fs-dac.hns',
        type: 'application/octet-stream',
      ),
      length,
      outStream.map((event) {
        return event.message;
      }),
    );

    if (result == null) {
      throw 'File Upload failed';
    }

    setFileState(
      fileMultiHash,
      FileState(
        type: FileStateType.idle,
        progress: null,
      ),
    );

    return EncryptAndUploadResponse(
      skylink: result,
      secretKey: secretKey.extractBytes(),
    );
  } */

  // final Map<String, SkynetUser> skynetUserCache = {};

  Future<DataWithRevisionAndKeys<DirectoryMetadata>>
      getDirectoryMetadataWithUri(
    Uri uri,
    Multihash uriHash,
  ) async {
    log('getRawDataEncryptedWithUri $uri');

    // late String userId;
    // late String pathSeed;

    Uint8List? writeKey;

    late final Uint8List publicKey;
    Uint8List? secretKey;
    late final Uint8List? encryptionKey;

    if (uri.host == 'root') {
      writeKey = await getPrivateKeyForDirectory(uri);

      final keys = await deriveKeysFromWriteKey(writeKey);
      publicKey = keys.keyPair.publicKey;
      secretKey = writeKey;
      encryptionKey = keys.encryptionKey;
    } else if (uri.host == 'shared-readonly') {
      final keys = await getReadKeysForDirectory(uri);
      publicKey = keys[0]!;
      encryptionKey = keys[1];

      /*   final userInfo = uri.userInfo;
      if (userInfo.startsWith('r:')) {
        userId = uri.host;
        final rootPathSeed = hex.encode(
          base64Url.decode(
            userInfo.substring(2),
          ),
        );
        final path = [...uri.pathSegments, 'index.json'].join('/');

        log('userId $userId');
        log('rootPathSeed $rootPathSeed');
        log('path $path');

        pathSeed = deriveEncryptedPathSeed(
          rootPathSeed,
          path,
          false,
        );
      } else if (userInfo.startsWith('rw:')) {
        final skynetUser = await _getSkynetUser(userInfo);
        userId = skynetUser.id;

        final path = [...uri.pathSegments, 'index.json'].join('/');

        pathSeed = await mysky_io_impl.getEncryptedPathSeed(
          path,
          false,
          skynetUser.rawSeed,
        );
      } else {
        throw 'Invalid URI';
      } */
    } else {
      throw 'Unsupported URI';
    }

    /* final dataKey = deriveEncryptedFileTweak(pathSeed);
    final encryptionKey = deriveEncryptedFileKeyEntropy(pathSeed); */

    final res = await api.registryGet(publicKey);

    if (res == null) {
      return DataWithRevisionAndKeys(
        DirectoryMetadata(
          details: DirectoryMetadataDetails({}),
          directories: {},
          files: {},
          extraMetadata: ExtraMetadata({}),
        ),
        -1,
        writeKey: writeKey,
        encryptionKey: encryptionKey,
        publicKey: publicKey,
        secretKey: secretKey,
        cid: null,
      );
    }

    final cid = CID.fromBytes(res.data.sublist(1));

    /*  if (collectSkylinks) {
      collectedSkylinks.add(cid.encode());
    } */

    final cached = dirCache.get(uriHash);

    if (res.revision > (cached?.revision ?? -1)) {
      final contentRes = await api.downloadRawFile(cid.hash);

      return DataWithRevisionAndKeys<DirectoryMetadata>(
        DirectoryMetadata.deserizalize(
          await decryptMutableBytes(
            contentRes,
            encryptionKey!,
            crypto: crypto,
          ),
        ),
        res.revision,
        cid: cid,
        writeKey: writeKey,
        secretKey: secretKey,
        encryptionKey: encryptionKey,
        publicKey: publicKey,
      );
    } else {
      return DataWithRevisionAndKeys(
        cached!.data,
        cached.revision,
        cid: cached.cid,
        writeKey: writeKey,
        secretKey: secretKey,
        encryptionKey: encryptionKey,
        publicKey: publicKey,
      );
    }
  }

  bool collectSkylinks = false;
  List<String> collectedSkylinks = [];

  Future<Map<String, String>> aggregateAllSkylinks({
    String startDirectory = '',
    required int registryFetchDelay,
  }) async {
    throw 'Not implemented';
    if (!rootAccessEnabled) {
      throw 'Permission denied';
    } /* 

    collectSkylinks = true;
    collectedSkylinks = [];
    final result = <String, String>{};
    Future<void> processDirectory(Uri uri) async {
      await Future.delayed(Duration(milliseconds: registryFetchDelay));
      final dir =
          /* getDirectoryMetadataCached(path) ??  */ await getDirectoryMetadata(
              uri.toString());

      if (dir.directories.isEmpty && dir.files.isEmpty) {
        return;
      }

      for (final subDir in dir.directories.keys) {
        if (subDir.isNotEmpty) {
          await processDirectory(getChildUri(uri, subDir));
        }
      }

      for (final key in dir.files.keys) {
        // final uri = parsePath('$path/$key');
        final file = dir.files[key]!;
        for (final version in [
          file.file,
          ...(file.history?.values ?? <FileData>[])
        ]) {
          result[version.url.substring(6)] = 'File Content';
          // coverKey
        }
        for (final key in [
          file.ext?['audio']?['coverKey'],
          file.ext?['video']?['coverKey'],
          file.ext?['thumbnail']?['key'],
        ]) {
          if (key != null) {
            final parts = key.split('/');
            if (parts.length != 2) continue;
            final keyInBytes = base64Url.decode(parts[1]);
            final pathSeed = hex.encode(keyInBytes);

            final dataKey = deriveEncryptedFileTweak(pathSeed);
            await Future.delayed(Duration(milliseconds: registryFetchDelay));
            // lookup the registry entry
            final res = await client.registry.getEntry(
              SkynetUser.fromId(parts[0]),
              '',
              timeoutInSeconds: 10,
              hashedDatakey: dataKey,
            );
            if (res == null) continue;
            final skylink = decodeSkylinkFromRegistryEntry(res.entry.data);
            result[skylink] = 'Thumbnail/Cover';
          }
        }
      }
    }

    await processDirectory(parsePath(startDirectory));

    collectSkylinks = false;
    for (final s in collectedSkylinks) {
      result[s] = 'DirectoryMetadata';
    }

    return result; */
  }

  Function? onLog;

  void log(
    String message,
  ) {
    if (onLog != null) {
      onLog!(message);
    } else {
      if (debugEnabled) {
        print('[SkyFS] $message');
      }
    }
  }
}

extension MultiKeyExtension on Uint8List {
  Uint8List toMultiKey() {
    return Uint8List.fromList([mkeyEd25519] + this);
  }
}

class KeyResponse {
  final KeyPairEd25519 keyPair;
  final Uint8List encryptionKey;

  KeyResponse({
    required this.keyPair,
    required this.encryptionKey,
  });
}

class FileStateNotifier extends StateNotifier<FileState> {
  FileStateNotifier()
      : super(FileState(
          type: FileStateType.idle,
          progress: null,
        ));

  void updateFileState(FileState fileState) {
    state = fileState;
    if (fileState.type == FileStateType.idle) {
      isCanceled = false;
    }
  }

  bool isCanceled = false;

  final _cancelStream = StreamController<Null>.broadcast();

  Stream<Null> get onCancel => _cancelStream.stream;

  @override
  void dispose() {
    _cancelStream.close();
    super.dispose();
  }

  void cancel() {
    isCanceled = true;
    _cancelStream.add(null);
  }
}

class DirectoryMetadataChangeNotifier
    extends StateNotifier<DirectoryMetadata?> {
  DirectoryMetadataChangeNotifier() : super(null);

  void updateDirectoryMetadata(DirectoryMetadata index) {
    state = index;
  }
}

class UploadingFilesChangeNotifier
    extends StateNotifier<Map<String, FileReference>> {
  UploadingFilesChangeNotifier() : super({});

  void removeUploadingFile(String name) {
    final map = Map.of(state);
    state.remove(name);
    map.remove(name);
    state = map;
  }

  void addUploadingFile(FileReference file) {
    final map = Map.of(state);

    map[file.name] = file;

    state = map;
  }
}

class EncryptAndUploadResponse {
  final Multihash encryptedBlobHash;
  final Uint8List? secretKey;
  // final String? encryptionType;
  final int? chunkSizeAsPowerOf2;
  final int? padding;
  // final Uint8List nonce;
  EncryptAndUploadResponse({
    required this.encryptedBlobHash,
    required this.secretKey,
    // required this.encryptionType,
    required this.chunkSizeAsPowerOf2,
    required this.padding,
    // required this.nonce,
  });
}
// void log(dynamic s) {}

/* Future<String> getMultiHashForFile(Stream<List<int>> stream) async {
  var output = AccumulatorSink<Digest>();
  var input = sha256.startChunkedConversion(output);
  await stream.forEach(input.add);

  input.close();
  final hash = output.events.single;
  return '1220$hash';
} */

class FileState {
  final double? progress;
  final FileStateType type;

  FileState({
    required this.type,
    required this.progress,
  });

  @override
  String toString() => '$type ${progress?.toStringAsFixed(2)}';
}

enum FileStateType {
  idle,
  downloading,
  decrypting,
  encrypting,
  uploading,
  sync,
}

class DirectoryOperationTask {
  // Uri uri;
  Completer<DirectoryOperationTaskResult> completer;
  DirectoryOperationMethod operation;

  DirectoryOperationTask(this.completer, this.operation);
}

class DirectoryOperationTaskResult {
  bool success;
  String? error;
  dynamic data;
  DirectoryOperationTaskResult(this.success, {this.error});

  Map toJson() {
    final map = <String, dynamic>{'success': success};
    if (!success) {
      map['error'] = error;
    }
    if (data != null) {
      map['data'] = data;
    }
    return map;
  }
}

class DownloadConfig {
  DownloadConfig(this.url, this.headers);

  String url;
  Map<String, String> headers;
}

class DataWithRevisionAndKeys<T> {
  final T data;
  final int revision;
  final CID? cid;

  final Uint8List? writeKey;

  final Uint8List? secretKey;
  final Uint8List publicKey;
  final Uint8List? encryptionKey;

  DataWithRevisionAndKeys(
    this.data,
    this.revision, {
    required this.secretKey,
    required this.writeKey,
    required this.publicKey,
    required this.encryptionKey,
    required this.cid,
  });

  @override
  String toString() =>
      'DataWithRevisionAndKeys<$T>(revision: $revision, data: $data)';
}
