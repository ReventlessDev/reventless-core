/** SSH2 (FTPS) bindings with added helper function to parseUrl */
include SSH2

/** parses the given url into a tuple of two strings: (host, port, path)
  (ftp://[user[:password]@])
  actually respects: host[:port]/url-path
 */
let parseUrl: string => (
  /* host */ string,
  /* port */ option<int>,
  /* url-path */ string,
) = url => {
  let colonI = url->String.indexOf(":")
  let slashI = url->String.indexOf("/")
  switch (colonI > -1, slashI > -1) {
  | (true, true) =>
    let fst = colonI < slashI ? colonI : slashI
    let port =
      colonI < slashI
        ? url->String.slice(~start=colonI + 1, ~end=slashI)
        : url->String.slice(~start=colonI + 1)
    let path =
      colonI < slashI
        ? url->String.slice(~start=slashI + 1)
        : url->String.slice(~start=slashI + 1, ~end=colonI)
    (url->String.slice(~start=0, ~end=fst), port->Int.fromString, path)
  | (false, true) => (
      url->String.slice(~start=0, ~end=slashI),
      None,
      url->String.slice(~start=slashI + 1),
    )
  | (true, false) => (
      url->String.slice(~start=0, ~end=colonI),
      url->String.slice(~start=colonI + 1)->Int.fromString,
      "",
    )
  | (false, false) => (url, None, "")
  }
}

exception CouldNotEstablishSftpConnection(error)

let make: Client.t => promise<t> = client => {
  let (promise, resolve, reject) = Util.Promise.make()
  client
  ->make((readdirError, entities) =>
    switch readdirError {
    | None => resolve(entities)
    | Some(err) => reject(CouldNotEstablishSftpConnection(err->toSftpError))
    }
  )
  ->ignore // ignore bool return value, which states to listen for continue event before sending more data
  promise
}

exception CouldNotReadDirectory(string, error)

let readdir: (t, string) => promise<array<entity>> = (client, dirName) => {
  let (promise, resolve, reject) = Util.Promise.make()
  client
  ->readdir(~dirName, (readdirError, entities) =>
    switch readdirError {
    | None => resolve(entities)
    | Some(err) => reject(CouldNotReadDirectory(dirName, err))
    }
  )
  ->ignore // ignore bool return value, which states to listen for continue event before sending more data
  promise
}
