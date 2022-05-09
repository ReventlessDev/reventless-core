export const createSpec = {
  type: 'add',
  path: 'src/Aggregates/{{properCase name}}/{{properCase name}}.re',
  templateFile: 'plop-templates/Aggregate/Spec.re.hbs'
};
export const createBehaviour = {
  type: 'add',
  path: 'src/Aggregates/{{properCase name}}/{{properCase name}}Behaviour.re',
  templateFile: 'plop-templates/Aggregate/Behaviour.re.hbs'
};
export const createAggregate = {
  type: 'add',
  path: 'src/Aggregates/{{properCase name}}/{{properCase name}}Aggregate.re',
  templateFile: 'plop-templates/Aggregate/Aggregate.re.hbs'
};
export const addAggregateToMain = {
  type: "modify",
  path: "src/Main.re",
  pattern: /(~aggregates\W[\S\s]*?\[\|)/,
  template: "$1(module {{properCase name}}Aggregate),",
};
export const createTestFixture = {
  type: 'add',
  path: 'tests/{{properCase name}}/{{properCase name}}Fixtures.re',
  templateFile: 'plop-templates/tests/Fixtures.re.hbs'
};
export const createBehaviourTest = {
  type: 'add',
  path: 'tests/{{properCase name}}/{{properCase name}}BehaviourTest.re',
  templateFile: 'plop-templates/tests/BehaviourTest.re.hbs'
};
