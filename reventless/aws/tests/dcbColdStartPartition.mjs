// Harness for DcbColdStartPartitionTest.
//
// Startup runs when the entry point is first imported, reading HANDLER_CONFIG from
// the environment — so the failed-startup case has to set it before that import,
// which only plain ESM can do. The assertions stay in the .res test.

const ENTRY = "../src/adapter/Runtime/DcbCommandTopicEntryPoint.mjs";

const baseConfig = {
  pluginName: "ColdStartTestPlugin",
  dcbEventLogTableName: "cold-start-test-table",
  queueUrl: "https://sqs.eu-west-1.amazonaws.com/000000000000/cold-start-test-queue",
  inboundTranslationSliceModules: [],
};

const messageOf = (err) => (err instanceof Error ? err.message : String(err));

// Imports the entry point with a registry it cannot load, then calls `handler`
// twice. Returns both rejection messages and any rejection nobody handled.
export async function invokeAfterFailedStartup() {
  const unhandled = [];
  const onUnhandled = (reason) => unhandled.push(messageOf(reason));
  process.on("unhandledRejection", onUnhandled);
  process.env.HANDLER_CONFIG = JSON.stringify({
    ...baseConfig,
    stateChangeSliceModules: [{ spec: "cold-start-test/missing-spec.mjs", behavior: "cold-start-test/missing-behavior.mjs" }],
  });
  try {
    const { handler } = await import(ENTRY);
    // Let the startup rejection settle before anyone awaits it.
    await new Promise((resolve) => setTimeout(resolve, 50));
    const messages = [];
    for (let i = 0; i < 2; i++) {
      try {
        await handler({ Records: [] }, { awsRequestId: `call-${i}` });
        messages.push("resolved");
      } catch (err) {
        messages.push(messageOf(err));
      }
    }
    return { messages, unhandled };
  } finally {
    delete process.env.HANDLER_CONFIG;
    process.off("unhandledRejection", onUnhandled);
  }
}

// Builds the handlers for a boundary holding one slice whose partition cannot be
// inferred. Returns the rejection message, or "started".
export async function startWithUnresolvedSlice() {
  const { buildHandlersForConfig } = await import(ENTRY);
  const loadModule = async (specifier) => {
    if (specifier === "cold-start-test://spec") return await import("./DcbUnresolvedPartitionSlice.res.mjs");
    if (specifier === "cold-start-test://behavior") return {};
    throw new Error("unknown test specifier: " + specifier);
  };
  try {
    await buildHandlersForConfig(
      { ...baseConfig, stateChangeSliceModules: [{ spec: "cold-start-test://spec", behavior: "cold-start-test://behavior" }] },
      { loadModule },
    );
    return "started";
  } catch (err) {
    return messageOf(err);
  }
}
