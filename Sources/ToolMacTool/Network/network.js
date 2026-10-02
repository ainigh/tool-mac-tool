/* The diagram tool's network view: Mermaid in (js from Mind Map Studio reads it,
   mermaid.js), a network diagram out, drawn the way Mind Map Studio's network view
   draws a map: every node a large icon in its color, picked from its name
   (icon-match.js: brands, services and plain words), with its name and description
   centered below; connections as elbows with rounded corners, shaded from one
   node's color to the other's, a comet running along each to show its direction;
   boxes (Mermaid subgraphs, groups, composite states) as tinted frames.

   Nothing here is interactive: the layout is worked out once per drawing.
   It's layered (Sugiyama): cycles broken, nodes put in ranks, ranks ordered to
   cross as little as possible, then placed so connections run straight where they
   can; boxes are laid out inside first and then placed as one block. Top-down,
   left-right and (for a hub with many branches) a two-sided mind map are all
   tried, and the one that shows largest in the window wins.

     MermaidNetwork.model(code)        -> the model, or null when it isn't a graph
     MermaidNetwork.draw(host, model)  -> draws it into host (an element), fitted */
(function (root) {
  'use strict';

  var NS = 'http://www.w3.org/2000/svg';
  // Mind Map Studio's node colors, and MindMapMermaid.paint's places in them.
  var PALETTE = ['#8b5cf6', '#6366f1', '#3b82f6', '#06b6d4', '#14b8a6', '#10b981', '#84cc16', '#f59e0b', '#f97316', '#ef4444', '#ec4899', '#d946ef'];
  // Lighter inks of the same colors, for icons and text on the dark glass.
  var INK = ['#a78bfa', '#818cf8', '#60a5fa', '#22d3ee', '#2dd4bf', '#34d399', '#a3e635', '#fbbf24', '#fb923c', '#f87171', '#f472b6', '#e879f9'];

  var SANS = '-apple-system, "SF Pro Text", "Helvetica Neue", "Segoe UI", Inter, system-ui, sans-serif';
  var ROUNDED = 'ui-rounded, "SF Pro Rounded", -apple-system, "Segoe UI", Inter, system-ui, sans-serif';
  var SERIF = '"New York", ui-serif, "Iowan Old Style", Georgia, serif';
  var MONO = 'ui-monospace, "SF Mono", Menlo, "DejaVu Sans Mono", monospace';

  var SIZE = {
    icon: 68, glyph: 46, hub: 96, hubGlyph: 62,
    name: { font: '600 21px ' + ROUNDED, size: 21, line: 25 },
    hubName: { font: '400 31px ' + SERIF, size: 31, line: 34 },
    desc: { font: '400 13px ' + SANS, size: 13, line: 17 },
    extra: { font: '400 11.5px ' + MONO, size: 11.5, line: 16 },
    label: { font: '600 10px ' + MONO, size: 10, line: 18 },
    boxName: { font: '600 15px ' + ROUNDED, size: 15, line: 19 },
    boxDesc: { font: '400 12px ' + SANS, size: 12, line: 16 },
    maxW: 200, hubMaxW: 300, nameGap: 9, descGap: 5,
    boxPad: 28, boxHead: 52, boxGlyph: 22,
    port: 9
  };
  var GAP = {
    TB: { node: 46, dummy: 14, mixed: 26, rank: 64, lead: 20, track: 13, tail: 24, labelTail: 46 },
    LR: { node: 30, dummy: 12, mixed: 20, rank: 78, lead: 22, track: 13, tail: 26, labelTail: 36 }
  };

  function el(tag, attrs, parent) {
    var e = document.createElementNS(NS, tag);
    for (var k in attrs) if (attrs[k] !== undefined && attrs[k] !== null) e.setAttribute(k, attrs[k]);
    if (parent) parent.appendChild(e);
    return e;
  }
  function r1(v) { return Math.round(v * 10) / 10; }

  // ---------- The model ----------

  function model(code) {
    var MM = root.MindMapMermaid;
    var m = MM && MM.toModel(code);
    if (!m || !m.nodes.length) return null;
    return m;
  }

  // ---------- Text ----------

  var measureEl = null;
  function measure(s, font) {
    if (!measureEl) {
      var svg = el('svg', { width: 0, height: 0, style: 'position:absolute;left:-9999px;top:0;visibility:hidden' }, document.body);
      measureEl = el('text', {}, svg);
    }
    measureEl.setAttribute('style', 'font:' + font);
    measureEl.textContent = s;
    return measureEl.getComputedTextLength();
  }

  // Words wrapped to maxW in at most max lines, the last ending in "…" when cut.
  function wrap(text, font, maxW, max) {
    var words = String(text || '').split(/\s+/).filter(Boolean), lines = [], cur = '';
    words.forEach(function (w) {
      var t = cur ? cur + ' ' + w : w;
      if (!cur || measure(t, font) <= maxW) cur = t;
      else { lines.push(cur); cur = w; }
    });
    if (cur) lines.push(cur);
    var cut = lines.length > max;
    lines = lines.slice(0, max);
    lines = lines.map(function (l, i) {
      var last = i === lines.length - 1;
      if (measure(l, font) <= maxW && !(last && cut)) return l;
      var s = l;
      while (s.length > 1 && measure(s + '…', font) > maxW) s = s.slice(0, -1);
      return s.replace(/\s+$/, '') + '…';
    });
    var w = 0;
    lines.forEach(function (l) { w = Math.max(w, measure(l, font)); });
    return { lines: lines, w: w };
  }

  // ---------- Icons ----------

  var SHAPE_WORDS = { database: 'database', circle: 'circle dot', decision: 'decision question', hexagon: 'hexagon', flag: 'flag' };

  // The icon for a node: an emoji in its name, else the best match for its name,
  // then for what the diagram hints (an architecture icon, an actor), then for
  // its description; else a spark.
  function iconFor(n) {
    var IM = root.MindMapIconMatch;
    var tries = [n.name, n.hint, String(n.description || '').split('\n')[0], SHAPE_WORDS[n.shape]];
    for (var i = 0; i < tries.length; i++) {
      if (!tries[i]) continue;
      var b = IM && IM.best(tries[i]);
      if (b) return b;
    }
    return 'sparkles';
  }

  function drawIcon(parent, icon, x, y, size, color) {
    var IC = root.MindMapIcons;
    if (IC && IC.has(icon)) {
      var brand = IC.brand(icon) !== null;
      var g = el('svg', {
        x: r1(x), y: r1(y), width: size, height: size, viewBox: '0 0 24 24', class: brand ? 'glyph brand' : 'glyph',
        fill: brand ? color : 'none', stroke: brand ? 'none' : color
      }, parent);
      g.innerHTML = IC.svg(icon).replace(/^<svg[^>]*>|<\/svg>$/g, '');
      return g;
    }
    var t = el('text', { x: r1(x + size / 2), y: r1(y + size * 0.82), 'font-size': r1(size * 0.86), 'text-anchor': 'middle', class: 'emoji' }, parent);
    t.textContent = icon;
    return t;
  }

  // ---------- Nodes ----------

  // Measures a node and lays out its parts around its top center:
  // { w, h, icon (tile size), parts }.
  function shapeNode(n) {
    var hub = !!n.isHub;
    var icon = hub ? SIZE.hub : SIZE.icon;
    var nameStyle = hub ? SIZE.hubName : SIZE.name;
    var maxW = hub ? SIZE.hubMaxW : SIZE.maxW;
    var lines = String(n.description || '').split('\n');
    var name = wrap(n.name || ' ', nameStyle.font, maxW, 2);
    var desc = lines[0] ? wrap(lines[0], SIZE.desc.font, maxW, 2) : { lines: [], w: 0 };
    var more = lines.slice(1).filter(function (l) { return l.trim(); });
    var extras = more.slice(0, more.length > 5 ? 4 : 5).map(function (l) { return wrap(l, SIZE.extra.font, maxW, 1); });
    if (more.length > 5) extras.push(wrap('+' + (more.length - 4) + ' more', SIZE.extra.font, maxW, 1));
    var w = Math.max(icon, name.w, desc.w);
    extras.forEach(function (e) { w = Math.max(w, e.w); });
    var y = icon + SIZE.nameGap, parts = { name: [], desc: [], extra: [] };
    name.lines.forEach(function (l) { parts.name.push({ text: l, y: y + nameStyle.size * 0.86 }); y += nameStyle.line; });
    if (desc.lines.length) y += SIZE.descGap;
    desc.lines.forEach(function (l) { parts.desc.push({ text: l, y: y + SIZE.desc.size * 0.9 }); y += SIZE.desc.line; });
    if (extras.length) y += 6;
    extras.forEach(function (e) { parts.extra.push({ text: e.lines[0], y: y + SIZE.extra.size * 0.9 }); y += SIZE.extra.line; });
    return { w: Math.ceil(w), h: Math.ceil(y), icon: icon, glyph: hub ? SIZE.hubGlyph : SIZE.glyph, parts: parts, name: nameStyle };
  }

  // ---------- Layered layout ----------
  // Coordinates here are c (across the ranks) and r (along them): x and y top-down,
  // y and x left-right. An item is a node or a box laid out as one block, with cs and
  // rs its size along c and r. Ports are where connections meet it: for a node, the
  // middle of its icon (left-right) or the middle of its top and bottom (top-down).

  function itemPorts(it, dir) {
    // c offsets of the port from the item's middle, and how far from its rank
    // start (rTop) a connection leaves (exit) or arrives (entry).
    if (it.box) return { off: 0 };
    return { off: dir === 'LR' ? it.shape.icon / 2 - it.cs / 2 : 0 };
  }

  // Lays out items (each { id, cs, rs, ... }) joined by links ({ a, b, offA, offB,
  // edge, label }) along dir: positions (c: middle, rTop) and routes (lists of
  // points in c, r). aspect: the c:r shape to pack separate pieces into.
  function layered(items, links, dir, aspect, inBox) {
    var G = GAP[dir];
    var byId = {};
    items.forEach(function (it, i) { it.index = i; byId[it.id] = it; });
    // Separate pieces are laid out on their own and packed side by side.
    var comp = {}, pieces = [];
    function find(x) { while (comp[x] !== x) x = comp[x] = comp[comp[x]]; return x; }
    items.forEach(function (it) { comp[it.id] = it.id; });
    links.forEach(function (l) { comp[find(l.a)] = find(l.b); });
    var groups = {};
    items.forEach(function (it) {
      var k = find(it.id);
      if (!groups[k]) { groups[k] = { items: [], links: [] }; pieces.push(groups[k]); }
      groups[k].items.push(it);
    });
    links.forEach(function (l) { groups[find(l.a)].links.push(l); });
    var done = pieces.map(function (p) { return layoutPiece(p.items, p.links, dir, G); });
    // A box of a few unconnected things lines them up.
    var line = inBox && pieces.length <= 6 && pieces.every(function (p) { return p.items.length === 1; });
    return pack(done, line ? 1e6 : aspect, dir === 'TB' ? 56 : 44, dir === 'TB' ? 48 : 40);
  }

  function layoutPiece(items, links, dir, G) {
    var ids = items.map(function (it) { return it.id; }), byId = {};
    items.forEach(function (it) { byId[it.id] = it; });
    var out = {}, inn = {};
    ids.forEach(function (id) { out[id] = []; inn[id] = []; });
    // Breaking cycles: a depth-first walk from the sources (in the diagram's
    // order) turns round the links that lead back up it.
    var state = {}, flip = [];
    function walk(u) {
      state[u] = 1;
      links.forEach(function (l, i) {
        if (l.a !== u || flip[i] !== undefined) return;
        if (state[l.b] === 1) { flip[i] = true; return; }
        flip[i] = false;
        if (!state[l.b]) walk(l.b);
      });
      state[u] = 2;
    }
    var hasIn = {};
    links.forEach(function (l) { hasIn[l.b] = true; });
    ids.forEach(function (id) { if (!hasIn[id] && !state[id]) walk(id); });
    ids.forEach(function (id) { if (!state[id]) walk(id); });
    var dag = links.map(function (l, i) {
      var f = flip[i] === true;
      return { from: f ? l.b : l.a, to: f ? l.a : l.b, link: l, flipped: f };
    });
    dag.forEach(function (d) { out[d.from].push(d); inn[d.to].push(d); });

    // Ranks: the longest path from a source, then sources pulled down next to
    // what they lead to.
    var rank = {}, order = [], seen = {};
    function visit(u) {
      if (seen[u]) return;
      seen[u] = true;
      inn[u].forEach(function (d) { visit(d.from); });
      order.push(u);
    }
    ids.forEach(visit);
    order.forEach(function (u) {
      rank[u] = 0;
      inn[u].forEach(function (d) { rank[u] = Math.max(rank[u], rank[d.from] + 1); });
    });
    for (var pass = 0; pass < 2; pass++) {
      order.slice().reverse().forEach(function (u) {
        if (inn[u].length || !out[u].length) return;
        var m = Infinity;
        out[u].forEach(function (d) { m = Math.min(m, rank[d.to] - 1); });
        if (m > rank[u]) rank[u] = m;
      });
    }
    var maxRank = 0;
    ids.forEach(function (id) { maxRank = Math.max(maxRank, rank[id]); });

    // Layers, with a dummy wherever a link passes a rank by.
    var layers = [];
    for (var k = 0; k <= maxRank; k++) layers.push([]);
    var slot = {};
    ids.forEach(function (id) {
      var s = { id: id, item: byId[id], rank: rank[id], cs: byId[id].cs, up: [], down: [] };
      slot[id] = s;
    });
    // First-seen order, depth first from the sources, starts each layer.
    var placed = {};
    function enter(id) {
      if (placed[id]) return;
      placed[id] = true;
      layers[rank[id]].push(slot[id]);
      out[id].forEach(function (d) { enter(d.to); });
    }
    ids.forEach(function (id) { if (!inn[id].length) enter(id); });
    ids.forEach(enter);
    var chains = [];
    dag.forEach(function (d, i) {
      var a = slot[d.from], b = slot[d.to], prev = a, chain = [a];
      var offA = d.flipped ? d.link.offB : d.link.offA, offB = d.flipped ? d.link.offA : d.link.offB;
      for (var r = rank[d.from] + 1; r < rank[d.to]; r++) {
        var dm = { id: 'd' + i + ':' + r, dummy: true, rank: r, cs: 2, up: [], down: [] };
        layers[r].push(dm);
        prev.down.push({ s: dm, off: offA, mine: prev === a ? offA : 0 });
        dm.up.push({ s: prev, off: prev === a ? offA : 0, mine: 0 });
        chain.push(dm);
        prev = dm;
      }
      prev.down.push({ s: b, off: offB, mine: prev === a ? offA : 0 });
      b.up.push({ s: prev, off: prev === a ? offA : 0, mine: offB });
      chain.push(b);
      chains.push({ d: d, slots: chain, offA: offA, offB: offB });
    });

    // Order within ranks: barycenter sweeps, keeping the order with fewest crossings.
    function positions() { layers.forEach(function (L) { L.forEach(function (s, i) { s.pos = i; }); }); }
    function crossings() {
      var c = 0;
      positions();
      for (var r = 0; r < layers.length - 1; r++) {
        var segs = [];
        layers[r].forEach(function (s) { s.down.forEach(function (n) { segs.push([s.pos, n.s.pos]); }); });
        for (var i = 0; i < segs.length; i++) {
          for (var j = i + 1; j < segs.length; j++) {
            if ((segs[i][0] - segs[j][0]) * (segs[i][1] - segs[j][1]) < 0) c++;
          }
        }
      }
      return c;
    }
    function sweep(down) {
      positions();
      var range = down ? layers.map(function (_, i) { return i; }).slice(1) : layers.map(function (_, i) { return i; }).reverse().slice(1);
      range.forEach(function (r) {
        layers[r].forEach(function (s) {
          var ns = down ? s.up : s.down;
          s.key = ns.length ? ns.reduce(function (t, n) { return t + n.s.pos; }, 0) / ns.length : s.pos;
        });
        layers[r] = layers[r].slice().sort(function (a, b) { return a.key - b.key || a.pos - b.pos; });
        layers[r].forEach(function (s, i) { s.pos = i; });
      });
    }
    var best = layers.map(function (L) { return L.slice(); }), bestC = crossings();
    for (var it = 0; it < 16 && bestC > 0; it++) {
      sweep(it % 2 === 0);
      var c = crossings();
      if (c < bestC) { bestC = c; best = layers.map(function (L) { return L.slice(); }); }
    }
    layers = best;
    positions();

    // Across the ranks: each node as near as it can be to what it connects with
    // (so links run straight), keeping order and room between neighbors.
    function gapBetween(a, b) {
      return a.dummy && b.dummy ? G.dummy : a.dummy || b.dummy ? G.mixed : G.node;
    }
    layers.forEach(function (L) {
      var c = 0;
      L.forEach(function (s, i) {
        if (i) c += L[i - 1].cs / 2 + gapBetween(L[i - 1], s) + s.cs / 2;
        s.c = c;
      });
    });
    function settle(L, which) {
      if (!L.length) return;
      var des = [], w = [], sep = [];
      L.forEach(function (s, i) {
        var ns = which === 'up' ? s.up : which === 'down' ? s.down : which === 'lone' ? (s.down.length ? [] : s.up) : s.up.concat(s.down);
        if (ns.length) {
          var t = 0;
          ns.forEach(function (n) { t += n.s.c + n.off - n.mine; });
          des.push(t / ns.length);
          w.push(ns.length * (s.dummy ? 3 : 1));
        } else { des.push(s.c); w.push(0.05); }
        if (i) sep.push(L[i - 1].cs / 2 + gapBetween(L[i - 1], s) + s.cs / 2);
      });
      var x = isotonic(des, w, sep);
      L.forEach(function (s, i) { s.c = x[i]; });
    }
    for (var round = 0; round < 10; round++) {
      for (var a = 1; a < layers.length; a++) settle(layers[a], 'up');
      for (var b = layers.length - 2; b >= 0; b--) settle(layers[b], 'down');
    }
    layers.forEach(function (L) { settle(L, 'both'); });
    // Last, each node over what it leads to (a parent centered over its children),
    // from the bottom up, then what's left hanging under what leads to it.
    for (var b2 = layers.length - 2; b2 >= 0; b2--) settle(layers[b2], 'down');
    for (var a2 = 1; a2 < layers.length; a2++) settle(layers[a2], 'lone');

    // Along the ranks: rank sizes, then the gaps between them, each wide enough
    // for its tracks (one per bundle of links that turn in it) and labels.
    var rankSize = layers.map(function (L) {
      var m = 0;
      L.forEach(function (s) { if (!s.dummy) m = Math.max(m, s.item.rs); });
      return m || 8;
    });
    var hops = layers.map(function () { return []; });
    chains.forEach(function (ch) {
      for (var i = 0; i < ch.slots.length - 1; i++) {
        var s = ch.slots[i], t = ch.slots[i + 1];
        var ca = s.c + (i === 0 ? ch.offA : 0), cb = t.c + (i === ch.slots.length - 2 ? ch.offB : 0);
        hops[s.rank].push({ ch: ch, i: i, ca: ca, cb: cb, key: s.id + '@' + Math.round(ca) });
      }
    });
    var gaps = hops.map(function (H) {
      var bundles = {}, list = [];
      H.forEach(function (h) {
        if (Math.abs(h.ca - h.cb) < 1) { h.track = -1; return; }
        var bkey = h.key;
        var bnd = bundles[bkey];
        if (!bnd) { bnd = bundles[bkey] = { lo: Infinity, hi: -Infinity, hops: [] }; list.push(bnd); }
        bnd.lo = Math.min(bnd.lo, h.ca, h.cb);
        bnd.hi = Math.max(bnd.hi, h.ca, h.cb);
        bnd.hops.push(h);
      });
      // Bundles that turn left take the tracks nearest the start, so they don't cross
      // the ones turning right on their way.
      list.sort(function (p, q) { return p.lo - q.lo; });
      var tracks = [];
      list.forEach(function (bnd) {
        var t = 0;
        for (; t < tracks.length; t++) {
          if (!tracks[t].some(function (o) { return bnd.lo < o.hi + 10 && o.lo < bnd.hi + 10; })) break;
        }
        (tracks[t] = tracks[t] || []).push(bnd);
        bnd.hops.forEach(function (h) { h.track = t; });
      });
      // Room after the tracks for the labels of what arrives across this gap: all
      // of those arriving at one node side by side (left-right) or stacked (top-down).
      var byTarget = {}, labelled = false, room = 0;
      H.forEach(function (h) {
        if (!h.ch.d.link.label || h.i !== h.ch.slots.length - 2) return;
        labelled = true;
        var t = h.ch.slots[h.i + 1].id, b = byTarget[t] = byTarget[t] || { w: -10, n: 0 };
        b.w += (h.ch.d.link.labelW || 0) + 10;
        b.n++;
        room = Math.max(room, dir === 'LR' ? b.w : b.n * 24 - 24);
      });
      var T = tracks.length;
      var tail = labelled ? G.labelTail + room : G.tail;
      var need = G.lead + Math.max(0, T - 1) * G.track + tail;
      return { size: Math.max(G.rank, need), T: T, tail: tail };
    });
    var rStart = [], at = 0;
    layers.forEach(function (L, k) {
      rStart.push(at);
      at += rankSize[k] + (k < layers.length - 1 ? gaps[k].size : 0);
    });

    // Where items sit: top-down, a rank's nodes line up along their tops (so the
    // icons make a row); left-right, along their middles.
    var minC = Infinity, maxC = -Infinity;
    layers.forEach(function (L) {
      L.forEach(function (s) {
        minC = Math.min(minC, s.c - s.cs / 2);
        maxC = Math.max(maxC, s.c + s.cs / 2);
      });
    });
    var place = {};
    layers.forEach(function (L, k) {
      L.forEach(function (s) {
        s.c -= minC;
        if (s.dummy) return;
        var rTop = dir === 'TB' ? rStart[k] : rStart[k] + (rankSize[k] - s.item.rs) / 2;
        place[s.id] = { c: s.c, rTop: rTop };
      });
    });
    hops.forEach(function (H) { H.forEach(function (h) { h.ca -= minC; h.cb -= minC; }); });

    // Routes: out of the source, through the gaps (straight, or across on a track),
    // into the target.
    function exitR(s) {
      var p = place[s.id], it = s.item;
      if (it.box || dir === 'TB') return p.rTop + it.rs + (it.box ? 0 : 3);
      return p.rTop + it.rs / 2 + it.shape.icon / 2 + SIZE.port;
    }
    function entryR(s) {
      var p = place[s.id], it = s.item;
      if (it.box) return p.rTop;
      if (dir === 'TB') return p.rTop - 3;
      return p.rTop + it.rs / 2 - it.shape.icon / 2 - SIZE.port;
    }
    var routes = [];
    var hopOf = {};
    hops.forEach(function (H) { H.forEach(function (h) { (hopOf[h.ch.d.link.key] = hopOf[h.ch.d.link.key] || [])[h.i] = h; }); });
    chains.forEach(function (ch) {
      var hs = hopOf[ch.d.link.key], pts = [];
      var first = ch.slots[0], last = ch.slots[ch.slots.length - 1];
      pts.push({ c: hs[0].ca, r: exitR(first) });
      var labelAt = null;
      hs.forEach(function (h, i) {
        var k = ch.slots[i].rank, end = rStart[k] + rankSize[k], next = rStart[k + 1];
        pts.push({ c: h.ca, r: end });
        if (h.track >= 0) {
          var g = gaps[k];
          var band = Math.max(0, g.T - 1) * GAP[dir].track;
          var lead = Math.max(GAP[dir].lead, (g.size - g.tail - band) / (g.tail > GAP[dir].tail ? 1.6 : 2));
          var tr = end + Math.min(lead, g.size - g.tail - band) + h.track * GAP[dir].track;
          pts.push({ c: h.ca, r: tr });
          pts.push({ c: h.cb, r: tr });
          if (i === hs.length - 1) labelAt = { c: h.cb, r0: tr, r1: entryR(last) };
        } else if (i === hs.length - 1) labelAt = { c: h.cb, r0: Math.max(end, exitR(first)), r1: entryR(last) };
        pts.push({ c: h.cb, r: next });
      });
      pts.push({ c: hs[hs.length - 1].cb, r: entryR(last) });
      routes.push({ link: ch.d.link, pts: ch.d.flipped ? pts.slice().reverse() : pts, flipped: ch.d.flipped, labelAt: labelAt });
    });
    return { cs: maxC - minC, rs: at, place: place, routes: routes, items: items };
  }

  // Weighted isotonic regression with minimum separations (pool adjacent
  // violators): positions in order, each as near its wish as the gaps allow.
  function isotonic(des, w, sep) {
    var n = des.length, cum = [0];
    for (var i = 1; i < n; i++) cum.push(cum[i - 1] + sep[i - 1]);
    var blocks = [];
    for (var j = 0; j < n; j++) {
      blocks.push({ sum: (des[j] - cum[j]) * w[j], w: w[j], n: 1 });
      while (blocks.length > 1) {
        var a = blocks[blocks.length - 2], b = blocks[blocks.length - 1];
        if (a.sum / a.w <= b.sum / b.w) break;
        blocks.splice(blocks.length - 2, 2, { sum: a.sum + b.sum, w: a.w + b.w, n: a.n + b.n });
      }
    }
    var out = [], k = 0;
    blocks.forEach(function (bl) {
      for (var m = 0; m < bl.n; m++, k++) out.push(bl.sum / bl.w + cum[k]);
    });
    return out;
  }

  // Pieces side by side in shelves, about as wide as aspect asks for.
  function pack(pieces, aspect, gapC, gapR) {
    if (pieces.length === 1) return pieces[0];
    var area = 0;
    pieces.forEach(function (p) { area += (p.cs + gapC) * (p.rs + gapR); });
    var width = Math.max(Math.sqrt(area * aspect), Math.max.apply(null, pieces.map(function (p) { return p.cs; })));
    var c = 0, r = 0, shelf = 0, place = {}, routes = [], items = [], maxC = 0, rows = [], row = [];
    pieces.forEach(function (p) {
      if (c > 0 && c + p.cs > width) { rows.push({ list: row, w: c - gapC }); r += shelf + gapR; c = 0; shelf = 0; row = []; }
      row.push({ p: p, c: c, r: r });
      c += p.cs + gapC;
      shelf = Math.max(shelf, p.rs);
      maxC = Math.max(maxC, c - gapC);
    });
    rows.push({ list: row, w: c - gapC });
    rows.forEach(function (rw) {
      var shift = (maxC - rw.w) / 2; // each shelf centered
      rw.list.forEach(function (e) {
        var p = e.p, dc = e.c + shift, dr = e.r;
        Object.keys(p.place).forEach(function (id) { place[id] = { c: p.place[id].c + dc, rTop: p.place[id].rTop + dr }; });
        p.routes.forEach(function (rt) {
          routes.push({
            link: rt.link, flipped: rt.flipped,
            pts: rt.pts.map(function (q) { return { c: q.c + dc, r: q.r + dr }; }),
            labelAt: rt.labelAt && { c: rt.labelAt.c + dc, r0: rt.labelAt.r0 + dr, r1: rt.labelAt.r1 + dr }
          });
        });
        items = items.concat(p.items);
      });
    });
    return { cs: maxC, rs: r + shelf, place: place, routes: routes, items: items };
  }

  // ---------- Scopes: boxes laid out inside first ----------

  // The whole diagram laid out along dir: { w, h, nodes: { id: {x, y} (top
  // middle) }, boxes: [{ id, x, y, w, h }], routes: [{ link, pts: [{x, y}] }] }.
  function layoutAll(m, shapes, dir, aspect, sides) {
    var parentOf = {}, isBox = {}, kids = {};
    m.boxes.forEach(function (b) { isBox[b.owner] = true; });
    m.nodes.forEach(function (n) { parentOf[n.id] = n.section && isBox[n.section] && n.section !== n.id ? n.section : null; });
    m.boxes.forEach(function (b) { parentOf[b.owner] = b.parent && isBox[b.parent] && b.parent !== b.owner ? b.parent : null; });
    // No box inside itself, however the diagram nests them.
    Object.keys(isBox).forEach(function (o) {
      var seen = {}, x = o;
      while (x) { if (seen[x]) { parentOf[o] = null; break; } seen[x] = true; x = parentOf[x]; }
    });
    m.nodes.forEach(function (n) { var p = parentOf[n.id] || ''; (kids[p] = kids[p] || []).push(n.id); });
    function path(id) {
      var p = [];
      for (var x = id; x; x = parentOf[x]) p.unshift(x);
      return p;
    }
    // Each link at the scope where its ends part ways.
    var linksAt = {};
    m.edges.forEach(function (e, i) {
      var pa = path(e.from), pb = path(e.to), k = 0;
      while (k < pa.length && k < pb.length && pa[k] === pb[k]) k++;
      if (k >= pa.length || k >= pb.length) return; // a box and what's inside it
      var scope = k ? pa[k - 1] : '';
      (linksAt[scope] = linksAt[scope] || []).push({ e: e, i: i, a: pa[k], b: pb[k] });
    });

    // Laid out scopes (relative to their content's top left), by owner id ('' the top).
    var done = {};
    function lay(scope) {
      var items = (kids[scope] || []).map(function (id) {
        if (isBox[id]) {
          var inner = lay(id);
          var head = boxHead(m, id, shapes);
          var cw = Math.max(inner.w, head.w) + SIZE.boxPad * 2, ch = inner.h + SIZE.boxPad + SIZE.boxHead + 8;
          if (!(kids[id] || []).length) ch = SIZE.boxHead + 18;
          return { id: id, box: true, w: cw, h: ch, cs: dir === 'TB' ? cw : ch, rs: dir === 'TB' ? ch : cw, inner: inner };
        }
        var s = shapes[id];
        return { id: id, shape: s, w: s.w, h: s.h, cs: dir === 'TB' ? s.w : s.h, rs: dir === 'TB' ? s.h : s.w };
      });
      var byId = {};
      items.forEach(function (it) { byId[it.id] = it; });
      // A link that ends inside a box meets the box's frame level with where it ends.
      function offset(it, endId) {
        if (it.box) {
          var at = locate(it, endId);
          if (!at) return 0;
          var lim = it.cs / 2 - 18;
          return Math.max(-lim, Math.min(lim, at - it.cs / 2));
        }
        return itemPorts(it, dir).off;
      }
      var links = (linksAt[scope] || []).map(function (L) {
        var label = L.e.label || '';
        return {
          key: 'l' + L.i, a: L.a, b: L.b, edge: L.e, label: label,
          labelW: label ? labelWidth(label) : 0,
          offA: offset(byId[L.a], L.e.from), offB: offset(byId[L.b], L.e.to)
        };
      }).filter(function (l) { return byId[l.a] && byId[l.b]; });
      function run() {
        return !scope && sides ? twoSided(items, links, sides, aspect) : layered(items, links, dir, scope ? 1.6 : aspect, !!scope);
      }
      var res = run();
      // At a node with labelled links, or two links to the same thing, the links
      // meet it side by side (in the order of where their other ends are) rather
      // than all at one point, so neither they nor their labels sit on one another.
      var ends = {}, pairs = {}, spread = false;
      links.forEach(function (l, i) {
        var k = l.a < l.b ? l.a + '\u0001' + l.b : l.b + '\u0001' + l.a;
        pairs[k] = (pairs[k] || 0) + 1;
        // Grouped by the side of the node they meet: toward the start of the ranks or the end.
        function side(id, other) {
          var p = res.place[id], q = res.place[other];
          return id + (p && q && q.rTop > p.rTop ? '>' : '<');
        }
        if (!byId[l.a].box) (ends[side(l.a, l.b)] = ends[side(l.a, l.b)] || []).push({ l: l, end: 'A', id: l.a, other: l.b, i: i });
        if (!byId[l.b].box) (ends[side(l.b, l.a)] = ends[side(l.b, l.a)] || []).push({ l: l, end: 'B', id: l.b, other: l.a, i: i });
      });
      Object.keys(ends).forEach(function (key) {
        var list = ends[key], id = list[0].id;
        if (list.length < 2) return;
        var busy = list.some(function (e) {
          var k = e.l.a < e.l.b ? e.l.a + '\u0001' + e.l.b : e.l.b + '\u0001' + e.l.a;
          return e.l.label || pairs[k] > 1;
        });
        if (!busy) return;
        var it = byId[id], half = it.shape.icon / 2 - 7, base = itemPorts(it, dir).off;
        var step = Math.min(22, (half * 2) / (list.length - 1));
        var at = function (e) {
          var p = res.place[e.other];
          return (p ? p.c : 0) + (e.end === 'A' ? e.l.offB : e.l.offA);
        };
        list.sort(function (p, q) { return at(p) - at(q) || p.i - q.i; });
        list.forEach(function (e, i) {
          var off = base + (i - (list.length - 1) / 2) * step;
          if (e.end === 'A') e.l.offA = off; else e.l.offB = off;
        });
        spread = true;
      });
      if (spread) res = run();
      // Back to x and y, relative to this scope's content.
      var out = { w: dir === 'TB' ? res.cs : res.rs, h: dir === 'TB' ? res.rs : res.cs, nodes: {}, boxes: [], routes: [] };
      function xy(c, r) { return dir === 'TB' ? { x: c, y: r } : { x: r, y: c }; }
      items.forEach(function (it) {
        var p = res.place[it.id];
        if (!p) return;
        var tl = dir === 'TB' ? { x: p.c - it.w / 2, y: p.rTop } : { x: p.rTop, y: p.c - it.h / 2 };
        if (it.box) {
          out.boxes.push({ id: it.id, x: tl.x, y: tl.y, w: it.w, h: it.h });
          var ox = tl.x + SIZE.boxPad + (it.w - SIZE.boxPad * 2 - it.inner.w) / 2, oy = tl.y + SIZE.boxHead + 8;
          Object.keys(it.inner.nodes).forEach(function (id) {
            out.nodes[id] = { x: it.inner.nodes[id].x + ox, y: it.inner.nodes[id].y + oy };
          });
          it.inner.boxes.forEach(function (b) { out.boxes.push({ id: b.id, x: b.x + ox, y: b.y + oy, w: b.w, h: b.h }); });
          it.inner.routes.forEach(function (rt) {
            var lb = rt.label && { x: rt.label.x + ox, y: rt.label.y + oy, axis: rt.label.axis };
            if (lb) { var o = lb.axis === 'y' ? oy : ox; lb.lo = rt.label.lo + o; lb.hi = rt.label.hi + o; }
            out.routes.push({ link: rt.link, flipped: rt.flipped, pts: rt.pts.map(function (q) { return { x: q.x + ox, y: q.y + oy }; }), label: lb });
          });
        } else {
          out.nodes[it.id] = { x: tl.x + it.w / 2, y: tl.y };
        }
      });
      res.routes.forEach(function (rt) {
        var lab = null;
        if (rt.labelAt && rt.link.label) {
          lab = xy(rt.labelAt.c, (rt.labelAt.r0 + rt.labelAt.r1) / 2);
          // The leg it sits on, which it may slide along to keep clear of other labels.
          lab.axis = dir === 'TB' ? 'y' : 'x';
          lab.lo = Math.min(rt.labelAt.r0, rt.labelAt.r1);
          lab.hi = Math.max(rt.labelAt.r0, rt.labelAt.r1);
        }
        out.routes.push({ link: rt.link, flipped: rt.flipped, pts: rt.pts.map(function (q) { return xy(q.c, q.r); }), label: lab });
      });
      done[scope] = out;
      return out;
    }
    // Where, along c, a node sits inside a laid-out box item (from the box's c edge).
    function locate(it, id) {
      var inner = it.inner, x = path(id), k = x.indexOf(it.id);
      if (k < 0) return null;
      var target = x[k + 1];
      var ox = SIZE.boxPad + (it.w - SIZE.boxPad * 2 - inner.w) / 2, oy = SIZE.boxHead + 8;
      var n = inner.nodes[id];
      if (n) {
        var s = shapes[id];
        return dir === 'TB' ? n.x + ox : n.y + oy + s.icon / 2;
      }
      for (var i = 0; i < inner.boxes.length; i++) {
        var b = inner.boxes[i];
        if (b.id === target) return dir === 'TB' ? b.x + ox + b.w / 2 : b.y + oy + b.h / 2;
      }
      return null;
    }
    var top = lay('');
    return top;
  }

  function labelWidth(label) { return Math.min(220, measure(label.toUpperCase(), SIZE.label.font) * 1.06 + 20); }

  function boxHead(m, id, shapes) {
    var s = shapes[id];
    return { w: Math.min(360, SIZE.boxGlyph + 12 + (s ? s.boxW : 120)) };
  }

  // A hub with branches on both sides, left-right: the branches split in two by
  // size, the right half laid out left to right and the left half mirrored.
  function twoSided(items, links, sides, aspect) {
    var right = {}, left = {};
    items.forEach(function (it) { if (sides[it.id] === 'R') right[it.id] = true; else if (sides[it.id] === 'L') left[it.id] = true; });
    var hub = sides.hub;
    var R = layered(items.filter(function (it) { return right[it.id] || it.id === hub; }),
      links.filter(function (l) { return (right[l.a] || l.a === hub) && (right[l.b] || l.b === hub); }), 'LR', aspect / 2);
    var L = layered(items.filter(function (it) { return left[it.id] || it.id === hub; }).map(function (it) {
      return it.id === hub ? Object.assign({}, it) : it;
    }), links.filter(function (l) { return (left[l.a] || l.a === hub) && (left[l.b] || l.b === hub); }), 'LR', aspect / 2);
    var hubItem = items.filter(function (it) { return it.id === hub; })[0];
    var hr = R.place[hub], hl = L.place[hub];
    // Mirror the left half (r -> -r) and line its hub up with the right one's.
    var dc = hr.c - hl.c;
    var place = {}, routes = [];
    function mr(r) { return -r; }
    Object.keys(L.place).forEach(function (id) {
      if (id === hub) return;
      var it = items.filter(function (x) { return x.id === id; })[0];
      var p = L.place[id];
      place[id] = { c: p.c + dc, rTop: mr(p.rTop + it.rs) + (hr.rTop - mr(hl.rTop + hubItem.rs)) };
    });
    var shiftL = hr.rTop - mr(hl.rTop + hubItem.rs);
    L.routes.forEach(function (rt) {
      routes.push({
        link: rt.link, flipped: rt.flipped,
        pts: rt.pts.map(function (q) { return { c: q.c + dc, r: mr(q.r) + shiftL }; }),
        labelAt: rt.labelAt && { c: rt.labelAt.c + dc, r0: mr(rt.labelAt.r0) + shiftL, r1: mr(rt.labelAt.r1) + shiftL }
      });
    });
    Object.keys(R.place).forEach(function (id) { place[id] = R.place[id]; });
    R.routes.forEach(function (rt) { routes.push(rt); });
    // Everything from 0, 0.
    var minC = Infinity, maxC = -Infinity, minR = Infinity, maxR = -Infinity;
    items.forEach(function (it) {
      var p = place[it.id];
      if (!p) return;
      minC = Math.min(minC, p.c - it.cs / 2); maxC = Math.max(maxC, p.c + it.cs / 2);
      minR = Math.min(minR, p.rTop); maxR = Math.max(maxR, p.rTop + it.rs);
    });
    Object.keys(place).forEach(function (id) { place[id] = { c: place[id].c - minC, rTop: place[id].rTop - minR }; });
    routes = routes.map(function (rt) {
      return {
        link: rt.link, flipped: rt.flipped,
        pts: rt.pts.map(function (q) { return { c: q.c - minC, r: q.r - minR }; }),
        labelAt: rt.labelAt && { c: rt.labelAt.c - minC, r0: rt.labelAt.r0 - minR, r1: rt.labelAt.r1 - minR }
      };
    });
    return { cs: maxC - minC, rs: maxR - minR, place: place, routes: routes, items: items };
  }

  // Which side of the hub each node goes on, for a two-sided layout: only for a
  // hub that leads to four or more branches, with nothing joining the two sides.
  function splitSides(m, hub) {
    if (!hub || m.boxes.length) return null;
    var out = {}, inc = {};
    m.edges.forEach(function (e) { (out[e.from] = out[e.from] || []).push(e.to); inc[e.to] = true; });
    if (inc[hub] || (out[hub] || []).length < 4) return null;
    var branches = out[hub].map(function (c) {
      var seen = {}, stack = [c];
      seen[c] = true;
      while (stack.length) {
        (out[stack.pop()] || []).forEach(function (x) { if (!seen[x] && x !== hub) { seen[x] = true; stack.push(x); } });
      }
      return { root: c, ids: Object.keys(seen) };
    });
    var total = 0;
    branches.forEach(function (b) { total += b.ids.length; });
    var side = { hub: hub }, acc = 0, half = Math.ceil(branches.length / 2);
    branches.forEach(function (b, i) {
      var s = (acc < total / 2 && i < Math.max(half, 1)) || i === 0 ? 'R' : 'L';
      acc += b.ids.length;
      b.ids.forEach(function (id) { if (!side[id]) side[id] = s; });
    });
    var ok = true;
    m.edges.forEach(function (e) {
      if (e.from === hub || e.to === hub) return;
      if (side[e.from] && side[e.to] && side[e.from] !== side[e.to]) ok = false;
    });
    m.nodes.forEach(function (n) { if (n.id !== hub && !side[n.id]) ok = false; });
    return ok ? side : null;
  }

  // ---------- Drawing ----------

  function straighten(pts) {
    var out = [];
    pts.forEach(function (p) {
      p = { x: r1(p.x), y: r1(p.y) };
      var last = out[out.length - 1];
      if (last && Math.abs(last.x - p.x) < 0.2 && Math.abs(last.y - p.y) < 0.2) return;
      var prev = out[out.length - 2];
      if (prev && ((Math.abs(prev.x - last.x) < 0.2 && Math.abs(last.x - p.x) < 0.2) || (Math.abs(prev.y - last.y) < 0.2 && Math.abs(last.y - p.y) < 0.2))) out.pop();
      out.push(p);
    });
    return out;
  }
  function leg(a, b) { return Math.abs(a.x - b.x) + Math.abs(a.y - b.y); }
  function along(from, to, len) {
    var l = leg(from, to) || 1;
    return { x: r1(from.x + (to.x - from.x) * len / l), y: r1(from.y + (to.y - from.y) * len / l) };
  }
  // Straight runs, each corner a curve of radius r (less where the runs are short).
  function rounded(pts, r) {
    var d = 'M' + pts[0].x + ',' + pts[0].y, at = pts[0];
    function lineTo(p) { if (p.x !== at.x || p.y !== at.y) { d += ' L' + p.x + ',' + p.y; at = p; } }
    for (var i = 1; i < pts.length - 1; i++) {
      var c = pts[i], n = pts[i + 1];
      var q = Math.min(r, leg(pts[i - 1], c) / 2, leg(c, n) / 2);
      if (q < 0.5) { lineTo(c); continue; }
      lineTo(along(c, at, q));
      var e = along(c, n, q);
      d += ' Q' + c.x + ',' + c.y + ' ' + e.x + ',' + e.y;
      at = e;
    }
    lineTo(pts[pts.length - 1]);
    return d;
  }

  var STYLE = [
    '.mn text { font-kerning: normal; }',
    '.mn .name { fill: #f4f4f5; text-anchor: middle; paint-order: stroke; stroke: rgba(8,8,12,.55); stroke-width: 4px; stroke-linejoin: round; }',
    '.mn .desc { fill: #b4b4bd; text-anchor: middle; paint-order: stroke; stroke: rgba(8,8,12,.5); stroke-width: 3px; stroke-linejoin: round; }',
    '.mn .extra { fill: #a1a1aa; text-anchor: middle; paint-order: stroke; stroke: rgba(8,8,12,.5); stroke-width: 3px; }',
    '.mn .glyph { stroke-width: 1.6; stroke-linecap: round; stroke-linejoin: round; }',
    '.mn .hub .glyph { stroke-width: 1.4; }',
    '.mn .emoji { font-family: "Apple Color Emoji", "Segoe UI Emoji", "Noto Color Emoji", sans-serif; }',
    '.mn .edge path { fill: none; stroke-linecap: round; stroke-linejoin: round; }',
    '.mn .edge .glow { stroke-width: 9; opacity: .1; }',
    '.mn .edge .main { stroke-width: 1.8; opacity: .95; }',
    '.mn .edge.thick .main { stroke-width: 3; }',
    '.mn .edge.thick .glow { stroke-width: 13; opacity: .14; }',
    '.mn .edge.dotted .main { stroke-dasharray: 0.5 6; stroke-width: 2.2; }',
    '.mn .edge .comet { stroke: #fff; stroke-width: 2.4; stroke-dasharray: 0.07 3; stroke-dashoffset: 0.07; opacity: .85;',
    '  animation: mn-comet var(--dur, 3.6s) cubic-bezier(.45,0,.55,1) var(--delay, 0s) infinite; }',
    '.mn .edge .port { fill: #121218; stroke-width: 1.6; }',
    '.mn .label rect { fill: rgba(20,20,26,.92); stroke: rgba(255,255,255,.14); }',
    '.mn .label text { fill: #d4d4dc; text-anchor: middle; letter-spacing: .06em; }',
    '.mn .frame { stroke-width: 1.25; }',
    '.mn .box-name { fill: #f4f4f5; }',
    '.mn .box-desc { fill: #a1a1aa; }',
    '.mn .tile { stroke-width: 1; }',
    '.mn .pulse { fill: none; stroke-width: 1.5; transform-box: fill-box; transform-origin: center;',
    '  animation: mn-pulse 3.4s cubic-bezier(.2,.6,.3,1) infinite; }',
    '.mn .in { animation: mn-in .7s cubic-bezier(.16,1,.3,1) var(--d, 0s) both; }',
    '.mn .edge.in .main, .mn .edge.in .glow { stroke-dasharray: 1; stroke-dashoffset: 1; animation: mn-draw .9s cubic-bezier(.65,0,.25,1) var(--d, 0s) forwards; }',
    '.mn .edge.dotted.in .main { stroke-dasharray: 0.5 6; stroke-dashoffset: 0; animation: mn-fade .9s ease var(--d, 0s) both; }',
    '@keyframes mn-in { from { opacity: 0; transform: translateY(10px) scale(.96); } }',
    '@keyframes mn-draw { to { stroke-dashoffset: 0; } }',
    '@keyframes mn-fade { from { opacity: 0; } }',
    '@keyframes mn-comet { 0% { stroke-dashoffset: 0.07; } 72%, 100% { stroke-dashoffset: -1; } }',
    '@keyframes mn-pulse { 0% { opacity: .55; transform: scale(1); } 70%, 100% { opacity: 0; transform: scale(1.35); } }',
    '.mn.quiet .in, .mn.quiet .edge.in .main, .mn.quiet .edge.in .glow { animation: none; stroke-dashoffset: 0; }',
    '.mn.quiet .edge.dotted.in .main { stroke-dasharray: 0.5 6; }',
    '@media (prefers-reduced-motion: reduce) { .mn .in, .mn .edge.in .main, .mn .edge.in .glow, .mn .pulse { animation: none; stroke-dashoffset: 0; }',
    '  .mn .edge .comet { animation: none; stroke-dashoffset: -0.66; } }'
  ].join('\n');

  var seq = 0;

  // Draws m into host (its old drawing goes), fitted to the host's size.
  function draw(host, m, opts) {
    var MM = root.MindMapMermaid;
    var paint = MM.paint(m);
    var isBox = {};
    m.boxes.forEach(function (b) { isBox[b.owner] = true; });
    var shapes = {}, icons = {}, colorOf = {}, inkOf = {};
    m.nodes.forEach(function (n) {
      var k = (paint.color[n.id] || 0) % PALETTE.length;
      colorOf[n.id] = PALETTE[k];
      inkOf[n.id] = INK[k];
      icons[n.id] = iconFor(n);
      if (isBox[n.id]) {
        shapes[n.id] = { boxW: Math.ceil(measure(n.name, SIZE.boxName.font)), icon: SIZE.boxGlyph };
        return;
      }
      n.isHub = n.id === paint.hub;
      shapes[n.id] = shapeNode(n);
    });

    var W = Math.max(200, host.clientWidth), H = Math.max(200, host.clientHeight);
    var aspect = W / H;
    // Every way of laying it out; the one that shows largest wins, the diagram's
    // own direction (and a two-sided mind map) by a little.
    var sides = splitSides(m, paint.hub);
    var tries = [{ dir: 'TB' }, { dir: 'LR' }];
    if (sides) tries.push({ dir: 'LR', sides: sides });
    if (root.FORCE_LAYOUT) tries = tries.filter(function (t) { return (t.sides ? 'sides' : t.dir) === root.FORCE_LAYOUT; });
    var best = null;
    tries.forEach(function (t) {
      var lay = layoutAll(m, shapes, t.dir, t.dir === 'TB' ? aspect : 1 / aspect, t.sides);
      var fit = Math.min((W - 40) / (lay.w + 80), (H - 40) / (lay.h + 80));
      var want = t.sides ? 1.25 : (m.direction === 'LR' || m.direction === 'RL') === (t.dir === 'LR') ? 1.12 : 1;
      var score = Math.min(fit, 1.7) * want;
      if (!best || score > best.score) best = { score: score, lay: lay, dir: t.dir };
    });
    var lay = best.lay, dir = best.dir;

    host.innerHTML = '';
    var id = 'mn' + (++seq);
    var pad = 40;
    var svg = el('svg', { xmlns: NS, class: opts && opts.quiet ? 'mn quiet' : 'mn', viewBox: (-pad) + ' ' + (-pad) + ' ' + r1(lay.w + pad * 2) + ' ' + r1(lay.h + pad * 2) }, host);
    el('style', {}, svg).textContent = STYLE;
    var defs = el('defs', {}, svg);
    var gBoxes = el('g', { class: 'boxes' }, svg), gEdges = el('g', { class: 'edges' }, svg),
      gNodes = el('g', { class: 'nodes' }, svg), gLabels = el('g', { class: 'labels' }, svg);
    var span = dir === 'TB' ? lay.h : lay.w;
    function delay(x, y) { return r1(((dir === 'TB' ? y : x) / Math.max(1, span)) * 0.55) + 's'; }
    var byId = {};
    m.nodes.forEach(function (n) { byId[n.id] = n; });

    // Boxes, outermost first.
    lay.boxes.slice().sort(function (a, b) { return (b.w * b.h) - (a.w * a.h); }).forEach(function (b) {
      var n = byId[b.id], c = colorOf[b.id], ink = inkOf[b.id];
      var g = el('g', { class: 'box in', style: '--d:' + delay(b.x, b.y) }, gBoxes);
      el('rect', { class: 'frame', x: r1(b.x), y: r1(b.y), width: r1(b.w), height: r1(b.h), rx: 20, fill: c, 'fill-opacity': 0.06, stroke: c, 'stroke-opacity': 0.45 }, g);
      drawIcon(g, icons[b.id], b.x + 18, b.y + 16, SIZE.boxGlyph, ink);
      var t = el('text', { class: 'box-name', x: r1(b.x + 18 + SIZE.boxGlyph + 10), y: r1(b.y + 16 + SIZE.boxGlyph * 0.74), style: 'font:' + SIZE.boxName.font }, g);
      t.textContent = wrap(n.name, SIZE.boxName.font, Math.max(60, b.w - SIZE.boxGlyph - 46), 1).lines[0] || '';
      var d = String(n.description || '').split('\n')[0];
      if (d) {
        var dt = el('text', { class: 'box-desc', x: r1(b.x + b.w - 18), y: r1(b.y + 16 + SIZE.boxGlyph * 0.72), 'text-anchor': 'end', style: 'font:' + SIZE.boxDesc.font }, g);
        var room = b.w - SIZE.boxGlyph - 60 - measure(t.textContent, SIZE.boxName.font);
        dt.textContent = room > 60 ? wrap(d, SIZE.boxDesc.font, room, 1).lines[0] : '';
      }
    });

    unclutter(lay.routes);

    // Connections.
    lay.routes.forEach(function (rt, i) {
      var e = rt.link.edge, pts = straighten(rt.pts);
      if (pts.length < 2) return;
      var a = pts[0], z = pts[pts.length - 1];
      var gid = id + 'g' + i;
      var grad = el('linearGradient', { id: gid, gradientUnits: 'userSpaceOnUse', x1: a.x, y1: a.y, x2: z.x, y2: z.y }, defs);
      el('stop', { offset: 0, 'stop-color': inkOf[e.from] }, grad);
      el('stop', { offset: 1, 'stop-color': inkOf[e.to] }, grad);
      var stroke = 'url(#' + gid + ')';
      var d = rounded(pts, 14);
      var g = el('g', { class: 'edge in ' + (e.style || 'solid'), style: '--d:' + delay(a.x, a.y) }, gEdges);
      el('path', { class: 'glow', d: d, stroke: stroke, pathLength: 1 }, g);
      el('path', { class: 'main', d: d, stroke: stroke, pathLength: e.style === 'dotted' ? null : 1 }, g);
      var comet = el('path', { class: 'comet', d: d, pathLength: 1 }, g);
      comet.style.setProperty('--dur', (3 + Math.random() * 1.8).toFixed(2) + 's');
      comet.style.setProperty('--delay', (-Math.random() * 4).toFixed(2) + 's');
      el('circle', { class: 'port', cx: a.x, cy: a.y, r: 2.8, stroke: inkOf[e.from] }, g);
      el('circle', { class: 'port', cx: z.x, cy: z.y, r: 2.8, stroke: inkOf[e.to] }, g);
      if (rt.label && rt.link.label) {
        var text = rt.link.label.toUpperCase(), w = rt.link.labelW;
        var lt = wrap(text, SIZE.label.font, w - 20, 1).lines[0];
        var lg = el('g', { class: 'label in', style: '--d:' + delay(rt.label.x, rt.label.y) }, gLabels);
        el('rect', { x: r1(rt.label.x - w / 2), y: r1(rt.label.y - 9), width: r1(w), height: 18, rx: 9 }, lg);
        el('text', { x: r1(rt.label.x), y: r1(rt.label.y + 3.6), style: 'font:' + SIZE.label.font }, lg).textContent = lt;
      }
    });

    // Nodes.
    Object.keys(lay.nodes).forEach(function (nid) {
      var n = byId[nid], s = shapes[nid], p = lay.nodes[nid];
      if (!n || !s || !s.parts) return;
      var c = colorOf[nid], ink = inkOf[nid];
      var g = el('g', { class: 'node in' + (n.isHub ? ' hub' : ''), style: '--d:' + delay(p.x, p.y) }, gNodes);
      var ix = p.x - s.icon / 2, iy = p.y;
      el('rect', {
        class: 'tile', x: r1(ix), y: r1(iy), width: s.icon, height: s.icon, rx: n.isHub ? 28 : 21,
        fill: c, 'fill-opacity': n.isHub ? 0.16 : 0.09, stroke: c, 'stroke-opacity': n.isHub ? 0.42 : 0.24
      }, g);
      if (n.isHub) el('rect', { class: 'pulse', x: r1(ix), y: r1(iy), width: s.icon, height: s.icon, rx: 28, stroke: ink }, g);
      drawIcon(g, icons[nid], p.x - s.glyph / 2, iy + (s.icon - s.glyph) / 2, s.glyph, ink);
      s.parts.name.forEach(function (l) {
        el('text', { class: 'name', x: r1(p.x), y: r1(p.y + l.y), style: 'font:' + s.name.font }, g).textContent = l.text;
      });
      s.parts.desc.forEach(function (l) {
        el('text', { class: 'desc', x: r1(p.x), y: r1(p.y + l.y), style: 'font:' + SIZE.desc.font }, g).textContent = l.text;
      });
      s.parts.extra.forEach(function (l) {
        el('text', { class: 'extra', x: r1(p.x), y: r1(p.y + l.y), style: 'font:' + SIZE.extra.font }, g).textContent = l.text;
      });
    });

    fit(host);
    return svg;
  }

  // Labels that would sit on one another slide apart along their legs, as far
  // as the legs go.
  function unclutter(routes) {
    var labs = routes.filter(function (rt) { return rt.label && rt.link.label; }).map(function (rt) {
      var L = rt.label;
      return { L: L, w: rt.link.labelW, h: 18 };
    });
    function hit(a, b) { return Math.abs(a.L.x - b.L.x) < (a.w + b.w) / 2 + 4 && Math.abs(a.L.y - b.L.y) < (a.h + b.h) / 2 + 3; }
    for (var round = 0; round < 3; round++) {
      labs.forEach(function (a, i) {
        for (var j = 0; j < i; j++) {
          var b = labs[j];
          if (!hit(a, b)) continue;
          var ax = a.L.axis, size = ax === 'y' ? (a.h + b.h) / 2 + 4 : (a.w + b.w) / 2 + 6;
          var half = ax === 'y' ? a.h / 2 + 2 : a.w / 2 + 4;
          var lo = a.L.lo + half, hi = a.L.hi - half, was = a.L[ax];
          var tries = [b.L[ax] + size, b.L[ax] - size].filter(function (v) { return v >= lo && v <= hi; });
          tries.sort(function (p, q) { return Math.abs(p - was) - Math.abs(q - was); });
          for (var t = 0; t < tries.length; t++) {
            a.L[ax] = tries[t];
            if (!labs.some(function (o, k) { return k !== i && hit(a, o); })) break;
            a.L[ax] = was;
          }
        }
      });
    }
  }

  // The drawing as large as fits the host, but never blown up past 1.7x.
  function fit(host) {
    var svg = host.querySelector('svg.mn');
    if (!svg) return;
    var vb = svg.viewBox.baseVal;
    var W = host.clientWidth, H = host.clientHeight;
    var k = Math.min(W / vb.width, H / vb.height, 1.7);
    svg.setAttribute('width', r1(vb.width * k));
    svg.setAttribute('height', r1(vb.height * k));
  }

  root.MermaidNetwork = { model: model, draw: draw, fit: fit, iconFor: iconFor };
})(this);
