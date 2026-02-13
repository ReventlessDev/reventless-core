/**
 * Creating a sidebar enables you to:
 - create an ordered group of docs
 - render a sidebar for each doc of that group
 - provide next/previous navigation

 The sidebars can be generated from the filesystem, or explicitly defined here.

 Create as many sidebars as you want.
 */

// @ts-check

/** @type {import('@docusaurus/plugin-content-docs').SidebarsConfig} */
const sidebars = {
  // Manual sidebar with ordering from general to specific
  docSidebar: [
    'index',
    'get-started',
    'development-process',
    'rescript-syntax',
    'component-overview',
    'unit-testing',
    {
      type: 'category',
      label: 'Components',
      items: [
        'reventless-components/aggregate',
        'reventless-components/readmodel',
        'reventless-components/plugin',
        'reventless-components/extension',
        'reventless-components/extensionpoint',
        'reventless-components/api',
        'reventless-components/task',
        'reventless-components/eventlog',
        'reventless-components/eventtopic',
        'reventless-components/commandtopic',
        'reventless-components/commandgenerator',
        'reventless-components/eventcollector',
        'reventless-components/eventmapper',
        'reventless-components/querydb',
        'reventless-components/counter',
        'reventless-components/heartbeat',
        'reventless-components/scheduler',
        'reventless-components/sideeffecthandler',
      ],
    },
    {
      type: 'category',
      label: 'Common Modules',
      items: [
        'reventless-common-modules/Id',
        'reventless-common-modules/config',
      ],
    },
    {
      type: 'category',
      label: 'AWS Adapters',
      items: [
        'aws-adapters/index',
        {
          type: 'category',
          label: 'Core Event Sourcing',
          items: [
            'aws-adapters/eventlog',
            'aws-adapters/commandtopic',
            'aws-adapters/eventtopic',
            'aws-adapters/eventcollector',
          ],
        },
        {
          type: 'category',
          label: 'Data Storage',
          items: [
            'aws-adapters/querydb',
            'aws-adapters/task',
          ],
        },
        {
          type: 'category',
          label: 'Supporting Services',
          items: [
            'aws-adapters/commandgenerator',
            'aws-adapters/counter',
            'aws-adapters/heartbeat',
            'aws-adapters/queryengine',
            'aws-adapters/scheduledpublisher',
            'aws-adapters/statetopic',
          ],
        },
      ],
    },
    {
      type: 'category',
      label: 'Inner Workings',
      items: [
        'inner-workings/framework-inner-workings',
        'inner-workings/component-structure-pattern',
        'inner-workings/messages',
        'inner-workings/runtime',
        'inner-workings/pulumi',
        'inner-workings/resources',
        'inner-workings/serialization',
      ],
    },
    {
      type: 'category',
      label: 'Troubleshooting',
      items: [
        'troubleshooting/common-issues',
      ],
    },
  ],
};

export default sidebars;
