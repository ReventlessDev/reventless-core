// @ts-check

/** @type {import('@docusaurus/plugin-content-docs').SidebarsConfig} */
const sidebars = {
  infrastructureSidebar: [
    'index',
    {
      type: 'category',
      label: 'Local',
      items: [
        'local/index',
        'local/get-started',
        {
          type: 'category',
          label: 'Core Event Sourcing',
          items: [
            'local/adapters/eventlog',
            'local/adapters/dcbeventlog',
            'local/adapters/commandtopic',
            'local/adapters/eventtopic',
            'local/adapters/eventcollector',
          ],
        },
        {
          type: 'category',
          label: 'Data Storage',
          items: [
            'local/adapters/querydb',
            'local/adapters/task',
          ],
        },
        {
          type: 'category',
          label: 'Supporting Services',
          items: [
            'local/adapters/commandgenerator',
            'local/adapters/counter',
            'local/adapters/heartbeat',
            'local/adapters/queryengine',
            'local/adapters/scheduledpublisher',
            'local/adapters/sideeffecthandler',
          ],
        },
      ],
    },
    {
      type: 'category',
      label: 'AWS',
      items: [
        'aws/index',
        'aws/get-started',
        'aws/architecture',
        {
          type: 'category',
          label: 'Core Event Sourcing',
          items: [
            'aws/adapters/eventlog',
            'aws/adapters/dcbeventlog',
            'aws/adapters/commandtopic',
            'aws/adapters/eventtopic',
            'aws/adapters/eventcollector',
          ],
        },
        {
          type: 'category',
          label: 'Data Storage',
          items: [
            'aws/adapters/querydb',
            'aws/adapters/task',
          ],
        },
        {
          type: 'category',
          label: 'Supporting Services',
          items: [
            'aws/adapters/commandgenerator',
            'aws/adapters/counter',
            'aws/adapters/heartbeat',
            'aws/adapters/queryengine',
            'aws/adapters/scheduledpublisher',
            'aws/adapters/statetopic',
          ],
        },
      ],
    },
    {
      type: 'category',
      label: 'Guides',
      items: [
        'deployment-guide',
        'operating',
        'lambda-deployment',
        'aws-lambda-layer',
        'callback-hooks-and-adapter-wrapping',
        'ui-fragments-deployment',
        'custom-domain',
        'appsync-events-live-updates',
        'postgres-status',
        'postgres-aws-deployment',
        'local-persistence',
      ],
    },
    {
      // Authoring a provider is framework work, not operating an application.
      // The pages stay here beside the adapter reference they describe; the
      // Contributing sidebar links to them.
      type: 'category',
      label: 'Writing a provider',
      items: [
        'scaffolding-a-provider',
        'adapter-pattern',
      ],
    },
  ],
};

export default sidebars;
