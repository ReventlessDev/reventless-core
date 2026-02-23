export const createEventMappings = {
  type: 'add',
  path: 'src/Aggregates/{{properCase target}}/{{properCase target}}EventMappings.re',
  templateFile: "plop-templates/Aggregate/EventMappings.re.hbs",
  abortOnFail: false,
};
export const addEventMappingsToAggregate = {
  type: "modify",
  path: "src/Aggregates/{{properCase target}}/{{properCase target}}Aggregate.re",
  pattern: /\(Reventless.NoEventMappings.Make\(.*?\)\)/,
  template: "{{properCase target}}EventMappings",
};
export const addMappingToEventMappings = {
  type: "modify",
  path: "src/Aggregates/{{properCase target}}/{{properCase target}}EventMappings.re",
  pattern: /(module type Mapping[\S\s]*?\[\|)/,
  templateFile: "plop-templates/Aggregate/addMappingToEventMappings.re.hbs",
};
