import React from 'react';
import clsx from 'clsx';

type Props = {
    title: string;
    children: React.ReactNode;
    className?: string;
};

export default function Callout({title, children, className}: Props) {
    return (
        <section className={clsx('jzx-callout', className)}>
            <div className="jzx-callout__title">{title}</div>
            <div className="jzx-callout__body">{children}</div>
        </section>
    );
}

