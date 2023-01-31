import 'dart:typed_data';

import 'package:lib5/lib5.dart';
import 'package:messagepack/messagepack.dart';

class CachedDirectoryMetadata {
  final DirectoryMetadata data;
  final int revision;
  final CID? cid;

  CachedDirectoryMetadata({
    required this.data,
    required this.revision,
    required this.cid,
  });

  factory CachedDirectoryMetadata.unpack(Uint8List bytes) {
    final u = Unpacker(bytes);
    final revision = u.unpackInt()!;
    final cidBytes = u.unpackBinary();

    return CachedDirectoryMetadata(
      revision: revision,
      cid: cidBytes.isEmpty
          ? null
          : CID.fromBytes(
              cidBytes,
            ),
      data: DirectoryMetadata.deserizalize(u.unpackBinary()),
    );
  }

  Uint8List pack() {
    final p = Packer();
    p.packInt(revision);
    p.packBinary(cid?.toBytes());
    p.packBinary(data.serialize());
    return p.takeBytes();
  }
}
