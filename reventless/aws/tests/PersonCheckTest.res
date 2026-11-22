// The person check on AWS: Turnstile's answers read as yes, no, or could not be
// asked; a missing token is a no without a call; and a function with no secret
// refuses every sign-up.

open JestGlobals

let kind = (answer: result<unit, Reventless.PersonCheck.failure>) =>
  switch answer {
  | Ok() => "passes"
  | Error(Rejected(_)) => "rejected"
  | Error(Unavailable(_)) => "unavailable"
  }

describe("Turnstile's answer", () => {
  testSync("success passes, a spent token is a no, its own failure is not asked", () =>
    expect(
      [
        `{"success":true,"error-codes":[]}`,
        `{"success":false,"error-codes":["timeout-or-duplicate"]}`,
        `{"success":false,"error-codes":["invalid-input-response"]}`,
        `{"success":false,"error-codes":["internal-error"]}`,
        `{"success":false,"error-codes":["invalid-input-secret"]}`,
        `<html>bad gateway</html>`,
      ]->Array.map(body => PersonCheck_Turnstile.verdict(body)->kind),
    )->toEqual(["passes", "rejected", "rejected", "unavailable", "unavailable", "unavailable"])
  )
})

describe("the check a door asks", () => {
  let posted = []
  let answering = (answer): PersonCheck_Turnstile.post =>
    async (~url, ~form) => {
      posted->Array.push((url, form))
      answer
    }

  testPromise("posts the secret and the token, and reads the verdict", async () => {
    let check = PersonCheck_Turnstile.provider(
      ~secret="s3cret",
      ~post=answering(Ok((200, `{"success":true}`))),
    )
    let answer = await check.verify(~token="tok en")
    expect((kind(answer), posted->Array.at(-1)))->toEqual((
      "passes",
      Some((PersonCheck_Turnstile.verifyUrl, "secret=s3cret&response=tok+en")),
    ))
  })

  testPromise("no token is a no, and Turnstile is not asked", async () => {
    let before = posted->Array.length
    let check = PersonCheck_Turnstile.provider(
      ~secret="s",
      ~post=answering(Ok((200, `{"success":true}`))),
    )
    let answer = await check.verify(~token="  ")
    expect((kind(answer), posted->Array.length - before))->toEqual(("rejected", 0))
  })

  testPromise("an unreachable or failing Turnstile cannot be asked", async () => {
    let unreachable = PersonCheck_Turnstile.provider(
      ~secret="s",
      ~post=answering(Error("timed out")),
    )
    let failing = PersonCheck_Turnstile.provider(~secret="s", ~post=answering(Ok((503, ""))))
    let a = await unreachable.verify(~token="t")
    let b = await failing.verify(~token="t")
    expect((kind(a), kind(b)))->toEqual(("unavailable", "unavailable"))
  })

  testPromise("a function with no secret refuses every sign-up", async () => {
    let a = await AwsPersonCheck.fromSecret(None).verify(~token="t")
    let b = await AwsPersonCheck.fromSecret(Some(" ")).verify(~token="t")
    expect((kind(a), kind(b)))->toEqual(("unavailable", "unavailable"))
  })

  testPromise("with its secret, the function asks Turnstile", async () => {
    let check = AwsPersonCheck.fromSecret(
      Some("s"),
      ~post=answering(Ok((200, `{"success":false,"error-codes":["timeout-or-duplicate"]}`))),
    )
    let answer = await check.verify(~token="t")
    expect(kind(answer))->toEqual("rejected")
  })
})
