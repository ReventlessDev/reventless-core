/** Bindings for SSH2 library
  https://github.com/mscdex/ssh2
 */
module Client = {
  type t

  /** Create a ConnectConfig JS-Object
		see: https://github.com/DefinitelyTyped/DefinitelyTyped/blob/3a2e4f09750932786e7d9c4200d7b9145488b48d/types/ssh2/index.d.ts#L413
    */
  type config = {
    host?: string,
    port?: int,
    forceIPv4?: bool,
    forceIPv6?: bool,
    username?: string,
    password?: string,
    privateKey?: string,
    passphrase?: string,
    readyTimeout?: int /* in ms, default = 20000 */,
    debug?: string => unit,
  }

  @module("ssh2") @new external make: unit => t = "Client"
  @send external onReady: (t, @as("ready") _, unit => unit) => t = "on"
  @send external onError: (t, @as("error") _, JsExn.t => unit) => t = "on"
  @send external onTimeout: (t, @as("timeout") _, unit => unit) => t = "on"
  @send external onEnd: (t, @as("end") _, unit => unit) => t = "on"
  @send external connect: (t, config) => unit = "connect"
  @send external end_: t => unit = "end"
  @send external error: (t, @as("error") _, JsExn.t) => bool = "emit"

  /** Helper function to pass the client into the callback of onReady */
  let onReady: (t, t => unit) => t = (client, handler) => client->onReady(() => handler(client))
}

type t
/** Error in sftp connection
   in typescript = any
 */
type error
type attrs = {size: int, uid: int, gid: int, atime: int, mtime: string}
type entity = {
  filename: string,
  longname: string,
  attrs: attrs,
}

/** Construct a js Error object from a string
  TODO: hide behind an interface definition
 */
@new
external makeError: string => JsExn.t = "Error"

external toSftpError: JsExn.t => error = "%identity"
external toJsError: error => JsExn.t = "%identity"

/** Starts an SFTP session
  Returns `false` if you should wait for the `continue`event before sending any more traffic
 */
@send
external make: (Client.t, (option<JsExn.t>, t) => unit) => bool = "sftp"

/** Retrieves a directory listing
  Returns `false`if you should wait for the `continue`event before sending any more traffic.
 */
@send
external readdir: (t, ~dirName: string, (option<error>, array<entity>) => unit) => bool = "readdir"
@send external end_: t => unit = "end"

module ReadStreamOptions = {
  type nodeBuffer
  /**
     see: https://github.com/DefinitelyTyped/DefinitelyTyped/blob/85dafa11088e72047bb240c04ddbec3a1c2a15fc/types/ssh2-streams/index.d.ts#L1638 "
  */
  type t = {
    flags?: string,
    encoding?: string,
    handle?: nodeBuffer,
    mode?: int,
    autoClose?: bool,
    start?: int,
    end?: int,
  }
}

@send
external createReadStream: (
  t,
  ~path: string,
  ~options: ReadStreamOptions.t=?,
) => NodeStreams.Readable.t = "createReadStream"

type fastOptions = {
  concurrency?: int,
  chunkSize?: int,
  step?: (~totalTransferred: int, ~chunk: int, ~total: int) => unit,
}

@send
external fastGet: (
  t,
  ~remotePath: string,
  ~localPath: string,
  ~options: fastOptions=?,
  ~callback: option<JsExn.t> => unit,
) => unit = "fastGet"

/**
  see: https://github.com/DefinitelyTyped/DefinitelyTyped/blob/85dafa11088e72047bb240c04ddbec3a1c2a15fc/types/ssh2-streams/index.d.ts#L1648 "
*/
type writeStreamOptions = {
  flags?: string,
  encoding?: string,
  mode?: int,
}

@send
external createWriteStream: (
  t,
  ~path: string,
  ~options: writeStreamOptions=?,
) => NodeStreams.Writable.t = "createWriteStream"

/** Emit an error-event
  Returns `true` if the event had listeners, `false` otherwise.
 */
@send
external error: (t, @as("error") _, error) => bool = "emit"
let extendedError: (~originalError: error, ~customError: JsExn.t=?, t) => bool = (
  ~originalError,
  ~customError=?,
  sftp,
) =>
  switch customError {
  | Some(err) => sftp->error(err->toSftpError)
  | None => false
  } ||
  sftp->error(originalError)

/** Error-event gets emitted when an error occured */
@send
external onError: (t, @as("error") _, error => unit) => t = "on"
/** End-event gets emitted when the session has ended */
@send
external onEnd: (t, @as("end") _, unit => unit) => t = "on"
/** Close-event gets emitted when the session has closed */
@send
external onClose: (t, @as("close") _, unit => unit) => t = "on"
