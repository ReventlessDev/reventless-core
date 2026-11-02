// A log line from app code, such as a directive's handler, written the way the framework writes its
// own: through the installed logger, under a component (`Extension(Ordering.Orders.Catalog)`), so
// the line carries its plugin and component instead of being bare output.

let line = (~comp: string, level: [#debug | #info | #warn | #error], msg: string) =>
  switch level {
  | #debug => Effect.logDebug(msg)
  | #info => Effect.logInfo(msg)
  | #warn => Effect.logWarning(msg)
  | #error => Effect.logError(msg)
  }
  ->Effect.annotateLogs("comp", comp)
  ->Effect.runSync

let debug = (~comp, msg) => line(~comp, #debug, msg)
let info = (~comp, msg) => line(~comp, #info, msg)
let warn = (~comp, msg) => line(~comp, #warn, msg)
let error = (~comp, msg) => line(~comp, #error, msg)
