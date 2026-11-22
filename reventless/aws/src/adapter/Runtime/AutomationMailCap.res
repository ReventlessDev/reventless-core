// The deploy side of the cap on registration mail: which slices of the plugin
// send it (those marked `Reventless.Admission.Mail`), and what the automation
// function they run on needs for the cap — the slices' names, the count table
// and its one call, the cap itself, a metric of the cap being reached, and an
// alarm on it to the deployment's operator.

/** The senders of registration mail, by the plugin's structure. */
let mailSlices = (structure: option<Reventless.Plugin.pluginStructure>): array<string> =>
  structure
  ->Option.flatMap(s => s.admissionDoors)
  ->Option.getOr([])
  ->Array.filter(d => d.part == Reventless.Admission.doorName(Mail))
  ->Array.map(d => d.component)

let current = () => mailSlices(ReventlessCore.Plugin_Helpers.currentStructureRef.contents)

/** The variables the function is handed where it runs a sender of registration
    mail: who they are, and where the day's mail is counted. */
let env = (envVars: dict<Pulumi.Input.t<string>>) =>
  switch current() {
  | [] => ()
  | slices =>
    envVars->Dict.set(Messaging_DailyCap.slicesVariable, slices->Array.join(",")->Pulumi.Input.make)
    envVars->Dict.set(
      VisitorLimit_Ops.tableVariable,
      AppSync_VisitorLimit.table(~opts={}).name->Pulumi.Output.asInput,
    )
  }

/** The metric lines the function's logs carry for the cap. */
let metricNames = () => current() == [] ? [] : [Messaging_DailyCap.metricName]

/** The alarm's settings: when, as a CloudWatch alarm reads them. */
let alarmPeriodSeconds = 300

/** The grant on the count table, and an alarm on the cap for each sender. */
let make = (~runtime: ReventlessCore.Runtime.environment<Util.Lambda.runtimeParts>, ~opts) =>
  switch current() {
  | [] => ()
  | slices =>
    let customOpts =
      opts->ReventlessCore.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions
    let table = AppSync_VisitorLimit.table(~opts={})
    let _ = PulumiAws.IAM.RolePolicy.make(
      ~name="AllAutomationSlicesMailCap",
      ~args={
        policy: table.arn
        ->Pulumi.Output.apply(arn =>
          AppSync_VisitorLimit.policy(~id="AllAutomationSlicesMailCapPolicy", arn)
        )
        ->Pulumi.Output.asInput,
        role: runtime.parts.lambdaRole.id->Pulumi.Output.asInput,
      },
      ~opts=customOpts,
    )
    let alerts = PluginRuntime_Builder.operatorAlerts()
    slices->Array.forEach(slice => {
      let _ = PulumiAws.Cloudwatch.MetricAlarm.make(
        ~name=`${slice}MailCap`,
        ~args={
          comparisonOperator: "GreaterThanThreshold"->Pulumi.Input.make,
          evaluationPeriods: 1->Pulumi.Input.make,
          metricName: Messaging_DailyCap.metricName->Pulumi.Input.make,
          namespace: Util_DcbMetrics.namespace->Pulumi.Input.make,
          period: alarmPeriodSeconds->Pulumi.Input.make,
          statistic: "Sum"->Pulumi.Input.make,
          threshold: 0.->Pulumi.Input.make,
          dimensions: Dict.fromArray([("slice", slice)])->Pulumi.Input.make,
          treatMissingData: "notBreaching"->Pulumi.Input.make,
          alarmActions: alerts
          ->Pulumi.Output.apply(arn => arn == "" ? [] : [arn->Pulumi.Input.make])
          ->Pulumi.Output.asInput,
          alarmDescription: (`${slice} has sent the day's cap of registration mail and sends ` ++ `no more today. Many sign-ups in one day, or a script signing strangers up.`)
            ->Pulumi.Input.make,
          tags: AWS.Tags.make(
            ~name=`${slice}MailCap`,
            ~kind=ReventlessCore.ComponentType.Plugin,
            ~role=Other("Alarm"),
            ~component=slice,
          ),
        },
        ~opts=customOpts,
      )
    })
  }
