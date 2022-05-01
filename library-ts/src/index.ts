import { CustomConnectorOptions, DacLibrary, SkynetClient } from "skynet-js";

import { PermCategory, Permission, PermType } from "skynet-mysky-utils";

import {
  IFileSystemDACResponse
} from "./types";

import { DirectoryFile, DirectoryIndex, FileData } from "./skystandards";
export * from "./skystandards";

const DAC_DOMAIN = "fs-dac.hns";

export class FileSystemDAC extends DacLibrary {
  public constructor() {
    super(DAC_DOMAIN);
  }

  client: SkynetClient | undefined

  async init(client: SkynetClient, customOptions: CustomConnectorOptions): Promise<void> {
    this.client = client;

    return super.init(client, customOptions);
  }

  public getPermissions(): Permission[] {
    return [
      new Permission(
        DAC_DOMAIN,
        DAC_DOMAIN,
        PermCategory.Discoverable,
        PermType.Read
      ),
      new Permission(
        DAC_DOMAIN,
        DAC_DOMAIN,
        PermCategory.Discoverable,
        PermType.Write
      ),
    ];
  }

  public async uploadFileData(
    blob: Blob,
    filename?: string,
    onProgress?: (progress: number) => void,
  ): Promise<FileData> {
    if (!this.connector) {
      throw new Error("Connector not initialized");
    }

    return await this.connector.connection
      .remoteHandle()
      .call("uploadFileData", blob, filename, onProgress);
  }

  public async downloadFileData(
    fileData: FileData,
    mimeType: string,
    onProgress?: (progress: number) => void,
    onChunk?: (blob: Blob) => void,
  ): Promise<Blob> {
    if (!this.connector) {
      throw new Error("Connector not initialized");
    }

    return await this.connector.connection
      .remoteHandle()
      .call("downloadFileData", fileData, mimeType, onProgress, onChunk);
  }

  public async loadThumbnail(
    key: string,
  ): Promise<Blob> {
    if (!this.connector) {
      throw new Error("Connector not initialized");
    }

    return await this.connector.connection
      .remoteHandle()
      .call("loadThumbnail", key);
  }

  public async createDirectory(
    path: string,
    name: string,
  ): Promise<IFileSystemDACResponse> {
    if (!this.connector) {
      throw new Error("Connector not initialized");
    }

    return await this.connector.connection
      .remoteHandle()
      .call("createDirectory", path, name);
  }

  public async copyFile(
    sourceFilePath: string,
    targetDirectoryPath: string,
  ): Promise<IFileSystemDACResponse> {
    if (!this.connector) {
      throw new Error("Connector not initialized");
    }

    return await this.connector.connection
      .remoteHandle()
      .call("copyFile", sourceFilePath, targetDirectoryPath);
  }

  public async moveFile(
    sourceFilePath: string,
    targetFilePath: string,
  ): Promise<IFileSystemDACResponse> {
    if (!this.connector) {
      throw new Error("Connector not initialized");
    }

    return await this.connector.connection
      .remoteHandle()
      .call("moveFile", sourceFilePath, targetFilePath);
  }

  public async renameFile(
    filePath: string,
    newName: string,
  ): Promise<IFileSystemDACResponse> {
    if (!this.connector) {
      throw new Error("Connector not initialized");
    }

    return await this.connector.connection
      .remoteHandle()
      .call("renameFile", filePath, newName);
  }

  public async createFile(
    directoryPath: string,
    name: string,
    fileData: FileData,
  ): Promise<IFileSystemDACResponse> {
    if (!this.connector) {
      throw new Error("Connector not initialized");
    }

    return await this.connector.connection
      .remoteHandle()
      .call("createFile", directoryPath, name, fileData);
  }

  public async createFileWithReturnValue(
    directoryPath: string,
    name: string,
    fileData: FileData,
  ): Promise<DirectoryFile> {
    if (!this.connector) {
      throw new Error("Connector not initialized");
    }

    const res: IFileSystemDACResponse = await this.connector.connection
      .remoteHandle()
      .call("createFile", directoryPath, name, fileData);

    if (!res.success) {
      throw new Error(res.error);
    }

    return res.data as DirectoryFile;
  }

  public async updateFile(
    directoryPath: string,
    name: string,
    fileData: FileData,
  ): Promise<IFileSystemDACResponse> {
    if (!this.connector) {
      throw new Error("Connector not initialized");
    }

    return await this.connector.connection
      .remoteHandle()
      .call("updateFile", directoryPath, name, fileData);
  }

  public async getDirectoryIndex(
    path: string,
  ): Promise<DirectoryIndex> {
    if (!this.connector) {
      throw new Error("Connector not initialized");
    }

    return await this.connector.connection
      .remoteHandle()
      .call("getDirectoryIndex", path);
  }

  /**
  * Everyone who receives the share uri for the specified path can read all files and subdirectories in it.
  * It is not possible to revoke the share seed once it is shared with someone. It is recommended to create a new hidden directory only used for sharing instead.
  */
  public async getShareUriReadOnly(
    path: string,
  ): Promise<string> {
    if (!this.connector) {
      throw new Error("Connector not initialized");
    }

    return await this.connector.connection
      .remoteHandle()
      .call("getShareUriReadOnly", path);
  }

  public async mountUri(
    localPath: string,
    uri: string,
  ): Promise<IFileSystemDACResponse> {
    if (!this.connector) {
      throw new Error("Connector not initialized");
    }

    return await this.connector.connection
      .remoteHandle()
      .call("mountUri", localPath, uri);
  }

  public async generateShareUriReadWrite(): Promise<string> {
    if (!this.connector) {
      throw new Error("Connector not initialized");
    }

    return await this.connector.connection
      .remoteHandle()
      .call("generateShareUriReadWrite");
  }
}
