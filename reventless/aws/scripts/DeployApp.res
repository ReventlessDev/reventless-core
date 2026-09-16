/***
Deploy an app to AWS — its platform stack and every plugin stack its
`deploy-manifest.yaml` lists — or remove it again.

```
pnpm exec deploy-app up      # deploy, bake the manifest, create the demo accounts
pnpm exec deploy-app down    # remove everything `up` created
```

Pulumi is driven through its Automation API, so it never stops to ask a
question. Every step of `up` can run again: a stack that exists is updated, a
layer already published for this version is reused, an account that exists is
adopted.

🚨 **Only try-out stacks.** Every stack `up` creates declares
`reventless:disposable: "true"`, which is also what lets `pulumi destroy` remove
its storage. `up` refuses to touch an existing stack without that setting, and
`down` refuses to remove one, so neither can reach `alpha` or a real deployment.
*/

module Automation = Pulumi.Automation
module Lambda = AwsSdk.Lambda
module Ssm = AwsSdk.SSM
module Sts = AwsSdk.STS
module Manifest = Reventless.AccountsManifest

// ── Arguments ────────────────────────────────────────────────────────────────

type command = Up | Down

type args = {
  command: option<command>,
  manifest: option<string>,
  stack: string,
  help: bool,
}

let defaultStack = "dev"

let parseArgs = (argv: array<string>): result<args, string> => {
  let acc = ref(Ok({command: None, manifest: None, stack: defaultStack, help: false}))
  let i = ref(0)
  let count = argv->Array.length
  while i.contents < count {
    let flag = argv->Array.getUnsafe(i.contents)
    let value = argv->Array.get(i.contents + 1)
    switch (acc.contents, flag, value) {
    | (Error(_), _, _) => i := count
    | (Ok(a), "up", _) if a.command == None =>
      acc := Ok({...a, command: Some(Up)})
      i := i.contents + 1
    | (Ok(a), "down", _) if a.command == None =>
      acc := Ok({...a, command: Some(Down)})
      i := i.contents + 1
    | (Ok(a), "--manifest", Some(v)) =>
      acc := Ok({...a, manifest: Some(v)})
      i := i.contents + 2
    | (Ok(a), "--stack", Some(v)) =>
      acc := Ok({...a, stack: v})
      i := i.contents + 2
    | (Ok(a), "--help", _) | (Ok(a), "-h", _) =>
      acc := Ok({...a, help: true})
      i := i.contents + 1
    | (Ok(_), "--manifest", None) | (Ok(_), "--stack", None) =>
      acc := Error(`${flag} needs a value`)
    | (Ok(_), unknown, _) => acc := Error(`unknown argument "${unknown}"`)
    }
  }
  acc.contents
}

let usage = `
Deploy an app to AWS, or remove it again.

  deploy-app up     Deploy the platform and every plugin, bake the component
                    manifest, create the accounts in .reventless/users.<stack>.yaml,
                    and print the web address and the sign-ins.
  deploy-app down   Remove every stack, and the Lambda layer and SSM parameter
                    \`up\` created.

  --manifest <path>  The deploy manifest. Defaults to ${DeployManifest.defaultFile}
                     in the working directory.
  --stack <name>     The try-out stack. Defaults to "${defaultStack}".

Region and credentials come from the environment, as for any AWS call. Only
stacks declaring reventless:disposable: "true" are touched; \`up\` sets it on
every stack it creates.
`

// ── The projects ─────────────────────────────────────────────────────────────

/** A stack folder, as `Pulumi.yaml` names it. `deploy-manifest.yaml`'s own
    `platform.name` need not match the real project name, so it is not used. */
type project = {
  label: string,
  dir: string,
  projectName: string,
  program: string,
  stackDefaults: dict<string>,
}

@module("yaml") external parseYaml: string => JSON.t = "parse"

let projectOf = (p: DeployManifest.project): result<project, string> => {
  let file = NodePath.join([p.dir, "Pulumi.yaml"])
  switch try Some(NodeFs.readFileSync(file)->parseYaml) catch {
  | _ => None
  } {
  | None => Error(`${file} cannot be read — is ${p.dir} a Pulumi project?`)
  | Some(json) =>
    let field = name =>
      json
      ->JSON.Decode.object
      ->Option.flatMap(o => o->Dict.get(name))
      ->Option.flatMap(JSON.Decode.string)
    switch field("name") {
    | None => Error(`${file} names no project`)
    | Some(projectName) =>
      Ok({
        label: p.name,
        dir: p.dir,
        projectName,
        program: NodePath.join([p.dir, field("main")->Option.getOr("index.js")]),
        stackDefaults: p.stackDefaults,
      })
    }
  }
}

let projectsOf = (manifest: DeployManifest.resolved): result<(project, array<project>), string> =>
  switch projectOf(manifest.platform) {
  | Error(_) as e => e
  | Ok(platform) =>
    let plugins = manifest.plugins->Array.map(projectOf)
    switch plugins->Array.find(Result.isError) {
    | Some(Error(message)) => Error(message)
    | _ => Ok((platform, plugins->Array.filterMap(r => r->Result.mapOr(None, p => Some(p)))))
    }
  }

// ── Checks before anything is created ────────────────────────────────────────

let requiredNodeMajor = 22

let checkNode = (version: string): option<string> =>
  switch version->String.split(".")->Array.get(0)->Option.flatMap(v => Int.fromString(v)) {
  | Some(major) if major >= requiredNodeMajor => None
  | _ =>
    Some(
      `Reventless needs Node ${requiredNodeMajor->Int.toString} or later, and this is Node ${version}. Switch to the version in .node-version (for example \`fnm use\` or \`nvm use\`).`,
    )
  }

/** A backend other than Pulumi Cloud keeps stack secrets with a passphrase, and
    asks for it on a terminal nobody is watching. */
let backendNeedsPassphrase = (~url: option<string>, ~env: dict<string>): bool =>
  switch url {
  | Some(url) if !(url->String.startsWith("https://")) =>
    env->Dict.get("PULUMI_CONFIG_PASSPHRASE") == None &&
      env->Dict.get("PULUMI_CONFIG_PASSPHRASE_FILE") == None
  | _ => false
  }

let unbuilt = (projects: array<project>): array<project> =>
  projects->Array.filter(p => !NodeFs.existsSync(p.program))

type ready = {region: string, account: string}

let check = async (~projects: array<project>): result<ready, array<string>> => {
  let problems = []
  checkNode(NodeProcess.versions->Dict.get("node")->Option.getOr("0"))->Option.forEach(p =>
    problems->Array.push(p)
  )
  let sts = Sts.client()
  let region = switch await (sts->Sts.config).region() {
  | region => Some(region)
  | exception _ =>
    problems->Array.push(
      "No AWS region is set. Set AWS_REGION (for example `export AWS_REGION=eu-west-1`) or give your AWS profile a region.",
    )
    None
  }
  let account = switch region {
  | None => None
  | Some(region) =>
    switch await Sts.client(~region, ())->Sts.GetCallerIdentityCommand.send(
      Sts.GetCallerIdentityCommand.make(Dict.make()),
    ) {
    | identity => identity.account
    | exception exn =>
      problems->Array.push(
        `The AWS credentials do not work (${Util_AwsError.describe(
            exn,
          )}). Sign in — \`aws sso login\`, or set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY — and try again.`,
      )
      None
    }
  }
  switch projects->Array.get(0) {
  | None => ()
  | Some(platform) =>
    switch await Automation.create({workDir: platform.dir}) {
    | workspace =>
      switch await workspace->Automation.whoAmI {
      | who =>
        if backendNeedsPassphrase(~url=who.url, ~env=NodeProcess.env) {
          problems->Array.push(
            `Pulumi is logged in to ${who.url->Option.getOr(
                "a self-managed backend",
              )}, which protects stack secrets with a passphrase. Set PULUMI_CONFIG_PASSPHRASE (an empty value is allowed) and try again.`,
          )
        }
      | exception _ =>
        problems->Array.push(
          "Pulumi is not logged in. Run `pulumi login` (Pulumi Cloud) or `pulumi login --local`, and try again.",
        )
      }
    | exception _ =>
      problems->Array.push(
        "The Pulumi CLI could not be run. Install it — https://www.pulumi.com/docs/iac/download-install/ — and try again.",
      )
    }
  }
  unbuilt(projects)->Array.forEach(p =>
    problems->Array.push(
      `${p.label} is not built: ${p.program} is missing. Run \`pnpm run build\` and try again.`,
    )
  )
  switch (problems, region, account) {
  | ([], Some(region), Some(account)) => Ok({region, account})
  | ([], _, _) => Error(["The AWS account could not be identified."])
  | (problems, _, _) => Error(problems)
  }
}

// ── The Lambda layer ─────────────────────────────────────────────────────────

let layerName = stack => `reventless-aws-${stack}`

/** What marks a layer version as one `up` published, and for which release. */
let layerDescriptionPrefix = "reventless-aws@"
let layerDescription = version => layerDescriptionPrefix ++ version

let releaseUrl = version =>
  `https://github.com/ReventlessDev/reventless-core/releases/download/${encodeURIComponent(
      "@reventlessdev/reventless-aws@" ++ version,
    )}/reventless-layer.zip`

/** The version of this package — the one the app installed, so the one its
    functions import. */
let installedVersion = (): string =>
  NodePath.join([NodePath.dirname(NodeUrl.fileURLToPath(NodeImportMeta.url)), "..", "package.json"])
  ->NodeFs.readFileSync
  ->JSON.parseOrThrow
  ->JSON.Decode.object
  ->Option.flatMap(o => o->Dict.get("version"))
  ->Option.flatMap(JSON.Decode.string)
  ->Option.getOr("unknown")

let errorName = (exn: exn): option<string> =>
  exn
  ->JsExn.fromException
  ->Option.flatMap(e => e->JsExn.name)

let storedLayerArn = async (~ssm: Ssm.client, ~parameter: string): option<string> =>
  switch await ssm->Ssm.GetParameterCommand.send(Ssm.GetParameterCommand.make({name: parameter})) {
  | output => output.parameter->Option.flatMap(p => p.value)
  | exception exn if errorName(exn) == Some(Ssm.parameterNotFound) => None
  }

let layerVersionDescription = async (~lambda: Lambda.client, ~arn: string): option<string> =>
  switch await lambda->Lambda.GetLayerVersionByArnCommand.send(
    Lambda.GetLayerVersionByArnCommand.make({arn: arn}),
  ) {
  | output => output.description
  | exception _ => None
  }

/** The layer this deploy attaches: `REVENTLESS_LAYER_ARN` when set, the one
    already stored for this version, or the release download published now. */
let ensureLayer = async (~stack: string, ~region: string, ~version: string): result<
  string,
  string,
> =>
  switch NodeProcess.env->Dict.get("REVENTLESS_LAYER_ARN") {
  | Some(arn) if arn->String.trim != "" =>
    Console.log(`layer    ${arn} (from REVENTLESS_LAYER_ARN)`)
    Ok(arn->String.trim)
  | _ =>
    let ssm = Ssm.client(~region, ())
    let lambda = Lambda.client(~region, ())
    let parameter = PulumiAws.Lambda.layerParameter(stack)
    let stored = await storedLayerArn(~ssm, ~parameter)
    let current = switch stored {
    | None => None
    | Some(arn) =>
      (await layerVersionDescription(~lambda, ~arn)) == Some(layerDescription(version))
        ? Some(arn)
        : None
    }
    switch current {
    | Some(arn) =>
      Console.log(`layer    ${arn} (already published for ${version})`)
      Ok(arn)
    | None =>
      let url = releaseUrl(version)
      Console.log(`layer    downloading ${url}`)
      switch await Web.Fetch.fetch(url, {}) {
      | response if response->Web.Fetch.status == 404 =>
        Error(
          `No Lambda layer was released for reventless-aws@${version} — this checkout sits between two releases. Build one with \`REVENTLESS_AWS_VERSION=${version} pnpm run build\` in reventless/layer-builder/, publish it, and set REVENTLESS_LAYER_ARN.`,
        )
      | response if !(response->Web.Fetch.ok) =>
        Error(`downloading ${url} failed with HTTP ${response->Web.Fetch.status->Int.toString}`)
      | response =>
        let zip = Uint8Array.fromBuffer(await response->Web.Fetch.arrayBuffer)
        let published = await lambda->Lambda.PublishLayerVersionCommand.send(
          Lambda.PublishLayerVersionCommand.make({
            layerName: layerName(stack),
            description: layerDescription(version),
            content: {zipFile: zip},
            compatibleRuntimes: ["nodejs20.x", "nodejs22.x"],
          }),
        )
        switch published.layerVersionArn {
        | None => Error(`publishing the layer ${layerName(stack)} returned no ARN`)
        | Some(arn) =>
          let _ = await ssm->Ssm.PutParameterCommand.send(
            Ssm.PutParameterCommand.make({
              name: parameter,
              value: arn,
              type_: "String",
              overwrite: true,
            }),
          )
          Console.log(`layer    ${arn} (published, stored in ${parameter})`)
          Ok(arn)
        }
      | exception exn => Error(`downloading ${url} failed: ${Util_AwsError.describe(exn)}`)
      }
    }
  }

/** Removes the layer versions `up` published for this stack, and the parameter
    when it points at one of them. A layer published by anyone else is left. */
let removeLayer = async (~stack: string, ~region: string) => {
  let lambda = Lambda.client(~region, ())
  let ssm = Ssm.client(~region, ())
  let name = layerName(stack)
  let versions = []
  let marker = ref(None)
  let more = ref(true)
  while more.contents {
    switch await lambda->Lambda.ListLayerVersionsCommand.send(
      Lambda.ListLayerVersionsCommand.make({layerName: name, marker: ?marker.contents}),
    ) {
    | page =>
      page.layerVersions->Option.forEach(page => versions->Array.pushMany(page))
      marker := page.nextMarker
      more := page.nextMarker != None
    | exception exn if errorName(exn) == Some("ResourceNotFoundException") => more := false
    }
  }
  for index in 0 to versions->Array.length - 1 {
    let v = versions->Array.getUnsafe(index)
    switch (v.version, v.description) {
    | (Some(version), Some(description))
      if description->String.startsWith(layerDescriptionPrefix) =>
      let _ = await lambda->Lambda.DeleteLayerVersionCommand.send(
        Lambda.DeleteLayerVersionCommand.make({layerName: name, versionNumber: version}),
      )
      Console.log(`layer    removed ${name}:${version->Int.toString}`)
    | _ => ()
    }
  }
  let parameter = PulumiAws.Lambda.layerParameter(stack)
  switch await storedLayerArn(~ssm, ~parameter) {
  | Some(arn) if arn->String.includes(`:layer:${name}:`) =>
    let _ = await ssm->Ssm.DeleteParameterCommand.send(
      Ssm.DeleteParameterCommand.make({name: parameter}),
    )
    Console.log(`layer    removed ${parameter}`)
  | _ => ()
  }
}

// ── Stacks ───────────────────────────────────────────────────────────────────

let disposableKey = "reventless:disposable"

let isDisposable = async (stack: Automation.stack): bool =>
  switch await stack->Automation.getConfig(disposableKey) {
  | {value} => value == "true"
  | exception _ => false
  }

let existingStack = async (~project: project, ~stack: string, ~envVars) =>
  switch await Automation.selectStack(
    {stackName: stack, workDir: project.dir},
    {envVars: envVars},
  ) {
  | found => Some(found)
  | exception _ => None
  }

/** The settings a stack `up` creates starts with: the app's defaults for the
    folder, then the region and the try-out flag, which the app cannot override. */
let newStackConfig = (~project: project, ~region: string): array<(string, string)> =>
  project.stackDefaults
  ->Dict.toArray
  ->Array.concat([("aws:region", region), ("aws-native:region", region), (disposableKey, "true")])

/** Opens the stack for `up`: creates it with its settings, or selects it when
    it exists and is a try-out stack. `extra` is set either way. */
let openForUp = async (
  ~project: project,
  ~stack: string,
  ~region: string,
  ~envVars: dict<string>,
  ~extra: array<(string, string)>,
): result<Automation.stack, string> => {
  let setAll = async (s, settings) =>
    for index in 0 to settings->Array.length - 1 {
      let (key, value) = settings->Array.getUnsafe(index)
      await s->Automation.setConfig(key, {value: value})
    }
  switch await existingStack(~project, ~stack, ~envVars) {
  | Some(existing) =>
    if await isDisposable(existing) {
      await setAll(existing, extra)
      Ok(existing)
    } else {
      Error(
        `${project.projectName}/${stack} already exists and does not declare ${disposableKey}: "true". deploy-app only deploys try-out stacks it created; pick another --stack.`,
      )
    }
  | None =>
    let created = await Automation.createOrSelectStack(
      {stackName: stack, workDir: project.dir},
      {envVars: envVars},
    )
    await setAll(created, newStackConfig(~project, ~region)->Array.concat(extra))
    Console.log(`stack    ${project.projectName}/${stack} (created)`)
    Ok(created)
  }
}

let stream = (text: string) => NodeProcess.stdout->NodeProcess.write(text)

/** The `error:` lines of a failed Pulumi command. A failure before the update
    starts — a missing program, a locked stack — streams nothing, so without
    these the run would end without a reason. */
let failureDetail = (exn: exn): string => {
  let message = Util_AwsError.describe(exn)
  let errors = []
  message
  ->String.split("\n")
  ->Array.map(String.trim)
  ->Array.forEach(line =>
    if line->String.startsWith("error:") && !(errors->Array.includes(line)) {
      errors->Array.push(line)
    }
  )
  errors->Array.length > 0 ? errors->Array.join("\n") : message
}

/** Deploys one stack, streaming Pulumi's output as it goes. */
let deploy = async (~project: project, ~stack: Automation.stack, ~name: string): result<
  unit,
  string,
> => {
  Console.log(`\n── Deploying ${project.label} (${project.projectName}/${name}) ──\n`)
  switch await stack->Automation.up({onOutput: stream}) {
  | _ => Ok()
  | exception exn =>
    Error(
      `deploying ${project.projectName}/${name} failed. Fix the cause and run up again; what was created is kept and reused.\n${failureDetail(
          exn,
        )}`,
    )
  }
}

let outputString = (outputs: dict<Automation.outputValue>, name: string): option<string> =>
  outputs->Dict.get(name)->Option.flatMap(o => o.value->JSON.Decode.string)

// ── The accounts ─────────────────────────────────────────────────────────────

/** The stack's own accounts file beside the platform, started from the app's
    template, or `None` when the app has no template — then there is nothing to
    create. Per stack because the file records the ids one pool minted: sharing
    `users.yaml` would overwrite another deployment's record of its accounts. */
let accountsFileName = stack => `users.${stack}.yaml`

let accountsFile = (~platformDir: string, ~stack: string): option<string> => {
  let file = NodePath.join([platformDir, ".reventless", accountsFileName(stack)])
  let template = NodePath.join([platformDir, Manifest.templateName])
  switch (NodeFs.existsSync(file), NodeFs.existsSync(template)) {
  | (false, false) => None
  | (true, _) => Some(file)
  | (false, true) =>
    NodeFs.mkdirSync(NodePath.dirname(file), {recursive: true})
    NodeFs.cpSync(template, file, {})
    Console.log(`manifest ${file} (new, copied from ${template})`)
    Some(file)
  }
}

let signInLines = (entries: array<Manifest.entry>): array<string> => {
  let width = entries->Array.reduce(0, (w, e) => Math.Int.max(w, e.username->String.length))
  entries->Array.map(e =>
    `    ${e.username->String.padEnd(width, " ")}  [${e.groups->Array.join(", ")}]`
  )
}

// ── up / down ────────────────────────────────────────────────────────────────

let up = async (~manifest: DeployManifest.resolved, ~stack: string): result<unit, string> =>
  switch projectsOf(manifest) {
  | Error(_) as e => e
  | Ok((platform, plugins)) =>
    switch await check(~projects=[platform]->Array.concat(plugins)) {
    | Error(problems) =>
      Error(`not ready to deploy:\n${problems->Array.map(p => `  - ${p}`)->Array.join("\n")}`)
    | Ok({region, account}) =>
      Console.log(`account  ${account}, region ${region}, stack ${stack}`)
      let startedAt = Date.make()->Date.toISOString
      switch await ensureLayer(~stack, ~region, ~version=installedVersion()) {
      | Error(_) as e => e
      | Ok(layerArn) =>
        let envVars = Dict.fromArray([("REVENTLESS_LAYER_ARN", layerArn)])
        switch await openForUp(~project=platform, ~stack, ~region, ~envVars, ~extra=[]) {
        | Error(_) as e => e
        | Ok(platformStack) =>
          switch await deploy(~project=platform, ~stack=platformStack, ~name=stack) {
          | Error(_) as e => e
          | Ok() =>
            let platformOutputs = await platformStack->Automation.outputs
            switch platformOutputs->outputString("platformStack") {
            | None =>
              Error(`the platform stack exports no platformStack — its reventless-aws is older than this command`)
            | Some(platformRef) =>
              let rec deployPlugins = async index =>
                switch plugins->Array.get(index) {
                | None => Ok()
                | Some(plugin) =>
                  switch await openForUp(
                    ~project=plugin,
                    ~stack,
                    ~region,
                    ~envVars,
                    ~extra=[("platform:stack", platformRef)],
                  ) {
                  | Error(_) as e => e
                  | Ok(pluginStack) =>
                    switch await deploy(~project=plugin, ~stack=pluginStack, ~name=stack) {
                    | Error(_) as e => e
                    | Ok() => await deployPlugins(index + 1)
                    }
                  }
                }
              switch await deployPlugins(0) {
              | Error(_) as e => e
              | Ok() =>
                Console.log("\n── Baking the component manifest ──\n")
                switch await BakeManifest.bake(~manifest, ~stack, ~since=Some(startedAt)) {
                | Error(_) as e => e
                | Ok() =>
                  let accounts = switch (
                    accountsFile(~platformDir=platform.dir, ~stack),
                    platformOutputs->outputString("identityProviderId"),
                  ) {
                  | (None, _) => Ok(None)
                  | (Some(_), None) =>
                    Error("the platform stack exports no identityProviderId to create accounts in")
                  | (Some(file), Some(providerId)) =>
                    Console.log("\n── Creating the accounts ──\n")
                    switch await ProvisionAccounts.provision(~file, ~providerId) {
                    | Error(_) as e => e
                    | Ok() => Ok(Some(file))
                    }
                  }
                  switch accounts {
                  | Error(_) as e => e
                  | Ok(file) =>
                    Console.log("\n── Ready ──\n")
                    switch platformOutputs->outputString("hostShellUrl") {
                    | Some(url) => Console.log(`  Open:    ${url}`)
                    | None => Console.log("  This platform deploys no web app.")
                    }
                    file->Option.forEach(file =>
                      switch Manifest.parseFile(file) {
                      | Ok(entries) if entries->Array.length > 0 =>
                        Console.log("  Sign in:")
                        signInLines(entries)->Array.forEach(line => Console.log(line))
                        Console.log(`  The passwords are in ${file}.`)
                      | _ => ()
                      }
                    )
                    Console.log(`  Remove it all again: deploy-app down --stack ${stack}`)
                    Ok()
                  }
                }
              }
            }
          }
        }
      }
    }
  }

let down = async (~manifest: DeployManifest.resolved, ~stack: string): result<unit, string> =>
  switch projectsOf(manifest) {
  | Error(_) as e => e
  | Ok((platform, plugins)) =>
    let sts = Sts.client()
    switch await (sts->Sts.config).region() {
    | exception _ => Error("No AWS region is set. Set AWS_REGION and try again.")
    | region =>
      let envVars = Dict.make()
      // Reverse deploy order: the plugins read the platform's outputs.
      let ordered = plugins->Array.toReversed->Array.concat([platform])
      let found = []
      let refused = []
      for index in 0 to ordered->Array.length - 1 {
        let project = ordered->Array.getUnsafe(index)
        switch await existingStack(~project, ~stack, ~envVars) {
        | None => Console.log(`stack    ${project.projectName}/${stack} (not deployed)`)
        | Some(s) =>
          if await isDisposable(s) {
            found->Array.push((project, s))
          } else {
            refused->Array.push(`${project.projectName}/${stack}`)
          }
        }
      }
      if refused->Array.length > 0 {
        Error(
          `nothing was removed: ${refused->Array.join(", ")} ${refused->Array.length == 1
              ? "does"
              : "do"} not declare ${disposableKey}: "true", and deploy-app only removes try-out stacks it created.`,
        )
      } else {
        let rec removeStacks = async index =>
          switch found->Array.get(index) {
          | None => Ok()
          | Some((project, s)) =>
            Console.log(
              `\n── Removing ${project.label} (${project.projectName}/${stack}) ──\n`,
            )
            switch await s->Automation.destroy({onOutput: stream}) {
            | _ =>
              await s->Automation.workspace->Automation.removeStack(stack)
              await removeStacks(index + 1)
            | exception exn =>
              Error(
                `removing ${project.projectName}/${stack} failed. Fix the cause and run down again.\n${failureDetail(
                    exn,
                  )}`,
              )
            }
          }
        switch await removeStacks(0) {
        | Error(_) as e => e
        | Ok() =>
          await removeLayer(~stack, ~region)
          Console.log(
            found->Array.length == 0
              ? `\nNo stack was deployed as ${stack}.`
              : `\nRemoved ${stack}.`,
          )
          Ok()
        }
      }
    }
  }

let run = async (): result<unit, string> =>
  switch parseArgs(NodeProcess.argv->Array.slice(~start=2, ~end=NodeProcess.argv->Array.length)) {
  | Error(_) as e => e
  | Ok(args) if args.help =>
    Console.log(usage)
    Ok()
  | Ok({command: None}) => Error("say `up` or `down` (--help for more)")
  | Ok({command: Some(command), manifest, stack}) =>
    switch DeployManifest.load(manifest->Option.getOr(DeployManifest.defaultFile)) {
    | Error(_) as e => e
    | Ok(manifest) =>
      switch command {
      | Up => await up(~manifest, ~stack)
      | Down => await down(~manifest, ~stack)
      }
    }
  }

let main = async () =>
  switch await run() {
  | Ok() => ()
  | Error(message) =>
    Console.error(`deploy-app: ${message}`)
    NodeProcess.exit(1)
  | exception exn =>
    Console.error(`deploy-app: ${Util_AwsError.describe(exn)}`)
    NodeProcess.exit(1)
  }

// No top-level call: `../run-deploy-app.mjs` invokes [main], so a test can import
// this module.
