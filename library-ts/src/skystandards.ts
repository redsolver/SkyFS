/**
 * Multihash of the unencrypted file, starts with 1220 for sha256
 */
export type Multihash = string

/**
 * Specific version of a file. Immutable.
 */
export interface FileData {
    /**
     * Can be used by applications to add more metadata
     */
    ext?: { [key: string]: any };

    /**
     * URL where the encrypted file blob can be downloaded, usually a skylink (sia://)
     */
    url: string
    /**
     * The secret key used to encrypt this file, base64Url-encoded
     */
    key?: string
    /**
     * Which algorithm is used to encrypt and decrypt this file
     */
    encryptionType?: string

    /**
     * Unencrypted size of the file, in bytes
     */
    size: number

    /**
     * Padding bytes count
     */
    padding?: number

    /**
     * maxiumum size of every unencrypted file chunk in bytes
     */
    chunkSize?: number
    hash: Multihash
    /**
     * Unix timestamp (in milliseconds) when this version was added to the FileSystem DAC
     */
    ts: number
    [k: string]: unknown
}

/**
 * Metadata of a file, can contain multiple versions
 */
export interface DirectoryFile {

    /**
     * Can be used by applications to add more metadata
     */
    ext?: { [key: string]: any };

    /**
     * Name of this file
     */
    name: string
    /**
     * Unix timestamp (in milliseconds) when this file was created
     */
    created: number
    /**
     * Unix timestamp (in milliseconds) when this file was last modified
     */
    modified: number
    /**
     * MIME Type of the file, optional
     */
    mimeType?: string
    /**
     * Current version of the file. When this file was already modified 9 times, this value is 9
     */
    version: number
    /**
     * The current version of a file
     */
    file: FileData
    /**
     * Historic versions of a file
     */
    history?: {
        /**
         * A file version
         *
         * This interface was referenced by `undefined`'s JSON-Schema definition
         * via the `patternProperty` "^[0-9]+$".
         */
        [k: string]: FileData
    }
    [k: string]: unknown
}

/**
 * Index file of a directory, contains all directories and files in this specific directory
 */
export interface DirectoryIndex {
    /**
     * A subdirectory in this directory
     */
    directories: {
        /**
         * This interface was referenced by `undefined`'s JSON-Schema definition
         * via the `patternProperty` "^.+$".
         */
        [k: string]: {
            /**
             * Name of this directory
             */
            name?: string
            /**
             * Unix timestamp (in milliseconds) when this directory was created
             */
            created?: number
            [k: string]: unknown
        }
    }
    /**
     * A file in this directory
     */
    files: {
        /**
         * Metadata of a file, can contain multiple versions
         *
         * This interface was referenced by `undefined`'s JSON-Schema definition
         * via the `patternProperty` "^.+$".
         */
        [k: string]: DirectoryFile
    }
    [k: string]: unknown
}
