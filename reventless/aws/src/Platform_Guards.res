// What the platform stack provides for a public sign-up beyond its door: a mail
// sender that keeps bounced and complained-about addresses off its list, the
// daily cap on registration mail, and an operator who is told when something
// costs or goes wrong.

type made = {
  /** The SES configuration set sends name, `""` where there is no sender. */
  configurationSet: Pulumi.Output.t<string>,
  /** The topic the deployment's alarms write to, `""` with no operator named. */
  operatorAlerts: Pulumi.Output.t<string>,
  /** Whether a budget watches what mail, sign-in and the APIs cost. */
  billAlarm: bool,
}

let config = () => Pulumi.Config.make(Some("platform"))

/** `platform:registrationMailDailyCap`, as written; `""` reads as the default.
    Refused here when it is not a positive number. */
let registrationMailDailyCap = (): string =>
  switch config()->Pulumi.Config.get("registrationMailDailyCap") {
  | None | Some("") => ""
  | Some(raw) =>
    switch Messaging_DailyCap.parseCap(raw) {
    | Ok(n) => n->Int.toString
    | Error(_) =>
      JsError.throwWithMessage(
        `platform:registrationMailDailyCap: "${raw}" is not a daily cap — write a positive number, such as ${Messaging_DailyCap.defaultCap->Int.toString}`,
      )
    }
  }

/** `platform:operatorAddress`, as written: who is told. Refused when it is not an
    address. */
let parseOperatorAddress = (raw: option<string>): result<option<string>, string> =>
  switch raw->Option.map(String.trim) {
  | None | Some("") => Ok(None)
  | Some(address) =>
    switch Reventless.Email.fromString(address) {
    | Ok(_) => Ok(Some(address))
    | Error(_) => Error(`platform:operatorAddress: "${address}" is not an email address`)
    }
  }

let operatorAddress = (): option<string> =>
  switch parseOperatorAddress(config()->Pulumi.Config.get("operatorAddress")) {
  | Ok(address) => address
  | Error(message) => JsError.throwWithMessage(message)
  }

/** The default monthly budget in US dollars: a small deployment's mail, sign-in
    and requests, with room. */
let defaultMonthlyUsd = 20

/** `platform:billAlarmMonthlyUsd`, a positive whole number of dollars. */
let parseMonthlyUsd = (raw: option<string>): result<int, string> =>
  switch raw->Option.map(String.trim) {
  | None | Some("") => Ok(defaultMonthlyUsd)
  | Some(raw) =>
    // Digits only: a number reader takes `7.5` as 7, a budget nobody chose.
    switch /^\d+$/->RegExp.test(raw) ? Int.fromString(raw) : None {
    | Some(n) if n > 0 => Ok(n)
    | _ =>
      Error(
        `platform:billAlarmMonthlyUsd: "${raw}" is not an amount — write whole dollars, such as ${defaultMonthlyUsd->Int.toString}`,
      )
    }
  }

let monthlyUsd = (): int =>
  switch parseMonthlyUsd(config()->Pulumi.Config.get("billAlarmMonthlyUsd")) {
  | Ok(n) => n
  | Error(message) => JsError.throwWithMessage(message)
  }

/** What the budget counts: the services a public sign-up spends. A budget filters
    by service across the account, not by stack, so it sees every deployment in the
    account that uses them: an upper bound, which is what an alarm needs. */
let budgetServices = ["Amazon Simple Email Service", "Amazon Cognito", "AWS AppSync", "AWS WAF"]

/** A name SES accepts for this stack's configuration set. */
let configurationSetName = (~project: string, ~stack: string): string =>
  `${project}-${stack}`
  ->String.replaceRegExp(/[^A-Za-z0-9_-]/g, "-")
  ->String.slice(~start=0, ~end=64)

let make = (~sender: bool): made => {
  let configurationSet = sender
    ? PulumiAws.SES.ConfigurationSet.make(
        ~name="mail",
        ~args={
          configurationSetName: configurationSetName(
            ~project=Pulumi.Pulumi.getProjectName(),
            ~stack=Pulumi.Pulumi.getStackName(),
          ),
          suppressionOptions: {suppressedReasons: ["BOUNCE", "COMPLAINT"]},
          tags: AWS.Tags.make(
            ~name="mail",
            ~kind=ReventlessCore.ComponentType.Platform,
            ~role=Other("Mail"),
            ~scope=Platform,
          ),
        },
      ).configurationSetName
    : Pulumi.Output.make("")
  switch operatorAddress() {
  | None => {configurationSet, operatorAlerts: Pulumi.Output.make(""), billAlarm: false}
  | Some(address) =>
    let topic = PulumiAws.SNS.Topic.make(
      ~name="operator-alerts",
      ~args={
        displayName: "Deployment alerts"->Pulumi.Input.make,
        tags: AWS.Tags.make(
          ~name="operator-alerts",
          ~kind=ReventlessCore.ComponentType.Platform,
          ~role=Other("Alarm"),
          ~scope=Platform,
        ),
      },
    )
    // An email subscription waits until the address confirms it, once.
    let _ = PulumiAws.SNS.TopicSubscription.make(
      ~name="operator-alerts-email",
      ~args={
        endpoint: address->Pulumi.Input.make,
        topic: topic.arn->Pulumi.Output.asInput,
        protocol: Email,
      },
      ~opts=None,
    )
    let notify = (~kind): PulumiAws.Budgets.Budget.notification => {
      comparisonOperator: "GREATER_THAN",
      threshold: 100.,
      thresholdType: "PERCENTAGE",
      notificationType: kind,
      subscriberEmailAddresses: [address]->Pulumi.Input.make,
    }
    let _ = PulumiAws.Budgets.Budget.make(
      ~name="bill",
      ~args={
        budgetType: "COST",
        limitAmount: monthlyUsd()->Int.toString->Pulumi.Input.make,
        limitUnit: "USD",
        timeUnit: "MONTHLY",
        namePrefix: `${Pulumi.Pulumi.getProjectName()}-${Pulumi.Pulumi.getStackName()}-`,
        costFilters: [{name: "Service", values: budgetServices}],
        notifications: [notify(~kind="ACTUAL"), notify(~kind="FORECASTED")],
        tags: AWS.Tags.make(
          ~name="bill",
          ~kind=ReventlessCore.ComponentType.Platform,
          ~role=Other("Alarm"),
          ~scope=Platform,
        ),
      },
    )
    {configurationSet, operatorAlerts: topic.arn, billAlarm: true}
  }
}
