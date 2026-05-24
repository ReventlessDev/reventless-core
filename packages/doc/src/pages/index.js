import clsx from 'clsx';
import Link from '@docusaurus/Link';
import useDocusaurusContext from '@docusaurus/useDocusaurusContext';
import Layout from '@theme/Layout';
import HomepageFeatures from '@site/src/components/HomepageFeatures';

import Heading from '@theme/Heading';
import styles from './index.module.css';

function HomepageHeader() {
  const {siteConfig} = useDocusaurusContext();
  return (
    <header className={clsx('hero', styles.heroBanner)}>
      <div className="container">
        <Heading as="h1" className={styles.heroTitle}>
          {siteConfig.title}
        </Heading>
        <p className={styles.heroSubtitle}>
          The spec-driven event platform — focus on your business, not technology
        </p>
        <p className={styles.heroDescription}>
          Your domain definition is the spec. Define events, commands, and read
          models in type-safe ReScript, and Reventless derives the rest — database
          schemas, GraphQL and MCP APIs, and AWS infrastructure. One source of
          truth: no glue code, no drift between layers. A type-safe, event-sourced
          CQRS platform that's production-ready and AI-native.
        </p>
        <div className={styles.buttons}>
          <Link
            className="button button--primary button--lg"
            to="/tutorials/get-started">
            Try the example
          </Link>
          <Link
            className="button button--secondary button--lg"
            to="/app/get-started">
            Build an app
          </Link>
          <Link
            className="button button--secondary button--lg"
            to="/framework/get-started">
            Contribute
          </Link>
        </div>
      </div>
    </header>
  );
}

const ReadingPaths = [
  {
    persona: 'Evaluator',
    question: '“What is Reventless? Should I use it?”',
    steps: [
      <><Link to="/app/">Introduction</Link> — what, why, who</>,
      <><Link to="/tutorials/get-started">Tutorial overview</Link></>,
      <><Link to="/tutorials/hybrid-based">Example walkthrough</Link></>,
    ],
  },
  {
    persona: 'App developer',
    question: '“I want to build something with Reventless.”',
    steps: [
      <>The <Link to="/tutorials/get-started">Tutorial spine</Link> — understand, run locally, deploy, test</>,
      <><Link to="/app/get-started">App Guide</Link> — build your own plugins</>,
      <><Link to="/infrastructure">Infrastructure</Link> — deploy to your own domain</>,
    ],
  },
  {
    persona: 'Contributor',
    question: '“I want to contribute to the framework.”',
    steps: [
      <><Link to="/framework/get-started">Contributing get-started</Link></>,
      <><Link to="/framework/internals/framework-internals">Framework internals</Link> (ordered)</>,
      <><Link to="/framework/internals/component-structure-pattern">Component-structure pattern</Link> → <Link to="/framework/internals/extending-the-framework">extending the framework</Link></>,
    ],
  },
];

function ReadingPathsSection() {
  return (
    <section className="margin-vert--lg">
      <div className="container">
        <Heading as="h2" className="text--center">
          Pick your path
        </Heading>
        <div className="row">
          {ReadingPaths.map((path, idx) => (
            <div key={idx} className="col col--4 margin-vert--md">
              <div className="card padding--md" style={{height: '100%'}}>
                <Heading as="h3">{path.persona}</Heading>
                <p><em>{path.question}</em></p>
                <ol>
                  {path.steps.map((step, i) => (
                    <li key={i}>{step}</li>
                  ))}
                </ol>
              </div>
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}

export default function Home() {
  return (
    <Layout
      title="The spec-driven event platform"
      description="Reventless is a type-safe, event-sourced CQRS platform for serverless applications. Define your domain as a spec in ReScript and derive database schemas, GraphQL and MCP APIs, and AWS infrastructure — production-ready and AI-native.">
      <HomepageHeader />
      <main>
        <HomepageFeatures />
        <ReadingPathsSection />
      </main>
    </Layout>
  );
}
