// Route P of the DCB command Lambda, built by the real `buildHandlersForConfig` over
// no slices: what a platform invocation's commands are answered with.
import { buildHandlersForConfig } from "@reventlessdev/reventless-aws/src/adapter/Runtime/DcbCommandTopicEntryPoint.mjs";

export async function answerPlatformCommands(commands) {
  const config = {
    pluginName: "PlatformCommandsTestPlugin",
    dcbEventLogTableName: "platform-commands-test-table",
    stateChangeSliceModules: [],
    queueUrl: "https://sqs.eu-west-1.amazonaws.com/000000000000/platform-commands-test-queue",
  };
  const handlers = await buildHandlersForConfig(config, {
    loadModule: async (specifier) => {
      throw new Error("unexpected module load: " + specifier);
    },
  });
  return await handlers[6](commands);
}
