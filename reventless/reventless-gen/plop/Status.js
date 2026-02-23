export const addEmptyTypeStatusToSpec = {
  type: "modify",
  path: "src/Aggregates/{{properCase aggregateName}}/{{properCase aggregateName}}.re",
  pattern: /(?<!type status\W[\S\s]*)(\[@decco\]\ntype command =)/,
  templateFile: "plop-templates/Aggregate/addEmptyTypeStatus.re.hbs",
};
export const addStatusToSpec = {
  type: "modify",
  path: "src/Aggregates/{{properCase aggregateName}}/{{properCase aggregateName}}.re",
  pattern: /(type status\W[\S\s]*?);/,
  template: "$1\n  | {{properCaseWithOptionalParams status}};",
};
export const addStatusFieldToBehaviorState = {
  type: "modify",
  path: "src/Aggregates/{{properCase aggregateName}}/{{properCase aggregateName}}Behavior.re",
  pattern: /(type state = {)\.?([\S\s]*?)(?<!status\W[\S\s]*?)(};)/,
  template: "$1status,$2$3",
};
export const addStatusSwitchToBehaviorExecute = {
  type: "modify",
  path: "src/Aggregates/{{properCase aggregateName}}/{{properCase aggregateName}}Behavior.re",
  pattern: /(let execute\W[\S\s]*?=>.*\n)([\S\s]*?)(    };)(?<!let execute\W[\S\s]*?switch \(state\.status\)[\S\s]*?)/,
  templateFile: "plop-templates/Aggregate/addStatusSwitch.re.hbs",
};
export const addStatusSwitchToBehaviorApply = {
  type: "modify",
  path: "src/Aggregates/{{properCase aggregateName}}/{{properCase aggregateName}}Behavior.re",
  pattern: /(let apply\W[\S\s]*?=>.*\n)([\S\s]*?)(    };)(?<!let apply\W[\S\s]*?switch \(state\.status\)[\S\s]*?)/,
  templateFile: "plop-templates/Aggregate/addStatusSwitch.re.hbs",
};
export const addStatusFieldToBehaviorInit = {
  type: "modify",
  path: "src/Aggregates/{{properCase aggregateName}}/{{properCase aggregateName}}Behavior.re",
  pattern: /(let init\W[\S\s]*?switch \(event\).*\n.*?{)(?![\S\s]*?status:)/,
  template: "$1status: {{properCaseWithOptionalParams status}},",
};
export const addStatusToBehaviorExecute = {
  type: "modify",
  path: "src/Aggregates/{{properCase aggregateName}}/{{properCase aggregateName}}Behavior.re",
  pattern: /(let execute\W[\S\s]*?switch \(state.status\) {[\S\s]*?)(\n    };)/,
  templateFile: "plop-templates/Aggregate/addStatusToBehaviorExecute.re.hbs",
};
export const addStatusToBehaviorApply = {
  type: "modify",
  path: "src/Aggregates/{{properCase aggregateName}}/{{properCase aggregateName}}Behavior.re",
  pattern: /(let apply\W[\S\s]*?switch \(state.status\) {[\S\s]*?)(\n    };)/,
  templateFile: "plop-templates/Aggregate/addStatusToBehaviorApply.re.hbs",
};
export const addStatusFieldToViewState = {
  type: "modify",
  path: "src/ReadModels/{{properCase aggregateName}}/{{properCase aggregateName}}View.re",
  pattern: /(type state = {)\.?([\S\s]*?)(?<!status\W[\S\s]*?)(};)/,
  template: "$1status,$2$3",
};
export const addStatusFieldToViewInit = {
  type: "modify",
  path: "src/ReadModels/{{properCase aggregateName}}/{{properCase aggregateName}}View.re",
  pattern: /(let init\W[\S\s]*?\[[\S\s]*?{)([\S\s]*?)(?<!let init\W[\S\s]*?status\W[\S\s]*?)(\])/,
  template: "$1status: {{properCaseWithOptionalParams status}},$2$3",
};
export const addStatusSwitchToViewApply = {
  type: "modify",
  path: "src/ReadModels/{{properCase aggregateName}}/{{properCase aggregateName}}View.re",
  pattern: /(let apply\W[\S\s]*?=>.*\n)([\S\s]*?)(    };)(?<!let apply\W[\S\s]*?switch \(state\.status\)[\S\s]*?)/,
  templateFile: "plop-templates/Aggregate/addStatusSwitch.re.hbs",
};
export const addStatusToViewApply = {
  type: "modify",
  path: "src/ReadModels/{{properCase aggregateName}}/{{properCase aggregateName}}View.re",
  pattern: /(let apply\W[\S\s]*?switch \(state.status\) {[\S\s]*?)(\n    };)/,
  templateFile: "plop-templates/Aggregate/addStatusToViewApply.re.hbs",
};
export const addStatusFieldToTestFixture = {
  type: "modify",
  path: "tests/{{properCase aggregateName}}/{{properCase aggregateName}}Fixtures.re",
  pattern: /(let state\W[\S\s]*?)(?<!status\W.*)(\n};)/,
  template: "$1\n  status: {{properCaseWithOptionalParams status}},$2",
};
