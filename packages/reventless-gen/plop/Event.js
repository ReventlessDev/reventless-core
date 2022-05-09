export const addEventToSpec = {
  type: "modify",
  path: "src/Aggregates/{{properCase aggregateName}}/{{properCase aggregateName}}.re",
  pattern: /(type event\W[\S\s]*?);/,
  template: "$1\n  | {{properCaseWithOptionalParams event}};",
};
export const addEventToBehaviourInit = {
  type: "modify",
  path: "src/Aggregates/{{properCase aggregateName}}/{{properCase aggregateName}}Behaviour.re",
  pattern: /(?<=let init\W[\S\s]*?)(switch \(event\)[\S\s]*?)(\n *)(};)/,
  template: "$1$2| {{properCaseWithOptionalParams event}} => invalidEvent(event)$2$3"
};
export const addEventToBehaviourApply = {
  type: "modify",
  path: "src/Aggregates/{{properCase aggregateName}}/{{properCase aggregateName}}Behaviour.re",
  pattern: /(?<=let apply\W[\S\s]*?)( *)(switch \(event\)[\S\s]*?{)/g,
  template: "$1$2\n$1| {{properCaseWithOptionalParams event}} => state // TODO: add implementation",
};
export const addEventToViewInit = {
  type: "modify",
  path: "src/ReadModels/{{properCase aggregateName}}/{{properCase aggregateName}}View.re",
  pattern: /(?<=let init\W[\S\s]*?)(switch \(event\)[\S\s]*?)(\n *)(}[^),\]])/,
  template: "$1$2| {{properCaseWithOptionalParams event}} => invalidEvent(event)$2$3"
};
export const addEventToViewApply = {
  type: "modify",
  path: "src/ReadModels/{{properCase aggregateName}}/{{properCase aggregateName}}View.re",
  pattern: /(?<=let apply\W[\S\s]*?)(switch \(event\)[\S\s]*?)(\n *)(}[^),\]])/g,
  templateFile: "plop-templates/ReadModel/addEventToViewApply.re.hbs",
};
export const addEventToViewTest = {
  type: "modify",
  path: "tests/{{properCase aggregateName}}/{{properCase aggregateName}}ViewTest.re",
  pattern: /(\n}\);)/,
  templateFile: "plop-templates/tests/addEventToViewTest.re.hbs",
};
