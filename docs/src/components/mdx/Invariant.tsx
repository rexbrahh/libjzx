import React from 'react';
import Callout from './Callout';

type Props = {
    children: React.ReactNode;
};

export default function Invariant({children}: Props) {
    return <Callout title="Invariant">{children}</Callout>;
}

