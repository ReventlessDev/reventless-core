// @ts-check
// `@type` JSDoc annotations allow editor autocompletion and type checking
// (when paired with `@ts-check`).
// There are various equivalent ways to declare your Docusaurus config.
// See: https://docusaurus.io/docs/api/docusaurus-config

import { themes as prismThemes } from "prism-react-renderer";

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
          editUrl:
            "https://gitlab.com/reventless/reventless-universe/-/tree/main/packages/doc/",
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
            href: "https://gitlab.com/reventless/reventless-universe",
            label: "GitLab",
            position: "right",
          },
        ],
      },
      footer: {
        style: "dark",
        links: [
          {
            title: "Documentation",
            items: [
              {
                label: "Getting Started",
                to: "/docs/",
              },
              {
                label: "Components",
                to: "/docs/reventless-components-overview",
              },
            ],
          },
          {
            title: "Resources",
            items: [
              {
                label: "ReScript",
                href: "https://rescript-lang.org/",
              },
              {
                label: "Pulumi",
                href: "https://www.pulumi.com/",
              },
              {
                label: "AWS Serverless",
                href: "https://aws.amazon.com/serverless/",
              },
            ],
          },
          {
            title: "More",
            items: [
              {
                label: "GitLab",
                href: "https://gitlab.com/reventless/reventless-universe",
              },
            ],
          },
        ],
        copyright: `Copyright © ${new Date().getFullYear()} Reventless. Built for serverless.`,
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
            /* MESSAGES */
            .command > circle,
            rect[name="CommandSource"] {
              stroke: #66f;
              fill: #fff;
              r: 45px;
              }
            .command .nodeLabel,
            rect[name="CommandSource"] {
              color: #66f;
              }

            .event > circle {
              stroke: #fa0;
              fill:none;
              }
            .event .nodeLabel {
              color: #fa0;
              }

            /* REVENTLESS COMPONENTS */
            .aggregate > rect,
            rect[name="Aggregate"] {
              fill: #ff6;
              stroke: #333;
              }
            .aggregate .nodeLabel {
              color:#333;
            }

            .readmodel > rect {
              fill: #9c5;
              stroke: #333;
              }
            .readmodel .nodeLabel {
              color: #333;
            }

            .eventmapper > rect {
              fill: #99f;
              stroke: #fa0;
              }
            .eventmapper .nodeLabel {
              }

            .task > rect {
              fill: #f9f;
              stroke:#333;
              }
            .task .nodeLabel {
              color: #333;
            }

            .sideeffecthandler > rect {
              fill: #f9f;
              stroke: #ff0;
              }
            .sideeffecthandler .nodeLabel {
            }

            .commandtopic > rect {
              fill: #88ccff;
              /*fill: #fff;*/
              }
            .commandtopic .nodeLabel {
              /*color: #66f;*/
              }
            
            .eventtopic > rect {
            /* TODO */
            }

            .client > rect {
            /* TODO */
            }

            /* HELPER */
            .parameter > rect,
            rect[name="Behaviour"] {
              fill: #f90;
              stroke: #f90;
            }
            .target > rect,
            .source > rect {
              stroke: none;
              fill: none;
            }
            `,
        },
      },
    }),
};

export default config;
