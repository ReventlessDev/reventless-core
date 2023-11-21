// open FTP
type password = string
type privateKey = string
type passphrase = option<string>

type secret = Password(password) | Key(privateKey, passphrase)

type connectionParams = {
  host: string,
  port: option<int>,
  path: string,
  userName: string,
  secret: secret,
  readyTimeout: option<int>,
  retryCount: int,
  retryInterval: int,
}
type getFile = (
  ~remotePath: string,
  ~localPath: string,
  ~options: FTP.FastOptions.t=?,
  ~callback: Js.Exn.t => unit,
) => promise<unit>
type failFn = Js.Exn.t => unit
type endFtpFn = unit => unit

type downloadAction = (
  ~connectionParams: connectionParams,
  ~entities: array<FTP.entity>,
  ~sftp: FTP.t,
  ~fail: failFn,
  ~endFtp: endFtpFn,
) => promise<bool>

type ftpAction =
  | Download(downloadAction)
  | Upload(NodeStreams.Readable.t, /* filename on ftp */ string)

let ftp = (~connectionParams: connectionParams, ~ftpAction: ftpAction) => {
  let {host, port, userName, secret, path, readyTimeout} = connectionParams
  let (promise, resolve, _reject) = Util.Promise.make()
  let result: ref<Belt.Result.t<bool, string>> = ref(Error("Stream ended before action handling!"))
  let client = FTP.Client.make()

  client
  ->FTP.Client.onEnd(() => {
    Js.log("Client.onEnd")
    resolve(. result.contents)
  })
  ->FTP.Client.onError(err => {
    resolve(.
      Belt.Result.Error(
        err->Js.Exn.message->Belt.Option.getWithDefault("Error contains no message."),
      ),
    )
    client->FTP.Client.end_
  })
  ->FTP.Client.onTimeout(() =>
    client
    ->FTP.Client.error(
      FTP.makeError("SSH-Client Error: Connection timed out")->Message.log("Client.onTimeout"),
    )
    ->ignore
  )
  ->FTP.Client.onReady(client => {
    let _ = Util.Promise.onEndHandler(
      async () =>
        switch await client->FTP.make {
        | sftp =>
          let fail: failFn = err => sftp->FTP.error(err->FTP.toSftpError)->ignore
          let endFtp: endFtpFn = () => sftp->FTP.end_

          sftp
          ->FTP.onEnd(() => {
            Js.log("FTPHandler: end sftp stream")
          })
          ->FTP.onError(err => {
            Js.log2("FTPHandler: Error:", err)
            client->FTP.Client.error(err->FTP.toJsError)->ignore
            endFtp()
          })
          ->ignore

          switch ftpAction {
          | Download(downloadAction) =>
            switch await sftp->FTP.readdir(path) {
            | entities =>
              result :=
                (
                  await downloadAction(~connectionParams, ~entities, ~sftp, ~fail, ~endFtp)
                )->Belt.Result.Ok
            | exception Js.Exn.Error(e) => result := e->Reventless.Util.Error.message->Error
            }
          | Upload(readableStream, filename) =>
            readableStream
            ->NodeStreams.Readable.pipe(
              (path ++ ("/" ++ filename))
              ->Message.log("FTPHandler: path for write stream")
              ->FTP.createWriteStream(sftp, ~path=_, ())
              ->NodeStreams.Writable.onFinish(() => {
                result := Ok(true)
                Js.log("FTPHandler: writable ended")
              })
              ->NodeStreams.Writable.onClose(() => {
                Js.log("FTPHandler: writable closed")
                sftp->FTP.end_
              })
              ->NodeStreams.Writable.onError(err => {
                Js.Console.error2("FTPHandler: FTPHandler: Error in Write Stream:", err)
                FTP.makeError("FTPHandler: Error in Write Stream")->fail
              }),
            )
            ->ignore
          }
        | exception FTP.CouldNotEstablishSftpConnection(err) =>
          client
          ->FTP.Client.error(
            err->Message.log("Couldn't establish SFTP connection:")->SSH2.toJsError,
          )
          ->ignore
        },
      (. _) => {
        result := Ok(true)
        client->FTP.Client.end_
      },
    )
  })
  ->FTP.Client.connect(
    switch secret {
    | Password(password) =>
      FTP.Client.Config.make(~host, ~port?, ~username=userName, ~password, ~readyTimeout?, ())
    | Key(privateKey, passphrase) =>
      FTP.Client.Config.make(
        ~host,
        ~port?,
        ~username=userName,
        ~privateKey,
        ~passphrase?,
        ~readyTimeout?,
        (),
      )
    },
  )

  promise
}
