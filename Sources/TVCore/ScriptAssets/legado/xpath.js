// A compact XPath 1.0 evaluator over cheerio/domhandler nodes, for Legado book source rules
// (Legado uses JsoupXpath). Besides XPath 1.0 it understands JsoupXpath's step functions
// text(), allText(), html(), outerHtml() and num().
// Results: arrays of nodes or strings. Attribute nodes are {type: 'attribute', name, value, parent}.

const isElement = node => node && (node.type === 'tag' || node.type === 'script' || node.type === 'style');
const isText = node => node && (node.type === 'text' || node.type === 'cdata');
const kids = node => (node && node.children) || [];

// --- Text, as Jsoup gives it ------------------------------------------------------------------
const BLOCKS = new Set(['address', 'article', 'aside', 'blockquote', 'body', 'br', 'dd', 'div', 'dl', 'dt', 'fieldset', 'figcaption', 'figure',
    'footer', 'form', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'header', 'hr', 'html', 'li', 'main', 'nav', 'ol', 'p', 'pre', 'section', 'table',
    'tbody', 'td', 'tfoot', 'th', 'thead', 'tr', 'ul', 'title', 'head']);
export const normalize = text => String(text).replace(/[\s ]+/g, ' ');
export function jsoupText(node) {
    if (!node) return '';
    if (isText(node)) return normalize(node.data ?? '').trim();
    if (node.type === 'attribute') return node.value;
    let out = '';
    const walk = n => {
        for (const child of kids(n)) {
            if (isText(child)) out += child.data ?? '';
            else if (isElement(child)) {
                if (child.name === 'script' || child.name === 'style') continue;
                const block = BLOCKS.has(child.name);
                if (block) out += ' ';
                walk(child);
                if (block) out += ' ';
            }
        }
    };
    walk(node);
    return normalize(out).trim();
}
export function ownText(node) {
    let out = '';
    for (const child of kids(node)) {
        if (isText(child)) out += child.data ?? '';
        else if (isElement(child) && child.name === 'br') out += ' ';
    }
    return normalize(out).trim();
}
export const textNodes = node => kids(node).filter(isText);

// XPath string-value: all descendant text, untouched.
function stringValue(node) {
    if (node == null) return '';
    if (typeof node === 'string') return node;
    if (isText(node) || node.type === 'comment') return node.data ?? '';
    if (node.type === 'attribute') return node.value ?? '';
    let out = '';
    const walk = n => { for (const child of kids(n)) { if (isText(child)) out += child.data ?? ''; else if (isElement(child) || child.type === 'root') walk(child); } };
    walk(node);
    return out;
}

// --- Document order -------------------------------------------------------------------------
const orders = new WeakMap();
function rootOf(node) { let n = node.type === 'attribute' ? node.parent : node; while (n && n.parent) n = n.parent; return n; }
function orderOf(node) {
    const root = rootOf(node);
    let map = orders.get(root);
    if (!map) {
        map = new Map(); let index = 0;
        const walk = n => { map.set(n, index++); for (const child of kids(n)) walk(child); };
        walk(root); orders.set(root, map);
    }
    if (node.type === 'attribute') return (map.get(node.parent) ?? 0) + 0.5;
    return map.get(node) ?? 0;
}
function sortUnique(nodes) {
    const seen = new Set(), out = [];
    for (const n of nodes) {
        const id = n.type === 'attribute' ? n.parent : n;
        const key = n.type === 'attribute' ? n.parent : n;
        if (n.type === 'attribute') { out.push(n); continue; }
        if (!seen.has(key)) { seen.add(key); out.push(n); }
        void id;
    }
    if (out.length > 1) out.sort((a, b) => orderOf(a) - orderOf(b));
    return out;
}

// --- Tokens ---------------------------------------------------------------------------------
function tokenize(text) {
    const tokens = [];
    let i = 0;
    const operatorBefore = () => {
        const last = tokens[tokens.length - 1];
        if (!last) return false;
        if (last.t === 'op' && !['(', '[', ',', '@', '::', '/', '//', '|', '+', '-', '=', '!=', '<', '<=', '>', '>=', 'and', 'or', 'div', 'mod', '*m'].includes(last.v)) return true;
        return last.t === 'name' || last.t === 'str' || last.t === 'num' || last.t === 'var' || last.t === 'star' || (last.t === 'op' && (last.v === ')' || last.v === ']' || last.v === '.' || last.v === '..'));
    };
    while (i < text.length) {
        const c = text[i];
        if (/\s/.test(c)) { i++; continue; }
        const two = text.substr(i, 2);
        if (['//', '::', '!=', '<=', '>=', '..'].includes(two)) { tokens.push({ t: 'op', v: two }); i += 2; continue; }
        if ('()[],@/|+=<>'.includes(c)) { tokens.push({ t: 'op', v: c }); i++; continue; }
        if (c === '-') { tokens.push({ t: 'op', v: '-' }); i++; continue; }
        if (c === '*') { tokens.push(operatorBefore() ? { t: 'op', v: '*m' } : { t: 'star', v: '*' }); i++; continue; }
        if (c === '"' || c === "'") {
            const end = text.indexOf(c, i + 1);
            if (end < 0) throw new Error('XPath: unterminated string');
            tokens.push({ t: 'str', v: text.slice(i + 1, end) }); i = end + 1; continue;
        }
        if (/[0-9]/.test(c) || (c === '.' && /[0-9]/.test(text[i + 1] ?? ''))) {
            const m = /^[0-9]*\.?[0-9]+|^[0-9]+\.?/.exec(text.slice(i));
            tokens.push({ t: 'num', v: Number(m[0]) }); i += m[0].length; continue;
        }
        if (c === '.') { tokens.push({ t: 'op', v: '.' }); i++; continue; }
        if (c === '$') {
            const m = /^\$([\w.-]+)/.exec(text.slice(i));
            tokens.push({ t: 'var', v: m ? m[1] : '' }); i += m ? m[0].length : 1; continue;
        }
        const m = /^[A-Za-z_À-￿][\w.À-￿-]*(?::(?!:)[A-Za-z_À-￿*][\w.À-￿-]*)?/.exec(text.slice(i));
        if (!m) throw new Error(`XPath: unexpected '${c}'`);
        const word = m[0];
        if (operatorBefore() && ['and', 'or', 'div', 'mod'].includes(word)) tokens.push({ t: 'op', v: word });
        else tokens.push({ t: 'name', v: word });
        i += word.length;
    }
    return tokens;
}

// --- Parser ---------------------------------------------------------------------------------
const AXES = new Set(['ancestor', 'ancestor-or-self', 'attribute', 'child', 'descendant', 'descendant-or-self', 'following', 'following-sibling',
    'namespace', 'parent', 'preceding', 'preceding-sibling', 'self']);
const NODE_TYPES = new Set(['node', 'text', 'comment', 'processing-instruction']);
const STEP_FUNCTIONS = new Set(['allText', 'alltext', 'html', 'outerHtml', 'outerhtml', 'num', 'text']);

function parse(text) {
    const tokens = tokenize(text);
    let p = 0;
    const peek = (o = 0) => tokens[p + o];
    const isOp = (v, o = 0) => peek(o)?.t === 'op' && peek(o).v === v;
    const take = () => tokens[p++];
    const expect = v => { if (!isOp(v)) throw new Error(`XPath: expected '${v}' in ${text}`); p++; };

    function orExpr() { let l = andExpr(); while (isOp('or')) { p++; l = { k: 'or', l, r: andExpr() }; } return l; }
    function andExpr() { let l = eqExpr(); while (isOp('and')) { p++; l = { k: 'and', l, r: eqExpr() }; } return l; }
    function eqExpr() { let l = relExpr(); while (isOp('=') || isOp('!=')) { const op = take().v; l = { k: 'cmp', op, l, r: relExpr() }; } return l; }
    function relExpr() { let l = addExpr(); while (isOp('<') || isOp('>') || isOp('<=') || isOp('>=')) { const op = take().v; l = { k: 'cmp', op, l, r: addExpr() }; } return l; }
    function addExpr() { let l = mulExpr(); while (isOp('+') || isOp('-')) { const op = take().v; l = { k: 'math', op, l, r: mulExpr() }; } return l; }
    function mulExpr() { let l = unary(); while (isOp('*m') || isOp('div') || isOp('mod')) { const op = take().v; l = { k: 'math', op, l, r: unary() }; } return l; }
    function unary() { if (isOp('-')) { p++; return { k: 'neg', e: unary() }; } return union(); }
    function union() { let l = pathExpr(); while (isOp('|')) { p++; l = { k: 'union', l, r: pathExpr() }; } return l; }
    function startsStep() {
        const t = peek();
        if (!t) return false;
        if (t.t === 'star' || (t.t === 'op' && (t.v === '.' || t.v === '..' || t.v === '@'))) return true;
        if (t.t === 'name') {
            const next = peek(1);
            if (next?.t === 'op' && next.v === '::') return true;
            if (next?.t === 'op' && next.v === '(') return NODE_TYPES.has(t.v) || STEP_FUNCTIONS.has(t.v);
            return true;
        }
        return false;
    }
    function pathExpr() {
        if (isOp('/') || isOp('//')) return locationPath(null);
        if (startsStep()) return locationPath(null);
        let e = primary();
        while (isOp('[')) { p++; const pred = orExpr(); expect(']'); e = { k: 'filter', e, pred }; }
        if (isOp('/') || isOp('//')) return locationPath(e);
        return e;
    }
    function locationPath(start) {
        const steps = [];
        let absolute = false;
        if (!start && (isOp('/') || isOp('//'))) {
            absolute = true;
            if (take().v === '//') steps.push({ axis: 'descendant-or-self', test: { type: 'node' }, preds: [] });
            else if (!startsStep()) return { k: 'path', start, absolute, steps };
        }
        steps.push(step());
        while (isOp('/') || isOp('//')) {
            if (take().v === '//') steps.push({ axis: 'descendant-or-self', test: { type: 'node' }, preds: [] });
            steps.push(step());
        }
        return { k: 'path', start, absolute, steps };
    }
    function step() {
        if (isOp('.')) { p++; return { axis: 'self', test: { type: 'node' }, preds: [] }; }
        if (isOp('..')) { p++; return { axis: 'parent', test: { type: 'node' }, preds: [] }; }
        let axis = 'child';
        if (isOp('@')) { p++; axis = 'attribute'; }
        else if (peek()?.t === 'name' && isOp('::', 1) && AXES.has(peek().v)) { axis = take().v; p++; }
        let test;
        const t = take();
        if (!t) throw new Error('XPath: unexpected end');
        if (t.t === 'star') test = { type: 'name', name: '*' };
        else if (t.t === 'name' && isOp('(')) {
            p++;
            const args = [];
            if (!isOp(')')) { args.push(orExpr()); while (isOp(',')) { p++; args.push(orExpr()); } }
            expect(')');
            if (NODE_TYPES.has(t.v) && !(t.v === 'text' && axis === 'child')) test = { type: t.v };
            else test = { type: 'fn', name: t.v, args };
        } else if (t.t === 'name') test = { type: 'name', name: t.v.toLowerCase() };
        else throw new Error(`XPath: unexpected token in ${text}`);
        const preds = [];
        while (isOp('[')) { p++; preds.push(orExpr()); expect(']'); }
        return { axis, test, preds };
    }
    function primary() {
        const t = take();
        if (!t) throw new Error('XPath: unexpected end');
        if (t.t === 'op' && t.v === '(') { const e = orExpr(); expect(')'); return e; }
        if (t.t === 'str') return { k: 'lit', v: t.v };
        if (t.t === 'num') return { k: 'lit', v: t.v };
        if (t.t === 'var') return { k: 'lit', v: '' };
        if (t.t === 'name' && isOp('(')) {
            p++;
            const args = [];
            if (!isOp(')')) { args.push(orExpr()); while (isOp(',')) { p++; args.push(orExpr()); } }
            expect(')');
            return { k: 'call', name: t.v, args };
        }
        throw new Error(`XPath: unexpected '${t.v}' in ${text}`);
    }
    const tree = orExpr();
    if (p < tokens.length) throw new Error(`XPath: unexpected '${peek().v}' in ${text}`);
    return tree;
}

// --- Evaluation -----------------------------------------------------------------------------
const attributesOf = node => isElement(node) ? Object.entries(node.attribs || {}).map(([name, value]) => ({ type: 'attribute', name, value: String(value ?? ''), parent: node })) : [];
function descendants(node, out) { for (const child of kids(node)) { out.push(child); descendants(child, out); } return out; }
function axisNodes(node, axis) {
    switch (axis) {
        case 'child': return kids(node).slice();
        case 'descendant': return descendants(node, []);
        case 'descendant-or-self': return descendants(node, [node]);
        case 'self': return [node];
        case 'parent': return node.type === 'attribute' ? [node.parent] : node.parent ? [node.parent] : [];
        case 'ancestor': case 'ancestor-or-self': {
            const out = axis === 'ancestor-or-self' ? [node] : [];
            let n = node.type === 'attribute' ? node.parent : node.parent;
            if (node.type === 'attribute' && axis === 'ancestor') out.push(node.parent), n = node.parent.parent;
            while (n) { out.push(n); n = n.parent; }
            return out;
        }
        case 'following-sibling': { const out = []; let n = node.next; while (n) { out.push(n); n = n.next; } return out; }
        case 'preceding-sibling': { const out = []; let n = node.prev; while (n) { out.push(n); n = n.prev; } return out; }
        case 'following': {
            const out = []; let n = node;
            while (n) { let s = n.next; while (s) { out.push(s); descendants(s, out); s = s.next; } n = n.parent; }
            return out;
        }
        case 'preceding': {
            const out = []; let n = node; const ancestors = new Set();
            for (let a = node.parent; a; a = a.parent) ancestors.add(a);
            while (n) { let s = n.prev; while (s) { const sub = descendants(s, []).reverse(); out.push(...sub, s); s = s.prev; } n = n.parent; }
            return out.filter(x => !ancestors.has(x));
        }
        case 'attribute': return attributesOf(node);
    }
    return [];
}
const reverseAxes = new Set(['ancestor', 'ancestor-or-self', 'preceding', 'preceding-sibling']);
function matches(node, test, axis) {
    switch (test.type) {
        case 'node': return true;
        case 'text': return isText(node);
        case 'comment': return node.type === 'comment';
        case 'processing-instruction': return node.type === 'directive';
        case 'name':
            if (axis === 'attribute') return node.type === 'attribute' && (test.name === '*' || node.name.toLowerCase() === test.name);
            return isElement(node) && (test.name === '*' || node.name.toLowerCase() === test.name || node.name.toLowerCase().split(':').pop() === test.name);
    }
    return false;
}

const toNumber = v => {
    if (Array.isArray(v)) v = v.length ? stringOf(v[0]) : '';
    if (typeof v === 'boolean') return v ? 1 : 0;
    if (typeof v === 'number') return v;
    const s = String(v).trim();
    return s === '' ? NaN : Number(s);
};
const stringOf = v => {
    if (Array.isArray(v)) return v.length ? stringOf(v[0]) : '';
    if (typeof v === 'object' && v) return stringValue(v);
    if (typeof v === 'number') return Number.isInteger(v) ? String(v) : String(v);
    return String(v ?? '');
};
const toBool = v => Array.isArray(v) ? v.length > 0 : typeof v === 'number' ? (v !== 0 && !isNaN(v)) : typeof v === 'string' ? v.length > 0 : !!v;

function compare(op, a, b) {
    const test = (x, y) => {
        if (op === '=' || op === '!=') {
            let eq;
            if (typeof x === 'boolean' || typeof y === 'boolean') eq = toBool(x) === toBool(y);
            else if (typeof x === 'number' || typeof y === 'number') eq = toNumber(x) === toNumber(y);
            else eq = stringOf(x) === stringOf(y);
            return op === '=' ? eq : !eq;
        }
        const l = toNumber(x), r = toNumber(y);
        return op === '<' ? l < r : op === '>' ? l > r : op === '<=' ? l <= r : l >= r;
    };
    const items = v => Array.isArray(v) ? v.map(n => typeof n === 'string' ? n : stringValue(n)) : [v];
    if (Array.isArray(a) || Array.isArray(b)) {
        if (typeof a === 'boolean' || typeof b === 'boolean') return test(toBool(a), toBool(b));
        for (const x of items(a)) for (const y of items(b)) if (test(x, y)) return true;
        return false;
    }
    return test(a, b);
}

const FUNCTIONS = {
    last: (c) => c.size, position: (c) => c.position,
    count: (c, [n]) => (n ?? []).length,
    'string': (c, [v]) => stringOf(v ?? [c.node]),
    concat: (c, args) => args.map(stringOf).join(''),
    'starts-with': (c, [a, b]) => stringOf(a).startsWith(stringOf(b)),
    'ends-with': (c, [a, b]) => stringOf(a).endsWith(stringOf(b)),
    contains: (c, [a, b]) => stringOf(a).includes(stringOf(b)),
    'substring-before': (c, [a, b]) => { const s = stringOf(a), i = s.indexOf(stringOf(b)); return i < 0 ? '' : s.slice(0, i); },
    'substring-after': (c, [a, b]) => { const s = stringOf(a), t = stringOf(b), i = s.indexOf(t); return i < 0 ? '' : s.slice(i + t.length); },
    substring: (c, [a, b, n]) => {
        const s = stringOf(a), start = Math.round(toNumber(b));
        const end = n === undefined ? Infinity : start + Math.round(toNumber(n));
        return [...s].filter((_, i) => i + 1 >= start && i + 1 < end).join('');
    },
    'string-length': (c, [a]) => [...stringOf(a ?? [c.node])].length,
    'normalize-space': (c, [a]) => normalize(stringOf(a ?? [c.node])).trim(),
    translate: (c, [a, b, d]) => { const from = [...stringOf(b)], to = [...stringOf(d)]; return [...stringOf(a)].map(ch => { const i = from.indexOf(ch); return i < 0 ? ch : (to[i] ?? ''); }).join(''); },
    not: (c, [a]) => !toBool(a), 'true': () => true, 'false': () => false, boolean: (c, [a]) => toBool(a),
    number: (c, [a]) => toNumber(a ?? [c.node]), sum: (c, [a]) => (a ?? []).reduce((s, n) => s + toNumber(stringValue(n)), 0),
    floor: (c, [a]) => Math.floor(toNumber(a)), ceiling: (c, [a]) => Math.ceil(toNumber(a)), round: (c, [a]) => Math.round(toNumber(a)),
    name: (c, [a]) => { const n = a ? a[0] : c.node; return n?.name ?? ''; }, 'local-name': (c, [a]) => { const n = a ? a[0] : c.node; return (n?.name ?? '').split(':').pop(); },
    lang: () => false,
    matches: (c, [a, b]) => { try { return new RegExp(stringOf(b)).test(stringOf(a)); } catch { return false; } },
    // JsoupXpath extras usable in predicates
    allText: (c) => jsoupText(c.node), alltext: (c) => jsoupText(c.node), text: (c) => ownText(c.node),
};

function evaluate(e, c) {
    switch (e.k) {
        case 'lit': return e.v;
        case 'or': return toBool(evaluate(e.l, c)) || toBool(evaluate(e.r, c));
        case 'and': return toBool(evaluate(e.l, c)) && toBool(evaluate(e.r, c));
        case 'cmp': return compare(e.op, evaluate(e.l, c), evaluate(e.r, c));
        case 'neg': return -toNumber(evaluate(e.e, c));
        case 'math': {
            const l = toNumber(evaluate(e.l, c)), r = toNumber(evaluate(e.r, c));
            return e.op === '+' ? l + r : e.op === '-' ? l - r : e.op === '*m' ? l * r : e.op === 'div' ? l / r : l % r;
        }
        case 'union': {
            const l = evaluate(e.l, c), r = evaluate(e.r, c);
            const nodes = [...(Array.isArray(l) ? l : []), ...(Array.isArray(r) ? r : [])];
            return nodes.some(n => typeof n === 'string') ? nodes : sortUnique(nodes);
        }
        case 'call': {
            const fn = FUNCTIONS[e.name];
            if (!fn) throw new Error(`XPath: unknown function ${e.name}()`);
            return fn(c, e.args.map(a => evaluate(a, c)));
        }
        case 'filter': {
            let nodes = evaluate(e.e, c);
            if (!Array.isArray(nodes)) return nodes;
            return applyPredicate(nodes, e.pred);
        }
        case 'path': return evalPath(e, c);
    }
    throw new Error('XPath: bad expression');
}

function applyPredicate(nodes, pred) {
    const out = [];
    nodes.forEach((node, index) => {
        const v = evaluate(pred, { node, position: index + 1, size: nodes.length });
        if (typeof v === 'number' ? v === index + 1 : toBool(v)) out.push(node);
    });
    return out;
}

function stepFunction(name, nodes) {
    const out = [];
    for (const node of nodes) {
        if (typeof node === 'string') { out.push(node); continue; }
        switch (name) {
            case 'text':
                if (isElement(node) && (node.name === 'script' || node.name === 'style')) { const t = stringValue(node); if (t) out.push(t); break; }
                for (const t of textNodes(node)) { const s = normalize(t.data ?? '').trim(); if (s) out.push(s); }
                break;
            case 'allText': case 'alltext': out.push(jsoupText(node)); break;
            case 'html': out.push(innerHTML(node)); break;
            case 'outerHtml': case 'outerhtml': out.push(outerHTML(node)); break;
            case 'num': { const m = /-?\d+(\.\d+)?/.exec(ownText(node)); if (m) out.push(m[0]); break; }
        }
    }
    return out;
}

function evalPath(e, c) {
    let nodes;
    if (e.start) { nodes = evaluate(e.start, c); if (!Array.isArray(nodes)) return []; }
    // As JsoupXpath, which Legado hands the element it works on: `/` and `//` start at that element, not the document.
    else if (e.absolute) nodes = [selectRoot ?? rootOf(c.node)];
    else nodes = [c.node];
    for (const step of e.steps) {
        if (step.test.type === 'fn') {
            if (STEP_FUNCTIONS.has(step.test.name)) { nodes = stepFunction(step.test.name, nodes); continue; }
            // A function as a step: evaluate per node and keep node results.
            const next = [];
            for (const node of nodes) { const v = evaluate({ k: 'call', name: step.test.name, args: step.test.args }, { node, position: 1, size: 1 }); if (Array.isArray(v)) next.push(...v); else next.push(stringOf(v)); }
            nodes = next; continue;
        }
        const next = [];
        for (const node of nodes) {
            if (typeof node === 'string') continue;
            let found = axisNodes(node, step.axis).filter(n => matches(n, step.test, step.axis));
            for (const pred of step.preds) {
                // Positions count along the axis: reverse axes count backwards from the node.
                found = applyPredicate(found, pred);
            }
            next.push(...found);
        }
        nodes = sortUnique(next);
        void reverseAxes;
    }
    return nodes;
}

let serializer = null;
export function setSerializer(fn) { serializer = fn; }
export function outerHTML(node) { return serializer ? serializer(node, true) : stringValue(node); }
export function innerHTML(node) { return serializer ? serializer(node, false) : stringValue(node); }

const cache = new Map();
/// Runs `expression` from `context` (a node). Returns an array of nodes and/or strings, or a scalar.
export function select(context, expression) {
    let tree = cache.get(expression);
    if (!tree) { tree = parse(expression); cache.set(expression, tree); if (cache.size > 200) cache.delete(cache.keys().next().value); }
    const outer = selectRoot;
    selectRoot = context;
    try { return evaluate(tree, { node: context, position: 1, size: 1 }); } finally { selectRoot = outer; }
}
let selectRoot = null;
/// One XPath result as Legado's JXNode.asString(): text for text/attributes, outer HTML for elements.
export function asString(item) {
    if (item == null) return '';
    if (typeof item === 'string' || typeof item === 'number' || typeof item === 'boolean') return String(item);
    if (item.type === 'attribute') return item.value;
    if (isText(item)) return item.data ?? '';
    if (item.type === 'comment') return item.data ?? '';
    return outerHTML(item);
}
