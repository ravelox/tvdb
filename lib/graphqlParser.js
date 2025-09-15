'use strict';

function syntaxError(message) {
  const err = new Error(message);
  err.expose = true;
  return err;
}

class GraphQLParser {
  constructor(source) {
    this.source = source;
    this.length = source.length;
    this.position = 0;
  }

  parse() {
    this.skipIgnored();
    this.consumeOperationType();
    this.skipIgnored();
    const selection = this.parseSelectionSet();
    this.skipIgnored();
    if (!this.isEOF()) {
      throw syntaxError('Unexpected token after GraphQL selection');
    }
    return selection;
  }

  consumeOperationType() {
    const keyword = this.peekWord();
    if (!keyword) return;
    if (keyword === 'query' || keyword === 'mutation' || keyword === 'subscription') {
      this.position += keyword.length;
      this.skipIgnored();
      const name = this.peekWord();
      if (name) {
        this.position += name.length;
      }
    }
  }

  parseSelectionSet() {
    this.expectChar('{');
    this.skipIgnored();
    const field = this.parseField();
    this.skipIgnored();
    if (this.peekChar() !== '}') {
      throw syntaxError('Only a single root field is supported');
    }
    this.advance();
    return field;
  }

  parseField() {
    const firstName = this.readName();
    if (!firstName) {
      throw syntaxError('Expected field name');
    }
    let fieldName = firstName;
    let alias = null;
    this.skipIgnored();
    if (this.peekChar() === ':') {
      this.advance();
      this.skipIgnored();
      const secondName = this.readName();
      if (!secondName) {
        throw syntaxError('Expected field name after alias');
      }
      alias = firstName;
      fieldName = secondName;
      this.skipIgnored();
    }
    const args = this.peekChar() === '(' ? this.parseArguments() : {};
    this.skipIgnored();
    if (this.peekChar() === '{') {
      this.skipSelectionSet();
      this.skipIgnored();
    }
    return { field: fieldName, alias: alias || fieldName, args };
  }

  parseArguments() {
    const args = {};
    this.expectChar('(');
    this.skipIgnored();
    while (this.peekChar() !== ')') {
      const name = this.readName();
      if (!name) {
        throw syntaxError('Expected argument name');
      }
      this.skipIgnored();
      this.expectChar(':');
      this.skipIgnored();
      args[name] = this.parseValue();
      this.skipIgnored();
      const next = this.peekChar();
      if (next === ',') {
        this.advance();
        this.skipIgnored();
      } else if (next !== ')') {
        throw syntaxError('Expected "," or ")" in argument list');
      }
    }
    this.advance();
    return args;
  }

  parseValue() {
    this.skipIgnored();
    const ch = this.peekChar();
    if (ch === '"') {
      return this.readString();
    }
    if (ch === '[') {
      return this.readList();
    }
    if (ch === '{') {
      return this.readObject();
    }
    if (ch === '-' || this.isDigit(ch)) {
      return this.readNumber();
    }
    if (ch === '$') {
      throw syntaxError('Variables are not supported');
    }
    const word = this.readName();
    if (!word) {
      throw syntaxError('Unexpected token in value');
    }
    if (word === 'true') return true;
    if (word === 'false') return false;
    if (word === 'null') return null;
    return word;
  }

  readList() {
    const list = [];
    this.expectChar('[');
    this.skipIgnored();
    while (this.peekChar() !== ']') {
      list.push(this.parseValue());
      this.skipIgnored();
      const next = this.peekChar();
      if (next === ',') {
        this.advance();
        this.skipIgnored();
      } else if (next !== ']') {
        throw syntaxError('Expected "," or "]" in list');
      }
    }
    this.advance();
    return list;
  }

  readObject() {
    const obj = {};
    this.expectChar('{');
    this.skipIgnored();
    while (this.peekChar() !== '}') {
      const name = this.readName();
      if (!name) {
        throw syntaxError('Expected object field name');
      }
      this.skipIgnored();
      this.expectChar(':');
      this.skipIgnored();
      obj[name] = this.parseValue();
      this.skipIgnored();
      const next = this.peekChar();
      if (next === ',') {
        this.advance();
        this.skipIgnored();
      } else if (next !== '}') {
        throw syntaxError('Expected "," or "}" in object');
      }
    }
    this.advance();
    return obj;
  }

  readNumber() {
    let start = this.position;
    if (this.peekChar() === '-') {
      this.advance();
    }
    if (this.peekChar() === '0') {
      this.advance();
    } else if (this.isDigit(this.peekChar())) {
      while (this.isDigit(this.peekChar())) {
        this.advance();
      }
    } else {
      throw syntaxError('Invalid number literal');
    }
    if (this.peekChar() === '.') {
      this.advance();
      if (!this.isDigit(this.peekChar())) {
        throw syntaxError('Invalid decimal literal');
      }
      while (this.isDigit(this.peekChar())) {
        this.advance();
      }
    }
    const ch = this.peekChar();
    if (ch === 'E' || ch === 'e') {
      this.advance();
      const sign = this.peekChar();
      if (sign === '+' || sign === '-') {
        this.advance();
      }
      if (!this.isDigit(this.peekChar())) {
        throw syntaxError('Invalid exponent literal');
      }
      while (this.isDigit(this.peekChar())) {
        this.advance();
      }
    }
    const raw = this.source.slice(start, this.position);
    const value = Number(raw);
    if (!Number.isFinite(value)) {
      throw syntaxError('Invalid numeric value');
    }
    return value;
  }

  readString() {
    if (this.peekTripleQuote()) {
      return this.readBlockString();
    }
    this.expectChar('"');
    let result = '';
    while (!this.isEOF()) {
      const ch = this.peekChar();
      if (ch === '"') {
        this.advance();
        return result;
      }
      if (ch === '\\') {
        result += this.readEscapedChar();
      } else {
        result += ch;
        this.advance();
      }
    }
    throw syntaxError('Unterminated string literal');
  }

  readBlockString() {
    this.advance();
    this.advance();
    this.advance();
    let result = '';
    while (!this.isEOF()) {
      if (this.peekTripleQuote()) {
        this.advance();
        this.advance();
        this.advance();
        return result;
      }
      const ch = this.peekChar();
      result += ch;
      this.advance();
    }
    throw syntaxError('Unterminated block string literal');
  }

  readEscapedChar() {
    this.advance();
    const ch = this.peekChar();
    if (ch == null) {
      throw syntaxError('Unterminated escape sequence');
    }
    this.advance();
    switch (ch) {
      case '"':
      case '\\':
      case '/':
        return ch;
      case 'b':
        return '\b';
      case 'f':
        return '\f';
      case 'n':
        return '\n';
      case 'r':
        return '\r';
      case 't':
        return '\t';
      case 'u':
        return this.readUnicodeEscape();
      default:
        throw syntaxError('Invalid escape sequence');
    }
  }

  readUnicodeEscape() {
    let hex = '';
    for (let i = 0; i < 4; i += 1) {
      const ch = this.peekChar();
      if (!this.isHexDigit(ch)) {
        throw syntaxError('Invalid unicode escape');
      }
      hex += ch;
      this.advance();
    }
    return String.fromCharCode(parseInt(hex, 16));
  }

  skipSelectionSet() {
    this.expectChar('{');
    let depth = 1;
    while (depth > 0 && !this.isEOF()) {
      const ch = this.peekChar();
      if (ch === '"') {
        this.readString();
        continue;
      }
      if (this.peekTripleQuote()) {
        this.readBlockString();
        continue;
      }
      if (ch === '{') {
        depth += 1;
      } else if (ch === '}') {
        depth -= 1;
      }
      this.advance();
    }
    if (depth !== 0) {
      throw syntaxError('Unterminated selection set');
    }
  }

  readName() {
    const start = this.position;
    if (!this.isNameStart(this.peekChar())) {
      return null;
    }
    this.advance();
    while (this.isNameContinue(this.peekChar())) {
      this.advance();
    }
    return this.source.slice(start, this.position);
  }

  peekWord() {
    const start = this.position;
    const name = this.readName();
    if (!name) return null;
    this.position = start;
    return name;
  }

  skipIgnored() {
    while (!this.isEOF()) {
      const ch = this.peekChar();
      if (this.isWhitespace(ch)) {
        this.advance();
        continue;
      }
      if (ch === '#') {
        this.advance();
        while (!this.isEOF() && !this.isLineTerminator(this.peekChar())) {
          this.advance();
        }
        continue;
      }
      break;
    }
  }

  expectChar(expected) {
    const ch = this.peekChar();
    if (ch !== expected) {
      throw syntaxError(`Expected "${expected}"`);
    }
    this.advance();
  }

  peekChar() {
    return this.source[this.position] || null;
  }

  advance() {
    this.position += 1;
    return this.source[this.position];
  }

  peekTripleQuote() {
    return this.source.slice(this.position, this.position + 3) === '"""';
  }

  isEOF() {
    return this.position >= this.length;
  }

  isWhitespace(ch) {
    return ch === ' ' || ch === '\t' || ch === '\n' || ch === '\r' || ch === ',';
  }

  isLineTerminator(ch) {
    return ch === '\n' || ch === '\r';
  }

  isNameStart(ch) {
    return (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') || ch === '_';
  }

  isNameContinue(ch) {
    return this.isNameStart(ch) || this.isDigit(ch);
  }

  isDigit(ch) {
    return ch >= '0' && ch <= '9';
  }

  isHexDigit(ch) {
    return this.isDigit(ch) || (ch >= 'A' && ch <= 'F') || (ch >= 'a' && ch <= 'f');
  }
}

function parseGraphQLQuery(source) {
  if (typeof source !== 'string') {
    throw syntaxError('Query must be a string');
  }
  const parser = new GraphQLParser(source.trim());
  return parser.parse();
}

module.exports = { parseGraphQLQuery };
