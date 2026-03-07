// @ts-check

/** @type {import('@docusaurus/plugin-content-docs').SidebarsConfig} */
const sidebars = {
  providersSidebar: [
    'index',
    'get-started',
    'adapter-pattern',
    {
      type: 'category',
      label: 'InMemory',
      items: [
        'in-memory/index',
        'in-memory/get-started',
        {
          type: 'category',
          label: 'Core Event Sourcing',
          items: [
            'in-memory/adapters/eventlog',
            'in-memory/adapters/commandtopic',
            'in-memory/adapters/eventtopic',
            'in-memory/adapters/eventcollector',
          ],
        },
        {
          type: 'category',
          label: 'Data Storage',
          items: [
            'in-memory/adapters/querydb',
            'in-memory/adapters/task',
          ],
        },
        {
          type: 'category',
          label: 'Supporting Services',
          items: [
            'in-memory/adapters/commandgenerator',
            'in-memory/adapters/counter',
            'in-memory/adapters/heartbeat',
            'in-memory/adapters/queryengine',
            'in-memory/adapters/scheduledpublisher',
            'in-memory/adapters/sideeffecthandler',
          ],
        },
        {
          type: 'category',
          label: 'DCB',
          items: [
            'in-memory/adapters/dcbeventlog',
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
        {
          type: 'category',
          label: 'Core Event Sourcing',
          items: [
            'aws/adapters/eventlog',
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
  ],
};

export default sidebars;
