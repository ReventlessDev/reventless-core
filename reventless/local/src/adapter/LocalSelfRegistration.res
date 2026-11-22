// The local platform's starting state for a self-service role: read from
// `REVENTLESS_SELF_REGISTRATION_INITIALLY`, `open` when unset. A value that does
// not parse fails the request rather than falling back, as the anonymous limit
// beside it does: a setting someone mistyped must not quietly become one they did
// not choose.

let initially = (): Reventless.Admission.initially =>
  switch Reventless.Admission.initiallyFrom(
    NodeProcess.env->Dict.get(Reventless.Admission.initiallyEnvKey),
    ~key=Reventless.Admission.initiallyEnvKey,
    ~default=Reventless.Admission.localInitially,
  ) {
  | Ok(i) => i
  | Error(message) => JsError.throwWithMessage(message)
  }
