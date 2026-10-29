@@reventless.translation

/** The role a sign-up that names none asks for: the one self-service role, where
    the table has exactly one. With none or several, the caller has to say. */
let defaultRole = (table: Reventless.Admission.t): option<Reventless.Role.name> =>
  switch table->Reventless.Admission.selfService {
  | [only] => Some(only)
  | _ => None
  }

/** The door over the app's table, which picks the role a sign-up may leave out. */
module Make = (App: Reventless.Admission.Declaration) => {
  module Spec = Spec
  let moduleUrl = moduleUrl

  let translate = async (
    input: externalInput,
    ~capabilities: Reventless.Capabilities.t,
    ~caller as _,
  ) =>
    switch (Reventless.Email.fromString(input.email->String.trim), input.role) {
    | (Error(_), _) => Error("not an email address")
    | (Ok(email), role) =>
      switch role
      ->Option.map(String.trim)
      ->Option.filter(r => r != "")
      ->Option.map(Reventless.Role.make)
      ->Option.orElse(defaultRole(App.table)) {
      | None => Error("say which role to sign up for")
      | Some(role) =>
        let address = email->ContactAddressId.normalize
        switch ContactAddressId.fingerprint(capabilities.secrets, address) {
        | Error(why) => Error(why)
        | Ok(id) =>
          // The envelope id is the fingerprint too: an id is stored beside the
          // event, where the address must not be.
          Ok([
            (
              id->ContactAddressId.toString,
              Register({
                email: id,
                address,
                role,
                requestedAt: Date.make()->Date.toISOString->Reventless.DateTime.unsafe,
              }),
            ),
          ])
        }
      }
    }
}
