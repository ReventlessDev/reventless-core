// @ts-check

/**
 * Two halves, deliberately: a **spine** you read in order while building your
 * first application, and a **reference** you look things up in. Anything an app
 * developer never writes — the infrastructure components the framework wires
 * for you — lives in Contributing, not here.
 *
 * @type {import('@docusaurus/plugin-content-docs').SidebarsConfig}
 */
const sidebars = {
  appSidebar: [
    'index',
    'get-started',
    {
      type: 'category',
      label: 'Model your domain',
      collapsed: false,
      items: [
        'aggregate-vs-dcb-decision-guide',
        'concepts/dcb',
      ],
    },
    {
      type: 'category',
      label: 'Write specs',
      collapsed: false,
      items: [
        'aggregates',
        'dcb-slices',
        'components/aggregate',
        'components/statechangeslice',
        'concepts/statechangeslice-usage',
        'components/automationslice',
        'components/inboundtranslationslice',
        'components/outboundtranslationslice',
        'components/task',
        'components/sideeffecthandler',
      ],
    },
    {
      type: 'category',
      label: 'Write scenarios',
      collapsed: false,
      items: [
        'given-when-then',
        'running-tests',
      ],
    },
    {
      type: 'category',
      label: 'Views and UI',
      collapsed: false,
      items: [
        'components/readmodel',
        'components/stateviewslice',
        'concepts/stateviewslice-usage',
        'ui-configuration',
        'authorization',
      ],
    },
    {
      type: 'category',
      label: 'Connect plugins',
      collapsed: false,
      items: [
        'plugin-system',
        'components/plugin',
        'components/extensionpoint',
        'components/extension',
        'concepts/aggregate-extension-connection',
      ],
    },
    'local-development',
    {
      type: 'category',
      label: 'Reference',
      items: [
        'component-overview',
        'reventless-ppx',
        'graphql-api-guide',
        'rescript-syntax',
        'querydb-key-design-guide',
        'seeding-guide',
        'dcb-usage',
        'mixed-source-readmodel',
        'mixed-source-automationslice',
        'concepts/directives',
        'platform-and-plugin-guide',
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
        'writing-unit-tests',
      ],
    },
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
    {
      type: 'category',
      label: 'Troubleshooting',
      items: [
        'troubleshooting/common-issues',
      ],
    },
    'glossary',
  ],
};

export default sidebars;
