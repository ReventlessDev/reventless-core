import pluralize from 'pluralize';

const addSpec = {
  type: 'add',
  path: 'src/Aggregates/{{properCase name}}/{{properCase name}}.re',
  templateFile: 'plop-templates/Aggregate/Spec.re.hbs'
};
const addBehaviour = {
  type: 'add',
  path: 'src/Aggregates/{{properCase name}}/{{properCase name}}Behaviour.re',
  templateFile: 'plop-templates/Aggregate/Behaviour.re.hbs'
};
const addService = {
  type: 'add',
  path: 'src/Aggregates/{{properCase name}}/{{properCase name}}Service.re',
  templateFile: 'plop-templates/Aggregate/Service.re.hbs'
};
const addTestFixture = {
  type: 'add',
  path: 'tests/{{properCase name}}/{{properCase name}}Fixture.re',
  templateFile: 'plop-templates/tests/Fixtures.re.hbs'
};
const addBehaviourTest = {
  type: 'add',
  path: 'tests/{{properCase name}}/{{properCase name}}BehaviourTest.re',
  templateFile: 'plop-templates/tests/BehaviourTest.re.hbs'
};

const addView = {
  type: 'add',
  path: 'src/ReadModels/{{properCase name}}/{{properCase name}}View.re',
  templateFile: 'plop-templates/ReadModel/View.re.hbs'
};
const addViewTest = {
  type: 'add',
  path: 'tests/{{properCase name}}/{{properCase name}}ViewTest.re',
  templateFile: 'plop-templates/tests/ViewTest.re.hbs'
};

const addApi = {
  type: 'add',
  path: 'src/API/{{properCase name}}/{{properCase name}}Api.re',
  templateFile: 'plop-templates/API/Api.re.hbs'
};


export default function (plop) {
  plop.setGenerator('Service', {
    prompts: [{
      type: 'input',
      name: 'name',
      message: 'Service name:'
    }],
    actions: [
      addSpec,
      addBehaviour,
      addService,
      addTestFixture,
      addBehaviourTest,
      addView,
      addViewTest,
      addApi
    ]
  });
  plop.setGenerator('Aggregate', {
    prompts: [{
      type: 'input',
      name: 'name',
      message: 'Aggregate name:'
    }],
    actions: [
      addSpec,
      addBehaviour,
      addService,
      addTestFixture,
      addBehaviourTest,
    ]
  });
  plop.setGenerator('ReadModel', {
    prompts: [{
      type: 'input',
      name: 'name',
      message: 'ReadModel name:'
    }],
    actions: [
      addView,
      addViewTest,
      addApi
    ]
  });

  plop.setHelper('pluralize', (txt) =>
    pluralize.plural(plop.getHelper("properCase")(txt)));
};