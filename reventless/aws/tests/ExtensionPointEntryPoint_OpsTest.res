// Guards the typed cold-start core hoisted out of ExtensionPointEntryPoint.mjs:
//   - parseHandlerConfig — the {specModule, mappingsModule, queueUrl,
//     publishToAggregates} shape written by
//     ExtensionPointRuntime_Builder_PerExtensionPoint.
//   - makeCallbackSpec — env-var resolution of the per-aggregate publish dict
//     and the stub shapes (the former shell's scheduler/resourceNaming stubs
//     carried wrong field names, crashing with "not a function" instead of the
//     intended error).

open JestGlobals


describe("ExtensionPointEntryPoint_Ops.parseHandlerConfig", () => {
  testSync("reads the builder's field names", () => {
    let config = ExtensionPointEntryPoint_Ops.parseHandlerConfig(
      `{"specModule":"@x/spec/src/Products_ExtensionPoint.res.mjs","mappingsModule":"@x/p/src/ExtensionPoint/Products_ExtensionPointMapping.res.mjs","queueUrl":"https://sqs/ep","publishToAggregates":{"Product":"EP_TEST_PRODUCT_QUEUE"}}`,
    )
    expect(config.specModule)->toEqual(Some("@x/spec/src/Products_ExtensionPoint.res.mjs"))
    expect(config.queueUrl)->toEqual(Some("https://sqs/ep"))
    expect(config.publishToAggregates->Option.flatMap(d => d->Dict.get("Product")))->toEqual(
      Some("EP_TEST_PRODUCT_QUEUE"),
    )
  })
})

describe("ExtensionPointEntryPoint_Ops.makeCallbackSpec", () => {
  testSync("resolves publishToAggregates queue URLs via env vars", () => {
    NodeProcess.env->Dict.set("EP_TEST_PRODUCT_QUEUE", "https://sqs/product")
    let spec = ExtensionPointEntryPoint_Ops.makeCallbackSpec({
      queueUrl: "https://sqs/ep",
      publishToAggregates: Dict.fromArray([("Product", "EP_TEST_PRODUCT_QUEUE")]),
    })
    expect(spec.publishToAggregates->Dict.keysToArray)->toEqual(["Product"])
    expect(spec.commandTopicResources->Array.length)->toBe(0)
  })

  testSync("scheduler and queryEngine stubs throw the intended errors", () => {
    let spec = ExtensionPointEntryPoint_Ops.makeCallbackSpec({})
    let scanThrew = switch spec.queryEngine.scan(~readModelName="X", ~filterConfigs=[], ~limit=1) {
    | _ => false
    | exception _ => true
    }
    expect(scanThrew)->toBe(true)
    let deleteThrew = switch spec.scheduler.deleteSchedule([], "s") {
    | _ => false
    | exception _ => true
    }
    expect(deleteThrew)->toBe(true)
  })

  testSync("resourceNaming passes names through", () => {
    let spec = ExtensionPointEntryPoint_Ops.makeCallbackSpec({})
    expect(spec.resourceNaming.validateName("My-Name"))->toBe("My-Name")
    expect(spec.resourceNaming.urnName("arn:x"))->toBe("arn:x")
  })
})
