// The runtime-extension cold start, on its own so a runtime can await it without
// pulling the rest of the entry-point toolkit in behind it.
//
// It lived in HandlerFactoryHelpers because every compiled entry shell wants it
// alongside the Effect runtime, the DynamoDB clients and the logging shims it
// already imports from there. The query interceptor is the first runtime that
// wants ONLY this: it sits in front of every read and is sized for a decision
// rather than for work, so paying that whole import graph on each cold start to
// reach one promise is the wrong trade.
//
// A module-level singleton, which is why HandlerFactoryHelpers re-exports this
// binding rather than keeping a copy: two definitions would fire the seam twice
// in any runtime that reached both.

import {
  parseConfig as parseRuntimeExtensionConfig,
  fire as fireRuntimeExtensions,
  reportLoadFailure as reportRuntimeExtensionLoadFailure,
} from "./RuntimeExtensionEntryPoint_Ops.res.mjs";

// Extension packages ride in the code archive rather than beside this module, so
// they resolve under /var/task and not relative to here.
const dynamicImport = (specifier) => import("/var/task/node_modules/" + specifier);

// The framework ships four runtime callback hooks (command interception, query
// interception, before/after publish) whose registrars are module-level refs.
// They are only reachable if something calls them in this process before the
// first request, and the entry shells import framework and domain modules only —
// so an out-of-tree extension had no way in. RUNTIME_EXTENSIONS closes that: it
// names the extension modules the archive carries (see
// ReventlessCore.RuntimeExtension and Util_Bundle.addRuntimeExtensionPackages),
// and each one's `onColdStart` runs here, once, before any handler is built.
//
// This is the seam's one untyped step: the modules are named at deploy time and
// their types are unknowable here. Parsing and invocation live in the typed
// RuntimeExtensionEntryPoint_Ops.res, so the call's arity is compiler-checked.
//
// Started at module load and exported as a promise every entry shell awaits in
// its own cold-start init — that is what makes "before the first request" a fact
// rather than a hope, and it holds for the shells that build handlers lazily.
// Absent env var ⇒ resolves immediately, having done nothing.
export const runtimeExtensionsReady = (async () => {
  const config = parseRuntimeExtensionConfig(process.env["RUNTIME_EXTENSIONS"]);
  if (config === undefined) return;
  const hooks = [];
  for (const specifier of config.modules) {
    try {
      const mod = await dynamicImport(specifier);
      if (typeof mod.onColdStart === "function") {
        hooks.push(mod.onColdStart);
      } else {
        reportRuntimeExtensionLoadFailure(specifier, "module exports no onColdStart function");
      }
    } catch (err) {
      reportRuntimeExtensionLoadFailure(specifier, err?.message ?? String(err));
    }
  }
  fireRuntimeExtensions(config, hooks);
})();
