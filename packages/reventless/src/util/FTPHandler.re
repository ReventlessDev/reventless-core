open FTP;

type connectionParams = {
  host: string,
  port: option(int),
  path: string,
  userName: string,
  password: string,
  readyTimeout: option(int),
  retryCount: int,
  retryInterval: int,
};
type getFile =
  (
    ~remotePath: string,
    ~localPath: string,
    ~options: FTP.FastOptions.t=?,
    ~callback: Js.Exn.t => unit
  ) =>
  unit;
type failFn = Js.Exn.t => unit;
type endFtpFn = unit => unit;

type recordDownload = string => Js.Promise.t(unit);

type downloadAction =
  (
    ~connectionParams: connectionParams,
    ~entities: array(FTP.entity),
    ~sftp: FTP.t,
    ~fail: failFn,
    ~endFtp: endFtpFn
  ) =>
  unit;

type ftpAction =
  | Download(downloadAction)
  | Upload(NodeStreams.Readable.t, /*filename on ftp*/ string);

let ftp = (~connectionParams: connectionParams, ~ftpAction: ftpAction) => {
  let {host, port, userName, password, path, readyTimeout} = connectionParams;
  //let {Import.importType, fileType, pattern, date, run, time} = descriptor;
  Js.Promise.make((~resolve as resolvePromise, ~reject as _rejectPromise) => {
    let isDone = ref(false);
    let client = Client.make();
    client
    ->Client.onEnd(() => {
        Js.log("Client.onEnd");
        resolvePromise(.
          isDone^
            ? Belt.Result.Ok(true)
            : Belt.Result.Error("Stream ended before action handling!"),
        );
      })
    ->Client.onError(err => {
        resolvePromise(.
          Belt.Result.Error(
            err
            ->Js.Exn.message
            ->Belt.Option.getWithDefault("Error contains no message."),
          ),
        );
        client->Client.end_;
      })
    ->Client.onTimeout(() =>
        client
        ->Client.error(
            FTP.makeError("SSH-Client Error: Connection timed out")
            ->Message.log("Client.onTimeout"),
          )
        ->ignore
      )
    ->Client.onReady(client =>
        client
        ->make((sftpError, sftp) => {
            let fail: failFn =
              err => {
                sftp->error(err->toSftpError)->ignore;
              };
            let endFtp: endFtpFn =
              () => {
                sftp->end_;
              };

            sftp
            ->onEnd(() => {
                Js.log("end sftp stream");
                client->Client.end_;
              })
            ->onError(err => {
                client
                ->Client.error(
                    err->Message.log("SFTP.onError")->FTP.toJsError,
                  )
                ->ignore;
                endFtp();
              })
            ->ignore;
            switch (sftpError, ftpAction) {
            | (None, Download(downloadAction)) =>
              sftp
              ->readdir(~dirName=path, (readdirError, entities) =>
                  switch (readdirError) {
                  | None =>
                    downloadAction(
                      ~connectionParams,
                      ~entities,
                      ~sftp,
                      ~fail,
                      ~endFtp,
                    );
                    isDone := true;

                  | Some(readdirError) =>
                    Js.Console.error2(
                      "Could not read directory:",
                      readdirError,
                    );
                    makeError("Could not read directory")->fail;
                  }
                )
              ->ignore // ignore bool return value, which states to listen for continue event before sending more data
            | (None, Upload(readableStream, filename)) =>
              readableStream
              ->NodeStreams.Readable.pipe(
                  (path ++ "/" ++ filename)
                  ->Message.log("path for write stream")
                  ->createWriteStream(sftp, ~path=_, ())
                  ->NodeStreams.Writable.onFinish(() => {
                      isDone := true;
                      Js.log("writable ended");
                    })
                  ->NodeStreams.Writable.onClose(() => {
                      Js.log("writable closed");
                      sftp->end_;
                    })
                  ->NodeStreams.Writable.onError(err => {
                      Js.Console.error2("Error in Write Stream:", err);
                      makeError("Error in Write Stream")->fail;
                    }),
                )
              ->ignore
            | (Some(err), _) =>
              err->Message.log("Couldn't establish SFTP connection:")->fail
            };
          })
        ->ignore
      ) // ignore bool return value, which states to listen for continue event before sending more data
    ->Client.connect(
        Client.Config.make(
          ~host,
          ~port?,
          ~username=userName,
          ~password,
          ~readyTimeout?,
          //~debug=msg => Js.log2("SFTP DEBUG:", msg),
          (),
        ),
      );
  });
};
