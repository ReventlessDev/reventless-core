// @ts-check

/** @type {import('@docusaurus/plugin-content-docs').SidebarsConfig} */
const sidebars = {
  awsSidebar: [
    'index',
    'get-started',
    {
      type: 'category',
      label: 'Core Event Sourcing',
      items: [
        'adapters/eventlog',
        'adapters/commandtopic',
        'adapters/eventtopic',
        'adapters/eventcollector',
      ],
    },
    {
      type: 'category',
      label: 'Data Storage',
      items: [
        'adapters/querydb',
        'adapters/task',
      ],
    },
    {
      type: 'category',
      label: 'Supporting Services',
      items: [
        'adapters/commandgenerator',
        'adapters/counter',
        'adapters/heartbeat',
        'adapters/queryengine',
        'adapters/scheduledpublisher',
        'adapters/statetopic',
      ],
    },
  ],
};

export default sidebars;
