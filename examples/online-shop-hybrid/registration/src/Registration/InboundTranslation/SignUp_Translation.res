@@reventless.translation

/** The role a sign-up that names none asks for: the one self-service role, where
    the declaration has exactly one. With none or several, the caller has to say. */
let defaultRole = (): option<Reventless.Role.name> =>
  switch Admission.table->Reventless.Admission.selfService {
  | [only] => Some(only)
  | _ => None
  }

let translate = async (input: externalInput, ~capabilities as _) =>
  switch (Reventless.Email.fromString(input.email->String.trim), input.role) {
  | (Error(_), _) => Error("not an email address")
  | (Ok(email), role) =>
    switch role
    ->Option.map(String.trim)
    ->Option.filter(r => r != "")
    ->Option.map(Reventless.Role.make)
    ->Option.orElse(defaultRole()) {
    | None => Error("say which role to sign up for")
    | Some(role) =>
      let email = email->Reventless.Email.toString->String.toLowerCase
      Ok([
        (
          email,
          Register({
            email: ContactAddressId.makeFromString(email),
            role,
            requestedAt: Date.make()->Date.toISOString->Reventless.DateTime.unsafe,
          }),
        ),
      ])
    }
  }
