/*
 * Picks a node's icon from its name. Pure functions over the icon set in
 * js/icon-set.js (names, keywords, Lucide tags) and the brand and service icons in
 * js/icon-brands.js (aliases); also works in Node.
 *
 *   best(name)                  -> an emoji in the name, else the best icon, else null
 *   rank(name)                  -> matching icon names, best first
 *   pick(name, current, empty)  -> the icon an auto-icon item should show now
 *   order(name, names)          -> names reordered for cycling: best matches first
 *
 * Scoring, per word of the name (case, accents and word endings ignored):
 * the icon's own name or one of our keywords (equal) > a Lucide tag > the start of
 * either. Scores add up over the words; ties go to the icon with the shorter
 * name, then to the one listed first in the set.
 *
 * Brand and service names ("Cloudflare Pages", "Next.js", "K8s", "S3") match as
 * phrases: runs of words, compared with spaces and punctuation taken out, so
 * "Next.js", "nextjs" and "next js" are one name. A phrase outscores any single
 * word (brands beat generic tags) and a longer phrase a shorter one (a service beats
 * its parent brand: "AWS Lambda" -> lambda, "AWS" -> the AWS logo). Between two
 * brands the one named first wins a tie. Weak aliases (~, ordinary words such as
 * python or rust) need a tech word, another brand or nothing much else in the name;
 * common aliases (!, everyday words such as go or snowflake) need a tech word or
 * another brand. So "Rust API" is Rust, "Go shopping" is not Go.
 */
(function (root) {
  'use strict';

  var NAME = 10, KEYWORD = 10, TAG = 5, PREFIX = 0.3, WHOLE = 2;
  var BRAND = 20, PHRASE = 5, BRAND_PREFIX = 2.9, LONGEST = 4; // a phrase of n words: BRAND + PHRASE * (n - 1)
  var TOP = 8; // matches that lead the cycle order

  // Words that say nothing about what a thing is.
  var STOP = {};
  ('a an the and or nor of to in on for with without by at from as is are be been was were my our your their its ' +
    'this that these those new vs via about into onto over under up out do does how what why when where who which ' +
    'it we you he she they i me us not no yes all any some more most very just so than then there here etc also ' +
    'get got make made use using used way ways part parts thing things stuff other others misc general untitled item items ' +
    'le la les de des du un une el los las del en y et und der die das mit von zu')
    .split(' ').forEach(function (w) { STOP[w] = true; });
  // Words in Lucide names that only describe the drawing.
  var SHAPE = { circle: 1, square: 1, big: 1, slightly: 1, horizontal: 1, vertical: 1, round: 1, pattern: 1 };

  function fold(s) {
    return String(s || '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase();
  }

  // A light stemmer: plurals, -ing, -ed and doubled consonants, so "deploying",
  // "deployed" and "deploys" all meet "deploy". A final e stays ("plane" is not
  // "plan"); matching puts it back where a cut ending lost it ("coding" -> "code").
  function stem(w) {
    if (w.length > 4 && /ies$/.test(w)) w = w.slice(0, -3) + 'y';
    else if (w.length > 4 && /(?:ch|sh|ss|x|z)es$/.test(w)) w = w.slice(0, -2);
    else if (w.length > 3 && /s$/.test(w) && !/(?:ss|us|is)$/.test(w)) w = w.slice(0, -1);
    if (w.length > 5 && /ing$/.test(w)) w = w.slice(0, -3);
    else if (w.length > 4 && /ed$/.test(w)) w = w.slice(0, -2);
    if (w.length > 3 && /([^aeiouls])\1$/.test(w)) w = w.slice(0, -1);
    return w;
  }

  function content(w) { return w.length > 1 && !STOP[w] && !/^\d+$/.test(w); }
  function words(s) {
    return fold(s).split(/[^a-z0-9]+/).filter(content);
  }
  // Every word, stop words and single letters included, for matching phrases;
  // C++, C#, F# and .NET keep their names.
  function tokens(s) {
    return fold(s).replace(/(^|[^a-z0-9])c\+\+/g, '$1 cplusplus ').replace(/(^|[^a-z0-9])([cf])#/g, '$1 $2sharp ')
      .replace(/(^|[^a-z0-9.])\.net\b/g, '$1 dotnet ').split(/[^a-z0-9]+/).filter(Boolean);
  }

  // Words that make a weak or common alias a brand: "Go API", "Snowflake warehouse".
  var CONTEXT = {}, NEUTRAL = {};
  ('code coding coder program programming programmer developer development dev devops language lang api sdk app application ' +
    'backend frontend fullstack server serverless deploy deployment hosting host cloud stack framework library lib package ' +
    'runtime database db sql nosql data warehouse pipeline cluster queue stream streaming service microservice tech web website ' +
    'repo repository build ci cd infra infrastructure integration auth authentication login oauth sso payment billing checkout ' +
    'email mail smtp plugin module migration migrate upgrade install setup config configuration docs documentation bot webhook ' +
    'compiler script cli terminal platform account storage bucket function worker edge cdn dns domain analytics monitoring log ' +
    'logging metric observability tracing alert ml ai model llm gpt index vector cache orm schema query endpoint env environment ' +
    'prod production staging container crate hook component jsx ui saas notebook dataset etl open source oss store cms blog')
    .split(' ').forEach(function (w) { CONTEXT[stem(w)] = true; });
  // Words that leave a weak alias standing on its own: "Learn Python", "Rust notes".
  ('learn learning basic basics intro introduction note notes course tutorial tip tips trick tricks guide book cheatsheet ' +
    'cheat sheet interview practice exercise overview resource resources roadmap study official version')
    .split(' ').forEach(function (w) { NEUTRAL[stem(w)] = true; });

  // First emoji in the text (with its skin tone, variation selector and ZWJ
  // parts), or a flag. Text-style symbols such as "→" or "©" don't count.
  var EMOJI = null;
  try {
    EMOJI = new RegExp('\\p{Regional_Indicator}{2}|(?:\\p{Emoji_Presentation}|\\p{Extended_Pictographic}\\uFE0F)\\p{Emoji_Modifier}?' +
      '(?:\\u200D\\p{Extended_Pictographic}\\uFE0F?\\p{Emoji_Modifier}?)*', 'u');
  } catch (e) { /* no Unicode property escapes: no emoji icons */ }
  function emoji(name) {
    var m = EMOJI && String(name || '').match(EMOJI);
    return m ? m[0] : null;
  }

  // ---------- Index ----------

  var src = null, srcBrands = null, built = false, set = {}, names = [], order0 = {}, nameWords = {}, exact = {}, raw = [];
  var phrases = {}, starts = [], brandIcon = {};
  function add(key, icon, w, word) {
    var list = exact[key] || (exact[key] = {});
    if (!list[icon] || list[icon] < w) list[icon] = w;
    raw.push([word, icon, w]);
  }
  // Aliases: "~python|python3" -> phrases["python"] = [{ icon, n: words, mode: 0 strong, 1 weak, 2 common }]
  function addAliases(icon, list) {
    String(list || '').split('|').forEach(function (a) {
      if (!a) return;
      var mode = a.charAt(0) === '~' ? 1 : a.charAt(0) === '!' ? 2 : 0;
      var ws = tokens(mode ? a.slice(1) : a);
      if (!ws.length) return;
      var key = ws.join('');
      // One entry per key and icon: its most words and strongest mode. A match counts the
      // words the name used ("Cloudflare" is one, "Ruby on Rails" three).
      var list = phrases[key] || (phrases[key] = []), n = Math.min(ws.length, LONGEST), p = null;
      list.forEach(function (x) { if (x.icon === icon) p = x; });
      if (p) { p.n = Math.max(p.n, n); p.mode = Math.min(p.mode, mode); } else list.push({ icon: icon, n: n, mode: mode });
      if (!mode && ws.length === 1 && key.length >= 4) starts.push([key, icon]);
    });
  }
  function index() {
    var node = typeof module !== 'undefined' && module.exports;
    var s = node ? require('./icon-set.js') : root.MindMapIconSet;
    var b = root.MindMapIconBrands;
    if (node && b === undefined) { try { b = require('./icon-brands.js'); } catch (e) { b = null; } }
    if (built && src === s && srcBrands === b) return;
    built = true;
    src = s;
    srcBrands = b;
    set = {};
    var k;
    for (k in s || {}) set[k] = s[k];
    var bi = (b && b.icons) || {};
    for (k in bi) if (!set[k]) set[k] = bi[k];
    names = Object.keys(set);
    exact = {}; raw = []; nameWords = {}; order0 = {}; phrases = {}; starts = []; brandIcon = {};
    names.forEach(function (icon, i) {
      order0[icon] = i;
      addAliases(icon, set[icon][3]);
      if (set[icon].length > 4) { brandIcon[icon] = true; nameWords[icon] = []; return; } // matched by its aliases only
      var own = icon.split('-').filter(function (w) { return !SHAPE[w] && !/^\d+$/.test(w); });
      nameWords[icon] = own.map(stem);
      own.forEach(function (w) { add(stem(w), icon, NAME, w); });
      if (own.length > 1) add(stem(own.join('')), icon, NAME, own.join('')); // "light bulb" -> lightbulb
      words(set[icon][1]).forEach(function (w) { add(stem(w), icon, KEYWORD, w); });
      words(set[icon][2]).forEach(function (w) { add(stem(w), icon, TAG, w); });
    });
    var sv = (b && b.services) || {};
    for (k in sv) if (set[k]) addAliases(k, sv[k]);
  }

  // Brand and service phrases in the name -> { icon: { score, pos } }.
  function phraseHits(text) {
    var toks = tokens(text), found = [], i, len;
    for (i = 0; i < toks.length; i++) {
      var key = '';
      for (len = 1; len <= 6 && i + len <= toks.length; len++) {
        key += toks[i + len - 1];
        var list = phrases[key] || (key.length > 4 && /s$/.test(key) && phrases[key.slice(0, -1)]); // "S3 buckets"
        if (list) list.forEach(function (p) { found.push({ icon: p.icon, n: Math.min(p.n, len), mode: p.mode, s: i, e: i + len }); });
      }
    }
    var covered = [];
    found.forEach(function (f) { for (var t = f.s; t < f.e; t++) covered[t] = true; });
    var rest = []; // content words that no phrase covers
    toks.forEach(function (t, k) { if (!covered[k] && content(t)) rest.push(stem(t)); });
    var context = rest.some(function (w) { return CONTEXT[w]; });
    var alone = rest.every(function (w) { return NEUTRAL[w]; });
    var ok = found.filter(function (f) { return f.mode === 0; });
    var apart = function (f) {
      return ok.some(function (o) { return o.icon !== f.icon && (o.e <= f.s || o.s >= f.e); });
    };
    found.forEach(function (f) { if (f.mode === 1 && (context || alone || apart(f))) ok.push(f); });
    found.forEach(function (f) { if (f.mode === 2 && (context || apart(f))) ok.push(f); });
    var hits = {}, used = [];
    ok.forEach(function (f) {
      for (var t = f.s; t < f.e; t++) used[t] = true;
      var score = BRAND + PHRASE * (f.n - 1), h = hits[f.icon];
      if (!h || h.score < score || (h.score === score && f.s < h.pos)) hits[f.icon] = { score: score, pos: f.s };
    });
    // Still typing the last word: the start of a brand's name counts a little.
    var last = toks[toks.length - 1];
    if (last && last.length >= 4 && !covered[toks.length - 1] && !exact[stem(last)]) {
      starts.forEach(function (st) {
        if (st[0].length > last.length && st[0].lastIndexOf(last, 0) === 0 && !hits[st[1]]) hits[st[1]] = { score: BRAND_PREFIX, pos: toks.length - 1 };
      });
    }
    return { hits: hits, toks: toks, used: used };
  }

  // -> [{ name, score }], best first
  function scored(text) {
    index();
    var ph = phraseHits(text), brands = ph.hits;
    // Words a brand or service took ("docker" in "Docker containers") don't also count as keywords.
    var ws = ph.toks.filter(function (t, i) { return !ph.used[i] && content(t); });
    if (!ws.length && !Object.keys(brands).length) return [];
    var total = {}, stems = [], pos = {};
    for (var b in brands) { total[b] = brands[b].score; pos[b] = brands[b].pos; }
    ws.forEach(function (t) {
      var k = stem(t);
      if (!exact[k] && exact[k + 'e']) k += 'e'; // coding -> cod -> code, without folding plane into plan
      var hits = exact[k];
      stems.push(k);
      if (!hits && t.length >= 3) { // still typing? the start of a word counts a little
        hits = {};
        raw.forEach(function (r) {
          if (r[0].length > t.length && r[0].lastIndexOf(t, 0) === 0 && (hits[r[1]] || 0) < r[2] * PREFIX) hits[r[1]] = r[2] * PREFIX;
        });
      }
      for (var icon in hits) total[icon] = (total[icon] || 0) + hits[icon];
    });
    var out = Object.keys(total).map(function (icon) {
      var own = nameWords[icon];
      var whole = own.length > 0 && own.every(function (w) { return stems.indexOf(w) >= 0; });
      return { name: icon, score: total[icon] + (whole ? WHOLE : 0) };
    });
    out.sort(function (a, b) {
      return b.score - a.score || (brandIcon[a.name] && brandIcon[b.name] ? pos[a.name] - pos[b.name] : 0) ||
        nameWords[a.name].length - nameWords[b.name].length || order0[a.name] - order0[b.name];
    });
    return out;
  }

  function rank(text) { return scored(text).map(function (r) { return r.name; }); }

  function best(text) {
    return emoji(text) || rank(text)[0] || null;
  }

  // What an item whose icon follows its name should show. Nothing matching
  // keeps the current icon, unless that is an emoji the name no longer has
  // (then `empty`, the default icon). A current icon that ties with the best
  // one stays, so the icon doesn't flip between equals while typing.
  function pick(text, current, empty) {
    var e = emoji(text);
    if (e) return e;
    var r = scored(text);
    if (!r.length) {
      index();
      var gone = current && !Object.prototype.hasOwnProperty.call(set, current) && String(text || '').indexOf(current) < 0;
      return gone && empty ? empty : current;
    }
    for (var i = 0; i < r.length && r[i].score === r[0].score; i++) if (r[i].name === current) return current;
    return r[0].name;
  }

  // The cycle order for clicking the icon: the best matches for the name, then the rest.
  function order(text, list) {
    list = list || (index(), names);
    var inList = {};
    list.forEach(function (n) { inList[n] = true; });
    var top = rank(text).filter(function (n) { return inList[n]; }).slice(0, TOP);
    return top.concat(list.filter(function (n) { return top.indexOf(n) < 0; }));
  }

  var api = { best: best, rank: rank, pick: pick, order: order, emoji: emoji, stem: stem, words: words, tokens: tokens };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.MindMapIconMatch = api;
})(this);
