// @ts-check

/** @type {import('@docusaurus/plugin-content-docs').SidebarsConfig} */
const sidebars = {
  onlineShopSidebar: [
    'get-started',
    {
      type: 'doc',
      id: 'aggregate-based',
      label: 'Aggregate based plugin',
    },
    {
      type: 'doc',
      id: 'dcb-based',
      label: 'DCB based plugin',
    },
    {
      type: 'category',
      label: 'Catalog',
      link: {
        type: 'generated-index',
        description: 'The Catalog bounded context — product listings and categories.',
      },
      items: [],
    },
    {
      type: 'category',
      label: 'Ordering',
      link: {
        type: 'generated-index',
        description: 'The Ordering bounded context — customers and orders.',
      },
      items: [],
    },
  ],
};

export default sidebars;
