import 'package:filesystem_dac/model/cached_entry.dart';
import 'package:lib5/lib5.dart';

abstract class DirectoryMetadataCache {
  CachedDirectoryMetadata? get(Multihash hash);
  void set(Multihash hash, CachedDirectoryMetadata metadata);
  bool has(Multihash hash);
}
