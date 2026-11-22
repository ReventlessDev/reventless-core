// A deployed function's starting state for a self-service role: the stack's
// `platform:selfRegistrationInitially`, handed to the function as
// `REVENTLESS_SELF_REGISTRATION_INITIALLY`; `closed` when unset, so a public address
// takes no stranger until someone opens it. A value that does not parse fails the
// call rather than falling back to either state.

let initially = (): Reventless.Admission.initially =>
  switch Reventless.Admission.initiallyFrom(
    NodeProcess.env->Dict.get(Reventless.Admission.initiallyEnvKey),
    ~key=Reventless.Admission.initiallyConfigKey,
    ~default=Reventless.Admission.awsInitially,
  ) {
  | Ok(i) => i
  | Error(message) => JsError.throwWithMessage(message)
  }
