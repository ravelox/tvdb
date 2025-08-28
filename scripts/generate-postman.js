const fs = require('fs');
const path = require('path');

const specPath = path.resolve(__dirname, '..', 'openapi.json');
const spec = JSON.parse(fs.readFileSync(specPath, 'utf8'));
const baseUrl = (spec.servers && spec.servers[0] && spec.servers[0].url) || '';
const url = new URL(baseUrl || 'http://localhost');

const collection = {
  info: {
    name: spec.info && spec.info.title ? spec.info.title : 'API',
    description: spec.info && spec.info.description ? spec.info.description : '',
    version: spec.info && spec.info.version ? spec.info.version : '1.0.0',
    schema: 'https://schema.getpostman.com/json/collection/v2.1.0/collection.json'
  },
  item: []
};

// Group items by first tag
const folders = {};

for (const [route, methods] of Object.entries(spec.paths || {})) {
  for (const [method, op] of Object.entries(methods)) {
    const tag = (op.tags && op.tags[0]) || 'default';
    if (!folders[tag]) {
      folders[tag] = { name: tag, item: [] };
      collection.item.push(folders[tag]);
    }
    const item = {
      name: `${method.toUpperCase()} ${route}`,
      request: {
        method: method.toUpperCase(),
        url: {
          raw: baseUrl + route,
          protocol: url.protocol.replace(':', ''),
          host: url.hostname.split('.'),
          port: url.port || undefined,
          path: route.split('/').filter(Boolean)
        },
        description: op.summary || ''
      }
    };
    folders[tag].item.push(item);
  }
}

const outPath = path.resolve(__dirname, '..', 'tvdb.postman_collection.json');
fs.writeFileSync(outPath, JSON.stringify(collection, null, 2));
console.log('Postman collection written to', outPath);
