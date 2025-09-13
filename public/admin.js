async function init() {
  const spec = await fetch('/openapi.json').then(r => r.json());
  const container = document.getElementById('endpoints');

  for (const [path, ops] of Object.entries(spec.paths || {})) {
    for (const [method, op] of Object.entries(ops)) {
      const section = document.createElement('section');
      const h3 = document.createElement('h3');
      h3.textContent = `${method.toUpperCase()} ${path}`;
      section.appendChild(h3);
      const form = document.createElement('form');

      // parameters (path & query)
      for (const param of op.parameters || []) {
        const div = document.createElement('div');
        const label = document.createElement('label');
        label.textContent = `${param.name} (${param.in})`;
        label.htmlFor = `${method}_${path}_${param.name}`;
        const input = document.createElement('input');
        input.id = label.htmlFor;
        input.name = param.name;
        input.type = param.schema?.type === 'integer' ? 'number' : 'text';
        div.appendChild(label);
        div.appendChild(input);
        form.appendChild(div);
      }

      // request body
      if (op.requestBody?.content?.['application/json']) {
        const div = document.createElement('div');
        const label = document.createElement('label');
        label.textContent = 'body (json)';
        label.htmlFor = `${method}_${path}_body`;
        const textarea = document.createElement('textarea');
        textarea.id = label.htmlFor;
        textarea.name = 'body';
        textarea.rows = 4;
        textarea.cols = 50;
        div.appendChild(label);
        div.appendChild(textarea);
        form.appendChild(div);
      }

      const button = document.createElement('button');
      button.type = 'submit';
      button.textContent = 'Send';
      form.appendChild(button);

      const pre = document.createElement('pre');
      form.appendChild(pre);

      form.addEventListener('submit', async (e) => {
        e.preventDefault();
        let url = path;
        const query = new URLSearchParams();
        let bodyText = null;
        for (const el of form.elements) {
          if (!el.name || el.type === 'submit') continue;
          if (el.name === 'body') {
            bodyText = el.value;
            continue;
          }
          const param = (op.parameters || []).find(p => p.name === el.name);
          if (!param) continue;
          const value = el.type === 'number' && el.value ? Number(el.value) : el.value;
          if (param.in === 'path') {
            url = url.replace(`{${param.name}}`, encodeURIComponent(value));
          } else if (param.in === 'query') {
            query.append(param.name, value);
          }
        }
        if (query.toString()) url += `?${query.toString()}`;
        const options = { method: method.toUpperCase() };
        if (bodyText !== null) {
          try {
            options.body = bodyText ? JSON.stringify(JSON.parse(bodyText)) : '';
          } catch (err) {
            pre.textContent = 'Invalid JSON body';
            return;
          }
          options.headers = { 'Content-Type': 'application/json' };
        }
        const res = await fetch(url, options);
        const text = await res.text();
        pre.textContent = text;
      });

      section.appendChild(form);
      container.appendChild(section);
    }
  }
}

init();
