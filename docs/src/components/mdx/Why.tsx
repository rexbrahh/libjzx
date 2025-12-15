import React from 'react';
import Callout from './Callout';

type Props = {
    children: React.ReactNode;
};

export default function Why({children}: Props) {
    return <Callout title="Why">{children}</Callout>;
}

