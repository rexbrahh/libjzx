import type {ReactNode} from 'react';
import Link from '@docusaurus/Link';
import useDocusaurusContext from '@docusaurus/useDocusaurusContext';
import Layout from '@theme/Layout';
import Heading from '@theme/Heading';

import styles from './index.module.css';

function HomepageHeader() {
  const {siteConfig} = useDocusaurusContext();
  return (
    <header className={styles.heroBanner}>
      <div className="container">
        <Heading as="h1" className={styles.heroTitle}>
          {siteConfig.title}
        </Heading>
        <p className={styles.heroSubtitle}>{siteConfig.tagline}</p>
        <div className={styles.buttons}>
          <Link
            className="button button--primary button--lg"
            to="/docs/intro">
            Read the docs
          </Link>
        </div>
      </div>
    </header>
  );
}

export default function Home(): ReactNode {
  const {siteConfig} = useDocusaurusContext();
  return (
    <Layout
      title={siteConfig.title}
      description="libjzx is a libxev-backed single-process actor runtime (early scaffold).">
      <HomepageHeader />
      <main className="container margin-vert--lg">
        <div className="row">
          <div className="col col--8 col--offset-2">
            <Heading as="h2">Start here</Heading>
            <ul>
              <li>
                <Link to="/docs/intro">Introduction</Link>
              </li>
              <li>
                <Link to="/docs/getting-started/installation">Installation</Link>
              </li>
              <li>
                <Link to="/docs/deep-dive/source-index">Source index (deep dive)</Link>
              </li>
              <li>
                <Link to="/docs/concepts/architecture">Architecture</Link>
              </li>
              <li>
                <Link to="/docs/reference/cli">CLI</Link>
              </li>
            </ul>
          </div>
        </div>
      </main>
    </Layout>
  );
}
