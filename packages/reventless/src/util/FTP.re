/** SSH2 (FTPS) bindings with added helper function to parseUrl */
include SSH2;

/** parses the given url into a tuple of two strings: (host, port, path)
 * (ftp://[user[:password]@])
 * actually respects: host[:port]/url-path
 */
let parseUrl:
  string =>
  (/* host */ string, /* port */ option(int), /* url-path */ string) =
  url => {
    let colonI = url |> Js.String.indexOf(":");
    let slashI = url |> Js.String.indexOf("/");
    Js.String.(
      switch (colonI > (-1), slashI > (-1)) {
      | (true, true) =>
        let fst = colonI < slashI ? colonI : slashI;
        let port =
          colonI < slashI
            ? url |> slice(~from=colonI + 1, ~to_=slashI)
            : url |> sliceToEnd(~from=colonI + 1);
        let path =
          colonI < slashI
            ? url |> sliceToEnd(~from=slashI + 1)
            : url |> slice(~from=slashI + 1, ~to_=colonI);
        (
          url |> slice(~from=0, ~to_=fst),
          switch (port |> int_of_string) {
          | portNum => Some(portNum)
          | exception (Failure("int_of_string")) => None
          },
          path,
        );
      | (false, true) => (
          url |> slice(~from=0, ~to_=slashI),
          None,
          url |> sliceToEnd(~from=slashI + 1),
        )
      | (true, false) => (
          url |> slice(~from=0, ~to_=colonI),
          switch (url |> sliceToEnd(~from=colonI + 1) |> int_of_string) {
          | portNum => Some(portNum)
          | exception (Failure("int_of_string")) => None
          },
          "",
        )
      | (false, false) => (url, None, "")
      }
    );
  };
