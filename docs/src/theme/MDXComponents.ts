import type {MDXComponents as MDXComponentsType} from 'mdx/types';
import MDXComponentsOriginal from '@theme-original/MDXComponents';

import Checklist from '../components/mdx/Checklist';
import Invariant from '../components/mdx/Invariant';
import Pitfall from '../components/mdx/Pitfall';
import Why from '../components/mdx/Why';

const components: MDXComponentsType = {
    ...MDXComponentsOriginal,
    Checklist,
    Invariant,
    Pitfall,
    Why,
};

export default components;
