// assumtions:
// - code is well indented (regex's check for number of spaces)
// limitations:
// - after some generations code has to be reformatted (i.e. saved)
// - Command Add and Event Added are generated and used for each new Status

import pluralize from 'pluralize';
import additionalActionTypes from './additionalActionTypes.js';

const createProjectFiles = {
  type: 'addMany',
  destination: '{{dashCase projectName}}/',
  base: 'plop-templates/Project/',
  templateFiles: 'plop-templates/Project/**/*',
  globOptions: {dot: true}
};
const gitInitPlatform = data => ({
  type: 'gitInit',
  path: `${process.cwd()}/${data.projectName}/platform/`,
  verbose: true,
  abortOnFail: false
});
const npmInstallApi = data => ({
  type: 'npmInstall',
  path: `${process.cwd()}/${data.projectName}/platform/api`,
  verbose: true
});
const rebuildApi = data => ({
  type: 'rebuild',
  path: `${process.cwd()}/${data.projectName}/platform/api`,
  verbose: true
});
const npmInstallCore = data => ({
  type: 'npmInstall',
  path: `${process.cwd()}/${data.projectName}/platform/core`,
  verbose: true
});
const rebuildCore = data => ({
  type: 'rebuild',
  path: `${process.cwd()}/${data.projectName}/platform/core`,
  verbose: true
});

const createPluginFiles = {
  type: 'addMany',
  destination: '{{dashCase pluginName}}/',
  base: 'plop-templates/Plugin/',
  templateFiles: 'plop-templates/Plugin/**/*',
  globOptions: {dot: true}
};
const gitInitPlugin = (plop, data) => ({
  type: 'gitInit',
  path: `${process.cwd()}/${plop.getHelper("dashCase")(data.pluginName)}/`,
  verbose: true,
  abortOnFail: false
});
const npmInstallPlugin = (plop, data) => ({
  type: 'npmInstall',
  path: `${process.cwd()}/${plop.getHelper("dashCase")(data.pluginName)}/plugin`,
  verbose: true
});
const rebuildPlugin = (plop, data) => ({
  type: 'rebuild',
  path: `${process.cwd()}/${plop.getHelper("dashCase")(data.pluginName)}/plugin`,
  verbose: true,
  abortOnFail: false
});
const npmInstallUi = (plop, data) => ({
  type: 'npmInstall',
  path: `${process.cwd()}/${plop.getHelper("dashCase")(data.pluginName)}/ui`,
  verbose: true
});
const rebuildUi = (plop, data) => ({
  type: 'rebuild',
  path: `${process.cwd()}/${plop.getHelper("dashCase")(data.pluginName)}/ui`,
  verbose: true,
  abortOnFail: false
});

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
const createAggregate = {
  type: 'add',
  path: 'src/Aggregates/{{properCase name}}/{{properCase name}}Aggregate.re',
  templateFile: 'plop-templates/Aggregate/Aggregate.re.hbs'
};
const addAggregateToMain = {
  type: "modify",
  path: "src/Main.re",
  pattern: /(~aggregates\W[\S\s]*?\[\|)/,
  template: "$1(module {{properCase name}}Aggregate),",
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
const createReadModel = {
  type: 'add',
  path: 'src/ReadModels/{{properCase name}}/{{properCase name}}ReadModel.re',
  templateFile: 'plop-templates/ReadModel/ReadModel.re.hbs'
};
const addReadModelToMain = {
  type: "modify",
  path: "src/Main.re",
  pattern: /(~readModels\W[\S\s]*?\[\|)/,
  template: "$1(module {{properCase name}}ReadModel),",
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
  pattern: /(type state = {)\.?([\S\s]*?)(?<!status\W[\S\s]*?)(};)/,
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
  template: "$1status: {{properCaseWithOptionalParams status}},",
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
  pattern: /(type state = {)\.?([\S\s]*?)(?<!status\W[\S\s]*?)(};)/,
  template: "$1status,$2$3",
};
const addStatusFieldToViewInit = {
  type: "modify",
  path: "src/ReadModels/{{properCase aggregateName}}/{{properCase aggregateName}}View.re",
  pattern: /(let init\W[\S\s]*?\[[\S\s]*?{)([\S\s]*?)(?<!let init\W[\S\s]*?status\W[\S\s]*?)(\])/,
  template: "$1status: {{properCaseWithOptionalParams status}},$2$3",
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
  pattern: /(?<=let execute\W[\S\s]*?)(switch \(command\)[\S\s]*?)(\n *)(})/g,
  template: "$1$2| {{properCaseWithOptionalParams command}} => [{{properCaseWithOptionalParams event}}] // TODO: check generated implementation$2$3",
};
const addCommandToBehaviourExecute = {
  type: "modify",
  path: "src/Aggregates/{{properCase aggregateName}}/{{properCase aggregateName}}Behaviour.re",
  pattern: /(?<=let execute\W[\S\s]*?)(switch \(command\)[\S\s]*?)(\n *)(})/g,
  template: "$1$2| {{properCaseWithOptionalParams command}} => [] // TODO: add implementation$2$3",
};
const addCommandToApiMutation = {
  type: "modify",
  path: "src/API/{{properCase aggregateName}}/{{properCase aggregateName}}Api.re",
  pattern: /(let mutationsSchema[\S\s]*?)(\|\};)/,
  templateFile: "plop-templates/API/addCommandToApiMutation.re.hbs",
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
  pattern: /(?<=let apply\W[\S\s]*?)(switch \(event\)[\S\s]*?)(\n *)(})/g,
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

const createEventMappings = {
  type: 'add',
  path: 'src/Aggregates/{{properCase target}}/{{properCase target}}EventMappings.re',
  templateFile: "plop-templates/Aggregate/EventMappings.re.hbs",
  abortOnFail: false,
};
const addEventMappingsToAggregate = {
  type: "modify",
  path: "src/Aggregates/{{properCase target}}/{{properCase target}}Aggregate.re",
  pattern: /\(Reventless.NoEventMappings.Make\(.*?\)\)/,
  template: "{{properCase target}}EventMappings",
};
const addMappingToEventMappings = {
  type: "modify",
  path: "src/Aggregates/{{properCase target}}/{{properCase target}}EventMappings.re",
  pattern: /(module type Mapping[\S\s]*?\[\|)/,
  templateFile: "plop-templates/Aggregate/addMappingToEventMappings.re.hbs",
};

export default function (plop) {
  additionalActionTypes(plop);

  plop.setGenerator('Project', {
    prompts: [{
      type: 'input',
      name: 'projectName',
      message: 'Project name:'
    }, {
      type: 'input',
      name: 'pulumiOrganization',
      message: 'Pulumi organization:'
    }],
    actions: data => {
      return [
        createProjectFiles,
        gitInitPlatform(data),
        npmInstallApi(data),
        rebuildApi(data),
        npmInstallCore(data),
        rebuildCore(data),
      ]
    }
  });
  plop.setGenerator('Plugin', {
    prompts: [{
      type: 'input',
      name: 'projectName',
      message: 'Project name:'
    }, {
      type: 'input',
      name: 'pluginName',
      message: 'Plugin name:'
    }, {
      type: 'input',
      name: 'gitLabProjectId',
      message: 'GitLab ProjectId:'
    }, {
      type: 'input',
      name: 'pulumiOrganization',
      message: 'Pulumi organization:'
    }],
    actions: data => [
      createPluginFiles,
      gitInitPlugin(plop, data),
      npmInstallPlugin(plop, data),
      rebuildPlugin(plop, data),
      npmInstallUi(plop, data),
      rebuildUi(plop, data)
    ]
  });
  plop.setGenerator('Aggregate+ReadModel', {
    prompts: [{
      type: 'input',
      name: 'name',
      message: 'Aggregate+ReadModel name:'
    }],
    actions: [
      createSpec,
      createBehaviour,
      createAggregate,
      addAggregateToMain,
      createTestFixture,
      createBehaviourTest,
      createView,
      createReadModel,
      addReadModelToMain,
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
      createAggregate,
      addAggregateToMain,
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
      createReadModel,
      addReadModelToMain,
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
    },
    {
      type: 'confirm',
      default: false,
      name: 'addMutation',
      message: 'Add Mutation?'
    }],
    actions: function (data) {
      var actions = [
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
      ];
      if (data.addMutation) {
        actions.push(addCommandToApiMutation);
      }
      return actions;
    },
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
    },
    {
      type: 'confirm',
      default: false,
      name: 'addMutation',
      message: 'Add Mutation?'
    }],
    actions: function (data) {
      var actions = [
        addCommandToSpec,
        addCommandToBehaviourCreate,
        addCommandToBehaviourExecute,
        addCommandToBehaviourTest
      ];
      if (data.addMutation) {
        actions.push(addCommandToApiMutation);
      }
      return actions;
    },
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
  plop.setGenerator('EventMapping', {
    prompts: [{
      type: 'input',
      name: 'target',
      message: 'Target:'
    },
    {
      type: 'input',
      name: 'source',
      message: 'Source:'
    }],
    actions: [
      createEventMappings,
      addEventMappingsToAggregate,
      addMappingToEventMappings,
    ]
  });

  plop.setHelper('pluralize', (name) =>
    pluralize.plural(plop.getHelper("properCase")(name)));

  plop.setHelper('properCaseWithoutOptionalParams', (txt) => txt.split("(")[0]);

  plop.setHelper('properCaseWithOptionalParams', (txt) => {
    const parts = txt.split("(");
    return plop.getHelper("properCase")(parts[0]) + (parts[1] ? '(' + parts[1] : '');
  });
};