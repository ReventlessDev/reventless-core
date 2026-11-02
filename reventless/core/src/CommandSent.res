// The line a component writes when it sends a command, under its own name and with the
// command's ids: `AutomationSlice(NotificationIntake) sending command: RequestNotification({…})`.
// The plugin's command topic publishes for every sender alike and cannot say whose a command
// is; this line does, as the API's `generated command` and a contract's `EP→` line do.

let log = (~comp: string, cmdJson: Message.commandJson) =>
  EffectLogger.logInfo(
    ~comp,
    ~ids=EffectLogger.idsOf(cmdJson.meta),
    ~detail=cmdJson.commandJson,
    `sending command: ${LogFormat.cmdDetailNoId(cmdJson)}`,
  )->Effect.runSync

/** The same publishing, each command announced first under `comp`. */
let announcing = (
  ~comp: string,
  publishJsons: ReventlessInfra.CommandTopic.publishJsons,
): ReventlessInfra.CommandTopic.publishJsons =>
  cmdJsons => {
    cmdJsons->Array.forEach(cmdJson => log(~comp, cmdJson))
    publishJsons(cmdJsons)
  }
