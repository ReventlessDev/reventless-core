// Typed cold-start core shared by the two command-path entry-point shells
// (AggregateEntryPoint.mjs, DcbCommandTopicEntryPoint.mjs).
//
// Both shells build their AppSync CommandGenerator handler by calling the
// compiled `CommandGenerator_Callback.makeGenerateCommand` positionally — a call
// their comments flagged as fragile: omitting the trailing `stripIdFromParams`
// shifts every argument left, sending the schema object through the `serviceName`
// slot and throwing "Cannot convert object to primitive value" at the first log
// line. This wrapper pins that correspondence: the arg order, the
// `commandComponentKind` variant, and an explicit (non-defaulted)
// `stripIdFromParams` are all compiler-checked against the framework signature,
// so a signature change is a build error rather than a silent runtime shift.
//
// The shell still calls this positionally from JS, but the wrapper's OWN call
// into the framework is typed — this file is the stable contract the shells pin
// to, far less likely to drift than the framework internal.

let makeCommandGenerator = (
  ~publishJsons,
  ~publishJsonsAndWait: option<_>,
  ~serviceName,
  ~commandSchema,
  ~componentKind: ReventlessCore.CommandGenerator_Callback.commandComponentKind,
  ~stripIdFromParams: bool,
): ReventlessCore.CommandGenerator.commandGenerator =>
  ReventlessCore.CommandGenerator_Callback.makeGenerateCommand(
    ~publishJsons,
    ~publishJsonsAndWait?,
    ~serviceName,
    ~commandSchema,
    ~componentKind,
    ~stripIdFromParams,
  )
