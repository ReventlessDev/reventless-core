open JestGlobals


// Driven through `makeGenerateCommand` rather than by calling `stampOwnerFields`
// directly. The unit under test is not really the stamp — it is the claim that
// the stamp is reached on the path a command actually takes, which is the half a
// direct call cannot establish. Both transports funnel through this function, so
// what passes here is true of the local resolver and of AppSync alike.

@schema
type command =
  | PlaceOrder({
      orderId: @s.matches(Reventless.DcbTag.string) string,
      customerId: @s.matches(Reventless.Owner.string) string,
      note: string,
    })
  | // The control variant: same union, no owner. Whatever the caller sends here
  // must survive untouched, or the stamp is reaching across constructors.
  ImportProducts({batchId: @s.matches(Reventless.DcbTag.string) string, source: string})

let published: ref<array<Message.commandJson>> = ref([])

let generate = CommandGenerator_Callback.makeGenerateCommand(
  ~publishJsons=async cmds => published := published.contents->Array.concat(cmds),
  ~serviceName="Ordering",
  ~commandSchema=commandSchema->S.castToUnknown,
  ~componentKind=CommandGenerator_Callback.StateChangeSlice,
  ~stripIdFromParams=false,
)

external asIdentity: 'a => Reventless.Identity.t = "%identity"

let cognito = (~userId, ~groups): Reventless.Identity.t =>
  asIdentity({"userId": userId, "username": userId, "groups": groups, "provider": "Cognito"})

let iam: Reventless.Identity.t = asIdentity({
  "userArn": "arn:aws:sts::1:assumed-role/Ingester",
  "accountId": "1",
  "username": "Ingester",
  "provider": "IAM",
})

let payload = (~command, ~args: dict<JSON.t>, ~identity): CommandGenerator.payload =>
  Obj.magic({
    "command": command,
    "arguments": Obj.magic(args),
    "meta": {"ip": ["127.0.0.1"], "user": "test", "info": ""},
    "identity": identity,
  })

let str = JSON.Encode.string

let placeOrder = (~customerId, ~identity) =>
  payload(
    ~command="PlaceOrder",
    ~args=Dict.fromArray([
      ("orderId", str("o-1")),
      ("customerId", str(customerId)),
      ("note", str("gift wrap")),
    ]),
    ~identity,
  )

let fieldOf = (cmd: Message.commandJson, name) =>
  cmd.commandJson->JSON.Decode.object->Option.flatMap(o => o->Dict.get(name))

let lastPublished = () => published.contents->Array.getUnsafe(published.contents->Array.length - 1)

let _ = beforeEach(() => {
  published := []
  Reventless.OwnerScope.setElevatedGroups(["Admin"])
})

describe("@owner stamping on the command path:", () => {
  testPromise("an omitted owner field is filled from the caller", async () => {
    let _ = await generate(
      payload(
        ~command="PlaceOrder",
        ~args=Dict.fromArray([("orderId", str("o-1")), ("note", str(""))]),
        ~identity=cognito(~userId="cust-A", ~groups=["User"]),
      ),
    )->Effect.runPromise
    expect(lastPublished()->fieldOf("customerId"))->toEqual(Some(str("cust-A")))
  })

  // The decisive case. An implementation that fills only the absent field passes
  // every other test in this file and hands one customer another's orders.
  testPromise("a FORGED owner field is overwritten, not respected", async () => {
    let _ =
      await generate(
        placeOrder(~customerId="cust-B", ~identity=cognito(~userId="cust-A", ~groups=["User"])),
      )->Effect.runPromise
    expect(lastPublished()->fieldOf("customerId"))->toEqual(Some(str("cust-A")))
  })

  testPromise("non-owner fields of the same command are untouched", async () => {
    let _ =
      await generate(
        placeOrder(~customerId="cust-B", ~identity=cognito(~userId="cust-A", ~groups=["User"])),
      )->Effect.runPromise
    expect(lastPublished()->fieldOf("note"))->toEqual(Some(str("gift wrap")))
  })

  testPromise("a command in the same union with no owner field is left alone", async () => {
    let _ =
      await generate(
        payload(
          ~command="ImportProducts",
          ~args=Dict.fromArray([("batchId", str("b-1")), ("source", str("acme"))]),
          ~identity=cognito(~userId="cust-A", ~groups=["User"]),
        ),
      )->Effect.runPromise
    expect((lastPublished()->fieldOf("source"), lastPublished()->fieldOf("customerId")))->toEqual((
      Some(str("acme")),
      None,
    ))
  })

  describe("exempt callers keep the value they sent:", () => {
    // Acting on another principal's behalf must stay possible for those who may
    // — otherwise an operator can never correct or back-fill anything.
    testPromise("an elevated caller's chosen customerId survives", async () => {
      let _ =
        await generate(
          placeOrder(~customerId="cust-B", ~identity=cognito(~userId="ops-1", ~groups=["Admin"])),
        )->Effect.runPromise
      expect(lastPublished()->fieldOf("customerId"))->toEqual(Some(str("cust-B")))
    })

    // The IAM shape carries no userId at all. Stamping it would write
    // `undefined`; refusing it would break internal traffic. It is exempt.
    testPromise("an IAM system caller's chosen customerId survives", async () => {
      let _ =
        await generate(placeOrder(~customerId="cust-B", ~identity=iam))->Effect.runPromise
      expect(lastPublished()->fieldOf("customerId"))->toEqual(Some(str("cust-B")))
    })
  })

  describe("a caller that cannot be identified is refused:", () => {
    let refused = async p =>
      switch await generate(p)->Effect.runPromise {
      | _ => false
      | exception _ => true
      }

    testPromise("an anonymous caller cannot place an owned command", async () =>
      expect(
        await refused(placeOrder(~customerId="cust-B", ~identity=Reventless.Identity.anonymous)),
      )->toBe(true)
    )

    // The refusal describes the caller's own request, so a transport is allowed
    // to report it. Unmarked it arrives as "Unexpected error", which tells a
    // caller who needs to authenticate nothing at all.
    testPromise("the refusal is marked as the caller's fault", async () => {
      let failure = switch await generate(
        placeOrder(~customerId="cust-B", ~identity=Reventless.Identity.anonymous),
      )->Effect.runPromise {
      | _ => None
      | exception e => Some(e)
      }
      expect(failure->Option.mapOr(false, Plugin_ResolverError.isCallerFault))->toBe(true)
    })

    testPromise("nothing is published when the caller is refused", async () => {
      let _ = await refused(
        placeOrder(~customerId="cust-B", ~identity=Reventless.Identity.anonymous),
      )
      expect(published.contents->Array.length)->toBe(0)
    })

    // The refusal is scoped to commands that actually record an owner. An
    // anonymous caller invoking an unowned command has nothing to prove, and
    // refusing it here would silently narrow `AllowAnonymous`.
    testPromise("an anonymous caller may still issue an unowned command", async () => {
      let _ = await generate(
        payload(
          ~command="ImportProducts",
          ~args=Dict.fromArray([("batchId", str("b-1")), ("source", str("acme"))]),
          ~identity=Reventless.Identity.anonymous,
        ),
      )->Effect.runPromise
      expect(lastPublished()->fieldOf("source"))->toEqual(Some(str("acme")))
    })
  })
})

// The schema is not only a validator, and the case below is the one that proves
// it. Two AppSync-side call sites passed `S.json` in place of the command schema
// — a defensible substitution while its only job was validation, since AppSync
// has already checked the input against the SDL, and per-slice decoding happens
// downstream anyway. Owner stamping then gave the same argument a second job:
// it is where the `@owner` fields are read from. Handed a permissive schema the
// lookup answers "no owner fields" for every command there is, and the write
// keeps whatever owner the client sent — no error, no warning, a wrong row.
//
// Nothing about a single call site was wrong, which is why per-path tests could
// not catch it. What was missing is a check on the RELATIONSHIP: a generator
// built for a command whose spec marks an owner must be able to find it.
describe("the schema a generator is built with must answer for its commands:", () => {
  let permissive = CommandGenerator_Callback.makeGenerateCommand(
    ~publishJsons=async cmds => published := published.contents->Array.concat(cmds),
    ~serviceName="Ordering",
    ~commandSchema=S.json->S.castToUnknown,
    ~componentKind=CommandGenerator_Callback.StateChangeSlice,
    ~stripIdFromParams=false,
  )

  testPromise("a permissive schema silently stamps nothing — the defect, pinned", async () => {
    let _ =
      await permissive(
        placeOrder(~customerId="cust-B", ~identity=cognito(~userId="cust-A", ~groups=["User"])),
      )->Effect.runPromise
    // Not the behaviour we want anywhere — recorded so that a change making the
    // permissive path stamp correctly is a deliberate one, and so the contrast
    // with the case below cannot be read as incidental.
    expect(lastPublished()->fieldOf("customerId"))->toEqual(Some(str("cust-B")))
  })

  testPromise("the real schema stamps, from the same payload and caller", async () => {
    let _ =
      await generate(
        placeOrder(~customerId="cust-B", ~identity=cognito(~userId="cust-A", ~groups=["User"])),
      )->Effect.runPromise
    expect(lastPublished()->fieldOf("customerId"))->toEqual(Some(str("cust-A")))
  })

  // The check a call site can run against itself, and the one the DCB routing
  // maps now satisfy by construction: every command a spec exposes resolves to
  // its own owner fields through the schema that command will be dispatched
  // with. Reading `[]` here is exactly the state that stamps nothing.
  testPromise("every command of a spec resolves its owner fields through that spec's schema", async () => {
    let schema = commandSchema->S.castToUnknown
    expect(Reventless.Owner.variantFieldNames(schema, ~variant="PlaceOrder"))->toEqual([
      "customerId",
    ])
    expect(Reventless.Owner.variantFieldNames(schema, ~variant="ImportProducts"))->toEqual([])
    // The substitution, asked the same question.
    expect(
      Reventless.Owner.variantFieldNames(S.json->S.castToUnknown, ~variant="PlaceOrder"),
    )->toEqual([])
  })
})
