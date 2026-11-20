// The doors a stand-in sends through: an inbound translation's webhook, as the
// local platform publishes it in `.reventless/webhook-secrets.json`, signed the
// way the door checks (an HMAC-SHA256 over the raw body, or over
// `<timestamp>.<body>` when the door names a timestamp header).

open ReventlessSeed

type signing = {
  header: string,
  prefix?: string,
  timestampHeader?: string,
  secret: string,
}

type door = {
  slice: string,
  url: string,
  method: string,
  // Absent: an open door, posted to unsigned.
  signing?: signing,
}

let get = Seed.Commands.get
let str = Seed.Commands.str
let items = Seed.Commands.items

/** The doors a secrets file lists, served under `base` (`http://…/webhooks`). */
let parse = (json: JSON.t, ~base: string): result<array<door>, string> => {
  let secrets = switch json->get("secrets") {
  | Some(Object(d)) => d
  | _ => Dict.make()
  }
  let base = base->String.endsWith("/") ? base->String.slice(~start=0, ~end=-1) : base
  json
  ->items("doors")
  ->Array.reduce(Ok([]), (acc, d) =>
    switch (acc, d->str("path"), d->str("slice")) {
    | (Error(_), _, _) => acc
    | (Ok(doors), Some(path), Some(slice)) =>
      let url = `${base}/${path}`
      let method = d->str("method")->Option.getOr("POST")
      switch (d->str("secret"), d->str("header")) {
      | (None, _) => Ok(doors->Array.concat([{slice, url, method}]))
      | (Some(name), Some(header)) =>
        switch secrets->Dict.get(name) {
        | Some(String(secret)) =>
          Ok(
            doors->Array.concat([
              {
                slice,
                url,
                method,
                signing: {
                  header,
                  prefix: ?(d->str("prefix")),
                  timestampHeader: ?(d->str("timestampHeader")),
                  secret,
                },
              },
            ]),
          )
        | _ => Error(`the door of ${slice} signs with "${name}", which the file holds no value for`)
        }
      | (Some(_), None) => Error(`the door of ${slice} names a secret but no header`)
      }
    | (Ok(_), _, _) => Error("a door without a path or a slice")
    }
  )
}

/** The doors in the secrets file at `path`. */
let read = (~path: string, ~base: string): result<array<door>, string> =>
  switch NodeFs.readFileSync(path)->JSON.parseOrThrow {
  | json => parse(json, ~base)
  | exception _ => Error(`${path} cannot be read as the doors' secrets`)
  }

let hmacHex = (~secret: string, text: string): string =>
  NodeCrypto.createHmac("sha256", secret)->NodeCrypto.hmacUpdate(text)->NodeCrypto.hmacDigest("hex")

/** The headers a post of `body` through `door` carries, signed at `nowSeconds`. */
let headersFor = (door: door, ~body: string, ~nowSeconds: float): dict<string> => {
  let headers = Dict.fromArray([("content-type", "application/json")])
  switch door.signing {
  | None => ()
  | Some(s) =>
    let signed = switch s.timestampHeader {
    | Some(name) =>
      let at = nowSeconds->Math.floor->Float.toString
      headers->Dict.set(name, at)
      `${at}.${body}`
    | None => body
    }
    headers->Dict.set(s.header, s.prefix->Option.getOr("") ++ hmacHex(~secret=s.secret, signed))
  }
  headers
}

type answer = {status: int, body: string}

/** Posts `body` through `door`, signed at `nowSeconds`; the door's answer. */
let post = async (door: door, ~body: string, ~nowSeconds: float): answer => {
  let res = await Seed.Client.fetch(
    door.url,
    {method: door.method, headers: headersFor(door, ~body, ~nowSeconds), body},
  )
  {status: res->Seed.Client.responseStatus, body: await res->Seed.Client.responseText}
}

let find = (doors: array<door>, ~slice: string): option<door> =>
  doors->Array.find(d => d.slice == slice)

/** What a running local platform's registry entry says a stand-in needs: where to
    read views and log in, and the doors with their secrets. */
type platform = {endpoint: string, loginEndpoint: string, doors: array<door>}

/** Reads a running platform's entry (`<app>/.reventless/running/<port>.json`). */
let fromRegistryEntry = (~path: string): result<platform, string> =>
  switch NodeFs.readFileSync(path)->JSON.parseOrThrow {
  | exception _ => Error(`${path} cannot be read as a running platform's entry`)
  | entry =>
    switch (
      entry->str("endpoint"),
      entry->str("loginEndpoint"),
      entry->get("webhooks")->Option.flatMap(w => w->str("base")),
      entry->get("webhooks")->Option.flatMap(w => w->str("secrets")),
    ) {
    | (Some(endpoint), Some(loginEndpoint), Some(base), Some(secrets)) =>
      read(~path=secrets, ~base)->Result.map(doors => {endpoint, loginEndpoint, doors})
    | (Some(endpoint), Some(loginEndpoint), Some(_), None) =>
      Ok({endpoint, loginEndpoint, doors: []})
    | _ => Error(`${path} names no endpoint or no webhook doors`)
    }
  }
