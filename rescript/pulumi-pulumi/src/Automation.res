/** `@pulumi/pulumi/automation` — driving the Pulumi CLI from a program, so a
    deploy never stops to ask a question.
    see: https://www.pulumi.com/docs/iac/using-pulumi/automation-api/

    Only the local-program half: a project folder with its own `Pulumi.yaml`. */
type workspace
type stack

type localProgramArgs = {stackName: string, workDir: string}

type workspaceOptions = {
  workDir?: string,
  /** Added to the environment of every `pulumi` the workspace runs. */
  envVars?: dict<string>,
}

type configValue = {value: string, secret?: bool}

type outputValue = {value: JSON.t, secret: bool}

type whoAmI = {user: string, url?: string, organizations?: array<string>}

type updateOptions = {onOutput?: string => unit}

type updateSummary = {result: string}

type upResult = {summary: updateSummary}

@module("@pulumi/pulumi/automation/index.js") @scope("LocalWorkspace")
external create: workspaceOptions => promise<workspace> = "create"

@module("@pulumi/pulumi/automation/index.js") @scope("LocalWorkspace")
external createOrSelectStack: (localProgramArgs, workspaceOptions) => promise<stack> =
  "createOrSelectStack"

/** Rejects when the stack does not exist. */
@module("@pulumi/pulumi/automation/index.js") @scope("LocalWorkspace")
external selectStack: (localProgramArgs, workspaceOptions) => promise<stack> = "selectStack"

@get external workspace: stack => workspace = "workspace"

/** Rejects when the key is not set. */
@send external getConfig: (stack, string) => promise<configValue> = "getConfig"

@send external setConfig: (stack, string, configValue) => promise<unit> = "setConfig"

@send external up: (stack, updateOptions) => promise<upResult> = "up"

@send external destroy: (stack, updateOptions) => promise<upResult> = "destroy"

@send external outputs: stack => promise<dict<outputValue>> = "outputs"

@send external whoAmI: workspace => promise<whoAmI> = "whoAmI"

@send external removeStack: (workspace, string) => promise<unit> = "removeStack"
