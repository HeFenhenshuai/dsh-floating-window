/**
 * Host half of dsh-floating-window-macos.
 *
 * The macOS-only package: one Host plugin plus one native window program, no
 * platform branching. (The Windows edition lives in its own repository —
 * HeFenhenshuai/dsh-floating-window.)
 *
 * What this half owns:
 *
 * - `POST /dsh-floating-window/open` — the composer control asks for the floating
 *   window. This side mints the browser-trust URL (`ctx.connection
 *   .authenticatedUrl`), forwards the Desktop shell's per-generation renderer
 *   capability header, and launches `../window/dsh-floating-window.app`.
 * - `GET /dsh-floating-window/page/` — the compact conversation page the window shows,
 *   served from this project so the window stays same-origin with the DSH Host
 *   and reuses its authenticated session for the Session JSON API.
 * - `/dsh-floating-window/sessions` and `/dsh-floating-window/session/*` — the window's
 *   conversation surface: the Host's official Session list with titles, one
 *   Session's history, its live transcript stream, prompting, cancelling and
 *   creating a new ordinary Session. These read and write the same Sessions the
 *   DSH window shows, which is what lets the floating window switch between every
 *   conversation the client already has.
 * - `GET|POST /dsh-floating-window/settings` — the floating window's own preferences
 *   (appearance override, always-on-top, geometry policy, opacity, …), stored as
 *   `~/Library/Application Support/dsh-floating-window/float-settings.json`. The
 *   window process reads that same file, so a change made in the settings page
 *   reaches the window in about a second without any IPC.
 * - `GET|POST /dsh-floating-window/theme` — the appearance channel: the browser half
 *   reports DSH's own ui-theme state, the window page asks.
 *
 * The window itself is a separate process — a native AppKit + WKWebView program,
 * not an Electron shell: the DSH renderer is sandboxed and cannot open native
 * windows, and Electron ships no Document Picture-in-Picture implementation, so
 * an always-on-top window over other applications has to be its own program.
 */
import { spawn } from 'node:child_process'
import { randomUUID } from 'node:crypto'
import { existsSync } from 'node:fs'
import { mkdir, readFile, readdir, rename, rm, stat, writeFile } from 'node:fs/promises'
import { homedir } from 'node:os'
import { dirname, join, sep } from 'node:path'
import { fileURLToPath } from 'node:url'

/** macOS only: the native half this package ships is `window/dsh-floating-window.app`. */
const IS_MAC = process.platform === 'darwin'

/**
 * The window program is a .app bundle, spawned through its executable rather than
 * `open`, so this process keeps the pid and the plugin teardown can close the
 * window. The bundle id decides where WebKit stores this window's cache and
 * cookies, so it is shared with window/build.sh and must stay in step.
 */
const BUNDLE_ID = 'com.dsh.floating-window'
const WINDOW_BIN = fileURLToPath(new URL(
  '../window/dsh-floating-window.app/Contents/MacOS/dsh-floating-window', import.meta.url))

/** Route paths (the page route is a prefix: the shell matches `prefix` or `prefix/…`). */
const OPEN_ROUTE = '/dsh-floating-window/open'
const PAGE_ROUTE = '/dsh-floating-window/page'
/** The window's own preferences (read and written by the settings page). */
const SETTINGS_ROUTE = '/dsh-floating-window/settings'
/** Appearance channel: the renderer reports itself here, the window page asks. */
const THEME_ROUTE = '/dsh-floating-window/theme'
/** Cache/garbage channel: the settings page reads the sizes here and asks for a clean. */
const STATS_ROUTE = '/dsh-floating-window/stats'
const CLEAN_ROUTE = '/dsh-floating-window/clean'
/**
 * The conversation surface of the floating window. The window is a client of the
 * Host's own Session services (`sessionController` / `sessionQuery`), so it lists
 * every Session the DSH window lists and writes into the real conversation —
 * the same sessions, not a private side thread.
 */
const SESSIONS_ROUTE = '/dsh-floating-window/sessions'
const SESSION_HISTORY_ROUTE = '/dsh-floating-window/session/history'
const SESSION_LIVE_ROUTE = '/dsh-floating-window/session/live'
const SESSION_PROMPT_ROUTE = '/dsh-floating-window/session/prompt'
const SESSION_CANCEL_ROUTE = '/dsh-floating-window/session/cancel'
const SESSION_NEW_ROUTE = '/dsh-floating-window/session/new'
/** Hide one Session from the DSH window's workspace grouping (used to retire extra blanks). */
const SESSION_ARCHIVE_ROUTE = '/dsh-floating-window/session/archive'
/** One image attachment's bytes, so a transcript can show the picture itself. */
const SESSION_ATTACHMENT_ROUTE = '/dsh-floating-window/session/attachment'
/** The live transcript stream (Server-Sent Events) for one chosen Session. */
const SESSION_FOLLOW_ROUTE = '/dsh-floating-window/session/follow'
/** One-shot "open this Session in the DSH window" request for the browser half. */
const FOCUS_ROUTE = '/dsh-floating-window/focus'
const PAGE_TAIL = join('page', 'float.html')

/* ── Where the window keeps its state ──────────────────────────────────────
 * The app is a bundle whose own directory may be replaced by a plugin update, so
 * settings, geometry and the log live in Application Support — the same place the
 * Swift half resolves (`Paths.stateDirectory`).
 */
const WINDOW_DIR = join(homedir(), 'Library', 'Application Support', 'dsh-floating-window')

/* ── 缓存与垃圾 ────────────────────────────────────────────────────────────
 * 只清纯缓存：掉了只是下次重新生成，登录态与对话关联不受影响。
 *
 * WKWebView 用 bundle id 建缓存目录，Cookie 与 Local Storage 不在其中；
 * 清理逻辑与 window/src/CacheMaintenance.swift 保持一致。
 */
const CACHE_DIRS = [
  join(homedir(), 'Library', 'Caches', BUNDLE_ID),
  join(homedir(), 'Library', 'WebKit', BUNDLE_ID, 'WebsiteData', 'Cache'),
]

/** Keep in step with `Log.rotateBytes` in window/src/Log.swift (18 MB). */
const LOG_CAP_BYTES = 18 * 1024 * 1024
const LOG_NAME = 'window-log.txt'
/** Left behind when a clean could not finish because the window holds the files:
 *  the window deletes the rest when it closes, or on its next start. */
const PENDING_CLEAN = 'clean-pending.txt'

/** Bytes inside a folder; a missing folder counts as zero. */
async function folderBytes(path) {
  let entries = []
  try { entries = await readdir(path, { withFileTypes: true }) } catch { return 0 }
  let total = 0
  for (const entry of entries) {
    const full = join(path, entry.name)
    if (entry.isDirectory()) {
      total += await folderBytes(full)
      continue
    }
    try { total += (await stat(full)).size } catch { /* vanished mid-walk */ }
  }
  return total
}

/** What the settings page shows: cache size, log size, and the log cap. */
async function cacheStats() {
  let cacheBytes = 0
  const parts = []
  for (const folder of CACHE_DIRS) {
    const size = await folderBytes(folder)
    if (size > 0) parts.push({ name: folder.split(sep).filter(Boolean).pop(), bytes: size })
    cacheBytes += size
  }
  let logBytes = 0
  try { logBytes = (await stat(join(WINDOW_DIR, LOG_NAME))).size } catch { logBytes = 0 }
  return { cacheBytes, logBytes, logCapBytes: LOG_CAP_BYTES, parts }
}

/**
 * Delete the browser cache and rotate an oversized log. What the running window
 * still holds cannot be deleted from here — `clean-pending.txt` then tells the
 * window to finish the job when it closes (see CleanPendingCache in
 * window/src/CacheMaintenance.swift, `finishPendingClean`).
 */
async function cleanCacheAndLog() {
  const before = await cacheStats()
  let freed = 0
  let locked = 0
  for (const folder of CACHE_DIRS) {
    const size = await folderBytes(folder)
    if (size === 0) continue
    try { await rm(folder, { recursive: true, force: true }) } catch { locked += 1 }
    freed += Math.max(0, size - (await folderBytes(folder)))
  }
  let rotated = false
  try {
    const logPath = join(WINDOW_DIR, LOG_NAME)
    if ((await stat(logPath)).size >= LOG_CAP_BYTES) {
      const first = join(WINDOW_DIR, 'window-log.1.txt')
      const second = join(WINDOW_DIR, 'window-log.2.txt')
      await rm(second, { force: true })
      try { await rename(first, second) } catch { /* no previous log yet */ }
      await rename(logPath, first)
      rotated = true
    }
  } catch { rotated = false }
  try {
    const marker = join(WINDOW_DIR, PENDING_CLEAN)
    if (locked > 0) await writeFile(marker, 'pending', 'utf8')
    else await rm(marker, { force: true })
  } catch { /* best effort */ }
  return { freed, locked, rotated, beforeCacheBytes: before.cacheBytes, after: await cacheStats() }
}

/** Header the Desktop shell attaches to its own renderer's requests. */
const RENDERER_HEADER = 'x-dsh-desktop-renderer'

/** A request body larger than this is not a window request (images get their own budget). */
const MAX_BODY_BYTES = 64 * 1024
/** A prompt may carry inline images, so its body budget is much larger. */
const MAX_PROMPT_BODY_BYTES = 40 * 1024 * 1024
/** Image media types the conversation API admits, and one image's base64 ceiling. */
const IMAGE_MEDIA_TYPES = new Set(['image/png', 'image/jpeg', 'image/webp', 'image/gif'])
const MAX_INLINE_IMAGE_CHARS = 14 * 1024 * 1024

/**
 * The floating window's preferences. Every field has to mean something in the
 * window process (`window/src/`) or the page (`page/float.html`):
 * a setting that changes nothing is worse than no setting.
 */
const SETTINGS_DEFAULTS = Object.freeze({
  /** `dsh` follows DSH's own ui-theme preference, `system` follows macOS, `light`/`dark` force one. */
  appearance: 'dsh',
  /** Start pinned over other applications. */
  alwaysOnTop: true,
  /** Remember and restore the window's size and position. */
  rememberGeometry: true,
  /** Window opacity, 0.6 – 1. */
  opacity: 1,
  /** Size used when geometry is not remembered (or nothing was saved yet). */
  defaultWidth: 620,
  defaultHeight: 900,
  /**
   * The old "burn the side thread on close" setting. Retired when the window started
   * real Sessions, so nothing here may delete one — but kept in the schema so an
   * older settings file still normalizes without losing the other keys.
   */
  ephemeralByDefault: false,
  /** Put the conversation's title in the window title bar. */
  showSessionTitle: true,
  /** Esc closes the window (running the page's own cleanup first). */
  closeOnEscape: false,
})

/** One accepted appearance: a forced scheme, "follow DSH", or "follow the system". */
const APPEARANCES = ['light', 'dark', 'dsh', 'system']

/** `auto` was the old name for "follow DSH": existing settings files keep working. */
const appearanceOf = (value) => {
  const wanted = value === 'auto' ? 'dsh' : value
  return APPEARANCES.includes(wanted) ? wanted : SETTINGS_DEFAULTS.appearance
}

const clampNumber = (value, fallback, min, max) => {
  const number = typeof value === 'number' && Number.isFinite(value) ? value : fallback
  return Math.min(max, Math.max(min, number))
}

/**
 * Fold whatever is on disk (or came in a request) into a complete, trusted
 * settings object. Unknown keys are dropped and out-of-range numbers are
 * clamped, so a hand-edited file can never crash the window.
 */
function normalizeSettings(raw) {
  const source = raw !== null && typeof raw === 'object' ? raw : {}
  return {
    appearance: appearanceOf(source.appearance),
    alwaysOnTop: typeof source.alwaysOnTop === 'boolean' ? source.alwaysOnTop : SETTINGS_DEFAULTS.alwaysOnTop,
    rememberGeometry: typeof source.rememberGeometry === 'boolean' ? source.rememberGeometry : SETTINGS_DEFAULTS.rememberGeometry,
    opacity: clampNumber(source.opacity, SETTINGS_DEFAULTS.opacity, 0.6, 1),
    defaultWidth: Math.round(clampNumber(source.defaultWidth, SETTINGS_DEFAULTS.defaultWidth, 320, 1600)),
    defaultHeight: Math.round(clampNumber(source.defaultHeight, SETTINGS_DEFAULTS.defaultHeight, 260, 1600)),
    ephemeralByDefault: typeof source.ephemeralByDefault === 'boolean' ? source.ephemeralByDefault : SETTINGS_DEFAULTS.ephemeralByDefault,
    showSessionTitle: typeof source.showSessionTitle === 'boolean' ? source.showSessionTitle : SETTINGS_DEFAULTS.showSessionTitle,
    closeOnEscape: typeof source.closeOnEscape === 'boolean' ? source.closeOnEscape : SETTINGS_DEFAULTS.closeOnEscape,
  }
}

/** Patch shape accepted by POST: only the keys the caller actually sent. */
const PATCH_KEYS = Object.freeze(Object.keys(SETTINGS_DEFAULTS))

/**
 * Locate a file that ships beside this package. Plugin packages are loaded
 * through the profile's `node_modules` junction, so the module's own directory
 * may be either the project directory or the junction — walking up from the
 * module finds the project in both worlds without depending on which one it is.
 */
function findBeside(relative) {
  let dir = dirname(fileURLToPath(import.meta.url))
  for (let depth = 0; depth < 8; depth += 1) {
    const candidate = join(dir, relative)
    if (existsSync(candidate)) return candidate
    const parent = dirname(dir)
    if (parent === dir) break
    dir = parent
  }
  return undefined
}

const PAGE_FILE = findBeside(PAGE_TAIL)
const SETTINGS_FILE = join(WINDOW_DIR, 'float-settings.json')

/** Read a JSON request body, refusing anything beyond the caller's budget. */
async function readJsonBody(req, maxBytes = MAX_BODY_BYTES) {
  const chunks = []
  let size = 0
  for await (const chunk of req) {
    size += chunk.length
    if (size > maxBytes) return undefined
    chunks.push(chunk)
  }
  if (size === 0) return {}
  try {
    return JSON.parse(Buffer.concat(chunks).toString('utf8'))
  } catch (error) {
    return undefined
  }
}

function sendJson(res, status, value) {
  const body = JSON.stringify(value)
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
    'content-length': String(Buffer.byteLength(body)),
  })
  res.end(body)
}

/** Only loopback origins may be handed a token URL. */
function loopbackOrigin(value) {
  if (typeof value !== 'string' || value === '') return undefined
  try {
    const url = new URL(value)
    const host = url.hostname.toLowerCase()
    if (url.protocol !== 'http:' && url.protocol !== 'https:') return undefined
    if (host !== '127.0.0.1' && host !== 'localhost' && host !== '[::1]' && host !== '::1') return undefined
    return url.origin
  } catch (error) {
    return undefined
  }
}

/**
 * The Host services this half drives. `webServer` has to be declared: cordis
 * only exposes an injected service as a property, and an undeclared
 * `ctx.webServer` is undefined — which fails `apply()` before a single route is
 * registered, and the composer button then reports 浮窗打开失败.
 */
export const inject = ['webServer']

export function apply(ctx) {
  /** The one companion window process, or null. */
  let child = null

  /** Appearance the renderer last reported about itself: { preference, resolved }. */
  let reportedTheme = undefined

  /** The settings as last read or written, so GET never needs the disk. */
  let cachedSettings = undefined

  /**
   * The official read of DSH's appearance: the Host `settings` service owns the
   * `ui-theme` namespace — the same entry the shell's own Appearance row writes —
   * so ask it instead of guessing. Service, namespace and value are all optional;
   * anything missing simply means "unknown".
   */
  const settingsTheme = () => {
    try {
      const settings = ctx.get('settings')
      if (settings === undefined || typeof settings.describe !== 'function') return undefined
      const entry = settings.describe().find((item) => String(item.ns) === 'ui-theme')
      const value = entry !== undefined ? entry.value : undefined
      const preference = value !== undefined ? value.preference : undefined
      if (preference !== 'light' && preference !== 'dark' && preference !== 'system') return undefined
      return { preference }
    } catch (error) {
      ctx.logger?.warn?.(`dsh-floating-window: settings read failed: ${error instanceof Error ? error.message : String(error)}`)
      return undefined
    }
  }

  /** What the window page should paint: the renderer's word first, settings second. */
  const currentTheme = () => {
    if (reportedTheme !== undefined) return reportedTheme
    const fromSettings = settingsTheme()
    return fromSettings === undefined ? {} : fromSettings
  }

  /**
   * Read the window's own settings file; a missing or broken file means defaults.
   *
   * Always reads the file: the window process writes it too (the header's pin
   * button, the geometry it remembers), so a cached copy served here would drift
   * from what the window actually uses and a later save from the settings page
   * would then write the stale values back over them. It is one small file, read
   * when a settings request arrives or a window opens.
   */
  const loadSettings = async () => {
    try {
      const text = await readFile(SETTINGS_FILE, 'utf8')
      cachedSettings = normalizeSettings(JSON.parse(text))
    } catch (error) {
      cachedSettings = normalizeSettings(undefined)
    }
    return cachedSettings
  }

  /** Write them back through a temp file, so the window never reads a half file. */
  const saveSettings = async (patch) => {
    const current = await loadSettings()
    const next = normalizeSettings(Object.assign({}, current, patch))
    const temp = `${SETTINGS_FILE}.tmp`
    // macOS keeps the file in Application Support: the window may never have run,
    // so the folder has to exist before the settings page's first save.
    await mkdir(dirname(SETTINGS_FILE), { recursive: true })
    await writeFile(temp, `${JSON.stringify(next, null, 2)}\n`, 'utf8')
    await rename(temp, SETTINGS_FILE)
    cachedSettings = next
    return next
  }

  const launch = (authUrl, pageUrl, rendererHeader) => {
    if (child !== null && child.exitCode === null && child.signalCode === null) return false
    const env = { ...process.env }
    // The DSH Host runs inside Electron: an inherited ELECTRON_RUN_AS_NODE would
    // turn a child Electron process into a Node one instead of a window.
    delete env.ELECTRON_RUN_AS_NODE
    const args = [
      `--dsh-auth-url=${authUrl}`,
      `--dsh-page-url=${pageUrl}`,
      '--dsh-title=\u60ac\u6d6e\u7a97',
    ]
    if (rendererHeader !== '') {
      args.push(`--dsh-header-name=${RENDERER_HEADER}`, `--dsh-header-value=${rendererHeader}`)
    }
    // The .app bundle's executable is spawned directly (not via `open`), so this
    // process owns the pid and the teardown below can close the window.
    child = spawn(WINDOW_BIN, args, {
      env,
      detached: true,
      stdio: ['ignore', 'inherit', 'inherit'],
    })
    child.on('exit', () => {
      child = null
    })
    child.on('error', (error) => {
      ctx.logger?.warn?.(`dsh-floating-window: window spawn failed: ${error instanceof Error ? error.message : String(error)}`)
      child = null
    })
    child.unref()
    return true
  }

  /* ── 会话：浮窗直接操作客户端已有的会话 ─────────────────────────────────
   * The floating window used to be a private side thread of one parent Session.
   * It is now an ordinary client of the Host's Session services, so the picker
   * lists exactly what the DSH window lists and a message typed here lands in the
   * real conversation. All reads are cold-safe (`sessionController` paginates and
   * `sessionQuery` reads titles), so browsing the list never resumes an Agent.
   */

  /** A Session identity that may be handed to the Host services. */
  const SESSION_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/

  /** The only event types a human transcript shows; attempts and headers are trace data. */
  const MESSAGE_EVENT_TYPES = new Set(['user/message', 'assistant/message'])

  const messageOf = (error) => (error instanceof Error ? error.message : String(error))

  /** Abort one service call that outlives its budget instead of hanging the window. */
  const callBudget = (ms) => {
    const controller = new AbortController()
    const timer = setTimeout(() => controller.abort(), ms)
    if (typeof timer.unref === 'function') timer.unref()
    return { signal: controller.signal, release: () => clearTimeout(timer) }
  }

  /** The Host's Session controller, or a clear failure for the route to report. */
  const sessionController = () => {
    const controller = ctx.get('sessionController')
    if (controller === undefined || typeof controller.list !== 'function') {
      throw new Error('session service unavailable')
    }
    return controller
  }

  /** Concatenate the text of one message content block list. */
  const textOfBlocks = (blocks) => {
    if (!Array.isArray(blocks)) return ''
    const parts = []
    for (const block of blocks) {
      if (block === null || typeof block !== 'object') continue
      if (block.type === 'text' && typeof block.text === 'string') parts.push(block.text)
    }
    return parts.join('\n\n').trim()
  }

  /** The image attachments carried by one message, so the window can show them. */
  const imageRefsOf = (blocks) => {
    const refs = []
    if (!Array.isArray(blocks)) return refs
    for (const block of blocks) {
      if (block === null || typeof block !== 'object' || block.type !== 'image') continue
      const ref = block.attachment
      if (ref === null || typeof ref !== 'object') continue
      if (typeof ref.attachmentId !== 'string' || ref.attachmentId === '') continue
      refs.push(ref)
    }
    return refs
  }

  /** A short, readable hint of one tool call's arguments (the first string it carries). */
  const argPreview = (raw) => {
    if (typeof raw !== 'string' || raw === '') return ''
    let text = raw
    try {
      const parsed = JSON.parse(raw)
      if (parsed !== null && typeof parsed === 'object') {
        const first = Object.values(parsed).find((value) => typeof value === 'string' && value !== '')
        if (typeof first === 'string') text = first
      }
    } catch {
      // Not JSON: the raw arguments already read fine.
    }
    const flat = text.replace(/\s+/g, ' ').trim()
    return flat.length > 72 ? `${flat.slice(0, 72)}…` : flat
  }

  /**
   * One wire message event as the compact transcript row the page renders.
   * Replacement copies (`surfaceOp` other than `append`) are model-only: a human
   * transcript keeps what the user already saw, so they are skipped.
   */
  const transcriptItemOf = (event) => {
    if (event === null || typeof event !== 'object') return undefined
    if (!MESSAGE_EVENT_TYPES.has(event.type)) return undefined
    if (event.surfaceOp !== undefined && event.surfaceOp !== 'append') return undefined
    const data = event.data
    if (data === null || typeof data !== 'object') return undefined
    if (event.type === 'user/message') {
      // Only a real user prompt is a transcript row: the harness also appends
      // runtime context, the skill catalog and time snapshots as `user/message`
      // events, and the DSH window never shows those as bubbles either.
      const source = data.source
      if (source === null || typeof source !== 'object' || source.kind !== 'user') return undefined
      const text = textOfBlocks(data.content)
      const images = imageRefsOf(data.content)
      if (text === '' && images.length === 0) return undefined
      return { kind: 'user', seq: event.seq, text, images }
    }
    const message = data.message
    const content = message !== null && typeof message === 'object' ? message.content : undefined
    const texts = []
    const reasoning = []
    const tools = []
    if (Array.isArray(content)) {
      for (const block of content) {
        if (block === null || typeof block !== 'object') continue
        if (block.type === 'text' && typeof block.text === 'string') texts.push(block.text)
        else if (block.type === 'reasoning' && typeof block.text === 'string') reasoning.push(block.text)
        else if (block.type === 'tool-call' && typeof block.name === 'string') {
          tools.push({ name: block.name, args: argPreview(block.arguments) })
        }
      }
    }
    const text = texts.join('\n\n').trim()
    const images = imageRefsOf(content)
    if (text === '' && reasoning.length === 0 && tools.length === 0 && images.length === 0) return undefined
    return {
      kind: 'assistant',
      seq: event.seq,
      text,
      reasoning: reasoning.join('\n\n').trim(),
      tools,
      images,
    }
  }

  /** Map a contiguous event window to transcript rows and its last event sequence. */
  const surfaceMessagesOf = (events) => {
    const items = []
    let cursor = -1
    for (const event of events) {
      if (event === null || typeof event !== 'object') continue
      const item = transcriptItemOf(event)
      if (item !== undefined) items.push(item)
      if (typeof event.seq === 'number' && event.seq > cursor) cursor = event.seq
    }
    return { items, cursor }
  }

  /**
   * One assistant-stream frame as the page's typing signal. Only the three
   * visible kinds are forwarded; block markers and usage stay on the Host.
   */
  const streamDeltaOf = (frame) => {
    if (frame === null || typeof frame !== 'object') return undefined
    if (frame.type === 'start') return { type: 'stream-start' }
    if (frame.type === 'end') {
      const outcome = frame.outcome !== null && frame.outcome !== undefined && typeof frame.outcome === 'object'
        ? frame.outcome.kind
        : undefined
      return { type: 'stream-end', outcome: outcome === 'abandoned' ? 'abandoned' : 'committed' }
    }
    const chunk = frame.chunk
    if (chunk === null || typeof chunk !== 'object') return undefined
    if (chunk.type === 'text-delta' && typeof chunk.text === 'string') return { type: 'stream-text', text: chunk.text }
    if (chunk.type === 'reasoning-delta' && typeof chunk.text === 'string') return { type: 'stream-reasoning', text: chunk.text }
    if (chunk.type === 'tool-call-delta' && typeof chunk.name === 'string' && chunk.name !== '') {
      return { type: 'stream-tool', name: chunk.name }
    }
    return undefined
  }

  /** The log-backed title of one Session, or an empty string when it has none yet. */
  const readTitleOf = async (sessionId) => {    const query = ctx.get('sessionQuery')
    if (query === undefined || typeof query.readTitleSnapshot !== 'function') return ''
    try {
      const observation = await query.readTitleSnapshot(sessionId)
      const title = observation !== null && observation !== undefined && observation.title !== undefined
        ? observation.title.title
        : undefined
      return typeof title === 'string' ? title : ''
    } catch (error) {
      return ''
    }
  }

  /**
   * The workspace side of the picker: membership order, the archive set and the
   * pin set, read from the first frame of the workspace stream. Without it the
   * float would list archived Sessions (which the DSH window hides) and in
   * corpus order instead of the user's own order.
   */
  const readWorkspaceBaseline = async () => {
    const controller = ctx.get('workspaceController')
    if (controller === undefined || typeof controller.follow !== 'function') return undefined
    const budget = callBudget(5000)
    try {
      for await (const frame of controller.follow(budget.signal)) {
        if (frame !== null && typeof frame === 'object' && frame.type === 'baseline') return frame.value
      }
      return undefined
    } catch (error) {
      ctx.logger?.warn?.(`dsh-floating-window: workspace baseline failed: ${messageOf(error)}`)
      return undefined
    } finally {
      budget.release()
    }
  }

  /** Every visible Session, with the title and workspace the DSH window shows. */
  const listSessionRows = async () => {
    const controller = sessionController()
    const budget = callBudget(20000)
    try {
      // `list` answers the wire envelope (`{ items }`), not a bare array.
      const value = await controller.list({}, budget.signal)
      const rows = Array.isArray(value) ? value : Array.isArray(value?.items) ? value.items : []
      const visible = rows.filter((row) => row !== null && typeof row === 'object'
        && typeof row.sessionId === 'string' && row.origin !== 'subagent')
      const titles = new Map()
      const query = ctx.get('sessionQuery')
      if (visible.length > 0 && query !== undefined && typeof query.readTitleSnapshots === 'function') {
        try {
          const results = await query.readTitleSnapshots(visible.map((row) => row.sessionId), budget.signal)
          for (const result of results) {
            if (result === null || typeof result !== 'object' || result.status !== 'fulfilled') continue
            const value = result.value
            const title = value !== undefined && value.title !== undefined ? value.title.title : undefined
            if (typeof title === 'string' && title !== '') titles.set(result.sessionId, title)
          }
        } catch (error) {
          // A corpus hiccup must not hide the list: rows without titles still work.
          ctx.logger?.warn?.(`dsh-floating-window: session titles unavailable: ${messageOf(error)}`)
        }
      }
      const baseline = await readWorkspaceBaseline()
      return {
        sessions: visible.map((row) => ({
          id: row.sessionId,
          title: titles.get(row.sessionId) ?? '',
          updatedAt: typeof row.updatedAt === 'number' ? row.updatedAt : 0,
          running: row.running === true,
          blank: row.blank === true,
          cwd: typeof row.cwd === 'string' ? row.cwd : '',
          parent: typeof row.parentSessionId === 'string' ? row.parentSessionId : '',
        })),
        workspaces: baseline !== undefined && Array.isArray(baseline.items)
          ? baseline.items.map((workspace) => ({
            id: String(workspace.workspaceId),
            title: typeof workspace.title === 'string' ? workspace.title : '',
            path: typeof workspace.path === 'string' ? workspace.path : '',
            sessionIds: Array.isArray(workspace.sessionIds) ? workspace.sessionIds.map(String) : [],
          }))
          : listWorkspaceRows(),
        archived: baseline !== undefined && Array.isArray(baseline.archivedSessionIds)
          ? baseline.archivedSessionIds.map(String)
          : [],
        pinned: baseline !== undefined && Array.isArray(baseline.pinnedSessionIds)
          ? baseline.pinnedSessionIds.map(String)
          : [],
      }
    } finally {
      budget.release()
    }
  }

  /** The workspace registry, as labels for the picker; absent services mean no labels. */
  const listWorkspaceRows = () => {
    try {
      const registry = ctx.get('workspaceRegistry')
      if (registry === undefined || typeof registry.list !== 'function') return []
      return registry.list().map((workspace) => ({
        id: String(workspace.id),
        title: typeof workspace.title === 'string' ? workspace.title : '',
        path: typeof workspace.path === 'string' ? workspace.path : '',
      }))
    } catch (error) {
      return []
    }
  }

  /** Validate one JSON request body field as a Session identity. */
  const sessionIdOf = (body, key = 'sessionId') => {
    const value = body !== undefined && body !== null ? body[key] : undefined
    return typeof value === 'string' && SESSION_ID_PATTERN.test(value) ? value : undefined
  }

  /** The conversation the browser half asks the DSH window to open, if any. */
  let focusRequest = undefined

  const disposeRoutes = [
    ctx.webServer.register({
      kind: 'exact',
      path: OPEN_ROUTE,
      handler: async (req, res) => {
        if (req.method !== 'POST') {
          sendJson(res, 405, { ok: false, error: 'method not allowed' })
          return
        }
        // This is the macOS edition: on another platform say so instead of
        // spawning something that cannot exist.
        if (!IS_MAC) {
          sendJson(res, 500, { ok: false, error: `dsh-floating-window-macos requires macOS (running on ${process.platform})` })
          return
        }
        if (!existsSync(WINDOW_BIN)) {
          sendJson(res, 500, { ok: false, error: 'window/dsh-floating-window.app missing (run window/build.sh)' })
          return
        }
        const body = await readJsonBody(req)
        if (body === undefined) {
          sendJson(res, 400, { ok: false, error: 'invalid body' })
          return
        }
        // Local compatibility patch for the Desktop shell: the renderer reports
        // `dsh-app://app`, while the token URL and the window page live on the
        // Host's loopback address, which the forwarded request's Host header names.
        let origin = loopbackOrigin(body.origin)
        if (origin === undefined && body.origin === 'dsh-app://app') {
          const forwardedHost = req.headers.host
          origin = typeof forwardedHost === 'string' && forwardedHost !== ''
            ? loopbackOrigin(`http://${forwardedHost}`)
            : undefined
        }
        if (origin === undefined) {
          sendJson(res, 400, { ok: false, error: 'loopback origin required' })
          return
        }
        const connection = ctx.get('connection')
        if (connection === undefined || typeof connection.authenticatedUrl !== 'function') {
          sendJson(res, 500, { ok: false, error: 'connection service unavailable' })
          return
        }
        const parent = typeof body.parent === 'string' ? body.parent : ''
        // The caller's own reading is a hint; what the theme channel knows (the
        // renderer's report, else the Host settings entry) decides, so the window
        // is born in the appearance DSH actually has. A forced appearance in the
        // window's own settings wins in the window process itself.
        const settings = await loadSettings()
        const reported = currentTheme()
        let opening = body.theme === 'light' || body.theme === 'dark' ? body.theme : undefined
        if (opening === undefined) opening = reported.resolved
        if (opening === undefined && (reported.preference === 'light' || reported.preference === 'dark')) {
          opening = reported.preference
        }
        // A forced scheme can seed the first paint; `dsh`/`system` are resolved by
        // the window process, which sees both DSH's preference and macOS.
        if (opening === undefined && (settings.appearance === 'light' || settings.appearance === 'dark')) {
          opening = settings.appearance
        }
        const pageUrl = new URL(`${PAGE_ROUTE}/`, origin)
        if (parent !== '') pageUrl.searchParams.set('parent', parent)
        if (opening !== undefined) pageUrl.searchParams.set('theme', opening)
        const forwarded = req.headers[RENDERER_HEADER]
        try {
          const started = launch(
            connection.authenticatedUrl(`${origin}/`),
            pageUrl.href,
            typeof forwarded === 'string' ? forwarded : '',
          )
          sendJson(res, 200, { ok: true, value: { started, pageUrl: pageUrl.href } })
        } catch (error) {
          ctx.logger?.warn?.(`dsh-floating-window: window launch threw: ${error instanceof Error ? error.message : String(error)}`)
          sendJson(res, 500, { ok: false, error: 'launch failed' })
        }
      },
    }),
    ctx.webServer.register({
      kind: 'exact',
      path: SETTINGS_ROUTE,
      handler: async (req, res) => {
        if (req.method === 'GET') {
          sendJson(res, 200, { ok: true, value: await loadSettings(), defaults: SETTINGS_DEFAULTS })
          return
        }
        if (req.method !== 'POST') {
          sendJson(res, 405, { ok: false, error: 'method not allowed' })
          return
        }
        const body = await readJsonBody(req)
        if (body === undefined) {
          sendJson(res, 400, { ok: false, error: 'invalid body' })
          return
        }
        // Only the keys this plugin owns: a request can never smuggle in extra
        // fields that later end up in the window's file.
        const patch = {}
        let touched = 0
        for (const key of PATCH_KEYS) {
          if (Object.prototype.hasOwnProperty.call(body, key) && body[key] !== undefined) {
            patch[key] = body[key]
            touched += 1
          }
        }
        if (touched === 0) {
          sendJson(res, 400, { ok: false, error: 'no known setting in body' })
          return
        }
        try {
          const saved = await saveSettings(patch)
          sendJson(res, 200, { ok: true, value: saved })
        } catch (error) {
          ctx.logger?.warn?.(`dsh-floating-window: settings write failed: ${error instanceof Error ? error.message : String(error)}`)
          sendJson(res, 500, { ok: false, error: 'settings write failed' })
        }
      },
    }),
    ctx.webServer.register({
      kind: 'exact',
      path: THEME_ROUTE,
      handler: async (req, res) => {
        if (req.method === 'GET') {
          // The window page polls this: one small object, no guessing on its side.
          sendJson(res, 200, { ok: true, value: currentTheme() })
          return
        }
        if (req.method !== 'POST') {
          sendJson(res, 405, { ok: false, error: 'method not allowed' })
          return
        }
        const body = await readJsonBody(req)
        if (body === undefined) {
          sendJson(res, 400, { ok: false, error: 'invalid body' })
          return
        }
        // The browser half reports straight from the ui-theme service: the
        // preference the user picked plus the scheme it resolves to right now.
        const preference = body.preference === 'light' || body.preference === 'dark' || body.preference === 'system'
          ? body.preference
          : undefined
        const resolved = body.resolved === 'light' || body.resolved === 'dark' ? body.resolved : undefined
        if (preference === undefined && resolved === undefined) {
          sendJson(res, 400, { ok: false, error: 'theme required' })
          return
        }
        const next = {}
        if (preference !== undefined) next.preference = preference
        if (resolved !== undefined) next.resolved = resolved
        reportedTheme = next
        sendJson(res, 200, { ok: true, value: reportedTheme })
      },
    }),
    ctx.webServer.register({
      kind: 'exact',
      path: STATS_ROUTE,
      handler: async (req, res) => {
        if (req.method !== 'GET') {
          sendJson(res, 405, { ok: false, error: 'method not allowed' })
          return
        }
        try {
          sendJson(res, 200, { ok: true, value: await cacheStats() })
        } catch (error) {
          sendJson(res, 500, { ok: false, error: String((error && error.message) || error) })
        }
      },
    }),
    ctx.webServer.register({
      kind: 'exact',
      path: CLEAN_ROUTE,
      handler: async (req, res) => {
        if (req.method !== 'POST') {
          sendJson(res, 405, { ok: false, error: 'method not allowed' })
          return
        }
        const body = await readJsonBody(req)
        if (body === undefined) {
          sendJson(res, 400, { ok: false, error: 'invalid body' })
          return
        }
        try {
          sendJson(res, 200, { ok: true, value: await cleanCacheAndLog() })
        } catch (error) {
          sendJson(res, 500, { ok: false, error: String((error && error.message) || error) })
        }
      },
    }),
    ctx.webServer.register({
      kind: 'exact',
      path: SESSIONS_ROUTE,
      handler: async (req, res) => {
        if (req.method !== 'GET') {
          sendJson(res, 405, { ok: false, error: 'method not allowed' })
          return
        }
        try {
          sendJson(res, 200, { ok: true, value: await listSessionRows() })
        } catch (error) {
          ctx.logger?.warn?.(`dsh-floating-window: session list failed: ${messageOf(error)}`)
          sendJson(res, 500, { ok: false, error: messageOf(error) })
        }
      },
    }),
    ctx.webServer.register({
      kind: 'exact',
      path: SESSION_HISTORY_ROUTE,
      handler: async (req, res) => {
        if (req.method !== 'POST') {
          sendJson(res, 405, { ok: false, error: 'method not allowed' })
          return
        }
        const body = await readJsonBody(req)
        if (body === undefined) {
          sendJson(res, 400, { ok: false, error: 'invalid body' })
          return
        }
        const sessionId = sessionIdOf(body)
        if (sessionId === undefined) {
          sendJson(res, 400, { ok: false, error: 'sessionId required' })
          return
        }
        const budget = typeof body.maxMessages === 'number' && Number.isSafeInteger(body.maxMessages) && body.maxMessages > 0
          ? Math.min(400, Math.max(10, body.maxMessages))
          : 120
        // An older page: everything strictly before the caller's oldest message.
        const beforeSeq = typeof body.beforeSeq === 'number' && Number.isSafeInteger(body.beforeSeq) && body.beforeSeq > 0
          ? body.beforeSeq
          : undefined
        const lease = callBudget(20000)
        try {
          // `turnWindow` makes the page start on a turn boundary: a bare message
          // budget can begin mid-turn and show answers without their question.
          const page = await sessionController().events({
            address: { kind: 'session', sessionId },
            maxMessages: budget,
            ...(beforeSeq === undefined ? {} : { beforeSeq }),
            turnWindow: { minMessages: Math.max(1, Math.floor(budget / 2)), minTurns: 1 },
          }, lease.signal)
          const records = Array.isArray(page.records) ? page.records : []
          const mapped = surfaceMessagesOf(records.map((record) => (record !== null && typeof record === 'object' ? record.event : undefined)))
          sendJson(res, 200, {
            ok: true,
            value: {
              items: mapped.items,
              cursor: typeof page.cursor === 'number' ? page.cursor : mapped.cursor,
              hasMore: page.hasMore === true,
            },
          })
        } catch (error) {
          ctx.logger?.warn?.(`dsh-floating-window: session history failed: ${messageOf(error)}`)
          sendJson(res, 500, { ok: false, error: messageOf(error) })
        } finally {
          lease.release()
        }
      },
    }),
    ctx.webServer.register({
      kind: 'exact',
      path: SESSION_LIVE_ROUTE,
      handler: async (req, res) => {
        if (req.method !== 'POST') {
          sendJson(res, 405, { ok: false, error: 'method not allowed' })
          return
        }
        const body = await readJsonBody(req)
        if (body === undefined) {
          sendJson(res, 400, { ok: false, error: 'invalid body' })
          return
        }
        const sessionId = sessionIdOf(body)
        if (sessionId === undefined) {
          sendJson(res, 400, { ok: false, error: 'sessionId required' })
          return
        }
        const after = typeof body.after === 'number' && Number.isSafeInteger(body.after) && body.after >= -1 ? body.after : -1
        const controller = sessionController()
        const lease = callBudget(10000)
        try {
          // Passive state: running / queued / waiting for an answer. It is also the
          // cheap poll that keeps the window's pulse honest between stream frames.
          const state = await controller.state({ sessionId }, lease.signal)
          let items = []
          let cursor = after
          const query = ctx.get('sessionQuery')
          if (query !== undefined && typeof query.inspectSession === 'function') {
            try {
              // Cold-safe incremental read: a live Session yields only the events
              // after the caller's cursor; a persisted one stays immutable, so a
              // Session that is not live simply reports no new rows.
              const events = await query.inspectSession(sessionId, (session) => session.snapshotEvents(after + 1))
              const mapped = surfaceMessagesOf(Array.isArray(events) ? events : [])
              items = mapped.items
              if (mapped.cursor > cursor) cursor = mapped.cursor
            } catch (error) {
              ctx.logger?.warn?.(`dsh-floating-window: live read failed: ${messageOf(error)}`)
            }
          }
          sendJson(res, 200, { ok: true, value: { state: state ?? null, items, cursor } })
        } catch (error) {
          sendJson(res, 500, { ok: false, error: messageOf(error) })
        } finally {
          lease.release()
        }
      },
    }),
    ctx.webServer.register({
      kind: 'exact',
      path: SESSION_PROMPT_ROUTE,
      handler: async (req, res) => {
        if (req.method !== 'POST') {
          sendJson(res, 405, { ok: false, error: 'method not allowed' })
          return
        }
        const body = await readJsonBody(req, MAX_PROMPT_BODY_BYTES)
        if (body === undefined) {
          sendJson(res, 400, { ok: false, error: 'invalid body' })
          return
        }
        const sessionId = sessionIdOf(body)
        if (sessionId === undefined) {
          sendJson(res, 400, { ok: false, error: 'sessionId required' })
          return
        }
        const text = typeof body.text === 'string' ? body.text.trim() : ''
        if (text.length > 32_000) {
          sendJson(res, 400, { ok: false, error: 'text too long' })
          return
        }
        // Inline images travel with the prompt itself: the conversation API admits
        // them into the attachment store exactly like the DSH window's own upload.
        const images = []
        if (Array.isArray(body.images)) {
          for (const image of body.images.slice(0, 4)) {
            if (image === null || typeof image !== 'object') continue
            const mediaType = typeof image.mediaType === 'string' ? image.mediaType : ''
            if (!IMAGE_MEDIA_TYPES.has(mediaType)) continue
            const data = typeof image.data === 'string' ? image.data : ''
            if (data === '' || data.length > MAX_INLINE_IMAGE_CHARS) continue
            images.push({
              type: 'image',
              mediaType,
              data,
              ...(typeof image.name === 'string' && image.name !== '' ? { name: image.name } : {}),
            })
          }
        }
        if (text === '' && images.length === 0) {
          sendJson(res, 400, { ok: false, error: 'text or image required' })
          return
        }
        const mode = body.mode === 'steer' ? 'steer' : 'queue'
        const clientTimeZone = typeof body.clientTimeZone === 'string' && body.clientTimeZone !== ''
          ? body.clientTimeZone
          : Intl.DateTimeFormat().resolvedOptions().timeZone
        const content = []
        if (text !== '') content.push({ type: 'text', text })
        content.push(...images)
        const lease = callBudget(30000)
        try {
          await sessionController().prompt({
            requestId: `float-${randomUUID()}`,
            sessionId,
            mode,
            content,
            clientTimeZone,
          }, lease.signal)
          sendJson(res, 200, { ok: true, value: { accepted: true } })
        } catch (error) {
          ctx.logger?.warn?.(`dsh-floating-window: prompt failed: ${messageOf(error)}`)
          sendJson(res, 500, { ok: false, error: messageOf(error) })
        } finally {
          lease.release()
        }
      },
    }),
    ctx.webServer.register({
      kind: 'exact',
      path: SESSION_CANCEL_ROUTE,
      handler: async (req, res) => {
        if (req.method !== 'POST') {
          sendJson(res, 405, { ok: false, error: 'method not allowed' })
          return
        }
        const body = await readJsonBody(req)
        const sessionId = sessionIdOf(body)
        if (sessionId === undefined) {
          sendJson(res, 400, { ok: false, error: 'sessionId required' })
          return
        }
        try {
          const value = await sessionController().cancel({ sessionId })
          sendJson(res, 200, { ok: true, value: value ?? { accepted: true } })
        } catch (error) {
          sendJson(res, 500, { ok: false, error: messageOf(error) })
        }
      },
    }),
    ctx.webServer.register({
      kind: 'exact',
      path: SESSION_NEW_ROUTE,
      handler: async (req, res) => {
        if (req.method !== 'POST') {
          sendJson(res, 405, { ok: false, error: 'method not allowed' })
          return
        }
        const body = await readJsonBody(req)
        const request = {}
        const workspaceId = body !== undefined && typeof body.workspaceId === 'string' && body.workspaceId !== ''
          ? body.workspaceId
          : undefined
        const cwd = body !== undefined && typeof body.cwd === 'string' && body.cwd !== '' ? body.cwd : undefined
        if (workspaceId !== undefined) request.workspaceId = workspaceId
        else if (cwd !== undefined) request.cwd = cwd
        const lease = callBudget(20000)
        try {
          const value = await sessionController().create(request)
          sendJson(res, 200, { ok: true, value: value ?? null })
        } catch (error) {
          ctx.logger?.warn?.(`dsh-floating-window: session create failed: ${messageOf(error)}`)
          sendJson(res, 500, { ok: false, error: messageOf(error) })
        } finally {
          lease.release()
        }
      },
    }),
    ctx.webServer.register({
      kind: 'exact',
      path: SESSION_ARCHIVE_ROUTE,
      handler: async (req, res) => {
        if (req.method !== 'POST') {
          sendJson(res, 405, { ok: false, error: 'method not allowed' })
          return
        }
        const body = await readJsonBody(req)
        const sessionId = sessionIdOf(body)
        if (sessionId === undefined) {
          sendJson(res, 400, { ok: false, error: 'sessionId required' })
          return
        }
        const controller = ctx.get('workspaceController')
        if (controller === undefined || typeof controller.archiveSession !== 'function') {
          sendJson(res, 503, { ok: false, error: 'workspace service unavailable' })
          return
        }
        try {
          // Archive is the DSH window's own "remove from the list": it hides the
          // Session from workspace grouping and can be undone there, so retiring
          // an empty blank never destroys anything.
          const value = await controller.archiveSession({ sessionId })
          sendJson(res, 200, { ok: true, value: value ?? null })
        } catch (error) {
          ctx.logger?.warn?.(`dsh-floating-window: session archive failed: ${messageOf(error)}`)
          sendJson(res, 500, { ok: false, error: messageOf(error) })
        }
      },
    }),
    ctx.webServer.register({
      kind: 'exact',
      path: SESSION_ATTACHMENT_ROUTE,
      handler: async (req, res) => {
        if (req.method !== 'POST') {
          sendJson(res, 405, { ok: false, error: 'method not allowed' })
          return
        }
        const body = await readJsonBody(req)
        const sessionId = sessionIdOf(body)
        const attachment = body !== undefined && body.attachment !== null && typeof body.attachment === 'object'
          ? body.attachment
          : undefined
        if (sessionId === undefined || attachment === undefined
          || typeof attachment.attachmentId !== 'string' || attachment.attachmentId === '') {
          sendJson(res, 400, { ok: false, error: 'sessionId and attachment required' })
          return
        }
        const controller = sessionController()
        if (typeof controller.attachment !== 'function') {
          sendJson(res, 503, { ok: false, error: 'attachment route unavailable' })
          return
        }
        const lease = callBudget(15000)
        try {
          // The image store decides what may be read; this route only hands the
          // exact reference the transcript carried back to it.
          const value = await controller.attachment({ sessionId, attachment }, lease.signal)
          sendJson(res, 200, { ok: true, value: value ?? null })
        } catch (error) {
          ctx.logger?.warn?.(`dsh-floating-window: attachment read failed: ${messageOf(error)}`)
          sendJson(res, 500, { ok: false, error: messageOf(error) })
        } finally {
          lease.release()
        }
      },
    }),
    ctx.webServer.register({
      kind: 'exact',
      path: FOCUS_ROUTE,
      handler: async (req, res) => {
        if (req.method === 'GET') {
          // One-shot: the browser half takes the request and the slot is cleared,
          // so a stale id is never reopened twice.
          const sessionId = focusRequest ?? ''
          focusRequest = undefined
          sendJson(res, 200, { ok: true, value: { sessionId } })
          return
        }
        if (req.method !== 'POST') {
          sendJson(res, 405, { ok: false, error: 'method not allowed' })
          return
        }
        const body = await readJsonBody(req)
        const sessionId = body !== undefined && typeof body.sessionId === 'string' && SESSION_ID_PATTERN.test(body.sessionId)
          ? body.sessionId
          : ''
        focusRequest = sessionId === '' ? undefined : sessionId
        sendJson(res, 200, { ok: true, value: { sessionId } })
      },
    }),
    ctx.webServer.register({
      kind: 'prefix',
      path: SESSION_FOLLOW_ROUTE,
      handler: async (req, res) => {
        const url = new URL(req.url ?? '/', 'http://127.0.0.1')
        if (url.pathname !== SESSION_FOLLOW_ROUTE) {
          res.writeHead(404, { 'cache-control': 'no-store' }).end('not found')
          return
        }
        if (req.method !== 'GET') {
          res.writeHead(405, { 'cache-control': 'no-store' }).end('method not allowed')
          return
        }
        const sessionId = url.searchParams.get('sessionId') ?? ''
        if (!SESSION_ID_PATTERN.test(sessionId)) {
          res.writeHead(400, { 'cache-control': 'no-store' }).end('sessionId required')
          return
        }
        const controller = ctx.get('sessionController')
        if (controller === undefined || typeof controller.follow !== 'function') {
          res.writeHead(503, { 'cache-control': 'no-store' }).end('session follow unavailable')
          return
        }
        res.writeHead(200, {
          'content-type': 'text/event-stream; charset=utf-8',
          'cache-control': 'no-store, no-transform',
          connection: 'keep-alive',
          'x-accel-buffering': 'no',
        })
        if (typeof res.flushHeaders === 'function') res.flushHeaders()
        let closed = false
        const abort = new AbortController()
        const finish = () => {
          if (closed) return
          closed = true
          abort.abort()
          try { res.end() } catch { /* already gone */ }
        }
        req.on('close', finish)
        req.on('aborted', finish)
        // A heartbeat keeps an idle stream from looking dead to the browser.
        const beat = setInterval(() => {
          if (closed) return
          try { res.write(': ping\n\n') } catch { finish() }
        }, 15000)
        if (typeof beat.unref === 'function') beat.unref()
        const write = (frame) => {
          if (closed) return
          try { res.write(`data: ${JSON.stringify(frame)}\n\n`) } catch { finish() }
        }
        try {
          const title = await readTitleOf(sessionId)
          if (closed) return
          // `activate: true` is what the DSH window itself does when it opens a
          // Session: a persisted conversation is resumed so the transcript can go
          // live. Browsing the list never reaches this route.
          const stream = controller.follow({
            address: { kind: 'session', sessionId },
            activate: true,
            assistantStream: true,
            maxMessages: 200,
            turnWindow: { minMessages: 80, minTurns: 1 },
          }, abort.signal)
          for await (const frame of stream) {
            if (closed) break
            if (frame === null || typeof frame !== 'object') continue
            if (frame.type === 'snapshot') {
              const records = Array.isArray(frame.records) ? frame.records : []
              const mapped = surfaceMessagesOf(records.map((record) => (record !== null && typeof record === 'object' ? record.event : undefined)))
              const header = frame.header !== null && frame.header !== undefined ? frame.header : {}
              write({
                type: 'snapshot',
                session: {
                  id: sessionId,
                  title,
                  cwd: typeof header.cwd === 'string' ? header.cwd : '',
                  createdAt: typeof header.createdAt === 'number' ? header.createdAt : 0,
                },
                items: mapped.items,
                cursor: typeof frame.cursor === 'number' ? frame.cursor : mapped.cursor,
                hasMore: frame.hasMore === true,
              })
              // Opening a Session in the middle of a step: the baseline already
              // holds the answer text produced so far, so the window starts with
              // the same partial answer the DSH window shows instead of an empty
              // bubble until the next chunk lands.
              const baseline = frame.assistantStream
              const active = baseline !== null && baseline !== undefined ? baseline.activeAttempt : undefined
              if (active !== null && active !== undefined && Array.isArray(active.stream) && active.stream.length > 0) {
                write({ type: 'stream-start' })
                for (const chunk of active.stream) {
                  const delta = streamDeltaOf({ chunk })
                  if (delta !== undefined) write(delta)
                }
              }
            } else if (frame.type === 'event') {
              const event = frame.event
              const item = transcriptItemOf(event)
              write({
                type: 'item',
                seq: event !== null && typeof event === 'object' && typeof event.seq === 'number' ? event.seq : undefined,
                item: item ?? null,
              })
            } else if (frame.type === 'assistant-stream') {
              const delta = streamDeltaOf(frame.frame)
              if (delta !== undefined) write(delta)
            }
          }
        } catch (error) {
          if (!closed) {
            ctx.logger?.warn?.(`dsh-floating-window: session follow failed: ${messageOf(error)}`)
            write({ type: 'fault', message: messageOf(error) })
          }
        } finally {
          clearInterval(beat)
          finish()
        }
      },
    }),
    ctx.webServer.register({
      kind: 'prefix',
      path: PAGE_ROUTE,
      handler: async (req, res) => {
        const path = new URL(req.url ?? '/', 'http://127.0.0.1').pathname
        if (PAGE_FILE === undefined || (path !== PAGE_ROUTE && path !== `${PAGE_ROUTE}/`)) {
          res.writeHead(404, { 'cache-control': 'no-store' }).end('not found')
          return
        }
        try {
          const bytes = await readFile(PAGE_FILE)
          res.writeHead(200, {
            'content-type': 'text/html; charset=utf-8',
            'cache-control': 'no-store',
            'content-length': String(bytes.byteLength),
          })
          res.end(req.method === 'HEAD' ? undefined : bytes)
        } catch (error) {
          res.writeHead(500, { 'cache-control': 'no-store' }).end('page unavailable')
        }
      },
    }),
  ]

  ctx.effect(() => () => {
    for (const dispose of disposeRoutes) dispose()
    if (child !== null && child.exitCode === null) child.kill()
    child = null
  }, 'dsh-floating-window routes and window process')
}
