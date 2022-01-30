# SkyFS

SkyFS manages a virtual encrypted file system structure and exposes methods to manipulate it to Skynet apps.

It uses the https://github.com/SkynetLabs/skystandards data structures.

## Features

- upload and download files (with automatic encryption)
- automatic metadata extraction and thumbnail generation for most image formats (including exif) and audio files (MP3 and FLAC, with cover images)
- list, create and delete directories
- create, update, copy, move and rename files
- share directories (read-only+static, read-only+updates and read+write)
- mount directories (both local and all types of shared directories) in another directory (only temporarily)
- global index of all images, audio files and videos uploaded by the currently logged-in user

## TypeScript library

[Link to install instructions and docs](https://github.com/redsolver/skyfs/tree/main/library-ts)
