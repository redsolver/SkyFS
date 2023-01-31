import 'dart:typed_data';

import 'package:filesystem_dac/model/cached_entry.dart';
import 'package:hive/hive.dart';
import 'package:lib5/lib5.dart';

import 'base.dart';

// TODO Improve efficiency, especially for Vup

class HiveDirectoryMetadataCache extends DirectoryMetadataCache {
  final Box<Uint8List> box;
  HiveDirectoryMetadataCache(this.box);

  @override
  CachedDirectoryMetadata? get(Multihash hash) {
    final bytes = box.get(hash.toBase64Url());
    if (bytes != null) {
      return CachedDirectoryMetadata.unpack(bytes);
    }
    return null;
  }

  @override
  void set(Multihash hash, CachedDirectoryMetadata metadata) {
    box.put(hash.toBase64Url(), metadata.pack());
  }

  @override
  bool has(Multihash hash) {
    return box.containsKey(hash.toBase64Url());
  }
}
