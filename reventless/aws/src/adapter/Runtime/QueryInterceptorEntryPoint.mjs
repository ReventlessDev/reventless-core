// Query-interceptor Lambda entry point.
//
// One job, and it is a scheduling one: pull the runtime-extension cold start
// into the INIT phase.
//
// `runtimeExtensionsReady` is an async IIFE started at module load and awaited
// by nobody, so evaluating a module that merely imports it does not wait for it.
// Awaiting it from the handler instead — which is what this runtime did before
// there was a shell — leaves the whole extension load in the INVOKE phase, where
// it runs without the init CPU boost and against the function timeout. An
// extension whose module graph reaches a cloud SDK does not finish inside a
// budget sized for a decision, and the way that fails is the worst shape
// available: the load neither completes nor throws, so every read times out
// having logged nothing at all.
//
// A top-level await is what moves it. It propagates to the generated `index.mjs`
// re-export, so init is not finished until the seam has fired — which is also
// the only way the handler's own await can be a formality rather than the place
// the work happens.
//
// It cannot reject: the seam catches and reports each extension's load failure
// individually, and resolves having skipped it. So a broken extension still
// costs interception nothing more than the counting it was going to do.

import { runtimeExtensionsReady } from "./RuntimeExtensionsReady.mjs";

await runtimeExtensionsReady;

export { handler } from "../QueryDb/QueryInterceptor_Lambda.res.mjs";
