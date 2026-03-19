/**
 * Generate Lambda entry point code for aggregate handlers.
 *
 * These functions produce JavaScript source code strings that are written to
 * temp files and bundled by esbuild. The generated code contains JS template
 * literals and dynamic imports — syntax that is impractical to express in
 * ReScript string templates. Hence this file stays as .mjs.
 *
 * Type definitions and config types live in Util_EntryPoint.res.
 */

export function generateAggregateEntryPoint(config) {
  const { name, handlers, shimModule } = config;

  const imports = new Map();
  handlers.forEach((h, i) => {
    const key = `${h.handlerModule}:${h.handlerExport}`;
    if (!imports.has(key)) {
      imports.set(key, `handler_${i}`);
    }
  });

  const importLines = [];
  importLines.push(
    `import { val, resource } from ${JSON.stringify(shimModule)};`
  );
  importLines.push(`import { Effect } from "effect";`);
  importLines.push(
    `import * as RequestContext from "@reventlessdev/reventless-core/src/RequestContext.res.mjs";`
  );

  for (const [[modPath, exportName], alias] of [...imports.entries()].map(
    ([k, v]) => [k.split(":"), v]
  )) {
    importLines.push(
      `import { ${exportName} as ${alias} } from ${JSON.stringify(modPath)};`
    );
  }

  const cmdTopicLines = [];
  const evtCollectorLines = [];
  const cmdGenLines = [];

  handlers.forEach((h, i) => {
    const key = `${h.handlerModule}:${h.handlerExport}`;
    const alias = imports.get(key);
    const urnEnvVar = `HANDLER_${i}_URN`;

    switch (h.handlerType) {
      case "commandTopic":
        cmdTopicLines.push(`  [process.env.${urnEnvVar}, ${alias}],`);
        break;
      case "eventCollector":
        evtCollectorLines.push(`  [process.env.${urnEnvVar}, [${alias}]],`);
        break;
      case "commandGenerator":
        cmdGenLines.push(`  [process.env.${urnEnvVar}, ${alias}],`);
        break;
    }
  });

  return `// Generated aggregate handler entry point for "${name}"
${importLines.join("\n")}

const runEffect = (correlationId, effect) =>
  effect
    .pipe(
      Effect.provideService(RequestContext.tag, { correlationId: correlationId || "unknown" })
    )
    .pipe(Effect.runPromise);

const commandTopicHandlers = new Map([
${cmdTopicLines.join("\n")}
]);

const eventCollectorHandlers = new Map([
${evtCollectorLines.join("\n")}
]);

const commandGeneratorHandlers = new Map([
${cmdGenLines.join("\n")}
]);

function groupBySource(event) {
  const dict = {};
  for (const record of event.Records || []) {
    const arn = record.eventSourceARN;
    if (!dict[arn]) dict[arn] = { Records: [] };
    dict[arn].Records.push(record);
  }
  return dict;
}

function extractCorrelationId(event) {
  try {
    const body = JSON.parse((event.Records || [])[0]?.body || "{}");
    return body?.meta?.correlationId;
  } catch { return undefined; }
}

export const handler = async (event, context) => {
  const correlationId = extractCorrelationId(event);
  const desc = "aggregateHandler for ${name}:";
  const grouped = groupBySource(event);

  for (const [urn, subEvent] of Object.entries(grouped)) {
    const cmdHandler = commandTopicHandlers.get(urn);
    if (cmdHandler) {
      console.log(\`----- \${desc} found handler for CommandTopic \${urn}\`);
      await runEffect(correlationId, cmdHandler(subEvent, context));
      continue;
    }

    const evtHandlers = eventCollectorHandlers.get(urn);
    if (evtHandlers) {
      console.log(\`----- \${desc} found \${evtHandlers.length} handler(s) for EventCollector \${urn}\`);
      await Promise.all(evtHandlers.map(h => runEffect(correlationId, h(subEvent, context))));
      continue;
    }

    console.warn(\`\${desc} no handler found: \${urn}\`);
  }

  return "";
};
`;
}

export function generateBundledExtensionPointEntryPoint(config) {
  const { name, handler: h, factoryModule, requestContextModule } = config;

  const importLines = [];
  importLines.push(
    `import { createExtensionPointHandler } from ${JSON.stringify(factoryModule)};`
  );
  importLines.push(`import { Effect } from "effect";`);
  importLines.push(
    `import * as RequestContext from ${JSON.stringify(requestContextModule)};`
  );
  importLines.push(
    `import * as Spec from ${JSON.stringify(h.specModulePath)};`
  );
  importLines.push(
    `import * as Mappings from ${JSON.stringify(h.mappingsModulePath)};`
  );

  // Build publishToAggregatesEnv object from env var references
  const publishToAggEntries = Object.entries(h.publishToAggregatesEnvVars || {})
    .map(([aggName, envVar]) => `    ${JSON.stringify(aggName)}: process.env.${envVar}`)
    .join(",\n");

  return `// Generated bundled ExtensionPoint handler entry point for "${name}"
${importLines.join("\n")}

const runEffect = (correlationId, effect) =>
  effect
    .pipe(
      Effect.provideService(RequestContext.tag, { correlationId: correlationId || "unknown" })
    )
    .pipe(Effect.runPromise);

const extensionPointHandler = createExtensionPointHandler({
  specModule: Spec,
  mappingsModule: Mappings,
  publishToAggregatesEnv: {
${publishToAggEntries}
  },
  queueUrl: process.env.${h.queueUrlEnvVar},
});

function extractCorrelationId(event) {
  try {
    const body = JSON.parse((event.Records || [])[0]?.body || "{}");
    return body?.meta?.correlationId;
  } catch { return undefined; }
}

export const handler = async (event, context) => {
  const correlationId = extractCorrelationId(event);
  console.log(\`----- bundledExtensionPointHandler for ${name}: processing \${(event.Records || []).length} record(s)\`);
  await runEffect(correlationId, extensionPointHandler(event, context));
  return "";
};
`;
}

export function generateBundledOutboundTranslationSliceEntryPoint(config) {
  // Same structure as AutomationSlice but imports OutboundTranslationSlice_Callback
  return generateBundledTodoSliceEntryPoint(config, "OutboundTranslationSlice",
    "@reventlessdev/reventless-core/src/components/OutboundTranslationSlice/OutboundTranslationSlice_Callback.res.mjs");
}

function generateBundledTodoSliceEntryPoint(config, sliceType, callbackModulePath) {
  const { name, handlers, factoryModule, requestContextModule } = config;

  const importLines = [];
  importLines.push(
    `import { createAutomationSliceHandler } from ${JSON.stringify(factoryModule)};`
  );
  if (callbackModulePath) {
    importLines.push(
      `import { Make as CallbackMake } from ${JSON.stringify(callbackModulePath)};`
    );
  }
  importLines.push(`import { Effect } from "effect";`);
  importLines.push(
    `import * as RequestContext from ${JSON.stringify(requestContextModule)};`
  );

  handlers.forEach((h, i) => {
    importLines.push(
      `import * as Spec_${i} from ${JSON.stringify(h.specModulePath)};`
    );
  });

  const callbackArg = callbackModulePath ? `\n    callbackMake: CallbackMake,` : "";
  const handlerInitLines = handlers.map((h, i) =>
    `  [process.env.${h.sourceUrnEnvVar}, [createAutomationSliceHandler({
    specModule: Spec_${i},${callbackArg}
    queryDbTableName: process.env.${h.queryDbTableEnvVar},
    dcbQueueUrl: process.env.${h.dcbQueueUrlEnvVar},
  })]],`
  );

  return `// Generated bundled ${sliceType} handler entry point for "${name}"
${importLines.join("\n")}

const runEffect = (correlationId, effect) =>
  effect
    .pipe(
      Effect.provideService(RequestContext.tag, { correlationId: correlationId || "unknown" })
    )
    .pipe(Effect.runPromise);

const eventCollectorHandlers = new Map([
${handlerInitLines.join("\n")}
]);

function groupBySource(event) {
  const dict = {};
  for (const record of event.Records || []) {
    const arn = record.eventSourceARN;
    if (!dict[arn]) dict[arn] = { Records: [] };
    dict[arn].Records.push(record);
  }
  return dict;
}

export const handler = async (event, context) => {
  const desc = "bundled${sliceType}Handler for ${name}:";
  const grouped = groupBySource(event);

  for (const [urn, subEvent] of Object.entries(grouped)) {
    const handlers = eventCollectorHandlers.get(urn);
    if (handlers) {
      console.log(\`----- \${desc} found \${handlers.length} handler(s) for EventCollector \${urn}\`);
      await Promise.all(handlers.map(h => runEffect(undefined, h(subEvent, context))));
      continue;
    }
    console.warn(\`\${desc} no handler found: \${urn}\`);
  }

  return "";
};
`;
}

export function generateBundledAutomationSliceEntryPoint(config) {
  // AutomationSlice uses the default callback (built into the factory import)
  return generateBundledTodoSliceEntryPoint(config, "AutomationSlice", null);
}

export function generateBundledStateViewSliceEntryPoint(config) {
  const { name, handlers, factoryModule, requestContextModule } = config;

  const importLines = [];
  importLines.push(
    `import { createStateViewSliceHandler } from ${JSON.stringify(factoryModule)};`
  );
  importLines.push(`import { Effect } from "effect";`);
  importLines.push(
    `import * as RequestContext from ${JSON.stringify(requestContextModule)};`
  );

  handlers.forEach((h, i) => {
    importLines.push(
      `import * as Spec_${i} from ${JSON.stringify(h.specModulePath)};`
    );
  });

  const handlerInitLines = handlers.map((h, i) =>
    `  [process.env.${h.sourceUrnEnvVar}, [createStateViewSliceHandler({
    specModule: Spec_${i},
    queryDbTableName: process.env.${h.queryDbTableEnvVar},
  })]],`
  );

  return `// Generated bundled StateViewSlice handler entry point for "${name}"
${importLines.join("\n")}

const runEffect = (correlationId, effect) =>
  effect
    .pipe(
      Effect.provideService(RequestContext.tag, { correlationId: correlationId || "unknown" })
    )
    .pipe(Effect.runPromise);

const eventCollectorHandlers = new Map([
${handlerInitLines.join("\n")}
]);

function groupBySource(event) {
  const dict = {};
  for (const record of event.Records || []) {
    const arn = record.eventSourceARN;
    if (!dict[arn]) dict[arn] = { Records: [] };
    dict[arn].Records.push(record);
  }
  return dict;
}

export const handler = async (event, context) => {
  const desc = "bundledStateViewSliceHandler for ${name}:";
  const grouped = groupBySource(event);

  for (const [urn, subEvent] of Object.entries(grouped)) {
    const handlers = eventCollectorHandlers.get(urn);
    if (handlers) {
      console.log(\`----- \${desc} found \${handlers.length} handler(s) for EventCollector \${urn}\`);
      await Promise.all(handlers.map(h => runEffect(undefined, h(subEvent, context))));
      continue;
    }
    console.warn(\`\${desc} no handler found: \${urn}\`);
  }

  return "";
};
`;
}

export function generateBundledReadModelEntryPoint(config) {
  const { name, handlers, factoryModule, requestContextModule } = config;

  const importLines = [];
  importLines.push(
    `import { createReadModelHandler } from ${JSON.stringify(factoryModule)};`
  );
  importLines.push(`import { Effect } from "effect";`);
  importLines.push(
    `import * as RequestContext from ${JSON.stringify(requestContextModule)};`
  );

  handlers.forEach((h, i) => {
    importLines.push(
      `import * as Spec_${i} from ${JSON.stringify(h.specModulePath)};`
    );
    importLines.push(
      `import * as Mappings_${i} from ${JSON.stringify(h.mappingsModulePath)};`
    );
  });

  const handlerInitLines = handlers.map((h, i) =>
    `  [process.env.${h.sourceUrnEnvVar}, [createReadModelHandler({
    specModule: Spec_${i},
    mappingsModule: Mappings_${i},
    queryDbTableName: process.env.${h.queryDbTableEnvVar},
  })]],`
  );

  return `// Generated bundled ReadModel handler entry point for "${name}"
${importLines.join("\n")}

const runEffect = (correlationId, effect) =>
  effect
    .pipe(
      Effect.provideService(RequestContext.tag, { correlationId: correlationId || "unknown" })
    )
    .pipe(Effect.runPromise);

const eventCollectorHandlers = new Map([
${handlerInitLines.join("\n")}
]);

function groupBySource(event) {
  const dict = {};
  for (const record of event.Records || []) {
    const arn = record.eventSourceARN;
    if (!dict[arn]) dict[arn] = { Records: [] };
    dict[arn].Records.push(record);
  }
  return dict;
}

export const handler = async (event, context) => {
  const desc = "bundledReadModelHandler for ${name}:";
  const grouped = groupBySource(event);

  for (const [urn, subEvent] of Object.entries(grouped)) {
    const handlers = eventCollectorHandlers.get(urn);
    if (handlers) {
      console.log(\`----- \${desc} found \${handlers.length} handler(s) for EventCollector \${urn}\`);
      await Promise.all(handlers.map(h => runEffect(undefined, h(subEvent, context))));
      continue;
    }
    console.warn(\`\${desc} no handler found: \${urn}\`);
  }

  return "";
};
`;
}

export function generateBundledAdminEventCollectorEntryPoint(config) {
  const {
    name,
    factoryModule,
    requestContextModule,
    queueUrlEnvVar,
    eventTopicArnEnvVar,
    pluginReadModelTableEnvVar,
    schedulerRoleArnEnvVar,
    schedulerQueueArnEnvVar,
    schedulerQueueNameEnvVar,
    appSyncApiIdEnvVar,
    clonerEnabledEnvVar,
  } = config;

  return `// Generated bundled Admin EventCollector handler entry point for "${name}"
import { createAdminEventCollectorHandler } from ${JSON.stringify(factoryModule)};
import { Effect } from "effect";
import * as RequestContext from ${JSON.stringify(requestContextModule)};

const runEffect = (correlationId, effect) =>
  effect
    .pipe(
      Effect.provideService(RequestContext.tag, { correlationId: correlationId || "unknown" })
    )
    .pipe(Effect.runPromise);

const adminHandler = createAdminEventCollectorHandler({
  queueUrl: process.env.${queueUrlEnvVar},
  eventTopicArn: process.env.${eventTopicArnEnvVar},
  pluginReadModelTableName: process.env.${pluginReadModelTableEnvVar},
  schedulerRoleArn: process.env.${schedulerRoleArnEnvVar},
  schedulerQueueArn: process.env.${schedulerQueueArnEnvVar},
  schedulerQueueName: process.env.${schedulerQueueNameEnvVar},
  appSyncApiId: process.env.${appSyncApiIdEnvVar},
  clonerEnabled: process.env.${clonerEnabledEnvVar} === "true",
});

export const handler = async (event, context) => {
  console.log(\`----- bundledAdminEventCollectorHandler for ${name}: processing \${(event.Records || []).length} record(s)\`);
  await runEffect(undefined, adminHandler(event, context));
  return "";
};
`;
}

export function generateBundledPluginExtensionPointEntryPoint(config) {
  const { name, handler: h, factoryModule, requestContextModule } = config;

  // Build publishToAggregatesEnv object from env var references
  const publishToAggEntries = Object.entries(h.publishToAggregatesEnvVars || {})
    .map(([aggName, envVar]) => `    ${JSON.stringify(aggName)}: process.env.${envVar}`)
    .join(",\n");

  return `// Generated bundled Plugin ExtensionPoint handler entry point for "${name}"
import { createPluginExtensionPointHandler } from ${JSON.stringify(factoryModule)};
import { Effect } from "effect";
import * as RequestContext from ${JSON.stringify(requestContextModule)};

const runEffect = (correlationId, effect) =>
  effect
    .pipe(
      Effect.provideService(RequestContext.tag, { correlationId: correlationId || "unknown" })
    )
    .pipe(Effect.runPromise);

const pluginEPHandler = createPluginExtensionPointHandler({
  publishToAggregatesEnv: {
${publishToAggEntries}
  },
  queueUrl: process.env.${h.queueUrlEnvVar},
  pluginReadModelTableName: process.env.${h.pluginReadModelTableEnvVar},
  schedulerRoleArn: process.env.${h.schedulerRoleArnEnvVar},
  schedulerQueueArn: process.env.${h.schedulerQueueArnEnvVar},
  schedulerQueueName: process.env.${h.schedulerQueueNameEnvVar},
});

function extractCorrelationId(event) {
  try {
    const body = JSON.parse((event.Records || [])[0]?.body || "{}");
    return body?.meta?.correlationId;
  } catch { return undefined; }
}

export const handler = async (event, context) => {
  const correlationId = extractCorrelationId(event);
  console.log(\`----- bundledPluginExtensionPointHandler for ${name}: processing \${(event.Records || []).length} record(s)\`);
  await runEffect(correlationId, pluginEPHandler(event, context));
  return "";
};
`;
}

export function generateBundledCommandGeneratorEntryPoint(config) {
  const { name, factoryModule, requestContextModule, specModulePath, behaviorModulePath, queueUrlEnvVar } = config;

  return `// Generated bundled CommandGenerator handler entry point for "${name}"
import { createCommandGeneratorHandler } from ${JSON.stringify(factoryModule)};
import { Effect } from "effect";
import * as RequestContext from ${JSON.stringify(requestContextModule)};
import * as Spec from ${JSON.stringify(specModulePath)};
import * as Behavior from ${JSON.stringify(behaviorModulePath)};

const runEffect = (correlationId, effect) =>
  effect
    .pipe(
      Effect.provideService(RequestContext.tag, { correlationId: correlationId || "unknown" })
    )
    .pipe(Effect.runPromise);

const generateCommand = createCommandGeneratorHandler({
  specModule: Spec,
  behaviorModule: Behavior,
  queueUrl: process.env.${queueUrlEnvVar},
});

export const handler = async (event, context) => {
  console.log(\`----- bundledCommandGeneratorHandler for ${name}: processing\`);
  const result = await runEffect(undefined, generateCommand(event, context));
  return result;
};
`;
}

export function generateBundledEventMapperEntryPoint(config) {
  const { name, factoryModule, requestContextModule, targetSpecModulePath, mappingsModulePath, queueUrlEnvVar } = config;

  return `// Generated bundled EventMapper handler entry point for "${name}"
import { createEventMapperHandler } from ${JSON.stringify(factoryModule)};
import { Effect } from "effect";
import * as RequestContext from ${JSON.stringify(requestContextModule)};
import * as TargetSpec from ${JSON.stringify(targetSpecModulePath)};
import * as Mappings from ${JSON.stringify(mappingsModulePath)};

const runEffect = (correlationId, effect) =>
  effect
    .pipe(
      Effect.provideService(RequestContext.tag, { correlationId: correlationId || "unknown" })
    )
    .pipe(Effect.runPromise);

const eventMapperHandler = createEventMapperHandler({
  targetSpecModule: TargetSpec,
  mappingsModule: Mappings,
  queueUrl: process.env.${queueUrlEnvVar},
});

export const handler = async (event, context) => {
  console.log(\`----- bundledEventMapperHandler for ${name}: processing \${(event.Records || []).length} record(s)\`);
  await runEffect(undefined, eventMapperHandler(event, context));
  return "";
};
`;
}

export function generateBundledAggregateEntryPoint(config) {
  const { name, handlers, factoryModule, requestContextModule } = config;

  const importLines = [];
  importLines.push(
    `import { createCommandTopicHandler } from ${JSON.stringify(factoryModule)};`
  );
  importLines.push(`import { Effect } from "effect";`);
  importLines.push(
    `import * as RequestContext from ${JSON.stringify(requestContextModule)};`
  );

  handlers.forEach((h, i) => {
    importLines.push(
      `import * as Spec_${i} from ${JSON.stringify(h.specModulePath)};`
    );
    importLines.push(
      `import * as Behavior_${i} from ${JSON.stringify(h.behaviorModulePath)};`
    );
  });

  const handlerInitLines = handlers.map((h, i) =>
    `  [process.env.${h.queueArnEnvVar}, createCommandTopicHandler({
    specModule: Spec_${i},
    behaviorModule: Behavior_${i},
    eventLogTableName: process.env.${h.eventLogTableEnvVar},
    queueUrl: process.env.${h.queueUrlEnvVar},
  })],`
  );

  return `// Generated bundled aggregate handler entry point for "${name}"
${importLines.join("\n")}

const runEffect = (correlationId, effect) =>
  effect
    .pipe(
      Effect.provideService(RequestContext.tag, { correlationId: correlationId || "unknown" })
    )
    .pipe(Effect.runPromise);

const commandTopicHandlers = new Map([
${handlerInitLines.join("\n")}
]);

function groupBySource(event) {
  const dict = {};
  for (const record of event.Records || []) {
    const arn = record.eventSourceARN;
    if (!dict[arn]) dict[arn] = { Records: [] };
    dict[arn].Records.push(record);
  }
  return dict;
}

function extractCorrelationId(event) {
  try {
    const body = JSON.parse((event.Records || [])[0]?.body || "{}");
    return body?.meta?.correlationId;
  } catch { return undefined; }
}

export const handler = async (event, context) => {
  const correlationId = extractCorrelationId(event);
  const desc = "bundledAggregateHandler for ${name}:";
  const grouped = groupBySource(event);

  for (const [arn, subEvent] of Object.entries(grouped)) {
    const cmdHandler = commandTopicHandlers.get(arn);
    if (cmdHandler) {
      console.log(\`----- \${desc} found handler for CommandTopic \${arn}\`);
      await runEffect(correlationId, cmdHandler(subEvent, context));
      continue;
    }
    console.warn(\`\${desc} no handler found: \${arn}\`);
  }

  return "";
};
`;
}

export function generateBundledSideEffectEntryPoint(config) {
  const { name, handlers, factoryModule, requestContextModule } = config;

  const importLines = [];
  importLines.push(
    `import { createSideEffectHandler } from ${JSON.stringify(factoryModule)};`
  );
  importLines.push(`import { Effect } from "effect";`);
  importLines.push(
    `import * as RequestContext from ${JSON.stringify(requestContextModule)};`
  );

  // Import all SideEffect modules across all handlers
  const moduleImports = new Map();
  let moduleIdx = 0;
  handlers.forEach((h) => {
    h.sideEffectModulePaths.forEach((modPath) => {
      if (!moduleImports.has(modPath)) {
        moduleImports.set(modPath, `SideEffect_${moduleIdx}`);
        moduleIdx++;
      }
    });
  });

  for (const [modPath, alias] of moduleImports.entries()) {
    importLines.push(
      `import * as ${alias} from ${JSON.stringify(modPath)};`
    );
  }

  const handlerInitLines = handlers.map((h) => {
    const moduleAliases = h.sideEffectModulePaths
      .map((modPath) => moduleImports.get(modPath))
      .join(", ");
    return `  [process.env.${h.sourceUrnEnvVar}, [createSideEffectHandler({
    sideEffectModules: [${moduleAliases}],
  })]],`;
  });

  return `// Generated bundled SideEffectHandler entry point for "${name}"
${importLines.join("\n")}

const runEffect = (correlationId, effect) =>
  effect
    .pipe(
      Effect.provideService(RequestContext.tag, { correlationId: correlationId || "unknown" })
    )
    .pipe(Effect.runPromise);

const eventCollectorHandlers = new Map([
${handlerInitLines.join("\n")}
]);

function groupBySource(event) {
  const dict = {};
  for (const record of event.Records || []) {
    const arn = record.eventSourceARN;
    if (!dict[arn]) dict[arn] = { Records: [] };
    dict[arn].Records.push(record);
  }
  return dict;
}

export const handler = async (event, context) => {
  const desc = "bundledSideEffectHandler for ${name}:";
  const grouped = groupBySource(event);

  for (const [urn, subEvent] of Object.entries(grouped)) {
    const handlers = eventCollectorHandlers.get(urn);
    if (handlers) {
      console.log(\`----- \${desc} found \${handlers.length} handler(s) for SideEffectHandler \${urn}\`);
      await Promise.all(handlers.map(h => runEffect(undefined, h(subEvent, context))));
      continue;
    }
    console.warn(\`\${desc} no handler found: \${urn}\`);
  }

  return "";
};
`;
}

export function generateBundledTaskBucketEntryPoint(config) {
  const { name, callbackModulePath, factoryModule, publishToAggregatesEnvVars } = config;

  const importLines = [];
  importLines.push(
    `import { createTaskBucketHandler } from ${JSON.stringify(factoryModule)};`
  );
  importLines.push(
    `import * as CallbackModule from ${JSON.stringify(callbackModulePath)};`
  );

  // Build publishToAggregatesEnv object from env var references
  const publishEntries = Object.entries(publishToAggregatesEnvVars || {})
    .map(([aggName, envVar]) => `    ${JSON.stringify(aggName)}: process.env.${envVar}`)
    .join(",\n");

  return `// Generated bundled Task bucket handler entry point for "${name}"
${importLines.join("\n")}

const taskHandler = createTaskBucketHandler({
  callbackModule: CallbackModule,
  publishToAggregatesEnv: {
${publishEntries}
  },
});

export const handler = async (event, context) => {
  console.log(\`----- bundledTaskBucketHandler for ${name}: processing \${(event.Records || []).length} record(s)\`);
  return await taskHandler(event, context);
};
`;
}

export function generateBundledCounterEntryPoint(config) {
  const {
    name,
    targetSpecModulePath,
    mappingsModulePath,
    factoryModule,
    countsTableEnvVar,
    publishQueueUrlEnvVar,
    referencesStreamArnEnvVar,
    countsStreamArnEnvVar,
  } = config;

  return `// Generated bundled Counter handler entry point for "${name}"
import { createCounterHandler } from ${JSON.stringify(factoryModule)};
import * as TargetSpec from ${JSON.stringify(targetSpecModulePath)};
import * as Mappings from ${JSON.stringify(mappingsModulePath)};

const counterHandler = createCounterHandler({
  targetSpecModule: TargetSpec,
  mappingsModule: Mappings,
  countsTableName: process.env.${countsTableEnvVar},
  publishQueueUrl: process.env.${publishQueueUrlEnvVar},
  referencesStreamArn: process.env.${referencesStreamArnEnvVar},
  countsStreamArn: process.env.${countsStreamArnEnvVar},
});

export const handler = async (event, context) => {
  console.log(\`----- bundledCounterHandler for ${name}: processing \${(event.Records || []).length} record(s)\`);
  await counterHandler(event, context);
  return "";
};
`;
}

// ---------- DCB CommandTopic ----------

/**
 * Generate bundled entry point for DCB CommandTopic Lambda.
 *
 * @param {Object} config
 * @param {string} config.name - Handler name
 * @param {string} config.factoryModule - Path to BundledDcbCommandTopicHandlerFactory.mjs
 * @param {string} config.requestContextModule - Path to RequestContext.res.mjs
 * @param {string} config.dcbTableEnvVar - Env var for DCB EventLog table name
 * @param {string} config.queueUrlEnvVar - Env var for SQS queue URL
 * @param {string} config.pluginName - Plugin name
 * @param {Array<{specModulePath: string}>} config.stateChangeSliceSpecs - Array of spec module paths
 * @returns {string} Generated entry point JS code
 */
export function generateBundledDcbCommandTopicEntryPoint(config) {
  const {
    name,
    factoryModule,
    requestContextModule,
    dcbTableEnvVar,
    queueUrlEnvVar,
    pluginName,
    stateChangeSliceSpecs,
  } = config;

  const imports = stateChangeSliceSpecs
    .map((spec, i) => `import * as SliceSpec_${i} from "${spec.specModulePath}";`)
    .join("\n");

  const specArray = stateChangeSliceSpecs
    .map((_, i) => `  { specModule: SliceSpec_${i} }`)
    .join(",\n");

  return `
import { createDcbCommandTopicHandler } from "${factoryModule}";
import * as RequestContext from "${requestContextModule}";
${imports}

const dcbHandler = createDcbCommandTopicHandler({
  dcbEventLogTableName: process.env.${dcbTableEnvVar},
  queueUrl: process.env.${queueUrlEnvVar},
  pluginName: "${pluginName}",
  stateChangeSliceSpecs: [
${specArray}
  ],
});

export const handler = async (event, context) => {
  console.log(\`----- bundledDcbCommandTopic for ${name}: processing \${JSON.stringify(event).slice(0, 200)}\`);

  // Handle InboundTranslation markers
  if (event.__inboundTranslation) {
    console.log(\`----- bundledDcbCommandTopic: InboundTranslation route (fieldName=\${event.fieldName})\`);
    // InboundTranslation not yet supported in bundled mode
    return "NOT_SUPPORTED_IN_BUNDLED_MODE";
  }

  // Handle CommandGenerator payload (AppSync direct invocation)
  if (event.command && event.arguments) {
    console.log(\`----- bundledDcbCommandTopic: CommandGenerator route (command=\${event.command})\`);
    // CommandGenerator not yet supported in bundled mode
    return "NOT_SUPPORTED_IN_BUNDLED_MODE";
  }

  // Normal SQS path
  const { Effect } = await import("effect");
  const correlationId = extractCorrelationId(event);
  RequestContext.set({ correlationId: correlationId || "unknown" });
  const result = await Effect.runPromise(dcbHandler(event, context));
  return result || "";
};

function extractCorrelationId(event) {
  try {
    const records = event.Records || [];
    if (records.length > 0) {
      const body = JSON.parse(records[0].body);
      return body?.meta?.correlationId;
    }
  } catch (_) {}
  return undefined;
}
`;
}

// ---------- Heartbeat ----------

/**
 * Generate bundled entry point for Heartbeat Lambda.
 *
 * @param {Object} config
 * @param {string} config.name - Handler name
 * @param {string} config.factoryModule - Path to BundledHeartbeatHandlerFactory.mjs
 * @param {string} config.epQueueUrlEnvVar - Env var for EP CommandTopic SQS queue URL
 * @param {string} config.pluginIdEnvVar - Env var for plugin ID
 * @param {string} config.timeoutEnvVar - Env var for heartbeat timeout
 * @returns {string} Generated entry point JS code
 */
export function generateBundledHeartbeatEntryPoint(config) {
  const { name, factoryModule, epQueueUrlEnvVar, pluginIdEnvVar, timeoutEnvVar } = config;

  return `
import { createHeartbeatHandler } from "${factoryModule}";

const heartbeatHandler = createHeartbeatHandler({
  epQueueUrl: process.env.${epQueueUrlEnvVar},
  pluginId: process.env.${pluginIdEnvVar},
  timeout: parseInt(process.env.${timeoutEnvVar} || "10", 10),
});

export const handler = async (event, context) => {
  console.log(\`----- bundledHeartbeat for ${name}: invoked\`);
  await heartbeatHandler(event, context);
  return "";
};
`;
}
