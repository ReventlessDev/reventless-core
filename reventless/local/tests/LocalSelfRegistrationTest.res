// The local platform's starting state for a self-service role: open unless the
// environment says otherwise, and a mistyped setting refused.

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

testSync("unset, a self-service role starts open; closed when the environment says so", () =>
  expect((
    withSetting(None, LocalSelfRegistration.initially),
    withSetting(Some("closed"), LocalSelfRegistration.initially),
    withSetting(Some("shut"), LocalSelfRegistration.initially)->Result.isError,
  ))->toEqual((
    Ok(Reventless.Admission.InitiallyOpen),
    Ok(Reventless.Admission.InitiallyClosed),
    true,
  ))
)
