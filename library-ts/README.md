# TypeScript library for the File System DAC

This library exposes a class that wraps the [File System DAC](https://github.com/redsolver/filesystem-dac).

## Install

https://www.npmjs.com/package/fs-dac-library

## Things to know

In the FS DAC, paths to directories and files are seperated with `/` and **do not** start with a leading slash.

If you skapp is hosted at `example.hns.siasky.net`, you only have read+write access to all local (owned by the currently logged-in user) paths starting with `example.hns/` by default.

This DAC can be used without being logged in to MySky, but some methods might not work as expected.

## Usage

```typescript
import { MySky, SkynetClient } from "skynet-js";
import { FileSystemDAC } from "fs-dac-library";

(async () => {
  // create client
  const client = new SkynetClient(); // You might need to use SkynetClient("https://siasky.net") here if testing on localhost

  // Initialize the File System DAC library
  const fileSystemDAC = new FileSystemDAC();

  // Load MySky
  const mySky = await client.loadMySky("example.hns", {}); // Warning: You need to specify your app domain here, "localhost" if you are testing on localhost

  // Load the File System DAC
  await mySky.loadDacs(fileSystemDAC);

  // Check if the user is logged in
  const isLoggedIn = await mySky.checkLogin();

  // Create a new directory
  const res = await fileSystemDAC.createDirectory("example.hns", "Documents");

  // The result contains a "success" bool value indicating if the operation was successfull
  console.log(res.success);
  console.log(res);

  // Get a file or blob (for example from a file input field)
  const file = ...

  // Encrypt and upload a file
  const fileData = await fileSystemDAC.uploadFileData(file, file.name, (progress) => {
    console.log("onProgress", progress);
  });

  // Create a new file in the new "Documents" directory containing the just uploaded FileData
  const res = await fileSystemDAC.createFile(
    "example.hns/Documents",
    f.name,
    fileData
  );

  // List the contents of a specific directory (files and subdirectories)
  const index = await fileSystemDAC.getDirectoryIndex(
    "example.hns/Documents"
  );
  console.log(index);

  // Pick a file from the directory
  const dirFile =
      index.files["HelloWorld.pdf"]; // Adjust this to a filename you created in the directory

  // Download and decrypt this file
  const blob = await fileSystemDAC.downloadFileData(
    fileData,
    dirFile.mimeType ?? "application/octet-stream",
    (progress) => {
      console.log("onProgress", progress);
    }
  );
})();
```
