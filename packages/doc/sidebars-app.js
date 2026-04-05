// @ts-check

/** @type {import('@docusaurus/plugin-content-docs').SidebarsConfig} */
const sidebars = {
  appSidebar: [
    'index',
    'get-started',
    'aggregates',
    'dcb-slices',
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
      label: 'Concepts',
      items: [
        'concepts/aggregate-extension-connection',
        'concepts/dcb',
        'concepts/statechangeslice-usage',
        'concepts/stateviewslice-usage',
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
    {
      type: 'category',
      label: 'AI-Assisted Development',
      items: [
        'ai-assisted/index',
        'ai-assisted/getting-started',
        'ai-assisted/describe-your-domain',
        'ai-assisted/architecture-decisions',
        'ai-assisted/generated-code-walkthrough',
        'ai-assisted/iterating',
      ],
    },
    'glossary',
  ],
};

export default sidebars;
