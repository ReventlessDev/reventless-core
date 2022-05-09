export const createView = {
  type: 'add',
  path: 'src/ReadModels/{{properCase name}}/{{properCase name}}View.re',
  templateFile: 'plop-templates/ReadModel/View.re.hbs'
};
export const createReadModel = {
  type: 'add',
  path: 'src/ReadModels/{{properCase name}}/{{properCase name}}ReadModel.re',
  templateFile: 'plop-templates/ReadModel/ReadModel.re.hbs'
};
export const addReadModelToMain = {
  type: "modify",
  path: "src/Main.re",
  pattern: /(~readModels\W[\S\s]*?\[\|)/,
  template: "$1(module {{properCase name}}ReadModel),",
};
export const createViewTest = {
  type: 'add',
  path: 'tests/{{properCase name}}/{{properCase name}}ViewTest.re',
  templateFile: 'plop-templates/tests/ViewTest.re.hbs'
};
