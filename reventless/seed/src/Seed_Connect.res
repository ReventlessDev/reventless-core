// Turns endpoints plus a login function into a ready `connection`.
//
// A connection is what a data set seeds against: an authenticated GraphQL
// client, the upload endpoint (empty when the deployment serves no uploads), and
// a human label for the target. `make` is provider-agnostic — it prompts for
// credentials, calls the supplied `login` to obtain a bearer, and wires it onto
// the client via `useToken`. Where the bearer comes from (a local `/login`
// round-trip, a Cognito id token) is the caller's concern.

open Seed_Types

type connection = {client: Seed_Client.t, uploadEndpoint: string, label: string}

/**
 * Prompts for credentials, calls `login` to mint a bearer, and returns a
 * connection with that bearer already applied. `login` returns the bearer so a
 * single `useToken` path serves every provider.
 */
let make = async (
  ~label: string,
  ~endpoint: string,
  ~uploadEndpoint: string,
  ~login: (~username: string, ~password: string) => promise<string>,
  ~localDefaults: bool=false,
): connection => {
  // `SEED_SKIP_UPLOADS` forces the connection to carry no upload endpoint, so a
  // data set's upload phase no-ops the same way it does when a deployment serves
  // none. Use it to seed domain data fast, or to skip a broken/absent upload path
  // without editing the data set. It is the single knob: an empty
  // `REVENTLESS_UPLOAD_ENDPOINT` env reads as "unset" (falls back to discovery),
  // so this is the reliable way to disable uploads.
  let uploadEndpoint = Seed_Prompt.envValue("SEED_SKIP_UPLOADS")->Option.isSome ? "" : uploadEndpoint
  let (username, password) = await Seed_Prompt.credentials(~localDefaults)
  let token = await login(~username, ~password)
  let client = Seed_Client.make(~config={endpoint: endpoint})
  client->Seed_Client.useToken(token)
  {client, uploadEndpoint, label}
}

/**
 * A login function backed by an HTTP login endpoint (the local dev
 * `/__inmemory/login` shape: POST `{username, password}` → `{token}`). Reuses
 * `Seed_Client.login` but hands the token back for `useToken`.
 */
let viaLoginEndpoint = (~loginEndpoint: string) => async (
  ~username: string,
  ~password: string,
): string => {
  let client = Seed_Client.make(
    ~config={endpoint: loginEndpoint, loginEndpoint, username, password},
  )
  await Seed_Client.login(client)
  switch Seed_Client.currentToken(client) {
  | Some(token) => token
  | None => throw(Failed(`login at ${loginEndpoint} returned no token`))
  }
}

let envOr = (key: string, fallback: string): string =>
  Seed_Prompt.envValue(key)->Option.getOr(fallback)

/**
 * A ready `connect` thunk for the local dev platform, with the localhost
 * defaults baked in and overridable per endpoint (arg, then env var, then
 * default). Empty input at the credential prompt falls back to `admin`/`admin`.
 */
let local = (~graphql=?, ~upload=?, ~login=?, ()): (unit => promise<connection>) => {
  let endpoint =
    graphql->Option.getOr(envOr("REVENTLESS_GRAPHQL_ENDPOINT", "http://localhost:4000/graphql"))
  let uploadEndpoint =
    upload->Option.getOr(
      envOr("REVENTLESS_UPLOAD_ENDPOINT", "http://localhost:4000/__inmemory/upload"),
    )
  let loginEndpoint =
    login->Option.getOr(envOr("REVENTLESS_LOGIN_ENDPOINT", "http://localhost:4000/__inmemory/login"))
  () =>
    make(
      ~label="local",
      ~endpoint,
      ~uploadEndpoint,
      ~login=viaLoginEndpoint(~loginEndpoint),
      ~localDefaults=true,
    )
}
