// @ts-check
// `@type` JSDoc annotations allow editor autocompletion and type checking
// (when paired with `@ts-check`).
// There are various equivalent ways to declare your Docusaurus config.
// See: https://docusaurus.io/docs/api/docusaurus-config

import {themes as prismThemes} from "prism-react-renderer";

/** @type {import('@docusaurus/types').Config} */
const config = {
  title: "Reventless",
  tagline: "Ship Value Fast",
  // TODO: favicon: "img/favicon.ico",

  // Set the production url of your site here
  url: "https://gitlab.com",
  // Set the /<baseUrl>/ pathname under which your site is served
  // For GitHub pages deployment, it is often '/<projectName>/'
  baseUrl: "/reventless/reventless-universe",

  // TODO:
  // GitHub pages deployment config.
  // If you aren't using GitHub pages, you don't need these.
  organizationName: "eviden", // Usually your GitHub org/user name.
  projectName: "reventless", // Usually your repo name.

  onBrokenLinks: "throw",
  onBrokenMarkdownLinks: "warn",

  // activate mermaid support
  // according to docusarus docs: https://docusaurus.io/docs/markdown-features/diagrams
  markdown: {
    mermaid: true,
  },

  themes: ["@docusaurus/theme-mermaid"],

  // Even if you don't use internationalization, you can use this field to set
  // useful metadata like html lang. For example, if your site is Chinese, you
  // may want to replace "en" with "zh-Hans".
  i18n: {
    defaultLocale: "en",
    locales: ["en"],
  },

  presets: [
    [
      "classic",
      /** @type {import('@docusaurus/preset-classic').Options} */
      ({
        docs: {
          sidebarPath: "./sidebars.js",
          // Please change this to your repo.
          // Remove this to remove the "edit this page" links.
          // FIXME:
          editUrl:
            "https://github.com/facebook/docusaurus/tree/main/packages/create-docusaurus/templates/shared/",
        },
        /*
        blog: {
          showReadingTime: true,
          feedOptions: {
            type: ["rss", "atom"],
            xslt: true,
          },
          // Please change this to your repo.
          // Remove this to remove the "edit this page" links.
          editUrl:
            "https://github.com/facebook/docusaurus/tree/main/packages/create-docusaurus/templates/shared/",
        },
        */
        theme: {
          customCss: "./src/css/custom.css",
        },
      }),
    ],
  ],

  themeConfig:
    /** @type {import('@docusaurus/preset-classic').ThemeConfig} */
    ({
      // Replace with your project's social card
      //image: 'img/docusaurus-social-card.jpg',
      navbar: {
        title: "Reventless",
        // logo: {
        //   alt: 'My Site Logo',
        //   src: 'img/logo.svg',
        // },
        items: [
          {
            type: "docSidebar",
            sidebarId: "docSidebar",
            position: "left",
            label: "Documentation",
          },
          // {
          //   type: 'docSidebar',
          //   sidebarId: 'tutorialSidebar',
          //   position: 'left',
          //   label: 'Tutorial',
          // },
          // { to: '/blog', label: 'Blog', position: 'left' },
          {
            href: "https://github.com/facebook/docusaurus",
            label: "GitHub",
            position: "right",
          },
        ],
      },
      footer: {
        // FIXME:
        style: "dark",
        links: [
          {
            title: "Docs",
            items: [
              {
                label: "Tutorial",
                to: "/docs/intro",
              },
            ],
          },
          {
            title: "Community",
            items: [
              {
                label: "Stack Overflow",
                href: "https://stackoverflow.com/questions/tagged/docusaurus",
              },
              {
                label: "Discord",
                href: "https://discordapp.com/invite/docusaurus",
              },
              {
                label: "Twitter",
                href: "https://twitter.com/docusaurus",
              },
            ],
          },
          {
            title: "More",
            items: [
              {
                label: "Blog",
                to: "/blog",
              },
              {
                label: "GitHub",
                href: "https://github.com/facebook/docusaurus",
              },
            ],
          },
        ],
        copyright: `Copyright © ${new Date().getFullYear()} My Project, Inc. Built with Docusaurus.`,
      },
      prism: {
        theme: prismThemes.github,
        darkTheme: prismThemes.dracula,
        additionalLanguages: ["rescript"],
      },
      mermaid: {
        options: {
          //maxTextSize: 50,
          // FIXME:
          themeCSS: `
            .cssClass > rect {
              fill: #f88;
              stroke: #f0f;
              }
            .cssClass .nodeLabel {
              color: #0ff;
              }

            .command > circle {
              stroke: #66f;
              fill:none;
              r: 45px;
              }
            .command .nodeLabel {
              color: #66f;
              }

            .event > circle {
              stroke: #fa0;
              fill:none;
              }
            .event .nodeLabel {
              color: #fa0;
              }

            .aggregate > rect {
              fill: #ff6;
              stroke: #333;
              }
            .aggregate .nodeLabel {
              color:#333;
            }
            `,

          /*
           */
        },
      },
    }),
};

export default config;
