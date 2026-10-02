/* Mermaid in, a map out: reads the Mermaid that AI models write so readily and
   turns it into this app's map, so a diagram pasted in the text panel just
   becomes a mind map (icons, colors, boxes and all) without anyone having to know
   which notation it was.

     detect(text)    -> the Mermaid diagram type ("flowchart", "mindmap", ...) or null
     toModel(text)   -> { type, title, direction, nodes, boxes, edges, errors }
     toMapText(text) -> the same map in the text panel's notation (js/map-text.js)
     extract(text)   -> the Mermaid in a reply: its ```mermaid block, or the text itself

   The model: nodes [{ id, name, description, section, hint, hub }] (section: the
   id of the node whose box holds it, null for none; hint: words that help pick an
   icon; hub: the diagram's center), boxes [{ owner, parent }] (a Mermaid subgraph,
   composite state, namespace or group is a box owned by a node with its title),
   edges [{ from, to, label, style }] (style: 'solid', 'dotted' or 'thick'), and
   errors [{ line, text }] for lines left out.

   Graph-like diagrams convert: flowchart / graph, mindmap, stateDiagram,
   classDiagram, erDiagram, sequenceDiagram (participants and their messages),
   timeline and architecture. Other types (pie, gantt, ...) are detected but give
   no nodes, only an error saying so. Pure functions; also works in Node. */
(function (root) {
  'use strict';

  var TYPES = ['flowchart-elk', 'flowchart', 'graph', 'mindmap', 'stateDiagram-v2', 'stateDiagram', 'classDiagram-v2', 'classDiagram',
    'erDiagram', 'sequenceDiagram', 'timeline', 'architecture-beta', 'architecture', 'journey', 'gantt', 'pie', 'quadrantChart',
    'requirementDiagram', 'gitGraph', 'C4Context', 'C4Container', 'C4Component', 'C4Dynamic', 'C4Deployment', 'sankey-beta',
    'sankey', 'xychart-beta', 'xychart', 'block-beta', 'block', 'packet-beta', 'packet', 'kanban', 'radar-beta', 'radar',
    'treemap-beta', 'treemap', 'zenuml'];
  var KIND = {
    'flowchart-elk': 'flowchart', flowchart: 'flowchart', graph: 'flowchart', mindmap: 'mindmap',
    'stateDiagram-v2': 'state', stateDiagram: 'state', 'classDiagram-v2': 'class', classDiagram: 'class',
    erDiagram: 'er', sequenceDiagram: 'sequence', timeline: 'timeline', 'architecture-beta': 'architecture',
    architecture: 'architecture'
  };

  // ---------- Text ----------

  function lines(text) { return String(text || '').replace(/\r\n?/g, '\n').split('\n'); }

  // The Mermaid in a reply or a paste: the first ```mermaid block (else the first
  // ``` block that is Mermaid), else the text itself.
  function extract(text) {
    var s = String(text || '').replace(/\r\n?/g, '\n');
    var re = /(^|\n)[ \t]*(`{3,}|~{3,})[ \t]*([\w-]*)[^\n]*\n([\s\S]*?)\n[ \t]*\2[ \t]*(?=\n|$)/g, m, any = null;
    while ((m = re.exec(s))) {
      if (/^mermaid$/i.test(m[3])) return m[4];
      if (any === null && header(m[4])) any = m[4];
    }
    return any !== null ? any : s;
  }

  // Front matter (--- title: ... ---) and the lines of the diagram after it.
  function frontMatter(ls) {
    var i = 0, title = '';
    while (i < ls.length && !ls[i].trim()) i++;
    if (i < ls.length && ls[i].trim() === '---') {
      for (var j = i + 1; j < ls.length; j++) {
        if (ls[j].trim() === '---') {
          ls.slice(i + 1, j).forEach(function (l) { var t = l.match(/^\s*title\s*:\s*(.*)$/); if (t) title = unq(t[1].trim()); });
          return { start: j + 1, title: title };
        }
      }
    }
    return { start: 0, title: '' };
  }

  // The first line that says something: { index, type, rest } or null.
  function header(text) {
    var ls = lines(text), fm = frontMatter(ls);
    for (var i = fm.start; i < ls.length; i++) {
      var t = ls[i].replace(/%%\{[\s\S]*?\}%%/g, '').trim();
      if (!t || /^%%/.test(t)) continue;
      for (var k = 0; k < TYPES.length; k++) {
        var w = TYPES[k];
        if (t.slice(0, w.length) === w && (t.length === w.length || /[\s;:]/.test(t[w.length]))) {
          return { index: i, type: w, rest: t.slice(w.length).replace(/^[\s;:]+/, ''), title: fm.title, lines: ls };
        }
      }
      return null;
    }
    return null;
  }

  function detect(text) {
    var h = header(extract(text));
    return h ? h.type : null;
  }

  function unq(s) {
    s = String(s == null ? '' : s).trim();
    if (s.length >= 2 && ((s[0] === '"' && s[s.length - 1] === '"') || (s[0] === "'" && s[s.length - 1] === "'"))) s = s.slice(1, -1);
    return s;
  }

  var ENT = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ', '#39': "'" };
  // A label as plain text: quotes, Markdown strings, <br>, other tags, entities
  // and Font Awesome marks out; line breaks kept (the first line is the name).
  function clean(s) {
    s = unq(String(s == null ? '' : s));
    if (s[0] === '`' && s[s.length - 1] === '`') s = s.slice(1, -1);
    s = s.replace(/<br\s*\/?>/gi, '\n').replace(/\\n/g, '\n').replace(/<[^>]+>/g, '');
    s = s.replace(/&(#?\w+);/g, function (m, e) {
      if (ENT[e]) return ENT[e];
      if (/^#\d+$/.test(e)) return String.fromCharCode(+e.slice(1));
      return m;
    }).replace(/#(quot|amp|lt|gt|\d+);/g, function (m, e) { return /^\d+$/.test(e) ? String.fromCharCode(+e) : ENT[e]; });
    s = s.replace(/\bfa[bsrl]?:fa-[\w-]+\s*/g, '').replace(/\*\*([^*]+)\*\*/g, '$1').replace(/__([^_]+)__/g, '$1')
      .replace(/(^|[\s(])[*_]([^*_\n]+)[*_](?=$|[\s).,!?])/g, '$1$2');
    return s.split('\n').map(function (l) { return l.replace(/\s+/g, ' ').trim(); }).filter(function (l, i, all) {
      return l || (i > 0 && i < all.length - 1);
    }).join('\n').trim();
  }

  // Splits on sep outside quotes and brackets.
  function splitTop(s, sep) {
    var out = [], cur = '', depth = 0, q = null;
    for (var i = 0; i < s.length; i++) {
      var c = s[i];
      if (q) { cur += c; if (c === q) q = null; continue; }
      if (c === '"' || c === '`') { q = c; cur += c; continue; }
      if ('[({'.indexOf(c) >= 0) depth++;
      else if ('])}'.indexOf(c) >= 0) depth = Math.max(0, depth - 1);
      if (!depth && c === sep) { out.push(cur); cur = ''; continue; }
      cur += c;
    }
    out.push(cur);
    return out;
  }

  // ---------- Building the model ----------

  function builder(type) {
    var m = { type: type, title: '', direction: '', nodes: [], boxes: [], edges: [], errors: [] };
    var byId = {}, boxOf = {}, seen = {};
    var api = {
      model: m,
      byId: byId,
      // A node by its Mermaid id, made the first time it's named.
      node: function (id, text, section) {
        var n = byId[id];
        if (!n) {
          n = byId[id] = { id: id, name: id, description: '', section: section === undefined ? null : section, named: false };
          m.nodes.push(n);
        }
        if (text != null && text !== '') api.label(n, text);
        return n;
      },
      label: function (n, text) {
        var t = clean(text);
        if (!t) return;
        var parts = t.split('\n');
        n.name = parts[0];
        n.description = parts.slice(1).join(' ').trim();
        n.named = true;
      },
      describe: function (n, line) {
        line = clean(line).replace(/\n/g, ' ');
        if (!line) return;
        n.description = n.description ? n.description + '\n' + line : line;
      },
      box: function (owner, parent) {
        if (boxOf[owner]) return boxOf[owner];
        var b = boxOf[owner] = { owner: owner, parent: parent || null };
        m.boxes.push(b);
        return b;
      },
      isBox: function (id) { return !!boxOf[id]; },
      edge: function (from, to, label, style) {
        if (!from || !to || from === to) return;
        label = clean(label || '').replace(/\n/g, ' ');
        var k = from + '\u0001' + to + '\u0001' + label;
        if (seen[k]) return;
        seen[k] = true;
        m.edges.push({ from: from, to: to, label: label, style: style || 'solid' });
      },
      error: function (line, text) { m.errors.push({ line: line, text: text }); },
      done: function () {
        m.nodes.forEach(function (n) { delete n.named; });
        return m;
      }
    };
    return api;
  }

  // ---------- Flowchart ----------

  var SHAPES = [ // longest openers first
    ['(((', ')))'], ['([', '])'], ['[[', ']]'], ['[(', ')]'], ['((', '))'], ['{{', '}}'], ['[/', '/]'], ['[/', '\\]'],
    ['[\\', '\\]'], ['[\\', '/]'], ['[', ']'], ['(', ')'], ['{', '}'], ['>', ']']
  ];

  // From i, the text inside a shape closed by close (quotes and nesting honored) -> { text, end } or null.
  function readShape(s, i, open, close) {
    var j = i + open.length, q = null, depth = 0;
    for (; j < s.length; j++) {
      var c = s[j];
      if (q) { if (c === q) q = null; continue; }
      if (c === '"' || c === '`') { q = c; continue; }
      if (s.startsWith(close, j) && depth === 0) return { text: s.slice(i + open.length, j), end: j + close.length };
      if (c === '[' || c === '(' || c === '{') depth++;
      else if ((c === ']' || c === ')' || c === '}') && depth) depth--;
    }
    return null;
  }

  var LINK_LABELED = /^\s*(<)?(--|==|-\.)\s+(?![->.=])("[^"]*"|[^"]*?)\s*(-{2,}>|-{3,}|={2,}>|={3,}|\.+->|\.+-|--[ox]|==[ox])(?=[\s\w"]|$)/;
  var LINK_PLAIN = /^\s*(<|o(?=-)|x(?=-))?(-{2,}[ox](?=\s)|={2,}[ox](?=\s)|-{2,}>?|={2,}>?|-\.+->?|~{3,})/;

  function linkStyle(tok) { return /=/.test(tok) ? 'thick' : /\./.test(tok) ? 'dotted' : /~/.test(tok) ? 'none' : 'solid'; }

  // A link at s[i...] -> { end, label, style, back } or null.
  function readLink(s, i) {
    var rest = s.slice(i), m = rest.match(LINK_LABELED), label = '', len, style;
    if (m) {
      label = m[3]; len = m[0].length; style = linkStyle(m[2] + m[4]);
    } else {
      m = rest.match(LINK_PLAIN);
      if (!m) return null;
      len = m[0].length; style = linkStyle(m[2]);
    }
    var pipe = rest.slice(len).match(/^\s*\|([^|]*)\|/);
    if (pipe) { label = pipe[1]; len += pipe[0].length; }
    return { end: i + len, label: label, style: style };
  }

  var ID = /^[^\s\[\](){}<>|&;:"'`=~,\\/-][^\s\[\](){}<>|&;:"'`=~,\\]*?(?=$|[\s\[\](){}<>|&;:"'`=~,\\]|-[-.>=ox]|@\{|-$)/;

  // A node reference at s[i...] (id, shape and text, :::class) -> { id, text, end } or null.
  function readNode(s, i) {
    while (s[i] === ' ' || s[i] === '\t') i++;
    var m = s.slice(i).match(ID);
    if (!m || !m[0]) return null;
    var id = m[0], j = i + id.length, text = null, hint = null;
    // A node id can't end in "-" or "." followed by a link ("A--B").
    if (s.startsWith('@{', j)) {
      var sh = readShape(s, j, '@{', '}');
      if (sh) {
        var lab = sh.text.match(/label\s*:\s*("(?:[^"\\]|\\.)*"|[^,}]+)/);
        if (lab) text = lab[1];
        var icon = sh.text.match(/icon\s*:\s*"?([^",}]+)/);
        if (icon) hint = icon[1].replace(/^[\w-]+:(fa-)?/, '').replace(/[-_]/g, ' ');
        j = sh.end;
      }
    } else {
      for (var k = 0; k < SHAPES.length; k++) {
        if (!s.startsWith(SHAPES[k][0], j)) continue;
        var r = readShape(s, j, SHAPES[k][0], SHAPES[k][1]);
        if (r) { text = r.text; j = r.end; break; }
      }
    }
    var cls = s.slice(j).match(/^:::[\w-]+/);
    if (cls) j += cls[0].length;
    return { id: id, text: text, hint: hint, end: j };
  }

  function parseFlowchart(h, B) {
    var dir = h.rest.match(/^(TB|TD|BT|RL|LR)\b/i);
    B.model.direction = dir ? dir[1].toUpperCase().replace('TD', 'TB') : 'TB';
    var stack = [], ls = h.lines, sub = 0;
    function section() { return stack.length ? stack[stack.length - 1] : null; }
    function place(n) {
      // A node lives in the first subgraph that names it (and not in its own box).
      if (n.section == null && section() && section() !== n.id && !B.isBox(n.id)) n.section = section();
    }
    for (var li = h.index + 1; li < ls.length; li++) {
      var raw = ls[li].replace(/%%\{[\s\S]*?\}%%/g, '');
      if (/^\s*%%/.test(raw)) continue;
      splitTop(raw, ';').forEach(function (part) {
        var t = part.trim();
        if (!t) return;
        var sg = t.match(/^subgraph\b\s*(.*)$/);
        if (sg) {
          var body = sg[1].trim(), id, title = null, mm;
          if ((mm = body.match(/^([^\s\[\]"]+)\s*\[(.*)\]\s*$/))) { id = mm[1]; title = mm[2]; }
          else if ((mm = body.match(/^"(.*)"$/))) { id = 'subgraph ' + (++sub); title = mm[1]; }
          else if (/\s/.test(body)) { id = body; title = body; }
          else id = body || 'subgraph ' + (++sub);
          var owner = B.node(id, title, section());
          if (owner.section == null && section() && section() !== id) owner.section = section();
          B.box(id, section());
          stack.push(id);
          return;
        }
        if (/^end$/.test(t)) { stack.pop(); return; }
        if (/^(direction|classDef|class|style|linkStyle|click|accTitle|accDescr|title)\b/.test(t)) {
          var tt = t.match(/^title\s+(.*)$/);
          if (tt) B.model.title = clean(tt[1]);
          return;
        }
        // A chain: groups of nodes (joined by &) between links.
        var i = 0, groups = [], links = [], ok = true;
        while (i < t.length) {
          var group = [];
          for (;;) {
            var n = readNode(t, i);
            if (!n) { ok = false; break; }
            group.push(n);
            i = n.end;
            var amp = t.slice(i).match(/^\s*&\s*/);
            if (amp) { i += amp[0].length; continue; }
            break;
          }
          if (!ok) break;
          groups.push(group);
          while (t[i] === ' ' || t[i] === '\t') i++;
          if (i >= t.length) break;
          var l = readLink(t, i);
          if (!l) { ok = false; break; }
          links.push(l);
          i = l.end;
        }
        if (!ok || groups.length !== links.length + 1) { B.error(li + 1, 'Not understood: ' + t); return; }
        groups.forEach(function (g) {
          g.forEach(function (r) {
            var n = B.node(r.id, r.text);
            if (r.hint) n.hint = r.hint;
            place(n);
          });
        });
        links.forEach(function (l, k) {
          if (l.style === 'none') return; // ~~~ only lays things out
          groups[k].forEach(function (a) {
            groups[k + 1].forEach(function (b) {
              B.edge(a.id, b.id, l.label, l.style);
            });
          });
        });
      });
    }
  }

  // ---------- Mindmap ----------

  function parseMindmap(h, B) {
    var ls = h.lines, stack = [], count = 0, last = null;
    B.model.direction = 'LR';
    for (var li = h.index + 1; li < ls.length; li++) {
      var raw = ls[li];
      if (!raw.trim() || /^\s*%%/.test(raw)) continue;
      var indent = raw.match(/^\s*/)[0].replace(/\t/g, '    ').length;
      var t = raw.trim();
      if (/^::icon\(/.test(t)) { if (last) last.hint = (last.hint ? last.hint + ' ' : '') + t.replace(/^::icon\(|\)$/g, '').replace(/\b(?:fa[bsrl]?|mdi)-/g, ' ').replace(/\b(?:fa[bsrl]?|mdi)\b/g, ' ').replace(/[-_]/g, ' ').replace(/\s+/g, ' ').trim(); continue; }
      if (/^:::/.test(t)) continue;
      t = t.replace(/:::[\w\s-]+$/, '').trim();
      var text = t, mm;
      if ((mm = t.match(/^[^\s\[\](){}]*(\(\(\(|\(\(|\)\)|\[|\(|\)|\{\{)([\s\S]*?)(\)\)\)|\)\)|\(\(|\]|\)|\(|\}\})$/)) && mm[2]) text = mm[2];
      var id = 'm' + (++count);
      while (stack.length && stack[stack.length - 1].indent >= indent) stack.pop();
      var parent = stack.length ? stack[stack.length - 1].id : null;
      var n = B.node(id, text);
      if (!n.name || n.name === id) n.name = clean(text) || 'Idea';
      if (!parent && B.model.nodes.length === 1) n.hub = true;
      if (parent) B.edge(parent, id, '');
      else if (B.model.nodes.length > 1) B.edge(B.model.nodes[0].id, id, ''); // a second root hangs off the first
      stack.push({ indent: indent, id: id });
      last = n;
    }
  }

  // ---------- State diagram ----------

  function parseState(h, B) {
    var ls = h.lines, stack = [], note = false;
    B.model.direction = 'TB';
    function scope() { return stack.length ? stack[stack.length - 1] : null; }
    function ref(s, asTarget) {
      s = s.trim().replace(/:::[\w-]+$/, '');
      if (s === '[*]') {
        var sc = scope();
        var id = (asTarget ? '[end]' : '[start]') + (sc ? ' ' + sc : '');
        var n = B.node(id, asTarget ? 'End' : 'Start', sc);
        n.hint = asTarget ? 'flag finish' : 'play start';
        return id;
      }
      var node = B.node(s, null, scope());
      return node.id;
    }
    for (var li = h.index + 1; li < ls.length; li++) {
      var t = ls[li].trim();
      if (!t || /^%%/.test(t)) continue;
      if (note) { if (/^end\s+note$/i.test(t)) note = false; continue; }
      if (/^note\b/i.test(t)) { if (!/:/.test(t)) note = true; continue; }
      if (/^(direction|classDef|class|style|accTitle|accDescr|scale|hide)\b/.test(t) || t === '--' || /^\[\*\]$/.test(t)) continue;
      var mm;
      if (t === '}') { stack.pop(); continue; }
      if ((mm = t.match(/^state\s+"([^"]*)"\s+as\s+([^\s{]+)\s*(\{)?$/))) {
        B.node(mm[2], null, scope()).name = clean(mm[1]);
        if (mm[3]) { B.box(mm[2], scope()); stack.push(mm[2]); }
        continue;
      }
      if ((mm = t.match(/^state\s+([^\s{"]+)\s+as\s+"([^"]*)"\s*(\{)?$/))) {
        B.node(mm[1], null, scope()).name = clean(mm[2]);
        if (mm[3]) { B.box(mm[1], scope()); stack.push(mm[1]); }
        continue;
      }
      if ((mm = t.match(/^state\s+([^\s{]+)\s*(<<\w+>>)?\s*(\{)?$/))) {
        var sn = B.node(mm[1], null, scope());
        if (mm[2]) sn.hint = mm[2].replace(/[<>]/g, '') === 'choice' ? 'split question' : 'merge';
        if (mm[3]) { B.box(mm[1], scope()); stack.push(mm[1]); }
        continue;
      }
      if ((mm = t.match(/^(\S.*?)\s*(-->|->)\s*(\S.*?)\s*(?::\s*(.*))?$/))) {
        B.edge(ref(mm[1], false), ref(mm[3], true), mm[4] || '');
        continue;
      }
      if ((mm = t.match(/^([^\s:]+)\s*:\s*(.*)$/))) {
        B.describe(B.node(mm[1], null, scope()), mm[2]);
        continue;
      }
      if ((mm = t.match(/^([\w.-]+)$/))) { B.node(mm[1], null, scope()); continue; }
      B.error(li + 1, 'Not understood: ' + t);
    }
  }

  // ---------- Class diagram ----------

  var CLASS_REL = /^("?[^\s"]+"?)\s*(?:"([^"]*)")?\s*(<\|--|<\|\.\.|\*--|o--|<--|<\.\.|--\|>|\.\.\|>|--\*|--o|-->|\.\.>|--|\.\.)\s*(?:"([^"]*)")?\s*("?[^\s":]+"?)\s*(?::\s*(.*))?$/;

  function parseClass(h, B) {
    var ls = h.lines, ns = [], inClass = null, note = false;
    B.model.direction = 'TB';
    function scope() { return ns.length ? ns[ns.length - 1] : null; }
    function cls(name) {
      name = unq(name).replace(/~[^~]*~/g, '');
      var label = null, mm = name.match(/^([^\["]+)\["(.*)"\]$/);
      if (mm) { name = mm[1]; label = mm[2]; }
      var n = B.node(name, label, scope());
      return n;
    }
    function member(n, text) {
      text = text.trim().replace(/[$*]$/, '');
      if (!text) return;
      if (/^<<.*>>$/.test(text)) { n.stereo = text.replace(/[<>]/g, ''); return; }
      (n.members = n.members || []).push(text.replace(/^[+\-#~]\s*/, ''));
    }
    for (var li = h.index + 1; li < ls.length; li++) {
      var t = ls[li].trim();
      if (!t || /^%%/.test(t)) continue;
      if (inClass) {
        if (t === '}') { inClass = null; continue; }
        member(inClass, t);
        continue;
      }
      var mm;
      if (/^(direction|classDef|style|cssClass|click|callback|link|accTitle|accDescr)\b/.test(t)) continue;
      if (/^note\b/.test(t)) continue;
      if (t === '}') { ns.pop(); continue; }
      if ((mm = t.match(/^namespace\s+(\S+)\s*\{?$/))) {
        B.node(mm[1], null, scope());
        B.box(mm[1], scope());
        ns.push(mm[1]);
        continue;
      }
      if ((mm = t.match(/^<<(.+)>>\s*(\S+)$/))) { cls(mm[2]).stereo = mm[1]; continue; }
      if ((mm = t.match(/^class\s+(\S+?)(\["[^"]*"\])?\s*(?::::\w+)?\s*(\{)?\s*(\})?$/))) {
        var c = cls(mm[1] + (mm[2] || ''));
        if (mm[3] && !mm[4]) inClass = c;
        continue;
      }
      if ((mm = t.match(CLASS_REL))) {
        var a = cls(mm[1]).id, b = cls(mm[5]).id, op = mm[3], label = mm[6] || '';
        if (!label && (mm[2] || mm[4])) label = (mm[2] || '') + ' → ' + (mm[4] || '');
        var style = /\.\./.test(op) ? 'dotted' : 'solid';
        if (/^(--\|>|\.\.\|>|--\*|--o)$/.test(op)) B.edge(b, a, label, style);
        else B.edge(a, b, label, style);
        continue;
      }
      if ((mm = t.match(/^(\S+)\s*:\s*(.+)$/))) { member(cls(mm[1]), mm[2]); continue; }
      if ((mm = t.match(/^[\w.-]+$/))) { cls(mm[0]); continue; }
      B.error(li + 1, 'Not understood: ' + t);
    }
    B.model.nodes.forEach(function (n) {
      if (!n.stereo && !n.members) return;
      // The first line is the description (the stereotype), each member a callout.
      n.description = [n.stereo ? '«' + n.stereo + '»' : ''].concat(n.members || []).join('\n').replace(/\n+$/, '');
      delete n.stereo; delete n.members;
    });
  }

  // ---------- ER diagram ----------

  function parseER(h, B) {
    var ls = h.lines, inEntity = null;
    B.model.direction = 'TB';
    function entity(s) {
      s = s.trim();
      var mm = s.match(/^("?[^\s"\[]+"?)\s*\[\s*"?([^"\]]*)"?\s*\]$/);
      if (mm) return B.node(unq(mm[1]), mm[2]);
      return B.node(unq(s));
    }
    for (var li = h.index + 1; li < ls.length; li++) {
      var t = ls[li].trim(), mm;
      if (!t || /^%%/.test(t)) continue;
      if (inEntity) {
        if (t === '}') { inEntity = null; continue; }
        var at = t.match(/^(\S+)\s+(\S+)\s*((?:PK|FK|UK)(?:\s*,\s*(?:PK|FK|UK))*)?\s*(?:"([^"]*)")?$/);
        if (at) (inEntity.attrs = inEntity.attrs || []).push(at[2] + ': ' + at[1] + (at[3] ? ' ' + at[3].replace(/\s+/g, '') : ''));
        continue;
      }
      if (/^(direction|classDef|class|style|accTitle|accDescr)\b/.test(t)) continue;
      if ((mm = t.match(/^(.+?)\s*\{\s*(\})?$/))) { var e = entity(mm[1]); if (!mm[2]) inEntity = e; continue; }
      if ((mm = t.match(/^("?[^\s"]+"?)\s*([|}{o]{1,2})(--|\.\.)([|}{o]{1,2})\s*("?[^\s":]+"?)\s*(?::\s*(.*))?$/))) {
        var a = entity(mm[1]).id, b = entity(mm[5]).id;
        B.edge(a, b, mm[6] || '', mm[3] === '..' ? 'dotted' : 'solid');
        continue;
      }
      if ((mm = t.match(/^("?[^\s"]+"?)$/))) { entity(mm[1]); continue; }
      B.error(li + 1, 'Not understood: ' + t);
    }
    B.model.nodes.forEach(function (n) {
      if (n.attrs) { n.description = (n.description || '') + '\n' + n.attrs.join('\n'); delete n.attrs; }
    });
  }

  // ---------- Sequence diagram ----------

  var SEQ = /^([^\s:<>+\-][^:<>]*?)\s*(<<-->>|<<->>|-->>|->>|--x|-x|--\)|-\)|-->|->)\s*[+-]?\s*([^:]+?)\s*:\s*(.*)$/;

  var BOX_COLOR = /^(?:rgba?\([^)]*\)|hsla?\([^)]*\)|#[0-9a-f]{3,8}\b|(?:transparent|aqua|black|blue|fuchsia|gray|grey|green|lime|maroon|navy|olive|purple|red|silver|teal|white|yellow|orange|pink|cyan|magenta|gold|beige|ivory|lavender|coral|salmon|khaki|tan|violet|indigo|light\w+|dark\w+|pale\w+)(?=\s|$))\s*/i;

  function parseSequence(h, B) {
    var ls = h.lines, blocks = [], pairs = {};
    B.model.direction = 'LR';
    function box() { for (var i = blocks.length - 1; i >= 0; i--) if (blocks[i]) return blocks[i]; return null; }
    function who(s) { return B.node(s.trim(), null, box()); }
    var boxes = 0;
    for (var li = h.index + 1; li < ls.length; li++) {
      var t = ls[li].trim(), mm;
      if (!t || /^%%/.test(t)) continue;
      if ((mm = t.match(/^(participant|actor)\s+(.+?)(?:\s+as\s+(.+))?$/))) {
        var n = who(mm[2].replace(/@\{.*\}$/, '').trim());
        if (mm[3]) n.name = clean(mm[3]);
        if (mm[1] === 'actor') n.hint = 'person user';
        continue;
      }
      if ((mm = t.match(/^create\s+(participant|actor)\s+(.+?)(?:\s+as\s+(.+))?$/))) { var c = who(mm[2]); if (mm[3]) c.name = clean(mm[3]); continue; }
      if ((mm = t.match(/^box\b\s*(.*)$/))) {
        var title = mm[1].replace(BOX_COLOR, '').trim() || 'Group ' + (++boxes);
        var id = 'box: ' + title;
        B.node(id, title, box());
        B.box(id, box());
        blocks.push(id);
        continue;
      }
      if (/^(loop|alt|opt|par|critical|break|rect)\b/.test(t)) { blocks.push(null); continue; }
      if (/^end$/.test(t)) { blocks.pop(); continue; }
      if (/^(else|and|option|autonumber|activate|deactivate|destroy|note|Note|title|accTitle|accDescr|links?|properties|details)\b/.test(t)) {
        var tt = t.match(/^title\s*:?\s*(.*)$/);
        if (tt) B.model.title = clean(tt[1]);
        continue;
      }
      if ((mm = t.match(SEQ))) {
        var a = who(mm[1]).id, b = who(mm[3]).id;
        var k = a + '\u0001' + b, label = clean(mm[4]).replace(/\n/g, ' ');
        if (pairs[k]) { pairs[k].count++; continue; }
        pairs[k] = { count: 1, label: label };
        B.edge(a, b, label, /--/.test(mm[2]) ? 'dotted' : 'solid');
        continue;
      }
      B.error(li + 1, 'Not understood: ' + t);
    }
    B.model.edges.forEach(function (e) {
      var p = pairs[e.from + '\u0001' + e.to];
      if (p && p.count > 1) e.label = (e.label ? e.label + ' ' : '') + '(+' + (p.count - 1) + ')';
    });
  }

  // ---------- Timeline ----------

  function parseTimeline(h, B) {
    var ls = h.lines, section = null, prev = null, period = null, count = 0, hub = null;
    B.model.direction = 'LR';
    for (var li = h.index + 1; li < ls.length; li++) {
      var t = ls[li].trim(), mm;
      if (!t || /^%%/.test(t)) continue;
      if ((mm = t.match(/^title\s+(.*)$/))) {
        B.model.title = clean(mm[1]);
        hub = B.node('timeline', mm[1]);
        hub.hub = true;
        continue;
      }
      if ((mm = t.match(/^section\s+(.*)$/))) {
        section = 'section: ' + clean(mm[1]);
        B.node(section, mm[1]);
        B.box(section, null);
        continue;
      }
      var parts = splitTop(t, ':').map(function (p) { return p.trim(); });
      if (parts[0]) {
        period = B.node('p' + (++count), parts[0], section);
        if (prev) B.edge(prev.id, period.id, '');
        else if (hub) B.edge(hub.id, period.id, '');
        prev = period;
      }
      if (!period) { B.error(li + 1, 'Not understood: ' + t); continue; }
      parts.slice(1).forEach(function (ev) {
        if (!ev) return;
        var n = B.node('e' + (++count), ev, section);
        B.edge(period.id, n.id, '');
      });
    }
  }

  // ---------- Architecture ----------

  function parseArchitecture(h, B) {
    var ls = h.lines, junctions = {}, jEdges = {};
    B.model.direction = 'LR';
    function hint(icon) { return String(icon || '').replace(/^[\w-]+:/, '').replace(/[-_]/g, ' '); }
    function end(s) { var id = s.replace(/\{group\}$/, ''); return id; }
    for (var li = h.index + 1; li < ls.length; li++) {
      var t = ls[li].trim(), mm;
      if (!t || /^%%/.test(t)) continue;
      if ((mm = t.match(/^(group|service)\s+([\w-]+)\s*(?:\(([^)]*)\))?\s*(?:\[([^\]]*)\])?\s*(?:in\s+([\w-]+))?$/))) {
        var n = B.node(mm[2], mm[4] || null, mm[5] || null);
        if (!mm[4]) n.name = mm[2];
        n.hint = hint(mm[3]);
        if (mm[1] === 'group') B.box(mm[2], mm[5] || null);
        continue;
      }
      if ((mm = t.match(/^junction\s+([\w-]+)/))) { junctions[mm[1]] = true; continue; }
      if ((mm = t.match(/^([\w-]+(?:\{group\})?)\s*(?::\s*[LRTB])?\s*(<)?-+(>)?\s*(?:[LRTB]\s*:)?\s*([\w-]+(?:\{group\})?)$/))) {
        var a = end(mm[1]), b = end(mm[4]);
        if (mm[2] && !mm[3]) { var x = a; a = b; b = x; }
        if (junctions[a] || junctions[b]) {
          (jEdges[a] = jEdges[a] || []).push(b);
          (jEdges[b] = jEdges[b] || []).push(a);
          continue;
        }
        B.edge(a, b, '');
        continue;
      }
      if (/^(title|accTitle|accDescr)\b/.test(t)) { var tt = t.match(/^title\s+(.*)$/); if (tt) B.model.title = clean(tt[1]); continue; }
      B.error(li + 1, 'Not understood: ' + t);
    }
    // Junctions only route: whatever meets at one is joined to the first thing there.
    var seen = {};
    Object.keys(junctions).forEach(function (j) {
      var ends = [], stack = [j];
      seen[j] = true;
      while (stack.length) {
        (jEdges[stack.pop()] || []).forEach(function (o) {
          if (seen[o]) return;
          seen[o] = true;
          if (junctions[o]) stack.push(o); else ends.push(o);
        });
      }
      for (var i = 1; i < ends.length; i++) B.edge(ends[0], ends[i], '');
    });
    B.model.nodes = B.model.nodes.filter(function (n) { return !junctions[n.id]; });
  }

  // ---------- Putting it together ----------

  var NAMES = {
    flowchart: 'flowchart', mindmap: 'mind map', state: 'state diagram', class: 'class diagram', er: 'ER diagram',
    sequence: 'sequence diagram', timeline: 'timeline', architecture: 'architecture diagram'
  };

  function toModel(text) {
    var h = header(extract(text));
    if (!h) return null;
    var kind = KIND[h.type];
    var B = builder(h.type);
    B.model.kind = kind || null;
    B.model.title = h.title || '';
    if (!kind) {
      B.error(h.index + 1, 'A Mermaid ' + h.type + ' isn’t a graph of things and connections, so it has no map');
      return B.done();
    }
    ({ flowchart: parseFlowchart, mindmap: parseMindmap, state: parseState, class: parseClass, er: parseER,
      sequence: parseSequence, timeline: parseTimeline, architecture: parseArchitecture })[kind](h, B);
    var m = B.done();
    // Ids that only Mermaid sees: a node never given a label keeps its id as the
    // name, made readable ("user_service" -> "user service").
    m.nodes.forEach(function (n) {
      if (n.name === n.id && /[_]/.test(n.name) && !/\s/.test(n.name)) n.name = n.name.replace(/_+/g, ' ').trim() || n.id;
      if (n.section && !m.nodes.some(function (o) { return o.id === n.section; })) n.section = null;
    });
    m.boxes = m.boxes.filter(function (b) { return m.nodes.some(function (n) { return n.id === b.owner; }); });
    m.edges = m.edges.filter(function (e) {
      return m.nodes.some(function (n) { return n.id === e.from; }) && m.nodes.some(function (n) { return n.id === e.to; });
    });
    if (!m.nodes.length && !m.errors.length) m.errors.push({ line: h.index + 1, text: 'This ' + NAMES[kind] + ' has nothing in it yet' });
    return m;
  }

  // The map in the text panel's notation (js/map-text.js generates it, so names
  // that read as notation are quoted and names alike told apart).
  function toMapText(text, mapText) {
    var m = toModel(text);
    if (!m) return null;
    var MT = mapText || (typeof module !== 'undefined' && module.exports ? require('./map-text.js') : root.MindMapText);
    var out = MT.generate({ nodes: m.nodes, boxes: m.boxes, edges: m.edges });
    if (m.title && !m.nodes.some(function (n) { return n.name === m.title; })) out = '# ' + m.title.replace(/\n/g, ' ') + '\n' + out;
    return out;
  }

  // Colors for a fresh map, as places in a 12-color wheel. With a hub: the hub
  // first (0), then each box's node and each branch off the hub a color of its
  // own, stepping 5 places round the wheel so neighbors differ; what a box holds
  // takes its color, and the rest the color of the node it branches from. With
  // none (a process, a pipeline), the colors run round the wheel along the flow.
  // -> { color: { id: 0..11 }, hub: id or null }
  var STEP = [0, 5, 10, 3, 8, 1, 6, 11, 4, 9, 2, 7];
  function paint(m) {
    var color = {}, adj = {}, deg = {}, out = {}, k = 0, ids = {};
    function next() { return STEP[k++ % STEP.length]; }
    m.nodes.forEach(function (n) { ids[n.id] = n; adj[n.id] = []; deg[n.id] = 0; out[n.id] = 0; });
    m.edges.forEach(function (e) {
      if (!ids[e.from] || !ids[e.to]) return;
      adj[e.from].push(e.to);
      deg[e.from]++; deg[e.to]++; out[e.from]++;
    });
    m.edges.forEach(function (e) { if (ids[e.from] && ids[e.to]) adj[e.to].push(e.from); }); // then what leads in
    var hub = null, best = 0;
    m.nodes.forEach(function (n) { if (n.hub && !hub) hub = n.id; });
    // Else a node most things lead out of: nothing leads into it, or it joins six or more.
    if (!hub) {
      m.nodes.forEach(function (n) {
        var s = deg[n.id] + out[n.id] * 0.5;
        if (out[n.id] >= 4 && (deg[n.id] === out[n.id] || deg[n.id] >= 6) && s > best) { best = s; hub = n.id; }
      });
    }
    if (!hub) return { color: flow(m, adj, out, ids), hub: null };
    color[hub] = next();
    var owners = m.boxes.map(function (b) { return b.owner; }).filter(function (o) { return ids[o]; });
    owners.forEach(function (o) { if (color[o] === undefined) color[o] = next(); });
    m.nodes.forEach(function (n) { if (n.section && color[n.id] === undefined && color[n.section] !== undefined) color[n.id] = color[n.section]; });
    function spread(start) {
      var queue = [start];
      while (queue.length) {
        var u = queue.shift();
        adj[u].forEach(function (v) {
          if (color[v] !== undefined) return;
          color[v] = u === hub ? next() : color[u];
          queue.push(v);
        });
      }
    }
    spread(hub);
    owners.forEach(spread);
    m.nodes.forEach(function (n) {
      if (color[n.id] !== undefined) return;
      color[n.id] = next();
      spread(n.id);
    });
    return { color: color, hub: hub };
  }

  // Without a hub: each node's color by how far along the flow it is (steps from
  // where things start), two places round the wheel per step; a box's node takes
  // the color of the first thing in it.
  function flow(m, adj, out, ids) {
    var depth = {}, queue = [], inc = {}, color = {};
    m.edges.forEach(function (e) { if (ids[e.from] && ids[e.to]) inc[e.to] = true; });
    function from(list) {
      list.forEach(function (id) { if (depth[id] === undefined) { depth[id] = 0; queue.push(id); } });
      while (queue.length) {
        var u = queue.shift();
        adj[u].slice(0, out[u]).forEach(function (v) { if (depth[v] === undefined) { depth[v] = depth[u] + 1; queue.push(v); } });
      }
    }
    var boxOwner = {};
    m.boxes.forEach(function (b) { boxOwner[b.owner] = true; });
    from(m.nodes.filter(function (n) { return !inc[n.id] && (out[n.id] || !boxOwner[n.id]); }).map(function (n) { return n.id; }));
    m.nodes.forEach(function (n) { if (depth[n.id] === undefined && !boxOwner[n.id]) from([n.id]); });
    m.boxes.slice().reverse().forEach(function (b) {
      if (depth[b.owner] !== undefined) return;
      var d = Infinity;
      m.nodes.forEach(function (n) { if (n.section === b.owner && depth[n.id] !== undefined) d = Math.min(d, depth[n.id]); });
      depth[b.owner] = d === Infinity ? 0 : d;
    });
    m.nodes.forEach(function (n) { color[n.id] = ((depth[n.id] || 0) * 2) % 12; });
    return color;
  }

  var api = { detect: detect, extract: extract, toModel: toModel, toMapText: toMapText, paint: paint, clean: clean, types: TYPES.slice() };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.MindMapMermaid = api;
})(this);
