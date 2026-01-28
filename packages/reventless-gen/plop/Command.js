export const addToSpec = {
  type: "modify",
  path: "src/Aggregates/{{properCase aggregateName}}/{{properCase aggregateName}}.re",
  pattern: /(type command\W[\S\s]*?);/,
  template: "$1\n  | {{properCaseWithOptionalParams command}};",
};
export const addToBehaviorCreate = {
  type: "modify",
  path: "src/Aggregates/{{properCase aggregateName}}/{{properCase aggregateName}}Behavior.re",
  pattern: /(?<=let create\W[\S\s]*?)(switch \(command\)[\S\s]*?)(\n *)(};)/,
  template: "$1$2| {{properCaseWithOptionalParams command}} => error(NotExisting, command, context)$2$3"
};
export const addCommandAndEventToBehaviorExecute = {
  type: "modify",
  path: "src/Aggregates/{{properCase aggregateName}}/{{properCase aggregateName}}Behavior.re",
  pattern: /(?<=let execute\W[\S\s]*?)( *)(switch \(command\)[\S\s]*?{)/g,
  template: "$1$2\n$1| {{properCaseWithOptionalParams command}} => [{{properCaseWithOptionalParams event}}] // TODO: check generated implementation",
};
export const addToBehaviorExecute = {
  type: "modify",
  path: "src/Aggregates/{{properCase aggregateName}}/{{properCase aggregateName}}Behavior.re",
  pattern: /(?<=let execute\W[\S\s]*?)( *)(switch \(command\)[\S\s]*?{)/g,
  template: "$1$2\n$1| {{properCaseWithOptionalParams command}} => [] // TODO: add implementation",
};
export const addToBehaviorTest = {
  type: "modify",
  path: "tests/{{properCase aggregateName}}/{{properCase aggregateName}}BehaviorTest.re",
  pattern: /(\n}\);)/,
  templateFile: "plop-templates/tests/addCommandToBehaviorTest.re.hbs",
};
export const addCommandAndEventToBehaviorTest = {
  type: "modify",
  path: "tests/{{properCase aggregateName}}/{{properCase aggregateName}}BehaviorTest.re",
  pattern: /(\n}\);)/,
  templateFile: "plop-templates/tests/addCommandAndEventToBehaviorTest.re.hbs",
};
export const addCommandToApiMutation = {
  type: "modify",
  path: "src/API/{{properCase aggregateName}}/{{properCase aggregateName}}Api.re",
  pattern: /(let mutationsSchema[\S\s]*?)(\|\};)/,
  templateFile: "plop-templates/API/addCommandToApiMutation.re.hbs",
};
