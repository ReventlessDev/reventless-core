/**
The outbound slice's body: ask the geocoder, and turn its answer into one of the
host's two report commands. The host supplies those as callbacks, so the trait
never names a constructor.

An outage is not a verdict — it comes back `Error`, which leaves the TODO pending
for another attempt — and once the retries are spent `exhaustedReason` is what the
host reports instead, by the same command a confident refusal produces.
*/

/** The geocoder arrives as a capability, so the deployment decides what answers. */
let translate = async (
  ~text: string,
  ~capabilities: Reventless.Capabilities.t,
  ~located: (~point: Reventless.GeoPoint.t, ~resolvedFrom: string) => 'command,
  ~unresolvable: (~subject: string, ~reason: string) => 'command,
): result<'command, string> => {
  let answer = await capabilities.geocode(~text)
  switch answer {
  // Matched only to keep `why`; `ofSearch` refuses this case too and is the rule.
  | Error(Reventless.Geocoding.Unavailable(why)) => Error(`geocoder unavailable: ${why}`)
  | _ =>
    switch Reventless.Geolocation.ofSearch(~requestedFor=text, answer) {
    | Some(Located({point})) => Ok(located(~point, ~resolvedFrom=text))
    | Some(Unresolvable({reason})) => Ok(unresolvable(~subject=text, ~reason))
    | Some(Pending(_)) => Error("unreachable: ofSearch never answers Pending")
    | None => Error("geocoder unavailable")
    }
  }
}

/**
Why a spent retry budget is a verdict and not a longer wait: `Pending` means the
geocoder has not answered *yet*, and once the retries are gone there is no yet.
*/
let exhaustedReason = lastError =>
  switch lastError {
  | Some(why) => `the geocoder never answered after repeated attempts (${why})`
  | None => "the geocoder never answered after repeated attempts"
  }
