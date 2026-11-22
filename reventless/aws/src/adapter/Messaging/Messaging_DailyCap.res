// A messaging provider that stops for the rest of the day once it has sent a cap.
// For the mail a visitor causes, such as a sign-up code: a script that signs
// strangers up gets at most the cap sent from the deployment's address in a day,
// whatever else lets it through.
//
// Past the cap a send is refused, not retried: what a visitor sees does not
// change, since a sign-up is answered alike whatever happens to its mail, and
// the visitor can ask again tomorrow. The cap being reached is logged once per
// refusal as a metric line, which the deployment's alarm counts.
//
// Runtime-pure: no Pulumi, bundled into a function.

/** The metric line's name, which the deploy's metric filter and alarm read. */
let metricName = "RegistrationMailCapReached"

/** The default cap: a small deployment's sign-ups in a day, with room. */
let defaultCap = 50

/** The setting, as the function reads it. */
let capVariable = "REVENTLESS_REGISTRATION_MAIL_DAILY_CAP"

/** `50`: a positive count. Refuses anything else rather than reading the default. */
let parseCap = (raw: string): result<int, string> =>
  switch /^\d+$/->RegExp.test(raw->String.trim) ? raw->String.trim->Int.fromString : None {
  | Some(n) if n > 0 => Ok(n)
  | _ =>
    Error(`${capVariable}: "${raw}" is not a daily cap — write a positive number, such as 50`)
  }

/** The function's cap: the setting when given, the default otherwise. */
let cap = (): int =>
  switch NodeProcess.env->Dict.get(capVariable) {
  | None | Some("") => defaultCap
  | Some(raw) =>
    switch parseCap(raw) {
    | Ok(n) => n
    | Error(message) => JsError.throwWithMessage(message)
    }
  }

let log = ReventlessCore.Logger.fromEnv()

/** `provider`, refusing every send once `allow` says the day's cap is spent.
    `slice` names the sender in the metric line. */
let capped = (
  provider: Reventless.Messaging.provider,
  ~allow: unit => promise<bool>,
  ~slice: string,
): Reventless.Messaging.provider => {
  ...provider,
  send: async (~recipient, ~message) =>
    if await allow() {
      await provider.send(~recipient, ~message)
    } else {
      Console.log(
        JSON.stringifyAny({
          "reventlessMetric": metricName,
          "slice": slice,
          "value": 1,
        })->Option.getOr(""),
      )
      log.error(
        ~comp="RegistrationMail",
        "the daily cap on registration mail is reached; no more is sent today",
      )
      Error(Refused("the daily cap on registration mail is reached"))
    },
}

/** Whether one more registration mail goes out today, counted in the table the
    narrow API's requests are counted in, as one door with one source. A function
    handed no table admits none: a sender without its cap is not deployed. */
let allowToday = async (): bool =>
  switch NodeProcess.env->Dict.get(VisitorLimit_Ops.tableVariable) {
  | None | Some("") => false
  | Some(tableName) =>
    await AnonymousLimiter_DynamoDb.admit(
      ~store=AnonymousLimiter_DynamoDb.dynamoDb(~tableName),
      ~limit={requests: cap(), windowSeconds: 86400},
      ~fingerprint=source => Ok(source),
      ~door="registration-mail",
      ~source="deployment",
    )
  }

/** The senders of registration mail on this function, by slice name. */
let slicesVariable = "ADMISSION_MAIL_SLICES"

let cappedSlices = (): array<string> =>
  NodeProcess.env
  ->Dict.get(slicesVariable)
  ->Option.mapOr([], raw => raw->String.split(",")->Array.map(String.trim))
  ->Array.filter(s => s != "")

/** What `slice` is handed: `capabilities`, with its mail capped if it sends
    registration mail. */
let forSlice = (
  capabilities: Reventless.Capabilities.t,
  ~slice: string,
): Reventless.Capabilities.t =>
  cappedSlices()->Array.includes(slice)
    ? {...capabilities, messaging: capped(capabilities.messaging, ~allow=allowToday, ~slice)}
    : capabilities
