open JestGlobals

// `SEED_ROLE` is how a run says what to act as when nobody can answer a prompt —
// a CI run wedged by a stored narrowing, or a deliberate restricted run.
//
// It carries two different intentions in one variable, which is why the parsing
// is worth pinning: naming a role narrows to it, and the "give me everything"
// answer has several spellings because an operator setting it by hand will write
// whichever one comes to mind. Getting that wrong is not a typo — `SEED_ROLE=full`
// read as a role named "full" would ask the platform to act as a group nobody
// holds, and be refused.

let withEnv = (value: option<string>, f: unit => unit) => {
  let key = "SEED_ROLE"
  let previous = NodeProcess.env->Dict.get(key)
  switch value {
  | Some(v) => NodeProcess.env->Dict.set(key, v)
  | None => NodeProcess.env->Dict.delete(key)
  }
  f()
  switch previous {
  | Some(v) => NodeProcess.env->Dict.set(key, v)
  | None => NodeProcess.env->Dict.delete(key)
  }
}

describe("Seed_Connect.roleFromEnv:", () => {
  testSync("is absent when nothing asked for a role", () =>
    withEnv(None, () => expect(Seed_Connect.roleFromEnv())->Expect.toEqual(None))
  )

  testSync("reads a named role as a narrowing to it", () =>
    withEnv(
      Some("Shopper"),
      () =>
        expect(Seed_Connect.roleFromEnv())->Expect.toEqual(Some(Seed_Connect.Narrowed("Shopper"))),
    )
  )

  // Every spelling of "everything" an operator might reach for. They all mean
  // clear the stored choice, which is what seeding wants.
  testSync("takes each spelling of full membership as a clear", () =>
    ["full", "all", "none", "clear", "FULL", "All"]->Array.forEach(
      v =>
        withEnv(
          Some(v),
          () => expect(Seed_Connect.roleFromEnv())->Expect.toEqual(Some(Seed_Connect.Full)),
        ),
    )
  )

  // Role names are case-sensitive to the platform (`mayActAs` compares exactly),
  // so a named role is passed through untouched — only the clear vocabulary is
  // case-folded.
  testSync("passes a role name through with its case intact", () =>
    withEnv(
      Some("Merchandiser"),
      () =>
        expect(Seed_Connect.roleFromEnv())->Expect.toEqual(
          Some(Seed_Connect.Narrowed("Merchandiser")),
        ),
    )
  )
})
