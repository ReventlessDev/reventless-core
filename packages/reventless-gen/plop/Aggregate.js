export const createSpec = {
  type: 'add',
  path: 'src/Aggregates/{{properCase name}}/{{properCase name}}.re',
  templateFile: 'plop-templates/Aggregate/Spec.re.hbs'
};
export const createBehavior = {
  type: 'add',
  path: 'src/Aggregates/{{properCase name}}/{{properCase name}}Behavior.re',
  templateFile: 'plop-templates/Aggregate/Behavior.re.hbs'
};
export const create = {
  type: 'add',
  path: 'src/Aggregates/{{properCase name}}/{{properCase name}}Aggregate.re',
  templateFile: 'plop-templates/Aggregate/Aggregate.re.hbs'
};
export const addToMain = {
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
export const createBehaviorTest = {
  type: 'add',
  path: 'tests/{{properCase name}}/{{properCase name}}BehaviorTest.re',
  templateFile: 'plop-templates/tests/BehaviorTest.re.hbs'
};
