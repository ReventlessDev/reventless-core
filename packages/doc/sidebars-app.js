// @ts-check

/** @type {import('@docusaurus/plugin-content-docs').SidebarsConfig} */
const sidebars = {
  appSidebar: [
    'index',
    'get-started',
    'aggregate-based-plugin',
    'dcb-based-plugin',
    'plugin-system',
    'component-overview',
    {
      type: 'category',
      label: 'Testing',
      items: [
        'running-tests',
        'writing-unit-tests',
      ],
    },
    {
      type: 'category',
      label: 'Architecture',
      items: [
        'architecture/aggregate-extension-connection',
        'architecture/dcb',
      ],
    },
    {
      type: 'category',
      label: 'Components',
      items: [
        'components/aggregate',
        'components/api',
        'components/automationslice',
        'components/commandgenerator',
        'components/commandtopic',
        'components/counter',
        'components/dcbeventlog',
        'components/eventcollector',
        'components/eventlog',
        'components/eventmapper',
        'components/eventtopic',
        'components/extension',
        'components/extensionpoint',
        'components/heartbeat',
        'components/inboundtranslationslice',
        'components/outboundtranslationslice',
        'components/plugin',
        'components/querydb',
        'components/readmodel',
        'components/scheduler',
        'components/sideeffecthandler',
        'components/statechangeslice',
        'components/stateviewslice',
        'components/task',
      ],
    },
    {
      type: 'category',
      label: 'Event Modeling',
      items: [
        'event-modeling/statechangeslice-usage',
        'event-modeling/stateviewslice-usage',
      ],
    },
    {
      type: 'category',
      label: 'Common Modules',
      items: [
        'common-modules/Id',
        'common-modules/identity',
        'common-modules/request-context',
        'common-modules/config',
      ],
    },
    {
      type: 'category',
      label: 'Troubleshooting',
      items: [
        'troubleshooting/common-issues',
      ],
    },
    'rescript-syntax',
  ],
};

export default sidebars;
