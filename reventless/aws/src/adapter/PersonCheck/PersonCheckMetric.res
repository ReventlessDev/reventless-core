// Whether the plugin being deployed reads its command function's logs for a person
// check that cannot be asked: where it has a door that starts a sign-up. Apart from
// the alarm, which needs the operator's topic, so a function builder can ask.

/** Whether the plugin being deployed has a door that starts a sign-up. */
let hasStart = (structure: option<Reventless.Plugin.pluginStructure>): bool =>
  structure
  ->Option.flatMap(s => s.admissionDoors)
  ->Option.getOr([])
  ->Array.some(d => d.part == Reventless.Admission.doorName(Start))

let current = () => hasStart(ReventlessCore.Plugin_Helpers.currentStructureRef.contents)

/** The metric lines a command function's logs carry for the check. */
let metricNames = () => current() ? [AwsPersonCheck.metricName] : []
