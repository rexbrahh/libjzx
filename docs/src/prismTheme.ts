import type {PrismTheme} from 'prism-react-renderer';

const prismTheme: PrismTheme = {
  plain: {
    color: '#c9d1d9',
    backgroundColor: '#0b0b0b',
  },
  styles: [
    {
      types: ['comment', 'prolog', 'doctype', 'cdata'],
      style: {
        color: '#9ea3a8',
        fontStyle: 'italic',
      },
    },
    {
      types: ['punctuation'],
      style: {
        color: '#c9d1d9',
      },
    },
    {
      types: [
        'keyword', // if/else/return/for (C + Zig)
        'builtin', // Zig builtins like @import(...)
        'builtin-type', // Zig builtin types like u32
        'directive', // C preprocessor directive body
        'directive-hash', // the leading '#'
        'macro',
        'macro-name',
      ],
      style: {
        color: '#ff7b72',
        fontWeight: '600',
      },
    },
    {
      types: ['operator'],
      style: {
        color: '#ff7b72',
      },
    },
    {
      types: ['function'],
      style: {
        color: '#d2a8ff',
      },
    },
    {
      types: ['class-name'],
      style: {
        color: '#ffa657',
      },
    },
    {
      types: ['property', 'variable', 'parameter', 'expression'],
      style: {
        color: '#c9d1d9',
      },
    },
    {
      types: ['string', 'char', 'attr-value', 'regex', 'url'],
      style: {
        color: '#85befd',
      },
    },
    {
      types: ['number', 'boolean', 'constant', 'symbol'],
      style: {
        color: '#f2cc60',
      },
    },
    {
      types: ['important', 'bold'],
      style: {
        fontWeight: '700',
      },
    },
    {
      types: ['italic'],
      style: {
        fontStyle: 'italic',
      },
    },
    {
      types: ['deleted'],
      style: {
        color: '#ff7b72',
        textDecorationLine: 'line-through',
      },
    },
    {
      types: ['inserted'],
      style: {
        color: '#7ee787',
        textDecorationLine: 'underline',
      },
    },
    {
      types: ['tag', 'attr-name', 'selector'],
      style: {
        color: '#85befd',
      },
    },
  ],
};

export default prismTheme;
