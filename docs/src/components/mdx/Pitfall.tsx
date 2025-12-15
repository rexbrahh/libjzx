import React from 'react';
import Callout from './Callout';

type Props = {
    children: React.ReactNode;
};

export default function Pitfall({children}: Props) {
    return <Callout title="Pitfall">{children}</Callout>;
}

