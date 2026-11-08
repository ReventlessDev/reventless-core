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
// (StateChangeSliceRuntime_Builder_Single.forDcbCommandTopic); a queue that reached
// neither would leave the automations' config unresolved.

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

// `pulumi.output` unwraps a promise of an output, and keeps it unknown where the
// function's name is not known yet (a preview of a new stack).
@module("@pulumi/pulumi")
external outputOfPromise: promise<Pulumi.Output.t<string>> => Pulumi.Output.t<string> = "output"

/** The function serving the queue whose `id` is `queueUrl`, or `""` where none was
    built. */
let functionFor = (queueUrl: Pulumi.Output.t<string>): Pulumi.Output.t<string> =>
  switch settled->Array.find(((url, _)) => url === queueUrl) {
  | Some((_, functionName)) => functionName
  | None =>
    Promise.make((resolve, _) =>
      waiters->Array.push({queueUrl, settle: functionName => resolve(functionName)})
    )->outputOfPromise
  }
