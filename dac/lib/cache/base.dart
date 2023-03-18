import 'package:filesystem_dac/model/cached_entry.dart';
import 'package:lib5/lib5.dart';

class DirectoryMetadataCache {
  // final Box<Uint8List> box;
  final KeyValueDB db;
  DirectoryMetadataCache(this.db);

  CachedDirectoryMetadata? get(Multihash hash) {
    final bytes = db.get(hash.fullBytes);
    if (bytes != null) {
      return CachedDirectoryMetadata.unpack(bytes);
    }
    return null;
  }

  void set(Multihash hash, CachedDirectoryMetadata metadata) {
    db.set(hash.fullBytes, metadata.pack());
  }

  bool has(Multihash hash) {
    return db.contains(hash.fullBytes);
  }
  /* CachedDirectoryMetadata? get(Multihash hash);
  void set(Multihash hash, CachedDirectoryMetadata metadata);
  bool has(Multihash hash); */
}
