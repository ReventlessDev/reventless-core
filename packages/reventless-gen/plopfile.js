// assumtions:
// - code is well indented (regex's check for number of spaces)
// limitations:
// - after some generations code has to be reformatted (i.e. saved)
// - Command Add and Event Added are generated and used for each new Status

import pluralize from 'pluralize';

const createSpec = {
  type: 'add',
  path: 'src/Aggregates/{{properCase name}}/{{properCase name}}.re',
  templateFile: 'plop-templates/Aggregate/Spec.re.hbs'
};
const createBehaviour = {
  type: 'add',
  path: 'src/Aggregates/{{properCase name}}/{{properCase name}}Behaviour.re',
  templateFile: 'plop-templates/Aggregate/Behaviour.re.hbs'
};
const createService = {
  type: 'add',
  path: 'src/Aggregates/{{properCase name}}/{{properCase name}}Service.re',
  templateFile: 'plop-templates/Aggregate/Service.re.hbs'
};
const createTestFixture = {
  type: 'add',
  path: 'tests/{{properCase name}}/{{properCase name}}Fixtures.re',
  templateFile: 'plop-templates/tests/Fixtures.re.hbs'
};
const createBehaviourTest = {
  type: 'add',
  path: 'tests/{{properCase name}}/{{properCase name}}BehaviourTest.re',
  templateFile: 'plop-templates/tests/BehaviourTest.re.hbs'
};

const createView = {
  type: 'add',
  path: 'src/ReadModels/{{properCase name}}/{{properCase name}}View.re',
  templateFile: 'plop-templates/ReadModel/View.re.hbs'
};
const createViewTest = {
  type: 'add',
  path: 'tests/{{properCase name}}/{{properCase name}}ViewTest.re',
  templateFile: 'plop-templates/tests/ViewTest.re.hbs'
};

const createApi = {
  type: 'add',
  path: 'src/API/{{properCase name}}/{{properCase name}}Api.re',
  templateFile: 'plop-templates/API/Api.re.hbs'
};

const addEmptyTypeStatusToSpec = {
  type: "modify",
  path: "src/Aggregates/{{properCase aggregateName}}/{{properCase aggregateName}}.re",
  pattern: /(?<!type status\W[\S\s]*)(\[@decco\]\ntype command =)/,
  templateFile: "plop-templates/Aggregate/addEmptyTypeStatus.re.hbs",
};
const addStatusToSpec = {
  type: "modify",
  path: "src/Aggregates/{{properCase aggregateName}}/{{properCase aggregateName}}.re",
  pattern: /(type status\W[\S\s]*?);/,
  template: "$1\n  | {{properCaseWithOptionalParams status}};",
};
const addStatusFieldToBehaviourState = {
  type: "modify",
  path: "src/Aggregates/{{properCase aggregateName}}/{{properCase aggregateName}}Behaviour.re",
  pattern: /(type state = {)\.?(?!status\W+)([\S\s]*?)(};)/,
  template: "$1status,$2$3",
};
const addStatusSwitchToBehaviourExecute = {
  type: "modify",
  path: "src/Aggregates/{{properCase aggregateName}}/{{properCase aggregateName}}Behaviour.re",
  pattern: /(let execute\W[\S\s]*?=>.*\n)([\S\s]*?)(    };)(?<!let execute\W[\S\s]*?switch \(state\.status\)[\S\s]*?)/,
  templateFile: "plop-templates/Aggregate/addStatusSwitch.re.hbs",
};
const addStatusSwitchToBehaviourApply = {
  type: "modify",
  path: "src/Aggregates/{{properCase aggregateName}}/{{properCase aggregateName}}Behaviour.re",
  pattern: /(let apply\W[\S\s]*?=>.*\n)([\S\s]*?)(    };)(?<!let apply\W[\S\s]*?switch \(state\.status\)[\S\s]*?)/,
  templateFile: "plop-templates/Aggregate/addStatusSwitch.re.hbs",
};
const addStatusFieldToBehaviourInit = {
  type: "modify",
  path: "src/Aggregates/{{properCase aggregateName}}/{{properCase aggregateName}}Behaviour.re",
  pattern: /(let init\W[\S\s]*?switch \(event\).*\n.*?{)(?![\S\s]*?status:)/,
  template: "$1\n        status: {{properCaseWithOptionalParams status}},",
};
const addStatusToBehaviourExecute = {
  type: "modify",
  path: "src/Aggregates/{{properCase aggregateName}}/{{properCase aggregateName}}Behaviour.re",
  pattern: /(let execute\W[\S\s]*?switch \(state.status\) {[\S\s]*?)(\n    };)/,
  templateFile: "plop-templates/Aggregate/addStatusToBehaviourExecute.re.hbs",
};
const addStatusToBehaviourApply = {
  type: "modify",
  path: "src/Aggregates/{{properCase aggregateName}}/{{properCase aggregateName}}Behaviour.re",
  pattern: /(let apply\W[\S\s]*?switch \(state.status\) {[\S\s]*?)(\n    };)/,
  templateFile: "plop-templates/Aggregate/addStatusToBehaviourApply.re.hbs",
};
const addStatusFieldToViewState = {
  type: "modify",
  path: "src/ReadModels/{{properCase aggregateName}}/{{properCase aggregateName}}View.re",
  pattern: /(type state = {)\.?(?!status+)([\S\s]*?)(};)/,
  template: "$1status,$2$3",
};
const addStatusFieldToViewInit = {
  type: "modify",
  path: "src/ReadModels/{{properCase aggregateName}}/{{properCase aggregateName}}View.re",
  pattern: /(let init\W[\S\s]*?switch \(event\)[\S\s]*?)(?<!status\W[\S\s]*)(\n *)(}[^),])/,
  template: "$1$2  status: {{properCaseWithOptionalParams status}},$2$3",
};
const addStatusSwitchToViewApply = {
  type: "modify",
  path: "src/ReadModels/{{properCase aggregateName}}/{{properCase aggregateName}}View.re",
  pattern: /(let apply\W[\S\s]*?=>.*\n)([\S\s]*?)(    };)(?<!let apply\W[\S\s]*?switch \(state\.status\)[\S\s]*?)/,
  templateFile: "plop-templates/Aggregate/addStatusSwitch.re.hbs",
};
const addStatusToViewApply = {
  type: "modify",
  path: "src/ReadModels/{{properCase aggregateName}}/{{properCase aggregateName}}View.re",
  pattern: /(let apply\W[\S\s]*?switch \(state.status\) {[\S\s]*?)(\n    };)/,
  templateFile: "plop-templates/Aggregate/addStatusToViewApply.re.hbs",
};
const addStatusFieldToTestFixture = {
  type: "modify",
  path: "tests/{{properCase aggregateName}}/{{properCase aggregateName}}Fixtures.re",
  pattern: /(let state\W[\S\s]*?)(?<!status\W.*)(\n};)/,
  template: "$1\n  status: {{properCaseWithOptionalParams status}},$2",
};

const addCommandToSpec = {
  type: "modify",
  path: "src/Aggregates/{{properCase aggregateName}}/{{properCase aggregateName}}.re",
  pattern: /(type command\W[\S\s]*?);/,
  template: "$1\n  | {{properCaseWithOptionalParams command}};",
};
const addEventToSpec = {
  type: "modify",
  path: "src/Aggregates/{{properCase aggregateName}}/{{properCase aggregateName}}.re",
  pattern: /(type event\W[\S\s]*?);/,
  template: "$1\n  | {{properCaseWithOptionalParams event}};",
};
const addCommandToBehaviourCreate = {
  type: "modify",
  path: "src/Aggregates/{{properCase aggregateName}}/{{properCase aggregateName}}Behaviour.re",
  pattern: /(?<=let create\W[\S\s]*?)(switch \(command\)[\S\s]*?)(\n *)(};)/,
  template: "$1$2| {{properCaseWithOptionalParams command}} => error(NotExisting, command, context)$2$3"
};
const addCommandAndEventToBehaviourExecute = {
  type: "modify",
  path: "src/Aggregates/{{properCase aggregateName}}/{{properCase aggregateName}}Behaviour.re",
  pattern: /(?<=let execute\W[\S\s]*?)(switch \(command\)[\S\s]*?)(\n *)(};)/g,
  template: "$1$2| {{properCaseWithOptionalParams command}} => [{{properCaseWithOptionalParams event}}] // TODO: check generated implementation$2$3",
};
const addCommandToBehaviourExecute = {
  type: "modify",
  path: "src/Aggregates/{{properCase aggregateName}}/{{properCase aggregateName}}Behaviour.re",
  pattern: /(?<=let execute\W[\S\s]*?)(switch \(command\)[\S\s]*?)(\n *)(};)/g,
  template: "$1$2| {{properCaseWithOptionalParams command}} => [] // TODO: add implementation$2$3",
};
const addEventToBehaviourInit = {
  type: "modify",
  path: "src/Aggregates/{{properCase aggregateName}}/{{properCase aggregateName}}Behaviour.re",
  pattern: /(?<=let init\W[\S\s]*?)(switch \(event\)[\S\s]*?)(\n *)(};)/,
  template: "$1$2| {{properCaseWithOptionalParams event}} => invalidEvent(event)$2$3"
};
const addEventToBehaviourApply = {
  type: "modify",
  path: "src/Aggregates/{{properCase aggregateName}}/{{properCase aggregateName}}Behaviour.re",
  pattern: /(?<=let apply\W[\S\s]*?)(switch \(event\)[\S\s]*?)(\n *)(};)/g,
  template: "$1$2| {{properCaseWithOptionalParams event}} => state // TODO: add implementation$2$3",
};
const addEventToViewInit = {
  type: "modify",
  path: "src/ReadModels/{{properCase aggregateName}}/{{properCase aggregateName}}View.re",
  pattern: /(?<=let init\W[\S\s]*?)(switch \(event\)[\S\s]*?)(\n *)(}[^),\]])/,
  template: "$1$2| {{properCaseWithOptionalParams event}} => invalidEvent(event)$2$3"
};
const addEventToViewApply = {
  type: "modify",
  path: "src/ReadModels/{{properCase aggregateName}}/{{properCase aggregateName}}View.re",
  pattern: /(?<=let apply\W[\S\s]*?)(switch \(event\)[\S\s]*?)(\n *)(}[^),\]])/g,
  templateFile: "plop-templates/ReadModel/addEventToViewApply.re.hbs",
};
const addCommandAndEventToBehaviourTest = {
  type: "modify",
  path: "tests/{{properCase aggregateName}}/{{properCase aggregateName}}BehaviourTest.re",
  pattern: /(\n}\);)/,
  templateFile: "plop-templates/tests/addCommandAndEventToBehaviourTest.re.hbs",
};
const addCommandToBehaviourTest = {
  type: "modify",
  path: "tests/{{properCase aggregateName}}/{{properCase aggregateName}}BehaviourTest.re",
  pattern: /(\n}\);)/,
  templateFile: "plop-templates/tests/addCommandToBehaviourTest.re.hbs",
};
const addEventToViewTest = {
  type: "modify",
  path: "tests/{{properCase aggregateName}}/{{properCase aggregateName}}ViewTest.re",
  pattern: /(\n}\);)/,
  templateFile: "plop-templates/tests/addEventToViewTest.re.hbs",
};

export default function (plop) {
  plop.setGenerator('Service', {
    prompts: [{
      type: 'input',
      name: 'name',
      message: 'Service name:'
    }],
    actions: [
      createSpec,
      createBehaviour,
      createService,
      createTestFixture,
      createBehaviourTest,
      createView,
      createViewTest,
      createApi
    ]
  });
  plop.setGenerator('Aggregate', {
    prompts: [{
      type: 'input',
      name: 'name',
      message: 'Aggregate name:'
    }],
    actions: [
      createSpec,
      createBehaviour,
      createService,
      createTestFixture,
      createBehaviourTest,
    ]
  });
  plop.setGenerator('ReadModel', {
    prompts: [{
      type: 'input',
      name: 'name',
      message: 'ReadModel name:'
    }],
    actions: [
      createView,
      createViewTest,
      createApi
    ]
  });
  plop.setGenerator('Status', {
    prompts: [{
      type: 'input',
      name: 'aggregateName',
      message: 'Aggregate name:'
    },
    {
      type: 'input',
      name: 'status',
      message: 'Status:'
    }],
    actions: [
      addEmptyTypeStatusToSpec,
      addStatusToSpec,
      addStatusFieldToBehaviourState,
      addStatusFieldToBehaviourInit,
      addStatusToBehaviourExecute,
      addStatusSwitchToBehaviourExecute,
      addStatusToBehaviourApply,
      addStatusSwitchToBehaviourApply,
      addStatusFieldToViewState,
      addStatusFieldToViewInit,
      addStatusToViewApply,
      addStatusSwitchToViewApply,
      addStatusFieldToTestFixture
    ]
  });
  plop.setGenerator('Command+Event', {
    prompts: [{
      type: 'input',
      name: 'aggregateName',
      message: 'Aggregate name:'
    },
    {
      type: 'input',
      name: 'command',
      message: 'Command:'
    },
    {
      type: 'input',
      name: 'event',
      message: 'Event:'
    }],
    actions: [
      addCommandToSpec,
      addEventToSpec,
      addCommandToBehaviourCreate,
      addCommandAndEventToBehaviourExecute,
      addEventToBehaviourInit,
      addEventToBehaviourApply,
      addEventToViewInit,
      addEventToViewApply,
      addCommandAndEventToBehaviourTest,
      addEventToViewTest
    ]
  });
  plop.setGenerator('Command', {
    prompts: [{
      type: 'input',
      name: 'aggregateName',
      message: 'Aggregate name:'
    },
    {
      type: 'input',
      name: 'command',
      message: 'Command:'
    }],
    actions: [
      addCommandToSpec,
      addCommandToBehaviourCreate,
      addCommandToBehaviourExecute,
      addCommandToBehaviourTest
    ]
  });
  plop.setGenerator('Event', {
    prompts: [{
      type: 'input',
      name: 'aggregateName',
      message: 'Aggregate name:'
    },
    {
      type: 'input',
      name: 'event',
      message: 'Event:'
    }],
    actions: [
      addEventToSpec,
      addEventToBehaviourInit,
      addEventToBehaviourApply,
      addEventToViewInit,
      addEventToViewApply,
      addEventToViewTest
    ]
  });

  plop.setHelper('pluralize', (name) =>
    pluralize.plural(plop.getHelper("properCase")(name)));

  plop.setHelper('properCaseWithoutOptionalParams', (txt) => txt.split("(")[0]);

  plop.setHelper('properCaseWithOptionalParams', (txt) => {
    const parts = txt.split("(");
    return plop.getHelper("properCase")(parts[0]) + (parts[1] ? '(' + parts[1] : '');
  })
};