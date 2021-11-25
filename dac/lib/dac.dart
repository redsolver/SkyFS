import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:blurhash_dart/blurhash_dart.dart';
import 'package:exif/exif.dart';
import 'package:filesystem_dac/model/utils.dart';
import 'package:flac_metadata/flac_metadata.dart';
import 'package:path/path.dart';
import 'package:universal_platform/universal_platform.dart';
import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';
import 'package:filesystem_dac/model/cached_entry.dart';
import 'package:hive/hive.dart';
import 'package:id3/id3.dart';
import 'package:pool/pool.dart';
import 'package:skynet/skynet.dart';
import 'package:skynet/src/mysky_provider/base.dart';
import 'package:skynet/src/skystandards/fs.dart';
import 'package:skynet/src/mysky/encrypted_files.dart';
import 'package:http/http.dart' as http;
import 'package:skynet/src/mysky/io.dart' as mysky_io_impl;
import 'package:mime/mime.dart';
import 'package:sodium/sodium.dart' hide Box;
import 'package:state_notifier/state_notifier.dart';
import 'package:image/image.dart' as img;
import 'package:pinenacl/api.dart' as pinenacl;
import 'package:skynet/src/encode_endian/encode_endian.dart';
import 'package:skynet/src/encode_endian/base.dart';

const DATA_DOMAIN = 'fs-dac.hns';

const maxChunkSize = 1 * 1024 * 1024;

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
];

const metadataSupportedExtensions = [
  '.mp3',
  '.flac',
  ...supportedImageExtensions,
];

const metadataMaxFileSize = 4 * 1000 * 1000;

Future<List> extractMetadata(List list) async {
  String extension = list[0].toLowerCase();
  Uint8List bytes = list[1];
  String rootPathSeed = list[2];

  List more = [];

  bool hasThumbnail = false;

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
      'COMMENT': 'comment',
      // 'cover': 'cover',
    };
    ext!['audio'] ??= {};
    for (final key in map.keys) {
      if (ext['flac'].containsKey(key)) {
        ext['audio'][map[key]] = ext['flac'][key];
      }
    }
  }
  // TODO audio length on web (use ffmpeg)

  if (hasThumbnail || supportedImageExtensions.contains(extension)) {
    try {
      var image = img.decodeImage(bytes);
      if (image != null) {
        ext ??= {};

        if (!hasThumbnail) {
          ext['image'] = {
            'width': image.width,
            'height': image.height,
          };
        }

        // Resize the image to a 200x? thumbnail (maintaining the aspect ratio).
        final thumbnail = image.width > image.height
            ? img.copyResize(
                image,
                height: 200,
              )
            : img.copyResize(
                image,
                width: 200,
              ); // TODO Adjust, maybe use boxFit: cover

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
        try {
          if (!hasThumbnail) {
            Map<String, IfdTag> data = await readExifFromBytes(bytes);
            if (data.isNotEmpty) {
              ext['exif'] =
                  data.map((key, value) => MapEntry(key, value.printable));
            }
          }
        } catch (e) {}
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
}

Map<String, String> temporaryThumbnailKeyPaths = {};

String deriveThumbnailKey(Digest hash, String rootPathSeed) {
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
}

typedef DirectoryOperationMethod = Future Function(
    DirectoryIndex directoryIndex);

class FileSystemDAC {
  final MySkyProvider mySkyProvider;
  SkynetClient get client => mySkyProvider.client;
  late final String skapp;

  late Sodium sodium;
  late final bool rootAccessEnabled;

  late final Box<CachedEntry> directoryIndexCache;
  late final Box<Uint8List> thumbnailCache;

  final _fileStateChangeNotifiers = <String, FileStateNotifier>{};
  final _directoryIndexChangeNotifiers =
      <String, DirectoryIndexChangeNotifier>{};

  final _uploadingFilesChangeNotifiers =
      <String, UploadingFilesChangeNotifier>{};

  final bool debugEnabled;

  FileSystemDAC({
    required this.mySkyProvider,
    required this.skapp,
    required this.sodium,
    this.debugEnabled = false,
  });

  FileStateNotifier getFileStateChangeNotifier(String hash) {
    // TODO Use a cross-process implementation (Not Hive)
    // TODO Permission limits when exposing to web
    if (!_fileStateChangeNotifiers.containsKey(hash)) {
      _fileStateChangeNotifiers[hash] = FileStateNotifier();
    }
    return _fileStateChangeNotifiers[hash]!;
  }

  DirectoryIndexChangeNotifier getDirectoryIndexChangeNotifier(
    String uriHash, {
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
      _directoryIndexChangeNotifiers[uriHash] = DirectoryIndexChangeNotifier();
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

  Future<void> init({bool devEnabled = false}) async {
    rootAccessEnabled =
        !UniversalPlatform.isWeb || domainsWithRootAccess.contains(skapp);
    log('rootAccessEnabled $rootAccessEnabled');
    final opts = {
      'dev': devEnabled,
    };
    await mySkyProvider.load(
      DATA_DOMAIN,
      options: opts,
    );
    Hive.registerAdapter(CachedEntryAdapter());
    directoryIndexCache = await Hive.openBox<CachedEntry>(
      'fs-dac-directory-index-cache',
    );
    thumbnailCache = await Hive.openBox<Uint8List>(
      'fs-dac-thumbnail-cache',
    );
  }

  Future<void> onUserLogin() async {
    print('onUserLogin');

    log('createRootDirectory $skapp [skapp: $skapp]');

    await doOperationOnDirectory(
      Uri.parse('skyfs://local/fs-dac.hns'),
      (directoryIndex) async {
        bool doUpdate = false;

        if (!directoryIndex.directories.containsKey('home')) {
          directoryIndex.directories['home'] = DirectoryDirectory(
            created: nowTimestamp(),
            name: 'home',
          );
          doUpdate = true;
        }

        if (!directoryIndex.directories.containsKey(skapp)) {
          directoryIndex.directories[skapp] = DirectoryDirectory(
            created: nowTimestamp(),
            name: skapp,
          );
          doUpdate = true;
        }

        return doUpdate;
      },
    );
  }

  Uri parsePath(String path, {bool resolveMounted = true}) {
    Uri uri;

    if (path.startsWith('skyfs://')) {
      uri = Uri.parse(path);
    } else {
      final list = [DATA_DOMAIN] +
          path
              .split('/')
              .map((e) => e.trim())
              .where((element) => element.isNotEmpty)
              .toList();

      uri = Uri(
        scheme: 'skyfs',
        host: 'local',
        pathSegments: list,
      );
    }
    // TODO consider additional permission checks for mounted directories
    if (resolveMounted) {
      for (final mount in mounts.keys) {
        final mountUri = mount;
        if (uri.toString().startsWith(mountUri)) {
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

  final mounts = <String, dynamic>{};

  Future<void> mountUri(String path, Uri uri) async {
    final localUri =
        resolvePath(path); // TODO Check if already mounted (recursive)
    validateAccess(
      localUri,
      read: true,
      write: true,
    );
    validateAccess(
      uri,
      read: true,
      write: false,
    );
    // log('mountUri $localUri $uri');
    if (mounts.containsKey(localUri.toString()))
      throw 'This path is already used as a mount point';

    mounts[localUri.toString()] = {
      'uri': uri.toString(),
    };
    log('mounts $mounts');
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

  void setFileState(String hash, FileState state) {
    log('setFileState $hash $state');
    // runningTasks
    getFileStateChangeNotifier(hash).updateFileState(state);
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
    final res = await getJsonEncryptedWithUri(uri);

    final directoryIndex = res.data != null
        ? DirectoryIndex.fromJson(res.data)
        : DirectoryIndex(
            directories: {},
            files: {},
          );

    final tasks = <DirectoryOperationTask>[];

    while (directoryOperationsQueue[uri]!.isNotEmpty) {
      final op = directoryOperationsQueue[uri]!.removeAt(0);
      tasks.add(op);
    }

    bool doUpdate = false;

    for (final task in tasks) {
      try {
        final res = await task.operation(directoryIndex);
        if (res != false) {
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

    var result = DirectoryOperationTaskResult(true);
    if (doUpdate) {
      if (uri.host == 'local') {
        // TODO Retry when an error happens here
        final success = await mySkyProvider.setJSONEncrypted(
          uriPathToMySkyPath(uri.pathSegments),
          directoryIndex,
          res.revision + 1,
        );

        if (success != true) throw 'Something went wrong';

        result = DirectoryOperationTaskResult(success);
      } else {
        final userInfo = uri.userInfo;

        final skynetUser = await _getSkynetUser(userInfo);
        final path = [...uri.pathSegments, 'index.json'].join('/');

        final success = await mysky_io_impl.setEncryptedJSON(
          skynetUser,
          path,
          directoryIndex,
          res.revision + 1,
          skynetClient: client,
        );

        if (success != true) throw 'Something went wrong';

        result = DirectoryOperationTaskResult(success);
      }
    }
    for (final task in tasks) {
      if (!task.completer.isCompleted) {
        task.completer.complete(result);
      }
    }

    if (uri.path == '/' + DATA_DOMAIN) return;

    getDirectoryIndexChangeNotifier(
      convertUriToHashForCache(uri),
    ).updateDirectoryIndex(directoryIndex);

    directoryIndexCache.put(
      convertUriToHashForCache(uri),
      CachedEntry(
        revision: res.revision + 1,
        data: json.encode(
          directoryIndex,
        ),
      ),
    );
  }

  String uriPathToMySkyPath(List<String> pathSegments) {
    return [...pathSegments, 'index.json'].join('/');
  }

  bool checkAccess(
    String path, {
    bool read = true,
    bool write = true,
  }) {
    final uri = resolvePath(path);
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

  Future<DirectoryIndex> getAllFiles({
    String startDirectory = '',
    required bool includeFiles,
    required bool includeDirectories,
  }) async {
    if (!rootAccessEnabled) {
      throw 'Permission denied';
    }

    final result = DirectoryIndex(
      directories: {},
      files: {},
    );
    Future<void> processDirectory(String path) async {
      final dir =
          getDirectoryIndexCached(path) ?? await getDirectoryIndex(path);

      for (final subDir in dir.directories.keys) {
        if (subDir.isNotEmpty) {
          await processDirectory('$path/$subDir');
          if (includeDirectories) {
            result.directories[parsePath('$path/$subDir').toString()] =
                dir.directories[subDir]!;
          }
        }
      }
      if (includeFiles) {
        for (final key in dir.files.keys) {
          final uri = parsePath('$path/$key');
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
    if (uri.host == 'local') {
      if (rootAccessEnabled) {
        if (uri.pathSegments.length > 1 && uri.pathSegments[1] == DATA_DOMAIN) {
          if (write) {
            throw 'Writing to internal paths is forbidden';
          }
          return;
        } else {
          return;
        }
      }

      if (uri.pathSegments.length < 2) {
        throw 'Access denied, path too short';
      }

      if (uri.pathSegments[0] != DATA_DOMAIN) {
        throw 'Internal permission error';
      }

      if (uri.pathSegments[1] != skapp) {
        throw 'Access denied.';
      }
    } else {
      if (uri.userInfo.startsWith('r:')) {
        if (write) {
          throw 'Can\'t write to read-only shared directories or files';
        }
      } else if (uri.userInfo.startsWith('rw:')) {
      } else {
        throw 'URI not supported (you might be using a deprecated format)';
      }
    }
  }

  int nowTimestamp() {
    return DateTime.now().millisecondsSinceEpoch;
  }

  String convertUriToHashForCache(Uri uri) {
    return sha256.convert(utf8.encode(uri.toString())).toString();
  }

  Uri resolvePath(String path) {
    return parsePath(path);
  }

  DirectoryIndex? getDirectoryIndexCached(String rawPath) {
    final uri = parsePath(rawPath);
    final uriHash = convertUriToHashForCache(uri);
    // TODO Permission checks

    if (directoryIndexCache.containsKey(uriHash)) {
      final cachedEntry = directoryIndexCache.get(uriHash)!;

      late final DirectoryIndex index;
      if (cachedEntry.data != 'null') {
        index = DirectoryIndex.fromJson(
            json.decode(cachedEntry.data).cast<String, dynamic>());
      } else {
        index = DirectoryIndex(directories: {}, files: {});
      }

      return index;
    }
  }

  Future<DirectoryIndex> getDirectoryIndex(String path) async {
    final parsedPath = parsePath(path);
    log('getDirectoryIndex $parsedPath');

    validateAccess(
      parsedPath,
      read: true,
      write: false,
    );

    final di = await _getDirectoryIndexInternal(parsedPath);

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
      for (final key in di.files.keys) {
        di.files[key]!.uri = key;
      }

      for (final key in di.directories.keys) {
        di.directories[key]!.uri = key;
      }
    }

    return di;
  }

  Future<DirectoryIndex> _getDirectoryIndexInternal(Uri parsedPath) async {
    final uriHash = convertUriToHashForCache(parsedPath);

    log('getDirectoryIndex $parsedPath');

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

      getDirectoryIndexChangeNotifier(uriHash).updateDirectoryIndex(di);
      return di;
    }

    int revision;
    Map<String, dynamic>? data;

    var hasUpdate = false;

    final res = await getJsonEncryptedWithUri(
      parsedPath,
    );

    if (directoryIndexCache.containsKey(uriHash)) {
      final existing = directoryIndexCache.get(uriHash)!;
      if (existing.revision < res.revision) {
        await directoryIndexCache.put(
          uriHash,
          CachedEntry(
            data: json.encode(res.data),
            revision: res.revision,
          ),
        );
        hasUpdate = true;
      }
    } else {
      await directoryIndexCache.put(
        uriHash,
        CachedEntry(
          data: json.encode(res.data),
          revision: res.revision,
        ),
      );
      hasUpdate = true;
    }
    revision = res.revision;
    if (res.data != null) {
      data = res.data as Map<String, dynamic>;
    }

    if (revision == -1 || data == null) {
      final index = DirectoryIndex(
        directories: {},
        files: {},
      );
      if (hasUpdate) {
        getDirectoryIndexChangeNotifier(uriHash).updateDirectoryIndex(index);
      }
      return index;
    }
    final directoryIndex = DirectoryIndex.fromJson(data);

    if (hasUpdate) {
      getDirectoryIndexChangeNotifier(uriHash)
          .updateDirectoryIndex(directoryIndex);
    }
    return directoryIndex;
  }

  Future<int> calculateRecursiveDirectorySize(String path) async {
    final di = await getAllFiles(
      startDirectory: path,
      includeFiles: true,
      includeDirectories: false,
    );
    return di.files.values.fold<int>(
        0, (previousValue, element) => previousValue + element.file.size);
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
      (directoryIndex) async {
        if (directoryIndex.directories.containsKey(name))
          throw 'Directory already contains a folder with the same name';

        directoryIndex.directories[name] = DirectoryDirectory(
          created: nowTimestamp(),
          name: name,
        );
      },
    );

    return res;
  }

  // TODO This is not recursive (yet)!
  Future<DirectoryOperationTaskResult> deleteDirectory(
    String path,
    String name,
  ) async {
    final uri = parsePath(path);
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
      (directoryIndex) async {
        if (directoryIndex.directories.isNotEmpty)
          throw 'Directory still contains subdirectories';
        if (directoryIndex.files.isNotEmpty)
          throw 'Directory still contains files';
        directoryIndex = DirectoryIndex(directories: {}, files: {});
      },
    );
    if (!res.success) return res;

    final res2 = await doOperationOnDirectory(
      uri,
      (directoryIndex) async {
        directoryIndex.directories.remove(name);
      },
    );

    return res2;
  }

  Future<SkynetUser> _getSkynetUser(String userInfo) async {
    if (!skynetUserCache.containsKey(userInfo)) {
      final mySkySeed = base64Url.decode(
        userInfo.substring(3),
      );
      final user = await SkynetUser.fromMySkySeedRaw(mySkySeed);
      skynetUserCache[userInfo] = user;
    }
    return skynetUserCache[userInfo]!; // TODO Error handling
  }

  Future<String> getShareUriReadOnly(String path) async {
    final uri = parsePath(path);

    validateAccess(
      uri,
      read: true,
      write: false,
    );

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

    return 'skyfs://r:${base64Url.encode(hex.decode(pathSeed))}@${await mySkyProvider.userId()}';
  }

  // TODO Better method name
  Future<String> generateSharedReadWriteDirectory() async {
    final seed = pinenacl.PineNaClUtils.randombytes(16);

    return 'skyfs://rw:${base64Url.encode(seed)}@shared';
  }

  Future<DirectoryOperationTaskResult> createFile(
    String directoryPath,
    String name,
    FileData fileData,
  ) async {
    final path = parsePath(directoryPath);

    validateAccess(
      path,
      read: true,
      write: true,
    );

    validateFileSystemEntityName(name);

    log('createFile $path $name [skapp: $skapp]');

    final res = await doOperationOnDirectory(
      path,
      (directoryIndex) async {
        if (directoryIndex.files.containsKey(name))
          throw 'Directory already contains a file with the same name';

        final file = DirectoryFile(
          created: fileData.ts,
          modified: fileData.ts,
          name: name,
          mimeType: lookupMimeType(name),
          version: 0,
          history: {},
          file: fileData,
          ext: fileData.ext,
        );
        file.file.ext = null;
        directoryIndex.files[name] = file;
        submitFileToIndexer(directoryPath, file);
      },
    );
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

    return FilePathParseResponse(
        filePath.substring(0, filePath.length - fileName.length - 1), fileName);
  }

  Future<DirectoryOperationTaskResult> copyFile(
    String sourceFilePath,
    String targetDirectoryPath,
  ) async {
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
    final sourceDir = await getDirectoryIndex(source.directoryPath);
    if (!sourceDir.files.containsKey(sourceFileName)) {
      throw 'Source file does not exist.';
    }

    final res = await doOperationOnDirectory(
      targetDirectory,
      (directoryIndex) async {
        if (directoryIndex.files.containsKey(sourceFileName))
          throw 'Target directory already contains a file with the same name';

        directoryIndex.files[sourceFileName] = sourceDir.files[sourceFileName]!;
      },
    );
    return res;
  }

  Future<DirectoryOperationTaskResult> moveFile(
    String sourceFilePath,
    String targetFilePath,
  ) async {
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
      (sourceDirIndex) async {
        if (!sourceDirIndex.files.containsKey(source.fileName))
          throw 'Source file does not exist.';

        final res = await doOperationOnDirectory(
          targetDirectory,
          (targetDirIndex) async {
            if (targetDirIndex.files.containsKey(target.fileName))
              throw 'Target directory already contains a file with the same name';

            targetDirIndex.files[target.fileName] =
                sourceDirIndex.files[source.fileName]!;

            targetDirIndex.files[target.fileName]!.name = target.fileName;
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
      (directoryIndex) async {
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
      (directoryIndex) async {
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

    final sourceDir = await getDirectoryIndex(sourceDirectoryPath);
    // log('cloneDirectory source index: ${json.encode(sourceDir)}');
    final res = await doOperationOnDirectory(
      targetDirectory,
      (directoryIndex) async {
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
          sourceDirectoryPath + '/$subDir',
          targetDirectoryPath + '/$subDir',
        );
      }
    }
  }

  bool isIndexPath(String path) {
    final uri = parsePath(path);
    return uri.path.startsWith('/$DATA_DOMAIN/$DATA_DOMAIN/index');
  }

  Future<DirectoryOperationTaskResult> updateFile(
    String directoryPath,
    String name,
    FileData fileData,
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
      (directoryIndex) async {
        if (!directoryIndex.files.containsKey(name))
          throw 'Directory does not contain a file with this name, so it can\'t be updated';

        final df = directoryIndex.files[name]!;

        df.modified = fileData.ts;

        df.history ??= {};
        df.history![df.version.toString()] = df.file;

        df.version++;

        df.file = fileData;

        df.ext = fileData.ext;

        df.file.ext = null;

        directoryIndex.files[name] = df;

        submitFileToIndexer(directoryPath, df);
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

  Future<void> submitFileToIndexer(
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
  }

// TODO Optimize
  Future<FileData> uploadFileData(
    String multihash,
    int size, {
    bool generateMetadata = false,
    String? filename,
    required Function customEncryptAndUploadFileFunction,
    Function? generateMetadataWrapper,
    Map<String, dynamic> additionalExt = const {},
  }) async {
    Map<String, dynamic>? ext;

    if (generateMetadata) {
      print('trying to extract metadata...');

      final rootPathSeed = await mySkyProvider.getEncryptedFileSeed(
          DATA_DOMAIN, true); // TODO Make this work when not logged in

      final res = await generateMetadataWrapper!(extension(filename!),
          rootPathSeed /* extractMetadata, [bytes, rootPathSeed] */);

      ext = json.decode(res[0]);

      int index = 1;

      for (final type in ['audio', 'video']) {
        if ((ext?[type] ?? {})?['coverKey'] != null) {
          ext![type]['coverKey'] =
              (await mySkyProvider.userId()) + '/' + ext[type]['coverKey'];

          uploadThumbnail(ext[type]['coverKey'], res[index]);

          index++;
        }
      }

      if (ext?.containsKey('thumbnail') ?? false) {
        ext!['thumbnail']['key'] =
            (await mySkyProvider.userId()) + '/' + ext['thumbnail']['key'];
        uploadThumbnail(ext['thumbnail']['key'], res[index]);
      }
    }

    for (final key in additionalExt.keys) {
      ext ??= {};
      ext[key] ??= {};
      for (final k in additionalExt[key].keys) {
        ext[key][k] = additionalExt[key][k];
      }
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

    ext['uploader'] = UniversalPlatform.isWeb ? 'fs-dac.hns:1' : 'vup.hns:1';

    final fileData = FileData(
      chunkSize: res.maxChunkSize,
      encryptionType: res.encryptionType,
      padding: res.padding,
      url: 'sia://${res.skylink}',
      key: base64Url.encode(res.secretKey),
      hash: multihash,
      size: size,
      ts: nowTimestamp(),
      ext: ext,
    );
    return fileData;
  }

  // TODO Use pool to prevent too many concurrent uploads
  Future<void> uploadThumbnail(String key, Uint8List bytes) async {
    final existing = await loadThumbnail(key);
    if (existing == null) {
      thumbnailCache.put(key, bytes);
      final parts = key.split('/');

      final keyInBytes = base64Url.decode(parts[1]);

      await mySkyProvider.setRawDataEncrypted(
        temporaryThumbnailKeyPaths[parts[1]] ?? '',
        bytes,
        0,
        customEncryptedFileSeed: hex.encode(
          keyInBytes,
        ),
      );
    }
  }

  // Map<String, Uint8List> thumbnailCache = {};

  Map<String, Completer<Uint8List?>> thumbnailCompleters = {};

  // TODO Optimization: only 1 concurrent instance / key
  Future<Uint8List?> loadThumbnail(String key) async {
    if (thumbnailCache.containsKey(key)) {
      return thumbnailCache.get(key);
    }
    if (thumbnailCompleters.containsKey(key)) {
      return thumbnailCompleters[key]!.future;
    }
    final completer = Completer<Uint8List?>();
    thumbnailCompleters[key] = completer;
    log('loadThumbnail $key');

    final parts = key.split('/');
    if (parts.length != 2) return null;
    final keyInBytes = base64Url.decode(parts[1]);

    final res = await mySkyProvider.getRawDataEncrypted(
      '',
      userID: parts[0],
      pathSeed: hex.encode(
        keyInBytes,
      ),
    );

    if (res.data == null) {
      completer.complete(null);
      return null;
    }

    final data = res.data!;
    thumbnailCache.put(key, data);

    completer.complete(data);

    return data;
  }

  final downloadChunkSize = 4 * 1000 * 1000;

  Stream<List<int>> _downloadFileInChunks(
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
  }

  Future<Stream<Uint8List>> downloadAndDecryptFile(
    FileData fileData, {
    Function? onProgress,
  }) async {
    log('downloadAndDecryptFile');

    final chunkSize = fileData.chunkSize; // ?? maxChunkSize;

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

    final streamCtrl = StreamController<SecretStreamCipherMessage>();

    final secretKey = base64Url.decode(fileData.key);
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
        trusted: true, // TODO Maybe remove this
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
        // TODO Handle error
      },
      cancelOnError: true,
    );

    return transformer.map((event) => event.message);
  }

  Future<Stream<Uint8List>> downloadAndDecryptFileInChunks(
    FileData fileData, {
    Function? onProgress,
  }) async {
    log('[download+decrypt] using libsodium_secretbox');

    final chunkSize = fileData.chunkSize;

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

    final totalEncSize = ((fileData.size / fileData.chunkSize).floor() *
            (fileData.chunkSize + 16)) +
        (fileData.size % fileData.chunkSize) +
        16 +
        fileData.padding;

    final streamCtrl = StreamController<Uint8List>();

    final secretKey = base64Url.decode(fileData.key);
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

    void sendDownloadRequest() async {
      try {
        final request = http.Request('GET', url);
        request.headers.addAll(client.headers ?? {});
        request.headers['range'] = 'bytes=$downloadedLength-';

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
        print(diff);
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
          if (fileData.padding > 0) {
            log('[download+decrypt] remove padding...');
            streamCtrl.add(r.sublist(0, r.length - fileData.padding));
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
        // TODO Handle error
      },
      cancelOnError: true,
    );

    return streamCtrl.stream;
  }
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

  final Map<String, SkynetUser> skynetUserCache = {};

  Future<DataWithRevision<dynamic>> getJsonEncryptedWithUri(Uri uri) async {
    log('getJsonEncryptedWithUri $uri');
    if (uri.host == 'local') {
      log('uriPathToMySkyPath result ${uriPathToMySkyPath(uri.pathSegments)}');
      return mySkyProvider.getJSONEncrypted(
        uriPathToMySkyPath(uri.pathSegments),
      );
    } else {
      final userInfo = uri.userInfo;
      if (userInfo.startsWith('r:')) {
        final userId = uri.host;
        final rootPathSeed = hex.encode(
          base64Url.decode(
            userInfo.substring(2),
          ),
        );
        final path = [...uri.pathSegments, 'index.json'].join('/');

        log('userId $userId');
        log('rootPathSeed $rootPathSeed');
        log('path $path');

        final childPathSeed = deriveEncryptedPathSeed(
          rootPathSeed,
          path,
          false,
        );
        log('childPathSeed $childPathSeed');

        return mySkyProvider.getJSONEncrypted(
          '',
          userID: userId,
          pathSeed: childPathSeed,
        );
      } else if (userInfo.startsWith('rw:')) {
        final skynetUser = await _getSkynetUser(userInfo);
        final path = [...uri.pathSegments, 'index.json'].join('/');

        final pathSeed = await mysky_io_impl.getEncryptedPathSeed(
          path,
          false,
          skynetUser.rawSeed,
        );

        return mysky_io_impl.getJSONEncrypted(
          skynetUser.id,
          pathSeed,
          skynetClient: client,
        );
      } else {
        throw 'Invalid URI';
      }
    }
  }

  void log(
    String message,
  ) {
    if (debugEnabled) {
      print('[FileSystemDAC] $message');
    }
  }
}

class FileStateNotifier extends StateNotifier<FileState> {
  FileStateNotifier()
      : super(FileState(
          type: FileStateType.idle,
          progress: null,
        ));

  void updateFileState(FileState fileState) {
    state = fileState;
  }
}

class DirectoryIndexChangeNotifier extends StateNotifier<DirectoryIndex?> {
  DirectoryIndexChangeNotifier() : super(null);

  void updateDirectoryIndex(DirectoryIndex index) {
    state = index;
  }
}

class UploadingFilesChangeNotifier
    extends StateNotifier<Map<String, DirectoryFile>> {
  UploadingFilesChangeNotifier() : super({});

  void removeUploadingFile(String name) {
    final map = Map.of(state);
    state.remove(name);
    map.remove(name);
    state = map;
  }

  void addUploadingFile(DirectoryFile file) {
    final map = Map.of(state);

    map[file.name] = file;

    state = map;
  }
}

class EncryptAndUploadResponse {
  final String skylink;
  final Uint8List secretKey;
  final String encryptionType;
  final int maxChunkSize;
  final int padding;
  // final Uint8List nonce;
  EncryptAndUploadResponse({
    required this.skylink,
    required this.secretKey,
    required this.encryptionType,
    required this.maxChunkSize,
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
  DirectoryOperationTaskResult(this.success, {this.error});

  Map toJson() {
    final map = <String, dynamic>{'success': success};
    if (!success) {
      map['error'] = error;
    }
    return map;
  }
}
