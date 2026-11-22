// Cloudflare Turnstile as the person check: the door posts the form's token and
// the deployment's secret to Turnstile's verification address and reads yes or no.
// The visitor's address is not sent; Turnstile saw it when the widget loaded.
//
// Runtime-pure: no Pulumi, bundled into the command function.

let verifyUrl = "https://challenges.cloudflare.com/turnstile/v0/siteverify"

/** How long the door waits for an answer before it calls the check unreachable. */
let timeoutMs = 5000

/** The answer's error codes that say the deployment, not the visitor, is wrong or
    the provider failed: the check could not be made. Every other code is a no. */
let unavailableCodes = ["internal-error", "missing-input-secret", "invalid-input-secret"]

/** The verdict in a verification answer's body. */
let verdict = (body: string): result<unit, Reventless.PersonCheck.failure> =>
  switch try Some(JSON.parseOrThrow(body)) catch {
  | _ => None
  } {
  | Some(Object(answer)) =>
    let codes = switch answer->Dict.get("error-codes") {
    | Some(Array(codes)) =>
      codes->Array.filterMap(c =>
        switch c {
        | String(s) => Some(s)
        | _ => None
        }
      )
    | _ => []
    }
    switch answer->Dict.get("success") {
    | Some(Boolean(true)) => Ok()
    | _ if codes->Array.some(c => unavailableCodes->Array.includes(c)) =>
      Error(Unavailable(`Turnstile could not verify: ${codes->Array.join(", ")}`))
    | _ => Error(Rejected(`Turnstile said no: ${codes->Array.join(", ")}`))
    }
  | _ => Error(Unavailable("Turnstile answered with something that is not a verdict"))
  }

/** One HTTP POST of a form body: the status and the body, or why it failed. */
type post = (~url: string, ~form: string) => promise<result<(int, string), string>>

type response
@get external status: response => int = "status"
@send external text: response => promise<string> = "text"
type abortSignal
@scope("AbortSignal") @val external timeout: int => abortSignal = "timeout"
@val
external fetch: (
  string,
  {"method": string, "headers": dict<string>, "body": string, "signal": abortSignal},
) => promise<response> = "fetch"

let fetchPost: post = async (~url, ~form) =>
  try {
    let response = await fetch(
      url,
      {
        "method": "POST",
        "headers": Dict.fromArray([("content-type", "application/x-www-form-urlencoded")]),
        "body": form,
        "signal": timeout(timeoutMs),
      },
    )
    Ok((response->status, await response->text))
  } catch {
  | JsExn(e) => Error(e->JsExn.message->Option.getOr("the request failed"))
  | _ => Error("the request failed")
  }

type searchParams
@new external searchParams: dict<string> => searchParams = "URLSearchParams"
@send external paramsToString: searchParams => string = "toString"

/** The check, with the deployment's secret. A missing token is a no without a call. */
let provider = (~secret: string, ~post: post=fetchPost): Reventless.PersonCheck.t => {
  verify: async (~token) =>
    switch token->String.trim {
    | "" => Error(Rejected("no token"))
    | token =>
      let form =
        Dict.fromArray([("secret", secret), ("response", token)])->searchParams->paramsToString
      switch await post(~url=verifyUrl, ~form) {
      | Error(why) => Error(Unavailable(`Turnstile cannot be reached: ${why}`))
      | Ok((status, _)) if status < 200 || status >= 300 =>
        Error(Unavailable(`Turnstile answered ${status->Int.toString}`))
      | Ok((_, body)) => verdict(body)
      }
    },
}
