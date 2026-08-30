/**
The conformance suite, run by a host against its own graft. `Make(Binding).register()`
inside a Jest test file registers one `describe` block; every assertion is written
over the binding, never over a host's constructors.
*/

// Warning 23 flags the spread in `geocoder` as redundant today; it is there for
// the day `Capabilities.t` grows a field.
@@warning("-23")

module Outcome = ReventlessGwt.Outcome

module Make = (B: AddressGeocoding.Binding) => {
  module A = ReventlessGwt.Behavior_GWT.MakeFromAggregate(B.Spec, B.Behavior)
  module S = ReventlessGwt.OutboundTranslation_GWT.Make(B.Slice)

  let vienna: Reventless.GeoPoint.t = {lat: 48.2082, lng: 16.3738}
  let bruges: Reventless.GeoPoint.t = {lat: 51.2093, lng: 3.2247}
  let entityId = "entity-1"
  let todoKey = subject => `${entityId}:${B.subjectText(subject)}`

  let geocoder = (answer): Reventless.Capabilities.t => {
    ...Reventless.Capabilities.none,
    geocode: (~text as _) => Promise.resolve(answer),
  }
  let translateWith = answer => (id, item) => B.translate(id, item, ~capabilities=geocoder(answer))

  let describeCommand = cmd =>
    cmd->Reventless.Message.encode(B.Slice.inboundCommandSchema)->JSON.stringify

  let thenReports = async (pending: promise<S.attempt>, ~expected, predicate) => {
    let {result, _} = await pending
    switch result {
    | Ok(Some((_, cmd))) if predicate(cmd) => Outcome.pass
    | Ok(Some((_, cmd))) =>
      Outcome.fail(TranslateError({expected, actual: Some(describeCommand(cmd))}))
    | Ok(None) => Outcome.fail(TranslateError({expected, actual: Some("no command")}))
    | Error(why) => Outcome.fail(TranslateError({expected, actual: Some(why)}))
    }
  }

  let sorted = names => names->Array.toSorted(String.compare)
  let strings = names => names->Array.map(JSON.Encode.string)

  let consumedSetMatchesTriggers = () => {
    let consumed = Reventless.DcbDecode.makeDecoder(B.Slice.consumedEventSchema).eventTypes->sorted
    let triggers =
      B.triggers(B.subjectA)
      ->Array.map(e =>
        e->Reventless.Message.encode(B.Slice.consumedEventSchema)->Reventless.Message.variantNameOfJson
      )
      ->sorted
    let widened = consumed->Array.some(t => B.standsDownOn->Array.includes(t))
    if consumed == triggers && !widened {
      Outcome.pass
    } else {
      Outcome.fail(
        StateMismatch({
          key: "consumedEvent",
          expected: Some(JSON.Encode.array(strings(triggers))),
          actual: Some(JSON.Encode.array(strings(consumed))),
        }),
      )
    }
  }

  let register = () =>
    A.describe(`${B.Spec.name} conforms to the address-geocoding trait`, () => {
      switch B.posture {
      | Observes =>
        A.test("posture: Observes is not supported by this runner", () =>
          Outcome.fail(
            Throw({error: "the runner checks a write-back graft; bind one, or wait", stack: ""}),
          )
        )
      | WritesBack => ()
      }

      // Aggregate: the graft rules.
      A.test("an answer for the current subject is applied", () =>
        A.givenEvents(B.created(B.subjectA))
        ->A.whenCmd(B.setLocation(~point=vienna, ~resolvedFrom=B.subjectA))
        ->A.thenEvent(B.located(~point=vienna, ~resolvedFrom=B.subjectA))
      )

      A.test("a verdict for the current subject is recorded", () =>
        A.givenEvents(B.created(B.subjectA))
        ->A.whenCmd(B.markUnresolvable(~subject=B.subjectA, ~reason="no match"))
        ->A.thenEvent(B.unresolvable(~subject=B.subjectA, ~reason="no match"))
      )

      A.test("an answer for a superseded subject is dropped as stale", () =>
        A.givenEvents(Array.concat(B.created(B.subjectA), [B.subjectChanged(B.subjectB)]))
        ->A.whenCmd(B.setLocation(~point=vienna, ~resolvedFrom=B.subjectA))
        ->A.thenNoEvent
      )

      A.test("a verdict for a superseded subject is dropped as stale", () =>
        A.givenEvents(Array.concat(B.created(B.subjectA), [B.subjectChanged(B.subjectB)]))
        ->A.whenCmd(B.markUnresolvable(~subject=B.subjectA, ~reason="no match"))
        ->A.thenNoEvent
      )

      A.test("a redelivered answer is a no-op", () =>
        A.givenEvents(
          Array.concat(B.created(B.subjectA), [B.located(~point=vienna, ~resolvedFrom=B.subjectA)]),
        )
        ->A.whenCmd(B.setLocation(~point=vienna, ~resolvedFrom=B.subjectA))
        ->A.thenNoEvent
      )

      A.test("a redelivered verdict is a no-op", () =>
        A.givenEvents(
          Array.concat(B.created(B.subjectA), [B.unresolvable(~subject=B.subjectA, ~reason="no match")]),
        )
        ->A.whenCmd(B.markUnresolvable(~subject=B.subjectA, ~reason="no match"))
        ->A.thenNoEvent
      )

      A.test("a subject change reopens the question", () =>
        A.givenEvents(
          Array.concat(
            B.created(B.subjectA),
            [B.located(~point=vienna, ~resolvedFrom=B.subjectA), B.subjectChanged(B.subjectB)],
          ),
        )
        ->A.whenCmd(B.setLocation(~point=bruges, ~resolvedFrom=B.subjectB))
        ->A.thenEvent(B.located(~point=bruges, ~resolvedFrom=B.subjectB))
      )

      // Slice: the binding surface.
      A.test("the slice consumes exactly its triggers and stands down on a supplied pair", () =>
        consumedSetMatchesTriggers()
      )

      B.triggers(B.subjectA)->Array.forEachWithIndex((trigger, i) =>
        S.testSync(`trigger ${Int.toString(i + 1)} queues one TODO keyed by entity and subject`, () =>
          S.givenEvent(trigger)
          ->S.whenCollect(~sourceId=entityId)
          ->S.thenTodos([(todoKey(B.subjectA), B.item(~entityId, ~subject=B.subjectA))])
        )
      )

      S.test("a confident answer reports the point", () =>
        S.givenTodo(todoKey(B.subjectA), B.item(~entityId, ~subject=B.subjectA))
        ->S.whenTranslateMocked(
          translateWith(
            Ok([
              {
                Reventless.Geocoding.label: B.subjectText(B.subjectA),
                point: vienna,
                relevance: Some(0.995),
              },
            ]),
          ),
        )
        ->thenReports(~expected="a location", B.isLocation)
      )

      S.test("a no-match completes the TODO with a verdict", () =>
        S.givenTodo(todoKey(B.subjectA), B.item(~entityId, ~subject=B.subjectA))
        ->S.whenTranslateMocked(translateWith(Error(Reventless.Geocoding.NoMatch)))
        ->thenReports(~expected="a verdict", B.isVerdict)
      )

      S.test("an outage leaves the TODO pending", () =>
        S.givenTodo(todoKey(B.subjectA), B.item(~entityId, ~subject=B.subjectA))
        ->S.whenTranslateMocked(translateWith(Error(Reventless.Geocoding.Unavailable("502"))))
        ->S.thenTodoStatus(todoKey(B.subjectA), #Pending)
      )
    })
}
