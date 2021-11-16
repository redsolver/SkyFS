import 'dart:convert';
import 'dart:html';

import 'package:skynet/src/skystandards/fs.dart';
import 'package:skynet/src/dacs/dac_library.dart';
import 'package:skynet/src/utils/js.dart';

const DAC_DOMAIN = "fs-dac.hns";

class FileSystemDAC extends DACLibrary {
  FileSystemDAC() : super(DAC_DOMAIN);

  Future<Blob> downloadFileData(
      FileData fileData, String mimeType, Function onProgress) async {
    return await call("downloadFileData", [
      jsify(fileData),
      mimeType,
      /* onProgress, onChunk */
      passCallback(onProgress)
    ]);
  }

  Future<Blob> loadThumbnail(String key) async {
    return await call("loadThumbnail", [key]);
  }

  Future<FileData> uploadFileData(
      Blob blob, String filename, Function onProgress) async {
    return FileData.fromJson(json.decode(
      json.encode(
        await call(
          "uploadFileData",
          [blob, filename, passCallback(onProgress)],
        ),
      ),
    ));
  }

  Future<dynamic> createFile(
    String directoryPath,
    String name,
    FileData fileData,
  ) async {
    return await call("createFile", [
      directoryPath,
      name,
      jsify(fileData),
    ]);
  }

  Future<dynamic> createDirectory(String path, String name) async {
    return await call("createDirectory", [
      path,
      name,
    ]);
  }

  Future<dynamic> mountUri(String localPath, String uri) async {
    return await call("mountUri", [
      localPath,
      uri,
    ]);
  }

  /**
  * Everyone who receives the share uri for the specified path can read all files and subdirectories in it.
  * It is not possible to revoke the share seed once it is shared with someone. It is recommended to create a new hidden directory only used for sharing instead.
  */
  Future<String> getShareUriReadOnly(
    String path,
  ) async {
    return await call("getShareUriReadOnly", [
      path,
    ]);
  }

  Future<String> generateShareUriReadWrite() async {
    return await call("generateShareUriReadWrite", []);
  }

  Future<DirectoryIndex> getDirectoryIndex(
    String path,
  ) async {
    return DirectoryIndex.fromJson(
        json.decode(json.encode(await call("getDirectoryIndex", [path]))));
  }
}
