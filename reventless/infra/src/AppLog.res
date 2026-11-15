// A log line from app code, such as a directive's handler, written the way the framework writes its
// own: through the installed logger, under a component (`Extension(Ordering.Orders.Catalog)`), so
// the line carries its plugin and component instead of being bare output.

type level = LogDebug | LogInfo | LogWarn | LogError

let line = (~comp: string, level: level, msg: string) =>
  switch level {
  | LogDebug => Effect.logDebug(msg)
  | LogInfo => Effect.logInfo(msg)
  | LogWarn => Effect.logWarning(msg)
  | LogError => Effect.logError(msg)
  }
  ->Effect.annotateLogs("comp", comp)
  ->Effect.runSync

let debug = (~comp, msg) => line(~comp, LogDebug, msg)
let info = (~comp, msg) => line(~comp, LogInfo, msg)
let warn = (~comp, msg) => line(~comp, LogWarn, msg)
let error = (~comp, msg) => line(~comp, LogError, msg)
