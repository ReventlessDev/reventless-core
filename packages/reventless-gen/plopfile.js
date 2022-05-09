// assumtions:
// - code is well indented (regex's check for number of spaces)
// limitations:
// - after some generations code has to be reformatted (i.e. saved)
// - Command Add and Event Added are generated and used for each new Status

import pluralize from 'pluralize';
import additionalActionTypes from './additionalActionTypes.js';

import * as Aggregate from './plop/Aggregate.js';
import * as API from './plop/API.js';
import * as Command from './plop/Command.js';
import * as Event from './plop/Event.js';
import * as EventMapping from './plop/EventMapping.js';
import * as Plugin from './plop/Plugin.js';
import * as PluginSpec from './plop/PluginSpec.js';
import * as Project from './plop/Project.js';
import * as ReadModel from './plop/ReadModel.js';
import * as Status from './plop/Status.js';

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
        Project.createProjectFiles,
        Project.npmInstallApi(data),
        Project.rebuildApi(data),
        Project.npmInstallCore(data),
        Project.rebuildCore(data),
        Project.gitInitPlatform(data),
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
      Plugin.createPluginFiles,
      Plugin.npmInstallPlugin(plop, data),
      Plugin.rebuildPlugin(plop, data),
      Plugin.npmInstallUi(plop, data),
      Plugin.rebuildUi(plop, data),
      Plugin.gitInitPlugin(plop, data),
    ]
  });
  plop.setGenerator('PluginSpec', {
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
      name: 'extensionPointName',
      message: 'ExtensionPoint name:'
    }],
    actions: data => [
      PluginSpec.createPluginSpecFiles,
      PluginSpec.npmInstallPluginSpec(plop, data),
      PluginSpec.rebuildPluginSpec(plop, data),
      PluginSpec.gitInitPluginSpec(plop, data),
    ]
  });
  plop.setGenerator('Aggregate+ReadModel', {
    prompts: [{
      type: 'input',
      name: 'name',
      message: 'Aggregate+ReadModel name:'
    }],
    actions: [
      Aggregate.createSpec,
      Aggregate.createBehaviour,
      Aggregate.createAggregate,
      Aggregate.addAggregateToMain,
      Aggregate.createTestFixture,
      Aggregate.createBehaviourTest,
      ReadModel.createView,
      ReadModel.createReadModel,
      ReadModel.addReadModelToMain,
      ReadModel.createViewTest,
      API.createApi
    ]
  });
  plop.setGenerator('Aggregate', {
    prompts: [{
      type: 'input',
      name: 'name',
      message: 'Aggregate name:'
    }],
    actions: [
      Aggregate.createSpec,
      Aggregate.createBehaviour,
      Aggregate.createAggregate,
      Aggregate.addAggregateToMain,
      Aggregate.createTestFixture,
      Aggregate.createBehaviourTest,
    ]
  });
  plop.setGenerator('ReadModel', {
    prompts: [{
      type: 'input',
      name: 'name',
      message: 'ReadModel name:'
    }],
    actions: [
      ReadModel.createView,
      ReadModel.createReadModel,
      ReadModel.addReadModelToMain,
      ReadModel.createViewTest,
      API.createApi
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
      Status.addEmptyTypeStatusToSpec,
      Status.addStatusToSpec,
      Status.addStatusFieldToBehaviourState,
      Status.addStatusFieldToBehaviourInit,
      Status.addStatusToBehaviourExecute,
      Status.addStatusSwitchToBehaviourExecute,
      Status.addStatusToBehaviourApply,
      Status.addStatusSwitchToBehaviourApply,
      Status.addStatusFieldToViewState,
      Status.addStatusFieldToViewInit,
      Status.addStatusToViewApply,
      Status.addStatusSwitchToViewApply,
      Status.addStatusFieldToTestFixture
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
        Command.addCommandToSpec,
        Command.addCommandToBehaviourCreate,
        Command.addCommandAndEventToBehaviourExecute,
        Command.addCommandAndEventToBehaviourTest,
        Event.addEventToSpec,
        Event.addEventToBehaviourInit,
        Event.addEventToBehaviourApply,
        Event.addEventToViewInit,
        Event.addEventToViewApply,
        Event.addEventToViewTest
      ];
      if (data.addMutation) {
        actions.push(Command.addCommandToApiMutation);
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
        Command.addCommandToSpec,
        Command.addCommandToBehaviourCreate,
        Command.addCommandToBehaviourExecute,
        Command.addCommandToBehaviourTest
      ];
      if (data.addMutation) {
        actions.push(Command.addCommandToApiMutation);
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
      Event.addEventToSpec,
      Event.addEventToBehaviourInit,
      Event.addEventToBehaviourApply,
      Event.addEventToViewInit,
      Event.addEventToViewApply,
      Event.addEventToViewTest
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
      EventMapping.createEventMappings,
      EventMapping.addEventMappingsToAggregate,
      EventMapping.addMappingToEventMappings,
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