open JestGlobals


// The point of the seam, end to end at the hook level: an extension that only
// ever gets `onColdStart` can reach the framework's runtime callback hooks from
// there, and they take effect on the requests that follow.
//
// `CommandGenerator_Callback.registerCommandInterceptor` stands in for all four
// registrars — they share the shape (a module-level ref consulted on the hot
// path), so what makes one reachable makes the others reachable too. What is
// being proved is the ordering: registration happens inside the cold-start hook,
// the command runs after it, and the interceptor is consulted.

@schema
type command = Add({@partitionTag productId: string, name: string})

let published: ref<array<Message.commandJson>> = ref([])
let publishJsons: CommandGenerator.publishJsons = async cmds =>
  published := published.contents->Array.concat(cmds)

let generateCommand = CommandGenerator_Callback.makeGenerateCommand(
  ~publishJsons,
  ~serviceName="Product",
  ~commandSchema=commandSchema->S.castToUnknown,
  ~componentKind=CommandGenerator_Callback.StateChangeSlice,
  ~stripIdFromParams=false,
)

let addChair = (): CommandGenerator.payload =>
  Obj.magic({
    "command": "Add",
    "arguments": {"productId": "p1", "name": "Chair"},
    "meta": {"ip": ["127.0.0.1"], "user": "test-user", "info": ""},
  })

let runAdd = async () => await generateCommand(addChair())->Effect.runPromise

describe("RuntimeExtension reaches the runtime callback hooks", () => {
  beforeEach(() => {
    RuntimeExtension.reset()
    CommandGenerator_Callback.clearCommandInterceptor()
    published := []
  })

  testPromise("an interceptor registered at cold start denies a later command", async () => {
    let seenAtColdStart: array<string> = []
    module Gatekeeper: RuntimeExtension.Extension = {
      let moduleUrl = "file:///pkg/gatekeeper.res.mjs"
      let companionModuleUrls = []
      let onColdStart = (~runtimeKind as _, ~component, ~plugin as _, ~platform as _) => {
        seenAtColdStart->Array.push(component)
        CommandGenerator_Callback.registerCommandInterceptor(async (
          ~identity as _,
          ~componentName,
          ~componentKind as _,
          ~tag,
          ~args as _,
        ) => CommandGenerator_Callback.Deny(`${componentName}.${tag} refused`))
      }
    }
    RuntimeExtension.use(module(Gatekeeper: RuntimeExtension.Extension))

    RuntimeExtension.notifyColdStart(
      ~runtimeKind=ComponentType.StateChangeSlice,
      ~component="CatalogStateChanges",
      ~plugin=Some("Catalog"),
      ~platform=Some("Shop"),
    )
    expect(seenAtColdStart)->toEqual(["CatalogStateChanges"])

    let denied = switch await runAdd() {
    | _ => None
    | exception exn => exn->JsExn.fromException->Option.flatMap(JsExn.message)
    }

    expect(denied)->toEqual(Some("Product.Add refused"))
    expect(published.contents->Array.length)->toBe(0)
  })

  testPromise("with nothing registered the same command publishes untouched", async () => {
    let _ = await runAdd()
    expect(published.contents->Array.length)->toBe(1)
  })
})
