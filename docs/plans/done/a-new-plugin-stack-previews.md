# Plan: a new plugin stack previews

> **Status:** Done 2026-11-16. [PNS3](#5-steps) was run as a preview only (see [§5](#5-steps)).
> Found on a new plugin stack whose
> plugin has one state change slice and one outbound translation: `pulumi preview` failed, and
> `pulumi up --skip-preview` deployed it.
>
> **Questions and short answers:**
>
> 1. *Why does the first preview of a plugin stack with an automation or an outbound translation
>    fail?* **Because the automations' Lambda waits for the DCB command Lambda, and on a new stack's
>    preview that Lambda is never built.** The plugin builds it inside an output callback that waits
>    for the schema push, and a preview skips a callback whose inputs are unknown. The wait in
>    `DcbCommandFunctions.functionFor` is never settled, the program ends with its resources still
>    waiting, and Pulumi exits with code 1 ([§2](#2-what-happens)).
> 2. *What should happen?* **The wait should end wherever the callback that would settle it cannot
>    run: the command function's name is then unknown, as a new stack's preview expects.** The fix
>    ties the wait to the same outputs the callback waits for ([PNQ1](#4-decisions)).
>
> **Relates to:** [a-refusal-nobody-hears.md](../a-refusal-nobody-hears.md), whose
> [RNS6](../a-refusal-nobody-hears.md#5-steps) made the automations' Lambda wait for the DCB command
> Lambda. Its note says the wait resolves *so a preview of a new stack stays unknown rather than
> waiting forever*; that holds when the plugin's callback runs, which on a new stack it does not.
>
> **Ids:** `PNQ` (preview of a new stack, question) for decisions in [§4](#4-decisions), `PNS`
> (step) for the steps in [§5](#5-steps).

---

## 1. In plain words

A deploy is checked before it runs: `pulumi preview` builds the program and lists what would change,
creating nothing. Anything the program can only know once something exists, such as the name of a
function not yet created, is *unknown* in a preview, and code that needs it is skipped.

A plugin's automations and outbound translations run in one Lambda, and since the refusals plan
that Lambda's configuration names the Lambda that decides the plugin's commands, so it can hear
whether a command was refused. The configuration waits for that name. On a stack that already
exists, the name is known and the wait ends. On a new stack, the part of the program that builds
the command Lambda is skipped in the preview, nothing ever answers the wait, and the preview fails
with a message that names neither.

`pulumi up` is not affected: it creates the resources, the skipped part runs, and the wait ends.
So the first deploy works when the preview is skipped, and fails wherever the preview is not,
which is the default of `pulumi up` and of a deploy workflow that previews first.

## 2. What happens

The order on AWS, for a plugin with a DCB state change slice and an automation or an outbound
translation:

1. The DCB command topic is created; `onDcbCommandTopicCreated` records its queue
   (`AutomationSliceRuntime_Builder_Single.setDcbQueueUrl`).
2. `onDcbSlicesCreated` finishes the automations' Lambda
   (`AutomationSliceRuntime_Builder_Single.finishWithDcbEventLog`). Its `HANDLER_CONFIG` waits for
   `DcbCommandFunctions.functionFor(dcbQueueUrl)`, which, with nothing settled yet, is a promise
   that a later `register` or `noFunction` for the same queue resolves.
3. The plugin's main construction continues in
   [Plugin_Builder.res](../../../reventless/core/src/plugin/component/Plugin_Builder.res) inside
   `ResourceAttribution_Deploytime.applyAttributed` over the admin extension points, the schema push
   (`preResolversSchemaHook`), the aggregate resources, the scheduler and the query engine. At its
   end it calls `dcbResult.dcbRuntimeSetup()`, which builds the DCB command Lambda
   (`StateChangeSliceRuntime_Builder_Single.forDcbCommandTopic`) and calls `register` or
   `noFunction`.
4. On a new stack's preview, the schema push's output is unknown, so the callback in 3 never runs.
   The promise from 2 is never resolved, and neither are the automations' Lambda, its role policy
   for the scheduler and its reconciling invocation, which depend on it.

What was seen, printed from the deploy program after `deployPlugin` returned:

| | `settled` | waiters | command functions |
|---|---|---|---|
| with the outbound translation | 0 | 1 | 0 |
| without it | 0 | 0 | 0 |

Without the outbound translation the preview passes, and still lists no command Lambda: the
callback is skipped either way, and only the wait turns that into a failure. Pulumi then reports
`Program exited with non-zero exit code: 1` and some 270 leaked promises, all of them the
automations' Lambda and the resources that hang off it. `pulumi up --skip-preview` on the same stack
created 91 resources, the command Lambda among them, and the automations' Lambda named it.

## 3. What an app can do until it is fixed

Deploy a new plugin stack the first time with `pulumi up --skip-preview`. Once the stack exists, a
preview works, because the outputs the callback waits for are known.

## 4. Decisions

### PNQ1. How does the wait end when the callback cannot run?

- **(a) Tie the wait to the callback's own inputs.** The plugin hands the platform the output the
  callback waits for, before it applies it; `functionFor` becomes that output, flat-mapped into the
  wait. Where the inputs are unknown, a preview skips the flat-map too and the name is unknown;
  where they are known, the callback runs and settles the wait, as now.
- **(b) Tie it to the queue's id.** `functionFor` waits only once the queue's `id` is known. Simple,
  and right for a new stack, but wrong for a stack that exists and changes its schema: the queue's
  id is known, the schema push is not, and the preview waits forever again.
- **(c) Build the command Lambda outside the callback.** Removes the cause, but the callback
  provides the extension points, the heartbeat and the resolvers the Lambda's configuration is made
  from; moving it means moving them.
- **(d) Settle every wait when the program ends, if it is a preview.** Works, and hides the next
  ordering fault of the same kind.

**Recommendation:** (a). It answers the question the wait asks, *will this callback run?*, with the
same outputs the callback runs on, so it stays right when the callback's inputs change. It needs a
platform hook, because `Plugin_Builder` is the same on every platform and `DcbCommandFunctions` is
AWS's: the plugin hands its gate to `Spec.hooks` before the callback, and AWS's
`DcbCommandFunctions` keeps it per plugin.

### PNQ2. Is a preview of a new stack tested?

**Recommendation:** yes, with Pulumi's mocks in preview mode, where an output whose value the mock
withholds is unknown, for a plugin with a DCB state change slice and an outbound translation: the
program ends with nothing waiting, and `HANDLER_CONFIG` is unknown rather than missing.

## 5. Steps

| Step | What | Exit | State |
|---|---|---|---|
| PNS1 | The test of [PNQ2](#4-decisions), failing as it should: a new stack's preview of such a plugin waits forever | the test fails with the wait still open | done |
| PNS2 | The plugin's gate handed to the platform before the callback; `functionFor` flat-mapped over it ([PNQ1](#4-decisions) (a)) | [PNS1](#5-steps)'s test passes; a preview of an existing stack still names the command function in `HANDLER_CONFIG` | done |
| PNS3 | A new plugin stack with an automation previewed and deployed on alpha, then destroyed | the preview ends with the resources listed; the deploy's `HANDLER_CONFIG` names the command function | preview done; deploy left out |
| PNS4 | The workaround of [§3](#3-what-an-app-can-do-until-it-is-fixed) removed from wherever it was written | no `--skip-preview` left for this reason | done |

What was built:

- **The gate.** `platformHooks.onDcbRuntimeSetupGate` takes the outputs the callback that runs
  `dcbRuntimeSetup` waits for, and both `Plugin_Builder` and `Platform_Admin` hand it over just
  before they apply that callback. AWS's `DcbCommandFunctions.gate` ties every wait still untied
  to it: the automations' Lambda asks for the function while its plugin is being built, before the
  plugin hands over its gate, so the next gate is that plugin's. That is how "per plugin" of
  [PNQ1](#4-decisions) came out, with no plugin name to thread through.
- **The wait.** `functionFor` answers at once for a queue already settled; otherwise it flat-maps
  over the gate and only then waits for `register` or `noFunction`. Where the gate is unknown no
  wait is ever opened.
- **The test** (`reventless/aws/tests/DcbCommandFunctionsPreviewTest.res`) runs at the level of
  `DcbCommandFunctions` under Pulumi's mocks in preview mode, not over a whole plugin as
  [PNQ2](#4-decisions) proposed: an unknown gate gives an unknown name and no open wait (with the
  old `functionFor` the name was still waiting); a known gate gives the registered name, or `""`
  where no Lambda was built. That the plugin hands over the right outputs is checked by
  [PNS3](#5-steps).
- **The check on alpha** ([PNS3](#5-steps)): a new stack of the hybrid example's ordering plugin,
  which has state change slices, automations and outbound translations, previewed against the
  alpha platform from the local build. The preview ends with exit 0 and 122 resources to create,
  among them the automations' Lambda, its scheduler policy and its reconciling invocation, which
  the open wait used to hold back. The deploy was left out: the only such plugin alpha can host is
  that ordering plugin, which alpha already runs, and a second copy would join the same merged API
  with the same types and register with the admin under the same name, superseding the live one.
  A deploy is not what the fix changes: `pulumi up` named the command function before it, and the
  callback it runs is unchanged. The stack was removed again.
- **The workaround** of [§3](#3-what-an-app-can-do-until-it-is-fixed) was written only here. The
  `--skip-preview` flags in `.github/workflows/deploy-reventless-aws.yml` are the workflow's own
  (it previews in a step of its own) and were not added for this.
