#!/usr/bin/env node
/**
 * clone-health.js - does this machine's picture of its own repos match reality?
 *
 * Why it exists: three machines once each published a confident wrong
 * conclusion in the same hour, and every one of them came from the same defect:
 * a probe measured
 * one thing and the claim asserted another. A clone can be git-clean, current,
 * and materially broken at the same time.
 *
 * Read-only, and that is a hard rule, not a default. It never resets, prunes
 * local refs, re-clones, deletes a branch, cleans, or fast-forwards on anyone's
 * behalf. `git fetch` is additive and always safe; nothing else is. "Fetch, see
 * nothing unique, reset to origin" is correct for a stranded framework clone and
 * lethal for a repo holding deliberate local commits - telling those two apart
 * before anyone reaches for a remedy is the entire point of check 3.
 *
 * The checks, and what each one actually measures:
 *   1 fetch      - exit code CHECKED and reported. ahead/behind are computed
 *                  against the last fetch, not the server; a stale ref reports
 *                  0/0, indistinguishable from health. Never 2>/dev/null.
 *   2 divergence - both counts non-zero. `merge-base --is-ancestor` alone is
 *                  wrong: it is false for any branch merely ahead, i.e. normal.
 *   3 local-only - `log --all --not --remotes`: work on any branch, reachable
 *                  from no remote ref. Immune to a stale upstream. Plus stashes.
 *   4 stamps     - shipped migrations vs ~/.claude/ej-migrations. Git currency
 *                  and installed-state currency are different things.
 *   5 visibility - anonymous ls-remote. Public-vs-private outranks any
 *                  framework-vs-memory layout argument, so it is on every line.
 *   6 safety     - the upstream tip's author and date. "What is only on this
 *                  disk" (check 3) cannot answer "is my work safe": work pushed
 *                  from another machine is on the server and on no local ref.
 *                  Never ask which machine something was done on - git knows.
 *   7 registered - `--registered <basename>`: what still points at a file you
 *                  moved or retired. A retirement is not done until every root
 *                  that ships the file stops shipping it.
 *   8 hooks      - a registration in settings.json is a CLAIM that something
 *                  runs every session. It is false when the script is absent,
 *                  and false in a quieter way when the script runs and exits 0
 *                  because what it fronts is not installed - which is why "my
 *                  memory recalled nothing" and "this machine has no memory"
 *                  read identically from inside a session. Named, not assumed.
 *
 * Usage:
 *   node claude-setup/scripts/clone-health.js              # every repo, one line each
 *   node claude-setup/scripts/clone-health.js -q           # only repos with flags
 *   node claude-setup/scripts/clone-health.js --json
 *   node claude-setup/scripts/clone-health.js --no-fetch   # loud: baseline is stale
 *   node claude-setup/scripts/clone-health.js --registered context-guard.sh
 *   node claude-setup/scripts/clone-health.js --root ~/projects/03_ai
 *
 * Exit 1 when any of !DIVERGED !LOCAL-ONLY !STASH !FETCH-FAILED fired: those mean
 * work exists in exactly one place. Behind-only is informational - it recovers.
 */

'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');

const argv = process.argv.slice(2);
const takeArg = (name) => {
  const i = argv.indexOf(name);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : null;
};

const OPT = {
  json: argv.includes('--json'),
  quiet: argv.includes('-q') || argv.includes('--quiet'),
  verbose: argv.includes('--verbose') || argv.includes('-v'),
  noFetch: argv.includes('--no-fetch'),
  registered: takeArg('--registered'),
  extraRoot: takeArg('--root'),
  jobs: Number(takeArg('--jobs')) || 6,
  color: !argv.includes('--no-color') && process.stdout.isTTY && !argv.includes('--json'),
};

const HOME = os.homedir();
const CLAUDE_DIR = path.join(HOME, '.claude');
const FETCH_TIMEOUT = 90000;
const PROBE_TIMEOUT = 20000;

const C = (code, s) => (OPT.color ? `\x1b[${code}m${s}\x1b[0m` : s);
const red = (s) => C('31', s);
const yellow = (s) => C('33', s);
const green = (s) => C('32', s);
const dim = (s) => C('2', s);
const bold = (s) => C('1', s);

// ---------------------------------------------------------------------------
// process plumbing
// ---------------------------------------------------------------------------

/** Run git. Resolves with {code, out, err} - a non-zero code is data, not a throw. */
function git(args, cwd, opts = {}) {
  return new Promise((resolve) => {
    const child = spawn('git', args, {
      cwd,
      env: { ...process.env, GIT_TERMINAL_PROMPT: '0', GIT_OPTIONAL_LOCKS: '0', ...(opts.env || {}) },
      windowsHide: true,
    });
    let out = '';
    let err = '';
    let timer = null;
    let done = false;
    const finish = (code, extra) => {
      if (done) return;
      done = true;
      if (timer) clearTimeout(timer);
      resolve({ code, out: out.trim(), err: (err + (extra || '')).trim() });
    };
    child.stdout.on('data', (d) => { out += d; });
    child.stderr.on('data', (d) => { err += d; });
    child.on('error', (e) => finish(127, `\n${e.message}`));
    child.on('close', (code) => finish(code === null ? 130 : code));
    if (opts.timeout) {
      timer = setTimeout(() => {
        try { child.kill(); } catch { /* already gone */ }
        finish(124, `\ntimed out after ${Math.round(opts.timeout / 1000)}s`);
      }, opts.timeout);
    }
  });
}

/** Resolve at most `limit` of `fn` at a time, preserving input order in the result. */
async function pool(items, limit, fn) {
  const results = new Array(items.length);
  let next = 0;
  const workers = Array.from({ length: Math.min(limit, items.length) }, async () => {
    for (;;) {
      const i = next++;
      if (i >= items.length) return;
      results[i] = await fn(items[i], i);
    }
  });
  await Promise.all(workers);
  return results;
}

const isDir = (p) => { try { return fs.statSync(p).isDirectory(); } catch { return false; } };
const isFile = (p) => { try { return fs.statSync(p).isFile(); } catch { return false; } };
const readText = (p) => { try { return fs.readFileSync(p, 'utf8'); } catch { return null; } };
const expandHome = (p) => (p.startsWith('~') ? path.join(HOME, p.slice(1)) : p);
const lines = (s) => (s ? s.split(/\r?\n/).filter(Boolean) : []);

// ---------------------------------------------------------------------------
// layout: where the roots and the conf live
// ---------------------------------------------------------------------------

const CONF_DEFAULTS = {
  MEMORY_DIR: 'claude-setup/memory',
  QUEUE_FILE: '',
  PROJECT_ROOTS: '',
};

function loadConf(repo) {
  const conf = { ...CONF_DEFAULTS };
  const text = repo && readText(path.join(repo, 'claude-setup/config/sunstone.conf'));
  if (!text) return conf;
  for (const line of lines(text)) {
    const m = /^\s*([A-Z0-9_]+)\s*=\s*(.*)$/.exec(line);
    if (!m) continue;
    conf[m[1]] = m[2].trim().replace(/^["']|["']$/g, '');
  }
  return conf;
}

/** The repo named in ~/.claude/<file>, when it really is a git checkout. */
function pathFileRepo(file) {
  const recorded = (readText(path.join(CLAUDE_DIR, file)) || '').trim();
  if (!recorded) return null;
  const dir = path.resolve(expandHome(recorded));
  return isDir(path.join(dir, '.git')) ? dir : null;
}

/**
 * Every git checkout under the roots, to depth 3. Descent stops at a .git: a
 * repo's submodules and vendored checkouts are that repo's business, not ours.
 */
function discoverRepos(roots) {
  const found = new Set();
  const walk = (dir, depth) => {
    if (depth > 3 || !isDir(dir)) return;
    if (isDir(path.join(dir, '.git')) || isFile(path.join(dir, '.git'))) {
      found.add(dir);
      return;
    }
    let entries = [];
    try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
    for (const e of entries) {
      if (!e.isDirectory()) continue;
      if (e.name === 'node_modules' || e.name.startsWith('.')) continue;
      walk(path.join(dir, e.name), depth + 1);
    }
  };
  for (const r of roots) walk(path.resolve(expandHome(r)), 1);
  return [...found].sort();
}

const label = (dir) => {
  const rel = path.relative(HOME, dir);
  return rel && !rel.startsWith('..') ? rel.split(path.sep).join('/') : dir.split(path.sep).join('/');
};

/** An https URL for an origin of any form, so the probe can go out anonymously. */
function httpsUrl(url) {
  if (!url) return null;
  let m = /^git@([^:]+):(.+?)(?:\.git)?$/.exec(url);
  if (m) return 'https://' + m[1] + '/' + m[2];
  m = /^ssh:\/\/git@([^/]+)\/(.+?)(?:\.git)?$/.exec(url);
  if (m) return 'https://' + m[1] + '/' + m[2];
  m = /^(https:\/\/)(?:[^@/]+@)?(.+?)(?:\.git)?$/.exec(url);
  if (m) return m[1] + m[2];
  return null;
}

// ---------------------------------------------------------------------------
// the per-repo checks
// ---------------------------------------------------------------------------

async function inspect(dir) {
  const r = {
    dir,
    name: label(dir),
    visibility: '?',
    branch: '?',
    behind: null,
    ahead: null,
    flags: [],
    notes: [],
    remoteTip: null,
  };

  const head = await git(['rev-parse', '--abbrev-ref', 'HEAD'], dir);
  r.branch = head.code === 0 ? head.out : '?';
  if (r.branch === 'HEAD') {
    const sha = await git(['rev-parse', '--short', 'HEAD'], dir);
    r.branch = 'detached@' + (sha.out || '?');
    r.notes.push('HEAD is detached - a commit made here is reachable from no branch.');
  }

  const originUrl = await git(['remote', 'get-url', 'origin'], dir);
  const hasOrigin = originUrl.code === 0 && Boolean(originUrl.out);
  if (!hasOrigin) r.flags.push('!NO-ORIGIN');

  // --- check 1: fetch, with its exit code checked and reported -------------
  let fetched = false;
  if (!hasOrigin) {
    r.notes.push('no origin: nothing committed here has anywhere to go.');
  } else if (OPT.noFetch) {
    r.notes.push('--no-fetch: the counts below are measured against the LAST fetch, not the server.');
  } else {
    const f = await git(['fetch', '--all', '--prune'], dir, { timeout: FETCH_TIMEOUT });
    fetched = f.code === 0;
    if (!fetched) {
      r.flags.push('!FETCH-FAILED');
      const why = lines(f.err).filter((l) => !/^From /.test(l)).pop() || ('exit ' + f.code);
      r.notes.push('fetch failed: ' + why);
      r.notes.push('ahead/behind suppressed - every number computed after a failed fetch is fiction. ' +
        'An HTTPS remote with no credential helper is also the likely cause of unpushed work here: ' +
        'the push failed the same way, just as quietly.');
    } else if (/forced update/.test(f.err)) {
      r.notes.push('remote history was rewritten: ' +
        lines(f.err).filter((l) => /forced update/.test(l)).join('; '));
    }
  }

  // --- check 2: divergence, and which kind ---------------------------------
  const up = await git(['rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}'], dir);
  const upstream = up.code === 0 ? up.out : null;
  if (hasOrigin && !upstream) r.notes.push(r.branch + ' tracks nothing - "behind" is undefined for it.');

  if (upstream && (fetched || OPT.noFetch)) {
    const behind = await git(['rev-list', '--count', 'HEAD..' + upstream], dir);
    const ahead = await git(['rev-list', '--count', upstream + '..HEAD'], dir);
    r.behind = behind.code === 0 ? Number(behind.out) : null;
    r.ahead = ahead.code === 0 ? Number(ahead.out) : null;

    if (r.behind > 0 && r.ahead > 0) {
      r.flags.push('!DIVERGED');
      // Both counts non-zero is where THREE very different situations meet, and
      // the remedy for one ruins the others. Name which one, from a probe, or
      // say nothing: "-44 +263" read as "a bit behind, a bit ahead" on a clone
      // that shares no history with its remote at all.
      const base = await git(['merge-base', 'HEAD', upstream], dir);
      const haveBase = base.code === 0 && base.out;
      const cherry = await git(['cherry', upstream, 'HEAD'], dir);
      const dup = lines(cherry.out).filter((l) => l.startsWith('-')).length;

      if (!haveBase) {
        // No merge base: not divergence at all, two unrelated histories. A
        // renamed repo whose URL still redirects looks exactly like this.
        r.flags.push('!UNRELATED');
        r.notes.push('NO COMMON ANCESTOR with ' + upstream + '. These are different histories, not a ' +
          'branch that drifted - a recreated or renamed remote (the old URL still redirects) reads this way. ' +
          'Neither pull nor rebase is meaningful here; the question is which repo this work belongs in.');
      } else if (dup > 0) {
        r.flags.push('!REWRITTEN:' + dup);
        r.notes.push(dup + ' of your ' + r.ahead + ' local commit(s) already exist upstream under a ' +
          'different sha - a stranded pre-rewrite line, not work in progress. A rebase replays duplicates.');
      } else {
        const baseAt = await git(['log', '-1', '--format=%h %ci', base.out], dir);
        r.notes.push('ordinary concurrent work: a common ancestor exists (' + (baseAt.out || base.out) +
          ') and no local commit is already upstream by patch-id, so `git pull --rebase` resolves it. ' +
          '(Probes: `git merge-base` found a base; `git cherry` found no duplicate.)');
      }
    }
    if (r.behind > 20) r.flags.push('!BEHIND:' + r.behind);
  }

  // --- check 3: what exists only on this disk ------------------------------
  // %d carries the ref: "only on this disk" on a branch named backup/... is a
  // deliberate backup, and on main it is unpushed work. Same count, and the
  // reader should not have to run a second command to tell them apart.
  const localOnly = await git(['log', '--all', '--not', '--remotes', '--format=%h%d %an %ci %s'], dir);
  const localOnlyCommits = lines(localOnly.out);
  if (localOnlyCommits.length) {
    r.flags.push('!LOCAL-ONLY:' + localOnlyCommits.length);
    r.localOnly = localOnlyCommits;
  }
  const stash = await git(['stash', 'list'], dir);
  const stashes = lines(stash.out);
  if (stashes.length) {
    r.flags.push('!STASH:' + stashes.length);
    r.stashes = stashes;
  }
  const dirty = await git(['status', '--porcelain'], dir);
  const dirtyFiles = lines(dirty.out);
  if (dirtyFiles.length) {
    r.flags.push('!DIRTY:' + dirtyFiles.length);
    r.dirty = dirtyFiles;
  }

  // --- check 5: visibility, before any layout argument ---------------------
  if (hasOrigin) {
    const url = httpsUrl(originUrl.out);
    r.origin = originUrl.out;
    if (url) {
      const probe = await git(['-c', 'credential.helper=', 'ls-remote', '--heads', url], dir, {
        timeout: PROBE_TIMEOUT,
        env: { GIT_ASKPASS: 'echo', GCM_INTERACTIVE: 'never' },
      });
      r.visibility = probe.code === 0
        ? 'pub'
        : (/authentication|could not read|denied|403|not found|terminal prompts disabled/i.test(probe.err) ? 'priv' : '?');
    }
  }

  // --- check 6: is my work safe - which check 3 cannot answer --------------
  if (upstream) {
    const tip = await git(['log', upstream, '-1', '--format=%h %an %ci %s'], dir);
    if (tip.code === 0 && tip.out) r.remoteTip = tip.out;
  }

  return r;
}

// ---------------------------------------------------------------------------
// check 4 - stamp drift: git currency is not installed-state currency
// ---------------------------------------------------------------------------

function migrationReport(roots) {
  const stampDir = process.env.EJ_MIGRATIONS_DIR || path.join(CLAUDE_DIR, 'ej-migrations');
  const out = { stampDir, shippedBy: [], shipped: [], ran: [], pending: [], failing: [], mechanismDead: false };

  for (const root of roots) {
    const dir = path.join(root, 'claude-setup/migrations');
    if (!isDir(dir)) continue;
    let files = [];
    try { files = fs.readdirSync(dir).filter((f) => /\.(sh|mjs|js)$/.test(f)); } catch { continue; }
    if (!files.length) continue;
    out.shippedBy.push(label(root));
    for (const f of files) {
      const name = f.replace(/\.(sh|mjs|js)$/, '');
      if (!out.shipped.includes(name)) out.shipped.push(name);
    }
  }
  if (!out.shipped.length) return out;

  const stamps = isDir(stampDir) ? fs.readdirSync(stampDir) : [];
  for (const name of out.shipped.sort()) {
    if (stamps.includes(name)) { out.ran.push(name); continue; }
    const attemptsFile = path.join(stampDir, name + '.attempts');
    const logFile = path.join(stampDir, name + '.log');
    const attempts = Number((readText(attemptsFile) || '').trim()) || 0;
    const lastLog = lines(readText(logFile) || '').pop() || '';
    if (attempts > 0 || lastLog) out.failing.push({ name, attempts, lastLog });
    else out.pending.push(name);
  }
  // A flag that fires for EVERY migration is reporting a broken mechanism, not
  // a stale clone - and it should say so in those words rather than print the
  // same line N times and let the reader assume they are the outlier.
  out.mechanismDead = out.ran.length === 0;
  return out;
}

// ---------------------------------------------------------------------------
// check 5 (second half) - drift is a claim about two SPECIFIC files
// ---------------------------------------------------------------------------

/**
 * setup.sh order is framework root, then the personal overlay, and the LAST
 * root that ships a file wins. For ~/.claude/CLAUDE.md a CLAUDE.global.md from
 * either root beats agents/CLAUDE.md. Comparing a live file against the wrong
 * candidate is how a session reported an upgrade as an impending overwrite.
 */
function claudeMdReport(roots) {
  const winnerFor = (dest) => {
    let winner = null;
    for (const root of roots) {
      if (dest === 'home') {
        const p = path.join(root, 'agents/CLAUDE.md');
        if (isFile(p)) winner = p;
      } else {
        const g = path.join(root, 'claude-setup/config/CLAUDE.global.md');
        if (isFile(g)) { winner = g; continue; }
        const a = path.join(root, 'agents/CLAUDE.md');
        if (isFile(a) && !winner) winner = a;
      }
    }
    // CLAUDE.global.md from any root outranks every agents/CLAUDE.md.
    if (dest === 'claude') {
      const globals = roots
        .map((root) => path.join(root, 'claude-setup/config/CLAUDE.global.md'))
        .filter(isFile);
      if (globals.length) winner = globals[globals.length - 1];
    }
    return winner;
  };

  const rows = [];
  for (const [dest, live] of [['home', path.join(HOME, 'CLAUDE.md')], ['claude', path.join(CLAUDE_DIR, 'CLAUDE.md')]]) {
    const source = winnerFor(dest);
    const row = { live, source, state: 'ok', detail: '' };
    let lst = null;
    try { lst = fs.lstatSync(live); } catch { /* absent */ }
    if (!lst) {
      row.state = 'missing';
      row.detail = 'no file installed here';
    } else if (lst.isSymbolicLink()) {
      const target = fs.readlinkSync(live);
      row.state = 'link';
      row.detail = '-> ' + target + (source && path.resolve(target) === path.resolve(source)
        ? ' (the source that installs here - editing the live file edits the repo)'
        : source ? ' (NOT ' + source + ', which is what installs here)' : '');
    } else if (!source) {
      row.state = 'no-source';
      row.detail = 'nothing in any root installs to this destination - the live file is unmanaged';
    } else {
      const a = readText(live);
      const b = readText(source);
      if (a === b) {
        row.detail = 'identical to ' + label(source);
      } else {
        row.state = 'differs';
        const ta = fs.statSync(live).mtimeMs;
        const tb = fs.statSync(source).mtimeMs;
        const newer = ta === tb ? null : (ta > tb ? 'the live file' : 'the repo source');
        row.detail = label(live) + ' (' + (a || '').length + 'B) differs from ' + label(source) +
          ' (' + (b || '').length + 'B), which is what installs here' +
          (newer ? '; newer by mtime: ' + newer : '; mtimes are equal - which side is newer is unknown');
      }
    }
    rows.push(row);
  }
  return rows;
}

// ---------------------------------------------------------------------------
// check 8 - a registered hook is a CLAIM about this machine, not a fact
// ---------------------------------------------------------------------------

/**
 * Every SessionStart hook in settings.json asserts that something runs at the
 * start of every session. Two ways that is false and neither shows up anywhere:
 * the script is registered but absent, or it is present and exits 0 because the
 * thing it fronts is not installed here. The second is deliberate in a hook - a
 * machine without a memory is not an error, and nobody wants a nag every session
 * - but it means a session cannot tell "my memory recalled nothing" from "I have
 * no memory". That distinction belongs in a diagnostic, which is here.
 *
 * Reported, never assumed: a hook whose dependency is missing is listed as
 * REGISTERED BUT INERT with the paths that were probed, so the claim and the
 * evidence sit on the same screen.
 */
function hookReport(memoryRepo, conf) {
  const settingsFile = path.join(CLAUDE_DIR, 'settings.json');
  const text = readText(settingsFile);
  if (!text) return null;
  let parsed;
  try { parsed = JSON.parse(text); } catch { return { error: 'settings.json is not valid JSON' }; }

  const rows = [];
  for (const [event, groups] of Object.entries((parsed && parsed.hooks) || {})) {
    for (const g of Array.isArray(groups) ? groups : []) {
      for (const h of (g && g.hooks) || []) {
        const cmd = String((h && h.command) || '');
        if (!cmd) continue;
        // The script in `bash ~/.claude/hooks/x.sh --flag` / `node C:/.../y.mjs`.
        const m = /(?:^|\s)((?:~|\/|[A-Za-z]:)[^\s"']+\.(?:sh|js|mjs|ps1|py))/.exec(cmd);
        const script = m ? expandHome(m[1]) : null;
        rows.push({
          event,
          command: cmd.length > 90 ? cmd.slice(0, 87) + '...' : cmd,
          script,
          present: script ? isFile(script) : null,
        });
      }
    }
  }

  // The one dependency we can resolve without running anything: palimpsest's
  // wrapper looks for build/cli/recall.js under the PALIMPSEST_REPO hints, then
  // under every <root>/*/palimpsest, then the private install, and exits 0 when
  // none of them exists. PALIMPSEST_REPO is a space-separated LIST, not one
  // absolute path: sunstone.conf is git-synced to every machine and the checkout
  // sits under a different group dir on each, so the glob for the leaf name is
  // what makes this report right on all of them. Mirror of palimpsest-recall.sh.
  let palimpsest = null;
  if (rows.some((r) => r.script && r.script.includes('palimpsest-recall'))) {
    const list = (v) => String(v || '').trim().split(/\s+/).filter(Boolean).map(expandHome);
    const roots = [...list(conf.PROJECT_ROOTS), path.join(HOME, 'projects'), path.join(HOME, 'Projects')];
    const discovered = [];
    for (const r of roots) {
      let kids = [];
      try {
        kids = fs.readdirSync(r, { withFileTypes: true }).filter((e) => e.isDirectory()).map((e) => e.name);
      } catch { /* root absent on this machine */ }
      for (const d of [r, ...kids.map((n) => path.join(r, n))]) discovered.push(path.join(d, 'palimpsest'));
    }
    const candidates = [...new Set(
      [...list(conf.PALIMPSEST_REPO), ...discovered, path.join(HOME, '.palimpsest/lib')]
        .filter(Boolean)
        .map((c) => path.resolve(c)))]
      .map((c) => ({ dir: c, entry: path.join(c, 'build/cli/recall.js'), found: isFile(path.join(c, 'build/cli/recall.js')) }))
      .filter((c) => c.found || isDir(c.dir));
    const db = path.join(HOME, '.palimpsest/memory.db');
    palimpsest = { candidates, live: candidates.some((c) => c.found), db, dbPresent: isFile(db) };
  }
  return { settingsFile, rows, palimpsest, memoryRepo };
}

// ---------------------------------------------------------------------------
// check 7 - when something moves, ask what stops running
// ---------------------------------------------------------------------------

function registrationReport(basename, roots) {
  const hits = [];
  const scan = (file) => {
    const text = readText(file);
    if (!text) return;
    lines(text).forEach((line, i) => {
      if (line.includes(basename)) hits.push({ file, line: i + 1, text: line.trim() });
    });
  };
  scan(path.join(CLAUDE_DIR, 'settings.json'));
  scan(path.join(CLAUDE_DIR, 'settings.local.json'));
  for (const root of roots) {
    const cfg = path.join(root, 'claude-setup/config');
    if (!isDir(cfg)) continue;
    for (const f of fs.readdirSync(cfg)) {
      if (/\.(json|conf)$/.test(f)) scan(path.join(cfg, f));
    }
  }
  const ships = [];
  for (const root of roots) {
    const stack = [path.join(root, 'claude-setup')];
    while (stack.length) {
      const dir = stack.pop();
      if (!isDir(dir)) continue;
      for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
        const p = path.join(dir, e.name);
        if (e.isDirectory()) { if (e.name !== 'node_modules') stack.push(p); continue; }
        if (e.name === basename) ships.push(p);
      }
    }
  }
  const installed = isFile(path.join(CLAUDE_DIR, 'hooks', basename)) ? path.join(CLAUDE_DIR, 'hooks', basename) : null;
  return { hits, ships, installed };
}

// ---------------------------------------------------------------------------
// the union-merge trade: duplicates are the expected cost, not a bug
// ---------------------------------------------------------------------------

function queueDuplicates(repo, queueFile) {
  if (!repo || !queueFile) return null;
  const file = path.join(repo, queueFile);
  const text = readText(file);
  if (!text) return null;
  const rows = lines(text).filter((l) => l.startsWith('|') && l.replace(/[|\-\s]/g, '').length > 0);
  const dups = [];
  const seen = new Map();
  for (const row of rows) {
    const key = row.trim();
    if (seen.has(key)) dups.push(key.slice(0, 120));
    else seen.set(key, true);
  }
  return { file, rows: rows.length, dups };
}

// ---------------------------------------------------------------------------
// rendering
// ---------------------------------------------------------------------------

const STRANDING = ['!DIVERGED', '!LOCAL-ONLY', '!STASH', '!FETCH-FAILED'];
const strands = (r) => r.flags.some((f) => STRANDING.some((s) => f.startsWith(s)));

function pad(s, n) { return String(s).length >= n ? String(s) : String(s) + ' '.repeat(n - String(s).length); }

function renderRepo(r, widths) {
  const count = (n, sign) => (n === null ? '-' : sign + n);
  const flags = r.flags.map((f) => (strands(r) && STRANDING.some((s) => f.startsWith(s)) ? red(f) : yellow(f))).join(' ');
  return [
    pad(r.name, widths.name),
    pad(r.visibility, 5),
    pad(r.branch, widths.branch),
    pad(count(r.behind, '-'), 5),
    pad(count(r.ahead, '+'), 5),
    flags,
  ].join(' ').trimEnd();
}

function renderDetail(r) {
  const out = [];
  for (const note of r.notes) out.push('      ' + dim(note));
  if (r.localOnly) {
    out.push('      ' + dim('only on this disk:'));
    for (const c of r.localOnly.slice(0, OPT.verbose ? 50 : 5)) out.push('        ' + c);
    if (!OPT.verbose && r.localOnly.length > 5) out.push('        ' + dim('... ' + (r.localOnly.length - 5) + ' more (--verbose)'));
  }
  if (r.stashes) for (const s of r.stashes) out.push('      stash: ' + s);
  if (r.dirty && OPT.verbose) for (const d of r.dirty) out.push('      dirty: ' + d);
  if (r.remoteTip) out.push('      ' + dim('upstream tip: ' + r.remoteTip));
  return out;
}

function main(repos, mig, claudeMd, queue, reg, hooksRep) {
  if (OPT.json) {
    process.stdout.write(JSON.stringify({ repos, migrations: mig, claudeMd, queue, registered: reg, hooks: hooksRep }, null, 2) + '\n');
    return;
  }

  const shown = OPT.quiet ? repos.filter((r) => r.flags.length) : repos;
  const widths = {
    name: Math.max(4, ...shown.map((r) => r.name.length)),
    branch: Math.max(6, ...shown.map((r) => r.branch.length)),
  };

  if (OPT.noFetch) {
    console.log(yellow('!! --no-fetch: nothing below was measured against a server. ' +
      'A stale remote-tracking ref reports 0/0, which is indistinguishable from health.'));
  }
  console.log(bold('repo'.padEnd(widths.name) + '  vis   ' + 'branch'.padEnd(widths.branch) + '  -behind +ahead  flags'));
  for (const r of shown) {
    console.log(renderRepo(r, widths));
    if (r.flags.length || OPT.verbose) for (const l of renderDetail(r)) console.log(l);
  }
  if (!shown.length) console.log(dim('(no repo carries a flag)'));

  // --- check 4 ------------------------------------------------------------
  if (mig.shipped.length) {
    console.log('');
    console.log(bold('migrations') + dim('  (git currency and installed-state currency are different things)'));
    console.log('  stamps: ' + mig.stampDir);
    console.log('  shipped by ' + mig.shippedBy.join(', ') + ': ' + mig.shipped.length +
      ', stamped here: ' + mig.ran.length);
    if (mig.mechanismDead) {
      console.log('  ' + red('NONE of the ' + mig.shipped.length + ' shipped migrations has ever run on this machine.'));
      console.log('  ' + dim('That is a broken mechanism, not a stale clone. Check the other machines before ' +
        'assuming you are the outlier: run claude-setup/scripts/migrate.sh --auto and read what it prints.'));
    }
    for (const f of mig.failing) {
      console.log('  ' + red('!STAMP-DRIFT') + ' ' + f.name + ': attempted ' +
        (f.attempts || '?') + 'x, never stamped');
      if (f.lastLog) console.log('      ' + dim('last log: ' + f.lastLog.slice(0, 160)));
      console.log('      ' + dim('it is retried every session and has failed every time, silently.'));
    }
    for (const p of mig.pending) console.log('  ' + yellow('!STAMP-DRIFT') + ' ' + p + ': never attempted here');
    if (!mig.failing.length && !mig.pending.length && !mig.mechanismDead) {
      console.log('  ' + green('all shipped migrations have run here'));
    }
  }

  // --- check 5, second half ------------------------------------------------
  console.log('');
  console.log(bold('CLAUDE.md destinations') + dim('  (a drift claim names BOTH files it compared)'));
  for (const row of claudeMd) {
    const mark = row.state === 'differs' ? yellow('differs') : row.state === 'ok' ? green('ok') : yellow(row.state);
    console.log('  ' + pad(mark, 18) + label(row.live));
    console.log('      ' + dim(row.detail));
  }

  // --- the union-merge trade ----------------------------------------------
  if (queue) {
    console.log('');
    console.log(bold('work queue') + dim('  (merge=union keeps both sides: a duplicate row is the trade, not a bug)'));
    console.log('  ' + label(queue.file) + ': ' + queue.rows + ' rows, ' +
      (queue.dups.length ? yellow(queue.dups.length + ' duplicated') : green('no duplicates')));
    for (const d of queue.dups) console.log('      ' + d);
  }

  // --- check 8 -------------------------------------------------------------
  if (hooksRep && hooksRep.rows) {
    const missing = hooksRep.rows.filter((r) => r.present === false);
    console.log('');
    console.log(bold('registered hooks') + dim('  (a registration is a claim that something runs every session)'));
    console.log('  ' + hooksRep.rows.length + ' registered, ' +
      (missing.length ? red(missing.length + ' pointing at a file that is not there') : green('all present')));
    for (const r of missing) console.log('  ' + red('MISSING') + ' ' + r.event + ': ' + r.command);
    if (OPT.verbose) for (const r of hooksRep.rows) console.log('  ' + dim(pad(r.event, 20) + r.command));
    const p = hooksRep.palimpsest;
    if (p) {
      if (p.live) {
        console.log('  ' + green('palimpsest: live') + dim(' (' + p.candidates.find((c) => c.found).dir +
          (p.dbPresent ? ', db present' : ', NO db - it will recall nothing until one is built') + ')'));
      } else {
        console.log('  ' + yellow('palimpsest: REGISTERED BUT INERT') +
          ' - the recall hook runs every session and exits 0 without a word, because none of these exists:');
        for (const c of p.candidates) console.log('      ' + c.entry);
        console.log('      ' + dim('db ' + (p.dbPresent ? 'present' : 'absent') + ': ' + p.db));
        console.log('      ' + dim('So "no memory was recalled" and "this home has no memory" look identical ' +
          'from inside a session. They are not the same thing, and only one of them is a reason to trust the silence.'));
        console.log('      ' + dim('⚠ Inert may be CORRECT here: a memory is per HOME (a Windows side and a WSL side ' +
          'are two homes on one box), and a home can be deliberately without one. Check the decision before ' +
          '"fixing" this by installing a second memory beside the real one.'));
      }
    }
  }

  // --- check 7 -------------------------------------------------------------
  if (reg) {
    console.log('');
    console.log(bold('registered: ' + reg.basename) + dim('  (what still points at it)'));
    console.log('  shipped by: ' + (reg.ships.length ? reg.ships.map(label).join(', ') : dim('no root ships it')));
    console.log('  installed:  ' + (reg.installed ? label(reg.installed) : dim('not installed')));
    if (!reg.hits.length) console.log('  ' + dim('no settings file mentions it'));
    for (const h of reg.hits) console.log('  ' + label(h.file) + ':' + h.line + '  ' + h.text.slice(0, 120));
    if (reg.ships.length > 1) {
      console.log('  ' + yellow('more than one root ships this file') +
        dim(' - a retirement is not complete until every root stops shipping it, or the next installer puts it back.'));
    }
  }

  const stranded = repos.filter(strands);
  console.log('');
  if (stranded.length) {
    console.log(red(stranded.length + ' repo(s) hold work that exists in exactly one place: ') +
      stranded.map((r) => r.name).join(', '));
    console.log(dim('Report only. Never reset --hard, re-clone, branch -D or clean on the strength of this ' +
      'output - check 3 exists to tell a stranded framework clone from a repo holding deliberate local work.'));
  } else {
    console.log(green('no repo holds work that exists in exactly one place.'));
  }
}

// ---------------------------------------------------------------------------

(async () => {
  const memoryRepo = pathFileRepo('ai-memory-path');
  const frameworkRepo = pathFileRepo('sunstone-path') ||
    (isDir(path.join(__dirname, '../../.git')) ? path.resolve(__dirname, '../..') : null);
  const conf = loadConf(memoryRepo);

  const roots = [];
  for (const r of String(conf.PROJECT_ROOTS || '').split(/\s+/).filter(Boolean)) roots.push(r);
  if (OPT.extraRoot) roots.push(OPT.extraRoot);
  if (!roots.length) roots.push(path.join(HOME, 'projects'));

  const installRoots = [frameworkRepo, memoryRepo].filter(Boolean);
  const repoDirs = [...new Set([...discoverRepos(roots), ...installRoots])].sort();

  if (!repoDirs.length) {
    console.error('no git checkout found under: ' + roots.join(', ') +
      '  (set PROJECT_ROOTS in sunstone.conf, or pass --root)');
    process.exit(2);
  }

  const repos = await pool(repoDirs, OPT.jobs, inspect);
  const mig = migrationReport(installRoots);
  const claudeMd = claudeMdReport(installRoots);
  const queue = queueDuplicates(memoryRepo, conf.QUEUE_FILE);
  const reg = OPT.registered
    ? { basename: OPT.registered, ...registrationReport(OPT.registered, installRoots) }
    : null;

  main(repos, mig, claudeMd, queue, reg, hookReport(memoryRepo, conf));
  process.exit(repos.some(strands) ? 1 : 0);
})();
