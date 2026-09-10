#!/usr/bin/env node
/**
 * memory-doctor.js — verify this machine's Claude memory system.
 *
 * Everything in the memory stack fails SILENTLY by design: the SessionStart
 * sync hook (ai-memory-sync.sh, or its .js port on Windows) swallows every
 * error so a dead network never blocks a session, and the SessionEnd commit
 * hook does the same. That is right for a session and wrong
 * for a month — a machine can stop syncing, or a memory can be written into
 * the wrong tier, and nothing ever says so.
 *
 * This is the thing that says so. Read-only: it never writes, moves, commits
 * or deletes anything. It reports, and you decide.
 *
 * Three tiers are checked:
 *   synced   — the personal memory repo named in ~/.claude/ai-memory-path
 *              (or $HOME/.ai-memory when that file is absent), under MEMORY_DIR
 *   working  — ~/.claude/projects/<slug>/memory/, machine-local, syncs nowhere
 *   repo     — <project>/docs/ai-memory/ inside each project Claude has opened
 *
 * Layout is read from <personal-repo>/claude-setup/config/sunstone.conf when it
 * exists (KEY=VALUE lines); every key has a default, so the file is optional:
 *   MEMORY_DIR         claude-setup/memory
 *   MEMORY_FILE        claude-setup/memory/ABOUT-ME.md
 *   MEMORY_INDEX       claude-setup/memory/MEMORY.md
 *   MEMORY_META_FILES  ""   space-separated basenames inside MEMORY_DIR that are
 *                           structure, not memories (never flagged as unindexed,
 *                           never counted). The index, MEMORY_FILE and README.md
 *                           are always implied.
 *   PROJECT_ROOTS      ""   space-separated directories ('~' allowed) under which
 *                           projects live. A working-tier slug that cannot be
 *                           decoded from the filesystem alone is matched against
 *                           the immediate children of each root, and a slug that
 *                           lands under a root promotes to that project's
 *                           docs/ai-memory/. Empty keeps slug resolution only.
 *
 * Usage:
 *   node claude-setup/scripts/memory-doctor.js            # human report
 *   node claude-setup/scripts/memory-doctor.js --verbose  # list every item
 *   node claude-setup/scripts/memory-doctor.js --json     # machine-readable
 *   node claude-setup/scripts/memory-doctor.js --brief    # a few lines, or nothing
 *
 * Exit code: 0 when no ERRORs, 1 when any ERROR is found.
 */

'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');

// ---------------------------------------------------------------------------
// options
// ---------------------------------------------------------------------------

const argv = process.argv.slice(2);
const OPT = {
  json: argv.includes('--json'),
  // --brief prints a few lines for the SessionStart hook — one summary line
  // plus at most three WARN lines (hook drift, unindexed files) — and prints
  // nothing at all when there is nothing worth saying. Nobody runs a doctor by
  // hand on a schedule, and nobody should have to remember to — the hook
  // raises it, and goes quiet for good once the stores are drained.
  brief: argv.includes('--brief'),
  verbose: argv.includes('--verbose') || argv.includes('-v'),
  color: !argv.includes('--no-color') && process.stdout.isTTY &&
    !argv.includes('--json') && !argv.includes('--brief'),
};

const HOME = os.homedir();
const CLAUDE_DIR = path.join(HOME, '.claude');
const PROJECTS_DIR = path.join(CLAUDE_DIR, 'projects');

/** The framework checkout this script lives in — where the hook sources are. */
const FRAMEWORK_DIR = path.resolve(__dirname, '..', '..');

/** The setup entry point for this platform, named in every "fix it" hint. */
const REINSTALL = process.platform === 'win32' ? 'setup.ps1' : 'setup.sh';

/** Where the optional layout file lives, relative to the personal repo. */
const CONF_SUBPATH = path.join('claude-setup', 'config', 'sunstone.conf');

/** Defaults for every layout key — the conf file may be absent entirely. */
const CONF_DEFAULTS = {
  MEMORY_DIR: 'claude-setup/memory',
  MEMORY_FILE: 'claude-setup/memory/ABOUT-ME.md',
  MEMORY_INDEX: 'claude-setup/memory/MEMORY.md',
  // Read by memory-doctor only. Both are space-separated lists; empty means
  // "nothing extra" and is the documented default.
  MEMORY_META_FILES: '',
  PROJECT_ROOTS: '',
  // Read here ONLY to diagnose. The two git guards (pre-commit, pre-push) are
  // the components that act on these; memory-doctor never enforces them. It
  // reads them because a guard that silently stops guarding is the one failure
  // in this system with no other symptom — see the check below.
  MEMORY_REPOS: '',
  GUARDED_REPOS: '',
};

/** The keys whose values are repo-relative paths (normalised per OS). */
const CONF_PATH_KEYS = ['MEMORY_DIR', 'MEMORY_FILE', 'MEMORY_INDEX'];

/**
 * Parse `KEY=VALUE` lines. Whitespace around '=' is accepted (`KEY = value`
 * reads the same as `KEY=value`) — the rule all nine readers share. Values may
 * be double-quoted,
 * '#' starts a comment only at line start or after whitespace. Surrounding
 * quotes are stripped and whitespace is trimmed (never deleted from inside a
 * value — a path may contain spaces). The file is user content, so it is
 * parsed, never evaluated. Unknown keys are ignored; known keys with empty
 * values keep the default.
 */
function parseConf(text) {
  const out = {};
  for (const raw of (text || '').split('\n')) {
    const line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    // Whitespace before the `=` is accepted, matching every other reader: the
    // two shell hooks and both git guards grep `^[[:space:]]*KEY[[:space:]]*=`,
    // and the two .js hooks take `line.slice(0, eq).trim()`. A doctor stricter
    // than the hooks it audits reports the user's memory tree as empty.
    // ⚠️ No `\s*` AFTER the `=`: the value's leading whitespace must survive
    // until the comment rule below runs, or `KEY= #x` stops being a comment.
    const m = /^([A-Za-z_][A-Za-z0-9_]*)[ \t]*=(.*)$/.exec(line);
    if (!m) continue;
    // Leading whitespace is kept until the comment rule has run: KEY=#x is
    // the value "#x", KEY= #x is a comment (empty → default) — the same rule
    // the .sh and .js hooks apply.
    let v = m[2];
    if (v.trimStart().startsWith('"')) {
      // A quoted value ends at its closing quote (contents kept verbatim);
      // whatever follows — a trailing comment — is ignored. An unterminated
      // quote takes the rest of the line.
      v = v.trimStart();
      const end = v.indexOf('"', 1);
      v = end > 0 ? v.slice(1, end) : v.slice(1);
    } else {
      // An unquoted value ends at the first whitespace-preceded '#'.
      v = v.replace(/\s#.*$/, '').trim();
    }
    // An empty value UNSETS the key rather than leaving an earlier line's
    // value standing: the shell readers grep `tail -n1`, so for them the last
    // `KEY=` simply resolves empty and falls back to the default. Keeping the
    // earlier value here would make the doctor the only reader of the nine
    // that reads a different tree from the same conf file.
    if (v) out[m[1]] = v; else delete out[m[1]];
  }
  return out;
}

/** Split a space-separated conf value; empty → []. */
const words = (v) => String(v || '').split(/\s+/).filter(Boolean);

/** Expand a leading '~' the way a shell would; leave everything else alone. */
const expandHome = (p) =>
  p === '~' ? HOME : p.startsWith('~/') || p.startsWith('~\\') ? path.join(HOME, p.slice(2)) : p;

function loadConf(repo) {
  const conf = { ...CONF_DEFAULTS, ...parseConf(read(path.join(repo, CONF_SUBPATH))) };
  // Path keys are repo-relative POSIX paths; normalise so joins work on every OS.
  for (const k of CONF_PATH_KEYS) {
    conf[k] = conf[k].replace(/^\.\//, '').replace(/\/+$/, '').split('/').join(path.sep);
  }
  return conf;
}

// Set once the personal repo is resolved (they depend on its conf file).
let CONF = { ...CONF_DEFAULTS };
let MEM_SUBPATH = CONF_DEFAULTS.MEMORY_DIR;
/** Files in the synced store that are structure, not memories. */
let STORE_META = new Set(['MEMORY.md', 'README.md']);
/** Absolute directories from PROJECT_ROOTS that exist on this machine. */
let PROJECT_ROOTS = [];

// ---------------------------------------------------------------------------
// findings
// ---------------------------------------------------------------------------

const findings = [];
const add = (level, check, message, items = []) =>
  findings.push({ level, check, message, items });
const error = (...a) => add('ERROR', ...a);
const warn = (...a) => add('WARN', ...a);
const info = (...a) => add('INFO', ...a);

const stats = {};

// ---------------------------------------------------------------------------
// small helpers
// ---------------------------------------------------------------------------

const exists = (p) => { try { fs.accessSync(p); return true; } catch { return false; } };
const isDir = (p) => { try { return fs.statSync(p).isDirectory(); } catch { return false; } };
const read = (p) => { try { return fs.readFileSync(p, 'utf8'); } catch { return null; } };
const listMd = (dir) => {
  try {
    return fs.readdirSync(dir).filter((f) => f.endsWith('.md')).sort();
  } catch { return []; }
};

function git(repo, args) {
  try {
    return execFileSync('git', ['-C', repo, ...args], {
      encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], timeout: 10000,
    }).trim();
  } catch { return null; }
}

/** Claude Code's project-directory slug: every non-alphanumeric becomes '-'. */
const slugify = (abs) => abs.replace(/[^A-Za-z0-9]/g, '-');

/** Leading `---` frontmatter block, parsed shallowly (top-level scalars only). */
function frontmatter(text) {
  if (!text || !text.startsWith('---')) return null;
  const end = text.indexOf('\n---', 3);
  if (end === -1) return null;
  const out = {};
  for (const line of text.slice(4, end).split('\n')) {
    const m = /^([A-Za-z_][\w-]*):\s*(.*)$/.exec(line);
    if (m) out[m[1]] = m[2].trim();
  }
  return out;
}

/**
 * Every markdown link target ending in .md, with the line it came from.
 *
 * `entry` marks a link that is an actual index entry — a `- [Title](file.md)`
 * list item. A link in prose ("see [x.md](x.md) for detail") is a
 * cross-reference and may legitimately repeat; two list items for one file is
 * the store indexed twice.
 */
function mdLinks(text) {
  const out = [];
  const lines = text.split('\n');
  for (let i = 0; i < lines.length; i++) {
    // Only the FIRST link on a list item is that item's entry. Anything after
    // it is prose inside the entry's own description ("- [a](a.md) — start
    // from [b](b.md)"), which is a cross-reference like any other and must not
    // be counted as a second index line for b.md.
    const isListItem = /^\s*[-*]\s/.test(lines[i]);
    let first = true;
    const re = /\[[^\]\n]*\]\(([^)\s]+)\)/g;
    let m;
    while ((m = re.exec(lines[i])) !== null) {
      const target = m[1];
      if (!target.endsWith('.md')) continue;
      if (/^[a-z]+:\/\//i.test(target)) continue; // external URL
      out.push({ target, line: i + 1, entry: isListItem && first });
      first = false;
    }
  }
  return out;
}

const STOPWORDS = new Set(
  ('the a an and or but of to in for on at is are was were be been it its this that with ' +
   'from by as not no never claude memory md how what why when where which').split(' ')
);

function tokens(...parts) {
  return new Set(
    parts.join(' ').toLowerCase()
      .replace(/[^a-z0-9]+/g, ' ')
      .split(' ')
      // Numbers are dropped on purpose: numbered siblings (notes-a-01 /
      // notes-a-02) are otherwise 100% identical on tokens and drown the real
      // hits.
      .filter((t) => t.length > 2 && !/^\d+$/.test(t) && !STOPWORDS.has(t))
  );
}

function jaccard(a, b) {
  if (!a.size || !b.size) return 0;
  let hit = 0;
  for (const t of a) if (b.has(t)) hit++;
  return hit / (a.size + b.size - hit);
}

// ---------------------------------------------------------------------------
// 1. locate the synced repo (same resolution order as the hooks)
// ---------------------------------------------------------------------------

/** A directory is a usable personal repo when git recognises it as a work tree. */
const isGitRepo = (p) => isDir(p) && git(p, ['rev-parse', '--is-inside-work-tree']) === 'true';

function resolveRepo() {
  const pathFile = path.join(CLAUDE_DIR, 'ai-memory-path');
  const recorded = exists(pathFile) ? (read(pathFile) || '').split('\n')[0].trim() : '';
  const fallback = path.join(HOME, '.ai-memory');

  if (recorded && isGitRepo(recorded)) return recorded;

  if (recorded) {
    error('wiring', `ai-memory-path points at ${recorded}, which is not a git checkout. ` +
      'The hooks do nothing until it names the personal memory repo — run setup.sh.');
  } else {
    // Same rule as the hooks: no path file means "try $HOME/.ai-memory, else
    // do nothing". The hooks stay silent about it; the doctor does not.
    error('wiring', '~/.claude/ai-memory-path is missing — the hooks only have the ' +
      `${fallback} fallback to go on. Run setup.sh.`);
  }

  return isGitRepo(fallback) ? fallback : null;
}

const REPO = resolveRepo();
if (!REPO) {
  error('wiring', 'No personal memory repo found. The portable memory is not installed ' +
    'on this machine — clone your memory repo and run setup.sh.');
  report();
  process.exit(1);
}

CONF = loadConf(REPO);
MEM_SUBPATH = CONF.MEMORY_DIR;
STORE_META = new Set([
  'README.md',
  path.basename(CONF.MEMORY_INDEX), path.basename(CONF.MEMORY_FILE),
  // MEMORY_FILE falls back to MEMORY.md inside MEMORY_DIR, so that file is
  // structure too — but ONLY while the fallback is live. Under a layout that
  // names its index something else and has a real MEMORY_FILE, a file called
  // MEMORY.md is an ordinary memory and must be counted and checked like one;
  // hardcoding the basename silently swallowed it.
  ...(exists(path.join(REPO, CONF.MEMORY_FILE)) ? [] : ['MEMORY.md']),
  // MEMORY_META_FILES names basenames inside MEMORY_DIR; a value written with
  // a directory part still counts by its basename.
  ...words(CONF.MEMORY_META_FILES).map((f) => path.basename(f)),
]);
{
  const roots = words(CONF.PROJECT_ROOTS).map((r) => path.resolve(expandHome(r)));
  const missing = roots.filter((r) => !isDir(r));
  PROJECT_ROOTS = roots.filter((r) => isDir(r));
  stats.projectRoots = PROJECT_ROOTS;
  if (missing.length) {
    info('wiring', `PROJECT_ROOTS names ${missing.length} director${missing.length === 1 ? 'y that does' : 'ies that do'} ` +
      'not exist on this machine (fine if the conf is shared across machines):', missing);
  }
}

// ── The guard lists: read to diagnose, never to enforce ───────────────────
//
// MEMORY_REPOS (pre-commit) and GUARDED_REPOS (pre-push) name repos by BARE
// BASENAME, matched whole. Both are space-separated, so an entry containing a
// space cannot be expressed — that is inherent to the format, not a bug, and
// changing it would mean one list grammar kept byte-identical across nine
// readers in five languages.
//
// ⚠️ What makes it worth a check anyway is the DIRECTION it fails in. A guard
// that cannot match its repo does not error; it goes quiet, on exactly the
// repo the user believed was protected. Every other misconfiguration in this
// system announces itself — a wrong MEMORY_DIR yields an empty tree, a bad
// path file yields a missing repo. This one is silent, so the doctor is the
// only place it can surface.
{
  const repoName = path.basename(REPO);
  for (const key of ['MEMORY_REPOS', 'GUARDED_REPOS']) {
    const raw = CONF[key];
    if (!raw) continue;   // empty → the guards derive their own default
    const entries = words(raw);

    // A quote character means someone tried to spell an entry containing a
    // space. The guards strip surrounding quotes from the VALUE, never from
    // the words inside it, so `A "b c"` is three entries and two of them have
    // a stray quote welded on.
    const quoted = entries.filter((e) => /["']/.test(e));
    if (quoted.length) {
      warn('wiring', `${key} contains quote characters, which do not group words: the value is ` +
        'split on whitespace and each word is matched whole, so a repo name containing a space ' +
        'cannot be expressed here. Rename the repo, or drop the quotes if they were not ' +
        'intended to group:', quoted);
    }

    // The repo being audited is the one whose memory these guards exist to
    // protect. If the list is set and omits it, the guard cannot ever fire.
    if (!entries.includes(repoName)) {
      warn('wiring', `${key} is set but does not list "${repoName}", the repo this check is ` +
        `auditing — so the ${key === 'MEMORY_REPOS' ? 'pre-commit mixed-staging guard' : 'pre-push history guard'} ` +
        'never fires on your own memory repo. Add it, or clear the key to fall back to the ' +
        `derived default. Currently listed: ${entries.join(' ')}`);
    }
  }
}

const SYNCED = path.join(REPO, MEM_SUBPATH);
const INDEX_PATH = path.join(REPO, CONF.MEMORY_INDEX);
const INDEX_REL = CONF.MEMORY_INDEX.split(path.sep).join('/');
stats.repo = REPO;
stats.conf = exists(path.join(REPO, CONF_SUBPATH)) ? path.join(REPO, CONF_SUBPATH) : null;

if (!isDir(SYNCED)) {
  error('wiring', `${MEM_SUBPATH}/ does not exist in ${REPO}. Nothing can be synced ` +
    'from a memory tree that is not there — check MEMORY_DIR in sunstone.conf.');
}
if (!exists(path.join(REPO, CONF.MEMORY_FILE)) && !exists(path.join(SYNCED, 'MEMORY.md'))) {
  warn('wiring', `Neither ${CONF.MEMORY_FILE} nor ${MEM_SUBPATH}/MEMORY.md exists — the ` +
    'SessionStart hook has nothing to inject, so every session starts without memory.');
}

// ---------------------------------------------------------------------------
// 2. hook wiring — is the machine actually running the system?
// ---------------------------------------------------------------------------

function checkHooks() {
  const installedDir = path.join(CLAUDE_DIR, 'hooks');
  // Hook sources ship with the framework (the checkout this script lives in),
  // not with the personal repo.
  const sourceDir = path.join(FRAMEWORK_DIR, 'claude-setup', 'config', 'hooks');

  // Each hook ships in two ports: a .sh (installed by setup.sh on Linux/macOS)
  // and a .js (installed by setup.ps1 on Windows, which has no bash/jq/python3).
  // Either counts as installed; the drift check compares against the matching
  // source, and a machine that somehow has both is checked on both.
  const wanted = [
    { name: 'ai-memory-sync', event: 'SessionStart', what: 'pull + inject the memory file + push' },
    { name: 'ai-memory-commit', event: 'SessionEnd', what: 'commit memory writes' },
  ];
  const PORTS = ['.sh', '.js'];

  // settings.json registration
  let settings = null;
  const settingsPath = path.join(CLAUDE_DIR, 'settings.json');
  const raw = read(settingsPath);
  if (raw === null) {
    error('wiring', '~/.claude/settings.json is missing — no hooks are registered.');
  } else {
    try { settings = JSON.parse(raw); }
    catch (e) { error('wiring', `~/.claude/settings.json is not valid JSON (${e.message}) — ` +
      'Claude Code silently ignores it, so every hook is off.'); }
  }

  const registered = (event) => {
    const groups = settings && settings.hooks && settings.hooks[event];
    if (!Array.isArray(groups)) return '';
    return JSON.stringify(groups);
  };

  const reinstall = REINSTALL;

  for (const { name, event, what } of wanted) {
    const present = PORTS.map((ext) => name + ext)
      .filter((file) => exists(path.join(installedDir, file)));
    if (present.length === 0) {
      error('wiring', `~/.claude/hooks/${name}.sh (or ${name}.js) is missing — ${what} never runs. ` +
        `Run ${reinstall} to reinstall.`);
      continue;
    }

    const reg = registered(event);
    if (!present.some((file) => reg.includes(file))) {
      error('wiring', `${present.join(' / ')} exists but is NOT registered under ${event} in ` +
        `settings.json — it is installed and dead. ${what} never runs.`);
    }

    for (const file of present) {
      const src = path.join(sourceDir, file);
      if (!exists(src)) continue;
      if (read(src) !== read(path.join(installedDir, file))) {
        warn('wiring', `~/.claude/hooks/${file} differs from the framework copy — this machine ` +
          'is running an older hook, or a local edit that was never committed back. ' +
          `Rerun ${reinstall} to refresh it.`, [showPath(src)]);
      }
    }

    // A .sh port on Windows only runs if a bash is on PATH; setup.ps1 installs
    // the .js port precisely to avoid that. Flag the case rather than assume.
    if (process.platform === 'win32' && !present.includes(name + '.js')) {
      info('wiring', `Windows: ~/.claude/hooks/${name}.sh is a bash script — it needs Git Bash ` +
        `or WSL on PATH, or it no-ops silently. setup.ps1 installs ${name}.js instead.`);
    }
  }
}

// ---------------------------------------------------------------------------
// 3. sync health — the "stopped syncing forever" failure
// ---------------------------------------------------------------------------

function checkSync() {
  const branch = git(REPO, ['rev-parse', '--abbrev-ref', 'HEAD']);
  const upstream = git(REPO, ['rev-parse', '--abbrev-ref', '@{u}']);
  stats.branch = branch;

  if (!upstream) {
    error('sync', `Branch ${branch || '?'} has no upstream — every pull and push in the ` +
      'hooks fails silently, so this machine\'s memory writes never leave it.');
    return;
  }
  stats.upstream = upstream;

  const counts = git(REPO, ['rev-list', '--left-right', '--count', 'HEAD...@{u}']);
  if (counts) {
    const [ahead, behind] = counts.split(/\s+/).map(Number);
    stats.ahead = ahead;
    stats.behind = behind;
    if (ahead > 20) {
      warn('sync', `${ahead} local commits have never been pushed. The SessionStart hook ` +
        'pushes on a best-effort basis; this many means it has been failing for a while.');
    }
    if (behind > 50) {
      warn('sync', `${behind} commits behind ${upstream} — another machine has been writing ` +
        'memory this one has not seen.');
    }
  }

  // Uncommitted memory writes: the SessionEnd hook should have taken these.
  const dirty = git(REPO, ['status', '--porcelain', '--', MEM_SUBPATH]);
  if (dirty) {
    // Porcelain is `XY <path>`, but git() trims the output — which eats the
    // leading space of an unstaged-only first line. Strip the status field by
    // pattern rather than by offset.
    const files = dirty.split('\n')
      .map((l) => l.trim().replace(/^\S{1,2}\s+/, ''))
      .filter(Boolean);
    warn('sync', `${files.length} uncommitted file(s) under ${MEM_SUBPATH}. If this is not ` +
      'the session that just wrote them, the SessionEnd commit hook is not firing.', files);
  }

  // Mid-rebase/merge: both hooks refuse to run in this state, silently.
  const gitDir = git(REPO, ['rev-parse', '--git-dir']);
  if (gitDir) {
    const abs = path.isAbsolute(gitDir) ? gitDir : path.join(REPO, gitDir);
    for (const marker of ['MERGE_HEAD', 'REBASE_HEAD', 'rebase-merge', 'rebase-apply']) {
      if (exists(path.join(abs, marker))) {
        error('sync', `The repo is mid-${marker.toLowerCase().includes('rebase') ? 'rebase' : 'merge'} ` +
          `(${marker}). Both memory hooks bail out in this state — memory is not being saved ` +
          'until you finish or abort it.');
        break;
      }
    }
  }
}

// ---------------------------------------------------------------------------
// 4. index parity — MEMORY.md vs the files on disk
// ---------------------------------------------------------------------------

function checkIndex() {
  const indexText = read(INDEX_PATH);
  const indexDir = path.dirname(INDEX_PATH);
  const files = listMd(SYNCED).filter((f) => !STORE_META.has(f));
  stats.syncedFiles = files.length;
  stats.indexPresent = indexText !== null;
  stats.injectedPresent = exists(path.join(REPO, CONF.MEMORY_FILE)) ||
    exists(path.join(SYNCED, 'MEMORY.md'));

  if (indexText === null) {
    error('index', `${INDEX_REL} is missing — nothing indexes the store.`);
    return { files, linked: new Set() };
  }

  const links = mdLinks(indexText);
  const seen = new Map();
  const linked = new Set();
  const dangling = [];
  const dupes = [];
  // One entry per EXTRA link, so a file listed three times pushes two items.
  // The headline counts files, not links, so the names are tracked separately.
  const dupeNames = new Set();

  for (const { target, line, entry } of links) {
    const name = path.basename(target);
    // Links are relative to the index file, which need not sit in MEMORY_DIR.
    if (!exists(path.resolve(indexDir, target))) {
      dangling.push(`${target}  (${path.basename(INDEX_PATH)}:${line})`);
      continue;
    }
    if (STORE_META.has(name)) continue;
    linked.add(name); // any link counts as coverage
    if (!entry) continue; // prose cross-reference, not an index entry
    if (seen.has(name)) {
      dupes.push(`${name}  (lines ${seen.get(name)} and ${line})`);
      dupeNames.add(name);
    } else seen.set(name, line);
  }

  if (dangling.length) {
    error('index', `${dangling.length} ${path.basename(INDEX_PATH)} link(s) point at files that do not exist. ` +
      'The index is the only thing loaded every session — a dead link is a memory Claude ' +
      'believes it has and cannot open.', dangling);
  }
  if (dupes.length) {
    warn('index', `${dupeNames.size} file(s) are linked from ${path.basename(INDEX_PATH)} more than once.`, dupes);
  }

  const unindexed = files.filter((f) => !linked.has(f));
  if (unindexed.length) {
    warn('index', `${unindexed.length} memory file(s) have no line in ${INDEX_REL}. ` +
      'The index is what enters context; an unindexed file is written but unreachable.', unindexed);
  }

  return { files, linked };
}

// ---------------------------------------------------------------------------
// 5. file hygiene — frontmatter, name/filename agreement, wikilinks
// ---------------------------------------------------------------------------

function checkFiles(files) {
  const noFm = [];
  const nameMismatch = [];
  const noDesc = [];
  const known = new Set(files.map((f) => f.replace(/\.md$/, '')));
  const wikiDangling = [];
  const meta = [];

  for (const f of files) {
    const text = read(path.join(SYNCED, f)) || '';
    const fm = frontmatter(text);
    const slug = f.replace(/\.md$/, '');

    if (!fm) noFm.push(f);
    else {
      if (fm.name && fm.name !== slug) nameMismatch.push(`${f}  (name: ${fm.name})`);
      if (!fm.description) noDesc.push(f);
    }

    meta.push({ slug, file: f, desc: (fm && fm.description) || '' });

    const re = /\[\[([^\]|#]+)/g;
    let m;
    while ((m = re.exec(text)) !== null) {
      const ref = m[1].trim();
      // `[[:space:]]` and friends are POSIX classes inside shell snippets,
      // not wikilinks.
      if (/^:.*:$/.test(ref)) continue;
      if (!known.has(ref) && !STORE_META.has(`${ref}.md`)) {
        wikiDangling.push(`${f} -> [[${ref}]]`);
      }
    }
  }

  if (nameMismatch.length) {
    warn('hygiene', `${nameMismatch.length} file(s) whose frontmatter name does not match ` +
      'the filename — [[wikilinks]] and recall both key off the name.', nameMismatch);
  }
  if (noFm.length) {
    info('hygiene', `${noFm.length} file(s) have no frontmatter. Not fatal — they still read ` +
      'fine — but they carry no description for relevance matching.', noFm);
  }
  if (noDesc.length) {
    info('hygiene', `${noDesc.length} file(s) have frontmatter but no description:`, noDesc);
  }
  if (wikiDangling.length) {
    info('hygiene', `${wikiDangling.length} [[wikilink]](s) name a memory that does not exist ` +
      'in this store. Intentional forward-references are fine; a typo is not.', wikiDangling);
  }

  return meta;
}

// ---------------------------------------------------------------------------
// 6. the working tier — is it drained?
// ---------------------------------------------------------------------------

/**
 * Map a Claude project slug back to the directory it stands for.
 *
 * The slug is lossy — '/', '.', '_' and '-' all become '-' — so it cannot be
 * decoded by string work alone. Instead the slug is matched against the real
 * filesystem: starting from $HOME (then the filesystem root), each directory
 * entry whose own slug is a prefix of what remains is descended into, until
 * the remainder is consumed. Only directories along candidate paths are read,
 * so this costs a handful of readdirs per slug and assumes nothing about
 * where projects live.
 */
const descendSlug = (dir, rest, depth) => {
  if (!rest) return dir;
  if (depth > 16) return null;
  let entries = [];
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return null; }
  for (const e of entries) {
    if (!e.isDirectory()) continue;
    const s = slugify(e.name);
    if (rest === s) return path.join(dir, e.name);
    if (rest.startsWith(s + '-')) {
      const hit = descendSlug(path.join(dir, e.name), rest.slice(s.length + 1), depth + 1);
      if (hit) return hit;
    }
  }
  return null;
};

/** `dir` is `root` or something inside it. */
const isUnder = (root, dir) => {
  const rel = path.relative(root, dir);
  return rel === '' || (!rel.startsWith('..') && !path.isAbsolute(rel));
};

/**
 * PROJECT_ROOTS fallback: a slug the walk from $HOME could not decode (a
 * project on another drive, behind a symlink, or under a directory that is
 * not readable from the top) is matched against the immediate children of
 * each configured root — as the child itself, or as a subfolder of it.
 */
function resolveSlugFromRoots(slug) {
  for (const root of PROJECT_ROOTS) {
    let entries = [];
    try { entries = fs.readdirSync(root, { withFileTypes: true }); } catch { continue; }
    for (const e of entries) {
      if (!e.isDirectory()) continue;
      const abs = path.join(root, e.name);
      const s = slugify(abs);
      if (slug === s) return abs;
      if (slug.startsWith(s + '-')) {
        const hit = descendSlug(abs, slug.slice(s.length + 1), 0);
        if (hit) return hit;
      }
    }
  }
  return null;
}

/**
 * The project a directory under PROJECT_ROOTS belongs to: the root's immediate
 * child that contains it. null when no configured root contains `dir`.
 */
function projectFromRoots(dir) {
  for (const root of PROJECT_ROOTS) {
    if (!isUnder(root, dir) || dir === root) continue;
    const first = path.relative(root, dir).split(path.sep)[0];
    if (first && first !== '..') return path.join(root, first);
  }
  return null;
}

const slugCache = new Map();
function resolveSlug(slug) {
  if (slugCache.has(slug)) return slugCache.get(slug);

  let found = null;
  for (const base of [HOME, path.parse(HOME).root]) {
    const prefix = slugify(base);                     // '-home-alice' or 'C--'
    const sep = prefix.endsWith('-') ? '' : '-';
    if (slug === prefix) { found = base; break; }
    if (slug.startsWith(prefix + sep)) {
      found = descendSlug(base, slug.slice(prefix.length + sep.length), 0);
      if (found) break;
    }
  }
  if (!found) found = resolveSlugFromRoots(slug);
  slugCache.set(slug, found);
  return found;
}

/** `dir` is the personal repo or something inside it. */
const insideRepo = (dir) => isUnder(REPO, dir);

/** A path for humans: relative to $HOME when it lives there, absolute otherwise. */
const showPath = (p) => {
  const rel = path.relative(HOME, p);
  return rel && !rel.startsWith('..') && !path.isAbsolute(rel) ? rel : p;
};

/** Project directories the working tier stands for — feeds the repo-store scan. */
const projectDirs = new Set();

function checkWorkingTier() {
  if (!isDir(PROJECTS_DIR)) return [];

  const undrained = [];
  const collected = [];
  const danglingIndex = [];

  let projects = [];
  try { projects = fs.readdirSync(PROJECTS_DIR); } catch { return []; }

  for (const slug of projects) {
    const memDir = path.join(PROJECTS_DIR, slug, 'memory');
    if (!isDir(memDir)) continue;

    const files = listMd(memDir).filter((f) => f !== 'MEMORY.md');
    const target = resolveSlug(slug);
    if (target && target !== HOME) projectDirs.add(target);
    // A session opened in a subfolder still promotes to the repo root's store.
    // Under a configured PROJECT_ROOT the project is the root's immediate
    // child — which also covers a project that is not (yet) a git repo.
    const rooted = target && target !== HOME ? projectFromRoots(target) : null;
    const top = !rooted && target && target !== HOME
      ? git(target, ['rev-parse', '--show-toplevel']) : null;
    const project = rooted || (top ? path.resolve(top) : target);
    if (rooted) projectDirs.add(rooted);
    // A session opened at $HOME (or inside the memory repo itself) has no
    // project to promote to — its facts belong in the synced tier.
    const home = !project || project === HOME || insideRepo(project)
      ? `${path.basename(REPO)}/${MEM_SUBPATH.split(path.sep).join('/')}/`
      : `${showPath(project)}/docs/ai-memory/`;

    for (const f of files) {
      const text = read(path.join(memDir, f)) || '';
      const fm = frontmatter(text);
      collected.push({
        slug: f.replace(/\.md$/, ''),
        file: f,
        desc: (fm && fm.description) || '',
        store: `working:${slug}`,
      });
    }

    if (files.length) {
      undrained.push({ slug, count: files.length, home, files });
    }

    // The working-tier MEMORY.md should be an index pointing at the real
    // stores, not a store of its own.
    const idx = read(path.join(memDir, 'MEMORY.md'));
    if (idx) {
      for (const { target: t, line } of mdLinks(idx)) {
        if (!exists(path.join(memDir, t))) {
          danglingIndex.push(`${slug}/memory/MEMORY.md:${line} -> ${t}`);
        }
      }
    }
  }

  const total = undrained.reduce((n, u) => n + u.count, 0);
  stats.undrained = total;
  stats.undrainedProjects = undrained.length;

  if (total) {
    const lines = undrained
      .sort((a, b) => b.count - a.count)
      .map((u) => `${String(u.count).padStart(3)} file(s)  ${u.slug}\n            -> promote to ${u.home}`);
    warn('working-tier', `${total} memory file(s) sit undrained in ` +
      `${undrained.length} machine-local project store(s). ` +
      '~/.claude/projects/<slug>/memory/ syncs NOWHERE — a machine wipe takes all of it. ' +
      'CLAUDE.md calls this a working tier: write there during a session, then promote and delete.',
      lines);
  }

  if (danglingIndex.length) {
    warn('working-tier', `${danglingIndex.length} working-tier MEMORY.md link(s) point at ` +
      'files that no longer exist — usually a memory that was promoted but left in the index.',
      danglingIndex);
  }

  return collected;
}

// ---------------------------------------------------------------------------
// 7. in-repo project memory — written but never committed dies the same death
// ---------------------------------------------------------------------------

function checkRepoStores() {
  const collected = [];
  const found = [];

  // Which projects have an in-repo store? The ones Claude Code has actually
  // opened on this machine — every ~/.claude/projects slug decodes to a
  // directory (checkWorkingTier collected them). No guess about where
  // projects live is needed, and a repo Claude never opened cannot have
  // been written to by it. A project's git toplevel is checked as well, so
  // a session opened in a subfolder still finds the store at the root.
  const seen = new Set();
  const consider = (dir) => {
    if (!dir || seen.has(dir)) return;
    seen.add(dir);
    const store = path.join(dir, 'docs', 'ai-memory');
    if (isDir(store) && !insideRepo(store)) found.push(store);
  };
  for (const dir of projectDirs) {
    consider(dir);
    const top = git(dir, ['rev-parse', '--show-toplevel']);
    if (top) consider(path.resolve(top));
  }

  stats.repoStores = found.length;
  const uncommitted = [];

  for (const dir of found) {
    const top = git(dir, ['rev-parse', '--show-toplevel']);
    if (top) {
      const dirty = git(top, ['status', '--porcelain', '--', dir]);
      if (dirty) {
        for (const l of dirty.split('\n').filter(Boolean)) {
          uncommitted.push(`${showPath(top)}: ${l.trim()}`);
        }
      }
    } else {
      warn('repo-store', `${showPath(dir)} is not inside a git repo — this store ` +
        'travels with nothing.');
    }

    // Recurse: a store may group its files into subfolders (a project might
    // keep facts/ beside its domain files). Reading only the top level made
    // the duplicate check silently under-report, which is the exact failure
    // this tool exists to catch.
    const repoName = path.basename(path.dirname(path.dirname(dir)));
    const collect = (d, depth) => {
      if (depth > 3) return;
      let entries = [];
      try { entries = fs.readdirSync(d, { withFileTypes: true }); } catch { return; }
      for (const e of entries) {
        const fp = path.join(d, e.name);
        if (e.isDirectory()) { collect(fp, depth + 1); continue; }
        if (!e.name.endsWith('.md')) continue;
        if (['MEMORY.md', 'README.md', 'INDEX.md'].includes(e.name)) continue;
        const fm = frontmatter(read(fp) || '');
        collected.push({
          slug: e.name.replace(/\.md$/, ''),
          file: path.relative(dir, fp),
          desc: (fm && fm.description) || '',
          store: `repo:${repoName}`,
        });
      }
    };
    collect(dir, 0);
  }

  if (uncommitted.length) {
    warn('repo-store', `${uncommitted.length} in-repo memory file(s) are uncommitted. ` +
      'docs/ai-memory/ is only durable once committed — until then it is as machine-local ' +
      'as the working tier.', uncommitted);
  }

  return collected;
}

// ---------------------------------------------------------------------------
// 8. cross-tier duplicates — the same fact written into two tiers, mechanised
// ---------------------------------------------------------------------------

function checkDuplicates(syncedMeta, workingMeta, repoMeta) {
  const all = [
    ...syncedMeta.map((m) => ({ ...m, store: 'synced' })),
    ...workingMeta,
    ...repoMeta,
  ];
  stats.totalMemories = all.length;

  // a) exact slug collisions across different stores
  const bySlug = new Map();
  for (const m of all) {
    if (!bySlug.has(m.slug)) bySlug.set(m.slug, []);
    bySlug.get(m.slug).push(m);
  }
  const collisions = [];
  for (const [slug, group] of bySlug) {
    const stores = [...new Set(group.map((g) => g.store))];
    if (stores.length > 1) collisions.push(`${slug}  —  ${stores.join('  +  ')}`);
  }
  if (collisions.length) {
    error('duplicates', `${collisions.length} memory slug(s) exist in more than one store. ` +
      'Two homes for one fact means one of them is stale and nothing says which.', collisions);
  }

  // b) near-duplicates by title + description overlap
  const withTokens = all.map((m) => ({ ...m, tok: tokens(m.slug.replace(/-/g, ' '), m.desc) }));
  const near = [];
  for (let i = 0; i < withTokens.length; i++) {
    for (let j = i + 1; j < withTokens.length; j++) {
      const a = withTokens[i], b = withTokens[j];
      if (a.slug === b.slug) continue; // already reported above
      // Too few tokens to judge: a two-word name matches another two-word name
      // far too easily. Undescribed files simply cannot be compared this way.
      if (a.tok.size < 4 || b.tok.size < 4) continue;
      const score = jaccard(a.tok, b.tok);
      if (score >= 0.6) {
        near.push(`${(score * 100).toFixed(0)}%  ${a.store}/${a.slug}  ~  ${b.store}/${b.slug}`);
      }
    }
  }
  if (near.length) {
    warn('duplicates', `${near.length} pair(s) of memories look like the same fact written ` +
      'twice (>=60% token overlap on name + description). Merge or supersede.',
      near.sort().reverse());
  }
}

// ---------------------------------------------------------------------------
// report
// ---------------------------------------------------------------------------

function report() {
  if (OPT.json) {
    process.stdout.write(JSON.stringify({ stats, findings }, null, 2) + '\n');
    return;
  }

  if (OPT.brief) {
    const errs = findings.filter((f) => f.level === 'ERROR');
    const undrained = stats.undrained || 0;
    // WARNs that the docs promise the notice will raise: an installed hook
    // that drifted from the framework copy (the pull-without-setup case) and
    // index parity (a file written but unreachable). Sync/duplicate WARNs stay
    // in the full report — they are advisory and would make the notice noisy.
    const BRIEF_WARN_CHECKS = new Set(['wiring', 'index']);
    const warns = findings.filter((f) => f.level === 'WARN' && BRIEF_WARN_CHECKS.has(f.check));
    // Silence is the goal state. Nothing to say once the stores are drained
    // and the wiring is sound — this stops being noise instead of becoming
    // wallpaper the user learns to scroll past.
    if (!errs.length && !undrained && !warns.length) return;

    const parts = [];
    if (errs.length) {
      // First clause only: cut at a sentence end or an em-dash aside, never at
      // the '.' inside a path like ~/.claude.
      parts.push(`${errs.length} ERROR(s): ` + errs.map((e) => e.message.split(/\.\s|\s—\s/)[0]).join('; '));
    }
    if (undrained) {
      // Slugs all start with the slugified $HOME; drop it so the line stays short.
      const homeSlug = slugify(HOME);
      const homePrefix = new RegExp('^' + homeSlug.replace(/[^A-Za-z0-9]/g, '\\$&') + '-');
      const wt = findings.find((f) => f.check === 'working-tier' && f.items.length);
      const where = wt
        ? wt.items.slice(0, 4)
            .map((i) => {
              const m = /^\s*(\d+) file\(s\)\s+(\S+)/.exec(String(i).split('\n')[0]);
              if (!m) return null;
              const short = m[2] === homeSlug ? '~' : m[2].replace(homePrefix, '');
              return `${short} ${m[1]}`;
            })
            .filter(Boolean).join(', ')
        : '';
      parts.push(
        `${undrained} memory file(s) sit in machine-local stores that sync nowhere` +
        (where ? ` (${where}${undrained > 4 ? ', …' : ''})` : '') +
        `. A machine wipe takes them.`
      );
    }
    const BRIEF_WARN_CAP = 3;
    const warnLines = warns.slice(0, BRIEF_WARN_CAP).map((w) => {
      // First clause of the message, plus the first item when it names the
      // culprit (the drifted hook is already in the message; the unindexed
      // files are only in the items).
      const head = w.message.split(/\.\s|\s—\s/)[0];
      const drift = /differs from the framework copy/.test(w.message);
      const tail = drift
        ? ` — rerun ${REINSTALL}`
        : w.items.length
          ? `: ${w.items.slice(0, 3).join(', ')}${w.items.length > 3 ? `, +${w.items.length - 3} more` : ''}`
          : '';
      return `WARN ${w.check}: ${head}${tail}`;
    });
    if (warns.length > BRIEF_WARN_CAP) warnLines.push(`+${warns.length - BRIEF_WARN_CAP} more WARN(s)`);

    // This line is handed to the model as SessionStart context, so the command
    // in it has to survive being pasted into a shell. The framework checkout is
    // wherever the user cloned it and may contain a space, hence the quotes.
    const doctorCmd = '`node "' + __filename + '"`';

    const lines = [];
    if (parts.length) {
      lines.push(
        parts.join('. ') +
        ' — the user does not track this by hand, so mention it ONCE, briefly, at a natural pause, ' +
        'and drop it if they do not pick it up. ' +
        // The "~15-minute slice" advice is about undrained stores. With only
        // ERRORs to report there are no stores to slice, and offering to drain
        // them points the model at something the report never mentioned.
        (undrained
          ? `Each store is a ~15-minute slice; ${doctorCmd} lists them.`
          : `${doctorCmd} has the full report.`)
      );
    }
    lines.push(...warnLines);
    if (!parts.length) {
      lines.push('Advisory only — mention it once if the user is touching memory or setup, otherwise ' +
        `let it go. ${doctorCmd} has the full report.`);
    }
    process.stdout.write(lines.join('\n') + '\n');
    return;
  }

  const c = (code, s) => (OPT.color ? `\x1b[${code}m${s}\x1b[0m` : s);
  const badge = {
    ERROR: c('1;31', 'ERROR'),
    WARN: c('1;33', ' WARN'),
    INFO: c('1;36', ' INFO'),
  };

  const counts = { ERROR: 0, WARN: 0, INFO: 0 };
  for (const f of findings) counts[f.level]++;

  console.log('');
  console.log(c('1', 'memory doctor') + `  ${stats.repo || '(no repo)'}`);
  if (stats.repo) {
    console.log(`               ${stats.conf ? 'layout: ' + showPath(stats.conf) : 'layout: defaults (no sunstone.conf)'}`);
  }
  if (stats.branch) {
    const drift = stats.upstream
      ? `${stats.branch} -> ${stats.upstream}` +
        (stats.ahead || stats.behind ? ` (+${stats.ahead || 0}/-${stats.behind || 0})` : ' (in sync)')
      : `${stats.branch} (no upstream)`;
    console.log(`               ${drift}`);
  }
  if (stats.projectRoots && stats.projectRoots.length) {
    console.log(`               project roots: ${stats.projectRoots.map(showPath).join(', ')}`);
  }
  if (stats.repo && !stats.syncedFiles) {
    // A fresh store is index + injected file and nothing else. "0 synced · 0
    // memories" reads as broken; say what is there and what is not yet.
    const have = [stats.indexPresent && 'index', stats.injectedPresent && 'injected file']
      .filter(Boolean);
    console.log(
      `               memory store: ${have.length ? have.join(' + ') + ' present' : 'no index, no injected file'}, ` +
      '0 topic files yet'
    );
  }
  console.log(
    `               ${stats.syncedFiles || 0} synced · ` +
    `${stats.undrained || 0} undrained · ` +
    `${stats.repoStores || 0} repo stores · ` +
    `${stats.totalMemories || 0} memories total`
  );
  console.log('');

  const order = ['ERROR', 'WARN', 'INFO'];
  for (const level of order) {
    for (const f of findings.filter((x) => x.level === level)) {
      console.log(`${badge[level]}  ${c('1', f.check)}  ${f.message}`);
      if (f.items.length) {
        const show = OPT.verbose ? f.items : f.items.slice(0, 10);
        for (const it of show) {
          for (const line of String(it).split('\n')) console.log(`        ${c('2', line)}`);
        }
        if (!OPT.verbose && f.items.length > show.length) {
          console.log(`        ${c('2', `... and ${f.items.length - show.length} more (--verbose)`)}`);
        }
      }
      console.log('');
    }
  }

  if (!findings.length) {
    console.log(c('1;32', '  clean — every tier wired, indexed and drained.') + '\n');
    return;
  }

  console.log(
    `${counts.ERROR} error(s), ${counts.WARN} warning(s), ${counts.INFO} note(s). ` +
    'Nothing was changed — this is a read-only check.\n'
  );
}

// ---------------------------------------------------------------------------
// run
// ---------------------------------------------------------------------------

checkHooks();
checkSync();
const { files } = checkIndex();
const syncedMeta = checkFiles(files);
const workingMeta = checkWorkingTier();
const repoMeta = checkRepoStores();
checkDuplicates(syncedMeta, workingMeta, repoMeta);

report();
process.exit(findings.some((f) => f.level === 'ERROR') ? 1 : 0);
