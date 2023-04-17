@ocaml.doc(" SSH2 (FTPS) bindings with added helper function to parseUrl ")
include SSH2

@ocaml.doc(" parses the given url into a tuple of two strings: (host, port, path)
 * (ftp://[user[:password]@])
 * actually respects: host[:port]/url-path
 ")
let parseUrl: string => (
  /* host */ string,
  /* port */ option<int>,
  /* url-path */ string,
) = url => {
  let colonI = url->Js.String2.indexOf(":")
  let slashI = url->Js.String2.indexOf("/")
  open Js.String2
  switch (colonI > -1, slashI > -1) {
  | (true, true) =>
    let fst = colonI < slashI ? colonI : slashI
    let port =
      colonI < slashI
        ? url->slice(~from=colonI + 1, ~to_=slashI)
        : url->sliceToEnd(~from=colonI + 1)
    let path =
      colonI < slashI
        ? url->sliceToEnd(~from=slashI + 1)
        : url->slice(~from=slashI + 1, ~to_=colonI)
    (url->slice(~from=0, ~to_=fst), port->Belt.Int.fromString, path)
  | (false, true) => (url->slice(~from=0, ~to_=slashI), None, url->sliceToEnd(~from=slashI + 1))
  | (true, false) => (
      url->slice(~from=0, ~to_=colonI),
      url->sliceToEnd(~from=colonI + 1)->Belt.Int.fromString,
      "",
    )
  | (false, false) => (url, None, "")
  }
}
