// The server's words on AWS: a sending Lambda reads a language's catalogue from where the shell
// serves it, `<shell>/i18n/<lang>.json`, the file the deploy uploaded beside `config.json`.
//
// Read rather than bundled because the catalogues are the platform stack's and the Lambdas the
// plugin stack's, and an archive is built before a stack output resolves. Held for a few minutes
// per container, so a burst of mails reads it once and a re-deployed translation is used soon.

type response = {ok: bool, status: int}
@send external responseText: response => promise<string> = "text"
@val external fetch: string => promise<response> = "fetch"

let heldForMs = 300_000.0

let held: dict<(float, option<dict<string>>)> = Dict.make()

/** A language's catalogue as served: `Ok(None)` where none is, `Error` where it could not be
    read, so the mail is tried again rather than sent in another language. */
let catalogue = async (~baseUrl: string, language: string): result<
  option<dict<string>>,
  string,
> => {
  let url = `${baseUrl->String.replaceRegExp(/\/+$/, "")}/${ReventlessCore.Platform_I18n.fileName(
      language,
    )}`
  let now = Date.now()
  switch held->Dict.get(url) {
  | Some((at, found)) if now -. at < heldForMs => Ok(found)
  | _ =>
    switch await fetch(url) {
    | response if response.ok =>
      switch ReventlessCore.Platform_I18n.parseCatalogue(await response->responseText) {
      | Ok(entries) =>
        held->Dict.set(url, (now, Some(entries)))
        Ok(Some(entries))
      | Error(reason) => Error(`${url}: ${reason}`)
      }
    // S3 behind CloudFront answers a missing object with 403.
    | {status: 403 | 404} =>
      held->Dict.set(url, (now, None))
      Ok(None)
    | {status} => Error(`${url}: HTTP ${Int.toString(status)}`)
    | exception JsExn(e) => Error(`${url}: ${e->JsExn.message->Option.getOr("unreachable")}`)
    }
  }
}

/** A recipient's own language: the `locale` attribute of the account their address signs in as,
    in the platform's pool. None where there is no such account, or it cannot be read: the mail
    then goes out in the default language rather than not at all. */
let localeOf = async (~poolId: string, recipient: Reventless.Messaging.recipient): option<string> =>
  switch recipient {
  | ToEmail(email) if poolId != "" =>
    module Get = AwsSdk.CognitoIdentityServiceProvider.AdminGetUserCommand
    switch await Get.send(
      Get.make({userPoolId: poolId, username: Reventless.Email.toString(email)}),
    ) {
    | found =>
      found.userAttributes
      ->Option.getOr([])
      ->Array.find(a => a.name == Reventless.Identity.localeClaim)
      ->Option.map(a => a.value)
    | exception _ => None
    }
  | _ => None
  }

/** The text capability from the Lambda's environment: English where no languages are declared
    or no shell is deployed to read them from. */
let text = (): Reventless.Text.t => {
  let env = name => NodeProcess.env->Dict.get(name)->Option.getOr("")
  switch (
    ReventlessCore.Platform_I18n.languagesOfJson(env("I18N_LANGUAGES")),
    env("I18N_BASE_URL"),
  ) {
  | (Some(i18n), baseUrl) if baseUrl != "" =>
    ReventlessCore.Platform_I18n.text(
      i18n,
      ~catalogue=language => catalogue(~baseUrl, language),
      ~localeOf=localeOf(~poolId=env("IDENTITY_PROVIDER_ID"), ...),
    )
  | _ => Reventless.Text.sourceOnly
  }
}
