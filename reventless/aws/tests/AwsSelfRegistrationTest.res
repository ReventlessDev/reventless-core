// A deployed function's starting state for a self-service role: closed unless the
// stack's configuration says otherwise, and a mistyped setting refused.

open JestGlobals

let key = Reventless.Admission.initiallyEnvKey
let withSetting = (value: option<string>, f) => {
  let before = NodeProcess.env->Dict.get(key)
  switch value {
  | Some(v) => NodeProcess.env->Dict.set(key, v)
  | None => NodeProcess.env->Dict.delete(key)
  }
  let result = try Ok(f()) catch {
  | JsExn(e) => Error(e->JsExn.message->Option.getOr(""))
  }
  switch before {
  | Some(v) => NodeProcess.env->Dict.set(key, v)
  | None => NodeProcess.env->Dict.delete(key)
  }
  result
}

testSync("unset, a self-service role starts closed; open when the stack says so", () =>
  expect((
    withSetting(None, AwsSelfRegistration.initially),
    withSetting(Some("open"), AwsSelfRegistration.initially),
    withSetting(Some("ajar"), AwsSelfRegistration.initially)->Result.mapError(m =>
      m->String.startsWith(Reventless.Admission.initiallyConfigKey)
    ),
  ))->toEqual((
    Ok(Reventless.Admission.InitiallyClosed),
    Ok(Reventless.Admission.InitiallyOpen),
    Error(true),
  ))
)

testSync("a platform that says nothing about its starting state takes no stranger", () =>
  expect(Reventless.Capabilities.none.selfRegistrationInitially)->toEqual(
    Reventless.Admission.InitiallyClosed,
  )
)
