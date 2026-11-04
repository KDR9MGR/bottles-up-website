// A small stand-in for the part of Go's template language that supabase/email-templates/*.html uses, so a test (or a preview) can see
// what each variant of an e-mail actually says. It understands exactly:
//   {{ .Field }}                                   output a value
//   {{- $name := eq .Field "literal" -}}           a yes/no variable ("-" trims the whitespace next to it)
//   {{ if $name }} ... {{ else if $other }} ... {{ else }} ... {{ end }}
// Anything else throws, so a template that starts using more than this cannot silently render wrongly in a test.

type Node =
  | { type: 'text'; value: string }
  | { type: 'out'; field: string }
  | { type: 'assign'; name: string; field: string; literal: string }
  | { type: 'if'; branches: { cond: string | null; body: Node[] }[] };

const ACTION = /\{\{(-\s)?([\s\S]*?)(\s-)?\}\}/g;

function tokenize(source: string): (string | { action: string })[] {
  const tokens: (string | { action: string })[] = [];
  let last = 0;
  for (const match of source.matchAll(ACTION)) {
    let text = source.slice(last, match.index);
    if (match[1]) text = text.replace(/\s+$/, '');
    if (text) tokens.push(text);
    tokens.push({ action: match[2].trim() });
    last = (match.index ?? 0) + match[0].length;
    if (match[3]) {
      const rest = source.slice(last);
      last += rest.length - rest.replace(/^\s+/, '').length;
    }
  }
  const tail = source.slice(last);
  if (tail) tokens.push(tail);
  return tokens;
}

function parse(tokens: (string | { action: string })[]): Node[] {
  let i = 0;
  function block(stopAt: string[]): { nodes: Node[]; stop: string | null } {
    const nodes: Node[] = [];
    while (i < tokens.length) {
      const token = tokens[i++];
      if (typeof token === 'string') {
        nodes.push({ type: 'text', value: token });
        continue;
      }
      const a = token.action;
      if (a === 'end' || a === 'else' || a.startsWith('else if ')) {
        if (!stopAt.includes(a === 'end' || a === 'else' ? a : 'else if')) throw new Error(`unexpected {{ ${a} }}`);
        return { nodes, stop: a };
      }
      let m: RegExpMatchArray | null;
      if ((m = a.match(/^\.([A-Za-z]+)$/))) nodes.push({ type: 'out', field: m[1] });
      else if ((m = a.match(/^(\$[a-z]+) := eq \.([A-Za-z]+) "([^"]*)"$/))) nodes.push({ type: 'assign', name: m[1], field: m[2], literal: m[3] });
      else if ((m = a.match(/^if (\$[a-z]+)$/))) {
        const branches: { cond: string | null; body: Node[] }[] = [];
        let cond: string | null = m[1];
        for (;;) {
          const { nodes: body, stop } = block(['else', 'else if', 'end']);
          branches.push({ cond, body });
          if (stop === 'end') break;
          if (stop === 'else') cond = null;
          else cond = (stop as string).replace(/^else if /, '');
          if (stop === null) throw new Error('{{ if }} without {{ end }}');
        }
        nodes.push({ type: 'if', branches });
      } else throw new Error(`unsupported template action: {{ ${a} }}`);
    }
    if (!stopAt.includes('eof')) throw new Error('{{ if }} without {{ end }}');
    return { nodes, stop: null };
  }
  return block(['eof']).nodes;
}

export function renderTemplate(source: string, data: Record<string, string>): string {
  const flags: Record<string, boolean> = {};
  const run = (nodes: Node[]): string =>
    nodes
      .map((node) => {
        if (node.type === 'text') return node.value;
        if (node.type === 'out') {
          if (!(node.field in data)) throw new Error(`no value for .${node.field}`);
          return data[node.field];
        }
        if (node.type === 'assign') {
          flags[node.name] = data[node.field] === node.literal;
          return '';
        }
        for (const branch of node.branches) {
          if (branch.cond === null || flags[branch.cond]) return run(branch.body);
        }
        return '';
      })
      .join('');
  return run(parse(tokenize(source)));
}
