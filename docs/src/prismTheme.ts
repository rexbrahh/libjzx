import type {PrismTheme} from 'prism-react-renderer';

const prismTheme: PrismTheme = {
  plain: {
    color: '#c2c6cc',
    backgroundColor: '#1b1b1d',
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
      types: ['punctuation', 'operator'],
      style: {
        color: '#c2c6cc',
      },
    },
    {
      types: ['keyword', 'tag', 'attr-name', 'selector'],
      style: {
        color: '#85befd',
        fontWeight: '600',
      },
    },
    {
      types: ['function', 'class-name', 'property', 'variable', 'parameter'],
      style: {
        color: '#ffffff',
      },
    },
    {
      types: ['string', 'char', 'attr-value', 'regex', 'url'],
      style: {
        color: '#ffffff',
      },
    },
    {
      types: ['number', 'boolean', 'constant', 'symbol', 'builtin'],
      style: {
        color: '#c2c6cc',
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
        color: '#ffffff',
        textDecorationLine: 'line-through',
      },
    },
    {
      types: ['inserted'],
      style: {
        color: '#ffffff',
        textDecorationLine: 'underline',
      },
    },
  ],
};

export default prismTheme;
