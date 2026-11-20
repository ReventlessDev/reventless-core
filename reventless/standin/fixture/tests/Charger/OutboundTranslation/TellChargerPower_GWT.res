@@reventless.gwt

let item: TellChargerPower.outboundItem = {chargerId: "bay-1", powerKw: 11.}

let told = ReventlessGwt.Capabilities_Fake.Told({
  kind: "Charger",
  instance: "bay-1",
  message: "setPower",
  body: JSON.parseOrThrow(`{"powerKw": 11}`),
})

describe("TellChargerPower OutboundTranslationSlice", () => {
  test("tells the charger the power it was limited to", () =>
    givenTodo("bay-1", item)->whenTranslated->thenSent([told])
  )

  test("a charger that is not reachable is told again later", () =>
    givenTodo("bay-1", item)
    ->givenCapabilities(
      fakes(
        ~tell=async (~kind as _, ~instance as _, ~message as _, ~body as _) => NotReachable(
          "offline",
        ),
        (),
      ),
    )
    ->whenTranslated
    ->thenTodoStatus("bay-1", Failed)
  )
})
