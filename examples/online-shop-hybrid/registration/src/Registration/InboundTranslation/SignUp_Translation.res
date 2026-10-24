@@reventless.translation

/** The scope every registration is admitted under until a deployment has more
    than one policy. */
let scopeId = "default"

let translate = async (input: externalInput, ~capabilities as _) =>
  switch Reventless.Email.fromString(input.email->String.trim) {
  | Error(_) => Error("not an email address")
  | Ok(email) =>
    let email = email->Reventless.Email.toString->String.toLowerCase
    Ok([
      (
        email,
        Register({
          email: ContactAddressId.makeFromString(email),
          scopeId,
          requestedAt: Date.make()->Date.toISOString->Reventless.DateTime.unsafe,
        }),
      ),
    ])
  }
