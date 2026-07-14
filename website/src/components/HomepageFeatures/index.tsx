import type {ReactNode} from 'react';
import clsx from 'clsx';
import Heading from '@theme/Heading';
import useBaseUrl from '@docusaurus/useBaseUrl';
import styles from './styles.module.css';

type FeatureItem = {
  title: string;
  imgSrc: string;
  description: ReactNode;
};

const FeatureList: FeatureItem[] = [
  {
    title: 'Local-First Persistence',
    imgSrc: '/img/database.png',
    description: (
      <>
        Treat your local database (like Drift) as the absolute primary source of truth. 
        Your Flutter app remains fully functional, fast, and responsive even with zero network connection.
      </>
    ),
  },
  {
    title: 'Smart Operation Queue',
    imgSrc: '/img/sync.png',
    description: (
      <>
        Automatically queue mutations offline, monitor network state changes, 
        and synchronize background tasks with built-in robust retry mechanisms and error handling.
      </>
    ),
  },
  {
    title: 'Highly Pluggable Design',
    imgSrc: '/img/plug.png',
    description: (
      <>
        Built using strict core contracts. Easily swap your storage engine (Drift, Hive, Isar) 
        or your network client (Dio, Http) to fit your project’s architecture perfectly.
      </>
    ),
  },
];

function Feature({title, imgSrc, description}: FeatureItem) {
  return (
    <div className={clsx('col col--4')}>
      <div className="text--center">
        {/* 
         
        */}
        <img 
          src={useBaseUrl(imgSrc)} 
          alt={title} 
          style={{ 
            width: '100%',               
            maxWidth: '380px',           
            aspectRatio: '1180 / 715',   
            objectFit: 'cover',          
            borderRadius: '10px',         
            boxShadow: '0 6px 16px rgba(0, 0, 0, 0.08)', 
            marginBottom: '16px' 
          }} 
        />
      </div>
      <div className="text--center padding-horiz--md">
        <Heading as="h3" style={{ marginTop: '16px' }}>{title}</Heading>
        <p>{description}</p>
      </div>
    </div>
  );
}

export default function HomepageFeatures(): ReactNode {
  return (
    <section className={styles.features}>
      <div className="container">
        <div className="row">
          {FeatureList.map((props, idx) => (
            <Feature key={idx} {...props} />
          ))}
        </div>
      </div>
    </section>
  );
}