// The sync DCB command Lambdas of this deploy, by the queue they serve, and the Lambdas
// allowed to invoke them to hear a command's outcome (DcbPlatformCommands_Runtime).
//
// The automations' Lambda is finished before the DCB command Lambda is built, and the
// plugin program builds parts of itself inside output callbacks, so its config waits
// for the function: `functionFor` answers with an output that resolves when the DCB
// side registers, or says it built none. A queue is matched by its `id` output, which
// both sides take from the same queue resource.
//
// Every sync DCB command topic reaches `register` or `noFunction`
// (StateChangeSliceRuntime_Builder_Single.forDcbCommandTopic) once the plugin's
// callback runs. A preview skips that callback where its inputs are unknown, so the
// wait is tied to the same inputs: the plugin hands them over as its gate (`gate`),
// and where they are unknown the function's name is unknown too.

type commandFunction = {
  queueUrl: Pulumi.Output.t<string>,
  name: string,
  functionName: Pulumi.Output.t<string>,
  functionArn: Pulumi.Output.t<string>,
}

type invoker = {name: string, roleId: Pulumi.Output.t<string>}

type waiter = {queueUrl: Pulumi.Output.t<string>, settle: Pulumi.Output.t<string> => unit}

let functions: array<commandFunction> = []
let settled: array<(Pulumi.Output.t<string>, Pulumi.Output.t<string>)> = []
let invokers: array<invoker> = []
let waiters: array<waiter> = []
// Waits not yet tied to a gate. A plugin's automations Lambda asks for the function
// while the plugin is being built, before the plugin hands over its gate, so the
// next gate is that plugin's.
let ungated: array<Pulumi.Output.t<unit> => unit> = []
// Waiting for the first sync command function's ARN, which is built inside the
// plugin's callback, after the resolvers that ask for it.
let firstWaiters: array<Pulumi.Output.t<string> => unit> = []

let grant = (invoker: invoker, fn: commandFunction) => {
  open PulumiAws.PolicyDocument
  let _ = PulumiAws.IAM.RolePolicy.make(
    ~name=`${invoker.name}-invoke-${fn.name}`,
    ~args={
      policy: fn.functionArn
      ->Pulumi.Output.apply(arn =>
        PulumiAws.PolicyDocument.make(
          ~id=`${invoker.name}-invoke-${fn.name}`,
          ~statements=[
            {
              sid: "AllowInvokeDcbCommandFunction",
              effect: Allow,
              actions: Action("lambda:InvokeFunction"),
              resources: Resource(arn),
            },
          ],
        )->PulumiAws.PolicyDocument.toJsonString
      )
      ->Pulumi.Output.asInput,
      role: invoker.roleId->Pulumi.Output.asInput,
    },
  )
}

let settle = (queueUrl, functionName) => {
  settled->Array.push((queueUrl, functionName))
  waiters->Array.forEach(w =>
    if w.queueUrl === queueUrl {
      w.settle(functionName)
    }
  )
}

/** A sync DCB command Lambda, serving the queue whose `id` is `queueUrl`. */
let register = (~queueUrl, ~name, ~lambda: Pulumi.Output.t<PulumiAws.Lambda.Function.t>) => {
  let fn = {
    queueUrl,
    name,
    functionName: lambda->Pulumi.Output.flatMap(l => l.name),
    functionArn: lambda->Pulumi.Output.flatMap(l => l.arn),
  }
  functions->Array.push(fn)
  if functions->Array.length == 1 {
    firstWaiters->Array.forEach(resolve => resolve(fn.functionArn))
    firstWaiters->Array.splice(~start=0, ~remove=firstWaiters->Array.length, ~insert=[])
  }
  invokers->Array.forEach(invoker => grant(invoker, fn))
  settle(queueUrl, fn.functionName)
}

/** A sync DCB command topic whose Lambda was not built: nothing to invoke. */
let noFunction = (~queueUrl) => settle(queueUrl, Pulumi.Output.make(""))

/** A Lambda that sends commands through these functions. */
let addInvoker = (~name, ~roleId) => {
  let invoker = {name, roleId}
  invokers->Array.push(invoker)
  functions->Array.forEach(fn => grant(invoker, fn))
}

/** The outputs the plugin's callback that builds its DCB command Lambdas waits for. */
let gate = (inputs: Pulumi.Output.t<unit>) => {
  ungated->Array.forEach(tie => tie(inputs))
  ungated->Array.splice(~start=0, ~remove=ungated->Array.length, ~insert=[])
}

// `pulumi.output` unwraps a promise of an output, and keeps it unknown where the
// output is.
@module("@pulumi/pulumi")
external outputOfPromise: promise<Pulumi.Output.t<'a>> => Pulumi.Output.t<'a> = "output"

let settledFor = queueUrl => settled->Array.find(((url, _)) => url === queueUrl)

let registered = queueUrl =>
  switch settledFor(queueUrl) {
  | Some((_, functionName)) => functionName
  | None =>
    Promise.make((resolve, _) =>
      waiters->Array.push({queueUrl, settle: functionName => resolve(functionName)})
    )->outputOfPromise
  }

/** The function serving the queue whose `id` is `queueUrl`, or `""` where none was
    built; unknown where the plugin's gate is. */
let functionFor = (queueUrl: Pulumi.Output.t<string>): Pulumi.Output.t<string> =>
  switch settledFor(queueUrl) {
  | Some((_, functionName)) => functionName
  | None =>
    Promise.make((resolve, _) => ungated->Array.push(inputs => resolve(inputs)))
    ->outputOfPromise
    ->Pulumi.Output.flatMap(() => registered(queueUrl))
  }

/** The ARN of the first sync command function this deploy builds, once it is built.
    Asked only by a plugin that builds one: otherwise it never resolves. */
let firstArn = (): Pulumi.Output.t<string> =>
  switch functions->Array.get(0) {
  | Some(fn) => fn.functionArn
  | None => Promise.make((resolve, _) => firstWaiters->Array.push(resolve))->outputOfPromise
  }
