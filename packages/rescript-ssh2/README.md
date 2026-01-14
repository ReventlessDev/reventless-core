# `rescript-ssh2`

ReScript bindings for [ssh2](https://github.com/mscdex/ssh2) - SSH2 client and server modules for Node.js.

## Installation

Add `rescript-ssh2` to your dependencies:

```bash
npm install rescript-ssh2
```

Add `rescript-ssh2` to your `rescript.json`:

```json
{
  "bs-dependencies": ["rescript-ssh2"]
}
```

For general information see this monorepo's [readme](../../README.md).

## API Overview

### SSH2.Client

The Client module provides SSH connection functionality.

#### Creating a Client

```rescript
let client = SSH2.Client.make()
```

#### Connection Configuration

```rescript
type config = {
  host?: string,              // Hostname or IP address (default: "localhost")
  port?: int,                 // Port number (default: 22)
  forceIPv4?: bool,          // Force IPv4 only
  forceIPv6?: bool,          // Force IPv6 only
  username?: string,          // Username for authentication
  password?: string,          // Password for password-based authentication
  privateKey?: string,        // Private key for key-based authentication
  passphrase?: string,        // Passphrase for encrypted private key
  readyTimeout?: int,         // Timeout in ms (default: 20000)
  debug?: string => unit,     // Debug output function
}
```

#### Client Methods

- **`connect(client, config)`** - Initiate SSH connection
- **`end_(client)`** - Close SSH connection
- **`onReady(client, callback)`** - Handle connection ready event
- **`onError(client, errorHandler)`** - Handle connection errors
- **`onTimeout(client, callback)`** - Handle connection timeout
- **`onEnd(client, callback)`** - Handle connection end event

### SFTP Operations

SFTP functionality is provided at the module level after establishing an SFTP session.

#### Starting an SFTP Session

```rescript
SSH2.make(client, (error, sftp) => {
  switch error {
  | Some(err) => Console.error("SFTP Error:", err)
  | None => // Use sftp
  }
})
```

#### SFTP Methods

- **`readdir(sftp, ~dirName, callback)`** - List directory contents
  - Returns array of entities with `filename`, `longname`, and `attrs` (size, uid, gid, atime, mtime)

- **`createReadStream(sftp, ~path, ~options?)`** - Create read stream for file
  - Options: `flags`, `encoding`, `handle`, `mode`, `autoClose`, `start`, `end`

- **`createWriteStream(sftp, ~path, ~options?)`** - Create write stream for file
  - Options: `flags`, `encoding`, `mode`

- **`fastGet(sftp, ~remotePath, ~localPath, ~options?, ~callback)`** - Fast file download
  - Options: `concurrency`, `chunkSize`, `step` (progress callback)

- **`onError(sftp, errorHandler)`** - Handle SFTP errors
- **`onEnd(sftp, callback)`** - Handle SFTP session end
- **`onClose(sftp, callback)`** - Handle SFTP session close

## Examples

### Basic SSH Connection with Password Authentication

```rescript
let client = SSH2.Client.make()

client
  ->SSH2.Client.onReady(client => {
    Console.log("SSH connection ready")
    client->SSH2.Client.end_()
  })
  ->SSH2.Client.onError(err => {
    Console.error("Connection error:", err)
  })
  ->SSH2.Client.onEnd(() => {
    Console.log("Connection closed")
  })
  ->SSH2.Client.connect({
    host: "example.com",
    port: 22,
    username: "myuser",
    password: "mypassword",
  })
```

### SSH Connection with Private Key

```rescript
open NodeJs

let privateKey = Fs.readFileSync("~/.ssh/id_rsa", #utf8)

let client = SSH2.Client.make()

client
  ->SSH2.Client.onReady(client => {
    Console.log("Authenticated with private key")
    client->SSH2.Client.end_()
  })
  ->SSH2.Client.connect({
    host: "example.com",
    username: "myuser",
    privateKey: privateKey,
  })
```

### SFTP: List Directory Contents

```rescript
let client = SSH2.Client.make()

client
  ->SSH2.Client.onReady(client => {
    SSH2.make(client, (error, sftp) => {
      switch error {
      | Some(err) => Console.error("SFTP Error:", err)
      | None =>
        sftp->SSH2.readdir(~dirName="/path/to/directory", (error, list) => {
          switch error {
          | Some(err) => Console.error("Readdir error:", SSH2.toJsError(err))
          | None =>
            list->Array.forEach(entity => {
              Console.log(`${entity.filename} (${entity.attrs.size->Int.toString} bytes)`)
            })
          }
          sftp->SSH2.end_()
          client->SSH2.Client.end_()
        })
      }
    })
  })
  ->SSH2.Client.connect({
    host: "example.com",
    username: "myuser",
    password: "mypassword",
  })
```

### SFTP: Download File with Progress

```rescript
let client = SSH2.Client.make()

client
  ->SSH2.Client.onReady(client => {
    SSH2.make(client, (error, sftp) => {
      switch error {
      | Some(err) => Console.error("SFTP Error:", err)
      | None =>
        sftp->SSH2.fastGet(
          ~remotePath="/remote/path/file.txt",
          ~localPath="/local/path/file.txt",
          ~options={
            concurrency: 64,
            chunkSize: 32768,
            step: (~totalTransferred, ~chunk, ~total) => {
              let percent = (totalTransferred->Int.toFloat /. total->Int.toFloat *. 100.0)
              Console.log(`Downloaded: ${percent->Float.toString}%`)
            },
          },
          ~callback=error => {
            switch error {
            | Some(err) => Console.error("Download error:", err)
            | None => Console.log("Download complete")
            }
            sftp->SSH2.end_()
            client->SSH2.Client.end_()
          },
        )
      }
    })
  })
  ->SSH2.Client.connect({
    host: "example.com",
    username: "myuser",
    password: "mypassword",
  })
```

### SFTP: Upload File Using Stream

```rescript
open NodeJs

let client = SSH2.Client.make()

client
  ->SSH2.Client.onReady(client => {
    SSH2.make(client, (error, sftp) => {
      switch error {
      | Some(err) => Console.error("SFTP Error:", err)
      | None =>
        let readStream = Fs.createReadStream("/local/path/file.txt")
        let writeStream = sftp->SSH2.createWriteStream(
          ~path="/remote/path/file.txt",
          ~options={mode: 0o644},
        )

        readStream->NodeStreams.Readable.pipe(writeStream)

        writeStream
          ->NodeStreams.Writable.onFinish(() => {
            Console.log("Upload complete")
            sftp->SSH2.end_()
            client->SSH2.Client.end_()
          })
          ->NodeStreams.Writable.onError(err => {
            Console.error("Upload error:", err)
            sftp->SSH2.end_()
            client->SSH2.Client.end_()
          })
      }
    })
  })
  ->SSH2.Client.connect({
    host: "example.com",
    username: "myuser",
    password: "mypassword",
  })
```

## Error Handling

The bindings provide proper error handling through option types and callbacks:

```rescript
// Client errors
client->SSH2.Client.onError(err => {
  Console.error("SSH Error:", err)
})

// SFTP errors
sftp->SSH2.onError(err => {
  Console.error("SFTP Error:", SSH2.toJsError(err))
})
```

## Type Conversions

- **`SSH2.toSftpError(Js.Exn.t)`** - Convert JS error to SFTP error
- **`SSH2.toJsError(error)`** - Convert SFTP error to JS error

## References

- [ssh2 Documentation](https://github.com/mscdex/ssh2)
- [ssh2 TypeScript Definitions](https://github.com/DefinitelyTyped/DefinitelyTyped/blob/master/types/ssh2/index.d.ts)

## Contribution

### Changelog
Please remember to update the changelog for any modifications accordingly!
