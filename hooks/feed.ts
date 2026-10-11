import type { RelayAgent, RelayCard, RelayDecision, RelayMessage, RelayPlan, RelayView } from '../types'

// What the room feed (Watch-RelayFeed.ps1 -Json) prints, turned into the view the pane draws. Nothing here
// touches the engine: the lines go in, the view and what is worth telling the owner come out.

export type FeedEvent =
  | { kind: 'up' }
  | { kind: 'card'; subject: string }
  | { kind: 'alarm'; text: string }
  | { kind: 'error'; text: string }
  | { kind: 'closed' }

const MESSAGE_LIMIT = 200
// Under a message whose header names another sender, receiver or number than its file: the file's place counts
const MISMATCH_NOTICE = 'HEADER DOES NOT MATCH ITS FILE'
const ALARM_LIMIT = 20

// An error the feed printed stands in the note until the feed shows that it reads the room again: at once with
// a line that only a round which read the room prints, or after this many ticks with no error line between
// them (a round that fails prints its error every time; the feed ticks every 30 seconds either way)
const ERROR_TICKS = 2
const READS_THE_ROOM: ReadonlySet<string> = new Set(['message', 'agents', 'plan', 'waiting'])

// What an agent wrote into a room file must not steer the owner's terminal, nor change the order in which it
// shows text: every control character but the line feed (C0, DEL and C1), the marks that set the direction of
// text, the invisible spaces and joiners, the line and paragraph separators and the byte order mark become a
// blank
const CONTROL = /[\u0000-\u0009\u000b-\u001f\u007f-\u009f\u200b-\u200f\u2028\u2029\u202a-\u202e\u2066-\u2069\ufeff]/g

const asText = (value: unknown): string =>
  (typeof value === 'string' ? value : value === null || value === undefined ? '' : String(value)).replace(CONTROL, ' ')

// The same for a text that did not come through the feed (what a script wrote, an error): every text the
// owner is shown in a toast or a notification goes through it
export const plainText = (value: unknown): string => asText(value)

const asList = (value: unknown): unknown[] =>
  Array.isArray(value) ? value : value === null || value === undefined ? [] : [value]

const asRecord = (value: unknown): Record<string, unknown> =>
  typeof value === 'object' && value !== null ? (value as Record<string, unknown>) : {}

const toAgent = (value: unknown): RelayAgent => {
  const row = asRecord(value)

  return {
    name: asText(row.name),
    display: asText(row.display) || asText(row.name),
    role: asText(row.role),
    state: asText(row.state),
    detail: asText(row.detail),
    attention: asText(row.attention),
    isCoordinator: row.isCoordinator === true,
    isFree: row.isFree === true,
    isIntroduced: row.isIntroduced === true,
    computer: asText(row.computer),
    product: asText(row.product),
    model: asText(row.model),
    effort: asText(row.effort),
    tier: asText(row.tier),
    rights: asText(row.rights),
    owes: Number(row.owes) || 0,
    progress: asText(row.progress),
    parts: asList(row.parts).map(asText),
  }
}

// The team plan: who builds which part. Absent when the room has none.
const toPlan = (value: unknown): RelayPlan | null => {
  if (typeof value !== 'object' || value === null) return null
  const row = asRecord(value)

  return {
    revision: Number(row.revision) || 0,
    goal: asText(row.goal),
    isComplete: row.isComplete === true,
    parts: asList(row.parts).map(part => {
      const one = asRecord(part)

      return { id: asText(one.id), owner: asText(one.owner), status: asText(one.status), title: asText(one.title) }
    }),
  }
}

const toMessage = (value: unknown): RelayMessage => {
  const row = asRecord(value)

  return {
    id: asText(row.id),
    from: asText(row.from),
    to: asText(row.to),
    type: asText(row.type),
    subject: asText(row.subject),
    time: asText(row.time),
    preview: asText(row.preview),
    mismatch: row.mismatch === true,
  }
}

const toCard = (value: unknown): RelayCard => {
  const row = asRecord(value)

  return { id: asText(row.id), re: asText(row.re), subject: asText(row.subject), text: asText(row.text) }
}

export const emptyView = (room: string): RelayView => ({
  room,
  job: '',
  coordinator: '',
  agents: [],
  plan: null,
  messages: [],
  cards: [],
  forCoordinator: 0,
  alarms: [],
  isClosed: false,
  note: '',
  errorTicks: 0,
})

// The view with a note of the pane's own under the room's rows (no error of the feed's)
export const withNote = (view: RelayView, note: string): RelayView => ({ ...view, note, errorTicks: 0 })

// A piece of the feed's output ends wherever the write did: whole lines are taken, the rest waits for more
export const takeLines = (text: string): { lines: string[]; rest: string } => {
  const parts = text.split('\n')
  const rest = parts.pop() ?? ''

  return { lines: parts.map(line => line.replace(/\r$/, '')).filter(line => line.trim() !== ''), rest }
}

// The messages of a snapshot added to those the view holds, by id: a feed that was started again sends only the
// last of them, and what the pane held before stays
const mergeMessages = (held: readonly RelayMessage[], given: readonly RelayMessage[]): RelayMessage[] => {
  const merged = [...held]
  const known = new Set(held.map(one => one.id))
  for (const one of given) {
    if (one.id === '' || known.has(one.id)) continue
    known.add(one.id)
    merged.push(one)
  }

  return merged.slice(-MESSAGE_LIMIT)
}

// Only a card the view did not hold yet is worth telling: a feed that was started again prints a snapshot of
// what the owner was told already
const newCards = (view: RelayView, cards: readonly RelayCard[]): FeedEvent[] => {
  const known = new Set(view.cards.map(card => card.id))

  return cards.filter(card => !known.has(card.id)).map(card => ({ kind: 'card', subject: card.subject }))
}

// The feed read the room again: an error it printed before is past
const healthy = (view: RelayView): RelayView => (view.errorTicks > 0 ? { ...view, note: '', errorTicks: 0 } : view)

const applyItem = (view: RelayView, item: Record<string, unknown>): { view: RelayView; events: FeedEvent[] } => {
  const events: FeedEvent[] = []
  switch (asText(item.type)) {
    case 'snapshot': {
      // The room resolved on this PC and the feed is up: whoever bound it may say so now
      events.push({ kind: 'up' })
      const cards = asList(item.waitingOnOwner).map(toCard)
      events.push(...newCards(view, cards))

      return {
        view: {
          ...view,
          room: asText(item.room) || view.room,
          job: asText(item.job),
          coordinator: asText(item.coordinator),
          agents: asList(item.agents).map(toAgent),
          plan: toPlan(item.plan),
          messages: mergeMessages(view.messages, asList(item.messages).map(toMessage)),
          cards,
          forCoordinator: asList(item.waitingOnCoordinator).length,
          isClosed: false,
          note: '',
          errorTicks: 0,
        },
        events,
      }
    }
    case 'message': {
      const message = toMessage(item.message)
      if (message.id === '' || view.messages.some(one => one.id === message.id)) return { view, events }

      return { view: { ...view, messages: [...view.messages, message].slice(-MESSAGE_LIMIT) }, events }
    }
    case 'removed': {
      // The file of the message is gone from the room (the tamper check moved a forgery out, or it was deleted):
      // what takes its place later is another message under the same id
      const id = asText(item.id)
      if (id === '' || !view.messages.some(one => one.id === id)) return { view, events }

      return { view: { ...view, messages: view.messages.filter(one => one.id !== id) }, events }
    }
    case 'agents':
      return { view: { ...view, agents: asList(item.agents).map(toAgent) }, events }
    case 'plan':
      return { view: { ...view, plan: toPlan(item.plan) }, events }
    case 'waiting': {
      const cards = asList(item.waitingOnOwner).map(toCard)
      events.push(...newCards(view, cards))

      return { view: { ...view, cards, forCoordinator: asList(item.waitingOnCoordinator).length }, events }
    }
    case 'alarm': {
      const text = asText(item.text)
      events.push({ kind: 'alarm', text })

      return { view: { ...view, alarms: [...view.alarms, text].slice(-ALARM_LIMIT) }, events }
    }
    case 'error': {
      const text = asText(item.text)
      events.push({ kind: 'error', text })

      return { view: { ...view, note: text, errorTicks: ERROR_TICKS }, events }
    }
    case 'tick': {
      if (view.errorTicks === 0) return { view, events }
      const left = view.errorTicks - 1

      return { view: left === 0 ? healthy(view) : { ...view, errorTicks: left }, events }
    }
    case 'closed':
      events.push({ kind: 'closed' })

      // The feed names the room by its id on this PC, also where it was bound by its folder
      return { view: { ...withNote(view, 'This room is closed.'), room: asText(item.room) || view.room, isClosed: true }, events }
    default:
      return { view, events }
  }
}

export const applyFeedLine = (view: RelayView, line: string): { view: RelayView; events: FeedEvent[] } => {
  let item: Record<string, unknown>
  try {
    item = asRecord(JSON.parse(line))
  } catch {
    return { view, events: [] }
  }
  const applied = applyItem(view, item)

  return READS_THE_ROOM.has(asText(item.type)) ? { ...applied, view: healthy(applied.view) } : applied
}

// A line of the feed of `room`, into a view of that room only: a view that was unbound, or bound to another room
// since the feed was started, takes nothing from it and tells nothing
export const applyRoomLine = (view: RelayView | null, room: string, line: string): { view: RelayView | null; events: FeedEvent[] } =>
  view === null || view.room !== room ? { view, events: [] } : applyFeedLine(view, line)

// The view a feed starts from, and what is worth telling of it. It goes on from what the pane holds of that room
// (after a reload, or the same room bound again), so that nothing the owner was told is told again and the
// window stays where it was; another room starts empty. first: the lines of a look at the room just taken.
export const openingView = (current: RelayView | null, room: string, first: readonly string[]): { view: RelayView; events: FeedEvent[] } => {
  // A view kept from an earlier version of the pane gets the fields it lacks
  let seen = current !== null && current.room === room ? { ...emptyView(room), ...current } : emptyView(room)
  const events: FeedEvent[] = []
  for (const line of first) {
    const applied = applyFeedLine(seen, line)
    seen = applied.view
    events.push(...applied.events)
  }

  return { view: seen.isClosed ? seen : withNote(seen, 'Connecting to the room...'), events }
}

// Whether what the owner typed or pressed may go to the room the pane showed when they did: only while that room
// is still the bound one. Card ids start again in every room, so a card of one room must never be decided in
// another. '' when it may; else what the owner is told.
export const refusalOf = (bound: string | null, shown: string): string =>
  bound === shown ? '' : `Not sent: the pane showed room ${shown}, and ${bound === null ? 'no room' : `room ${bound}`} is bound now.`

// The decision on its way for a card of a room, if there is one
export const decisionOn = (deciding: readonly RelayDecision[], room: string, card: string): RelayDecision | undefined =>
  deciding.find(one => one.room === room && one.card === card)

// A decision is taken on its way only while none is for that card: a second press (the other button, or the same
// one again) waits for the answer to the first
export const claimDecision = (deciding: readonly RelayDecision[], wanted: RelayDecision): { deciding: RelayDecision[]; isClaimed: boolean } =>
  decisionOn(deciding, wanted.room, wanted.card) === undefined
    ? { deciding: [...deciding, wanted], isClaimed: true }
    : { deciding: [...deciding], isClaimed: false }

// The decision on a card has its answer: the card takes presses again
export const releaseDecision = (deciding: readonly RelayDecision[], room: string, card: string): RelayDecision[] =>
  deciding.filter(one => one.room !== room || one.card !== card)

// "@emma do this" is for Emma; anything else is for the coordinator
export const splitOwnerText = (typed: string): { to: string; text: string } => {
  const match = /^@([A-Za-z][A-Za-z0-9]{1,15})\s+([\s\S]+)$/.exec(typed.trim())
  if (match === null) return { to: '', text: typed.trim() }

  return { to: (match[1] ?? '').toLowerCase(), text: (match[2] ?? '').trim() }
}

// The lines PowerShell adds to an error about where it was thrown: "At <script>:<line> char:<column>" in
// English, the same in other words in another language, then the code with "+ " and its marks "~", and the
// category and the id of the error
const WHERE_THROWN = /^(At |\+ |~|CategoryInfo|FullyQualifiedErrorId)/
const POSITION = /\S:\s?\d+\s+\S*\s?:\s?\d+\s*$/

// Why a script ended, from what it wrote: its message without the lines PowerShell adds about where it was
// thrown, on one line, and short enough for a toast
export const reasonOf = (output: string): string => {
  const said: string[] = []
  for (const line of asText(output).split('\n')) {
    const one = line.trim()
    if (WHERE_THROWN.test(one)) {
      // A localised PowerShell says "At" in its own words: the line before the code, when it names a position
      const last = said[said.length - 1]
      if (!one.startsWith('At ') && last !== undefined && POSITION.test(last)) said.pop()
      break
    }
    if (one !== '') said.push(one)
  }
  const reason = said.join(' ')

  return reason.length > 300 ? `${reason.slice(0, 300)} ...` : reason
}

// The feed sends a long card cut, and marks the cut with three dots after a blank: the owner must be told
// that there is more before deciding on it
export const isCutText = (text: string): boolean => text.endsWith(' ...')

// The cells of a terminal a character takes: none for a mark that belongs to the character before it (and for
// the parts of a Hangul syllable after its first), two for the wide and full-width characters of the East Asian
// scripts and for an emoji drawn as a picture, one for every other
const PRINTABLE_ASCII = /^[ -~]*$/
const ZERO_WIDTH = /^[\p{Mn}\p{Me}\p{Cf}\u1160-\u11ff]$/u
const EMOJI = /^\p{Emoji_Presentation}$/u
const WIDE: readonly (readonly [number, number])[] = [
  [0x1100, 0x115f],
  [0x2e80, 0x303e],
  [0x3041, 0x33ff],
  [0x3400, 0x4dbf],
  [0x4e00, 0x9fff],
  [0xa000, 0xa4cf],
  [0xa960, 0xa97f],
  [0xac00, 0xd7a3],
  [0xf900, 0xfaff],
  [0xfe10, 0xfe19],
  [0xfe30, 0xfe6f],
  [0xff00, 0xff60],
  [0xffe0, 0xffe6],
  [0x20000, 0x2fffd],
  [0x30000, 0x3fffd],
]

const cellsOf = (character: string): number => {
  const code = character.codePointAt(0) ?? 0
  if (code >= 0x20 && code < 0x7f) return 1
  if (ZERO_WIDTH.test(character)) return 0
  if (EMOJI.test(character)) return 2

  return WIDE.some(([from, to]) => code >= from && code <= to) ? 2 : 1
}

// The cells a text takes on one row; a string is walked by characters, so a surrogate pair is one
export const textWidth = (text: string): number => {
  if (PRINTABLE_ASCII.test(text)) return text.length
  let cells = 0
  for (const character of text) cells += cellsOf(character)

  return cells
}

// How much of a text (in UTF-16 units) fits in so many cells: whole characters only, and a mark goes with the
// character it belongs to
const fitLength = (text: string, cells: number): number => {
  let taken = 0
  let at = 0
  for (const character of text) {
    const width = cellsOf(character)
    if (taken + width > cells) break
    taken += width
    at += character.length
  }

  return at
}

// A text cut to so many cells, and one padded with blanks to so many
const cutToWidth = (text: string, cells: number): string => text.slice(0, fitLength(text, cells))
const padToWidth = (text: string, cells: number): string => text + ' '.repeat(Math.max(0, cells - textWidth(text)))

// A text as the rows it takes in a column of that width (in the cells of a terminal, so a wide character counts
// two): broken at a blank where there is one, inside a word where a word is longer than the column, never inside
// a character. The pane draws these rows as they stand, so nothing is cut off at its edge and the number of rows
// is known, which its window needs. Blank lines in a row become one, and none stand at the start or the end.
export const wrapText = (text: string, width: number): string[] => {
  const columns = Math.max(8, width)
  const rows: string[] = []
  for (const raw of text.split('\n')) {
    let line = raw.replace(/\s+$/, '')
    if (line === '') {
      if (rows.length > 0 && rows[rows.length - 1] !== '') rows.push('')
      continue
    }
    for (;;) {
      // A column is at least eight cells wide and no character takes more than two: a row is never empty
      const fit = fitLength(line, columns)
      if (fit >= line.length) break
      const blank = line.lastIndexOf(' ', fit)
      const at = blank > 0 && textWidth(line.slice(0, blank)) > columns / 3 ? blank : fit
      rows.push(line.slice(0, at).replace(/\s+$/, ''))
      line = line.slice(at).replace(/^\s+/, '')
    }
    if (line !== '') rows.push(line)
  }
  while (rows.length > 0 && rows[rows.length - 1] === '') rows.pop()

  return rows
}

// A thin line and a full block (this file stays ASCII)
const TRACK = String.fromCharCode(0x2502)
const THUMB = String.fromCharCode(0x2588)

// The first row a window of `shown` rows shows of `total`. at: where the owner scrolled to; null while the
// window follows the end, which is where the newest is.
export const windowTop = (total: number, shown: number, at: number | null): number => {
  const last = Math.max(0, total - shown)

  return at === null ? last : Math.min(last, Math.max(0, Math.floor(at)))
}

// Where the window stands after a move of `by` rows (negative: toward the top). A page key asks for as many
// rows as the whole pane has: that is a window of these rows, less the one row that stays for the eye. Home
// and End (isJump) go to the first row and to the end. A window moved to its end follows the end again.
export const scrolledTo = (total: number, shown: number, at: number | null, by: number, isJump = false): number | null => {
  const last = Math.max(0, total - shown)
  const page = Math.max(1, shown - 1)
  const step = isJump ? Math.sign(by) * total : Math.abs(by) > page ? Math.sign(by) * page : Math.trunc(by)
  const to = Math.max(0, windowTop(total, shown, at) + step)

  return to >= last ? null : to
}

// The engine asks for as many rows as the pane's body has for a page key, and for as many as the tree it drew
// for Home and End: the two are told apart where those differ (the pane's tree keeps a row of its body free)
export const isHomeOrEnd = (by: number, bodyRows: number, contentRows: number): boolean =>
  contentRows !== bodyRows && contentRows > 0 && Math.abs(by) === contentRows

// The scroll bar beside a window of `shown` rows that stands at row `top` of `total`: a mark for every row
// of the window, in three pieces from its top. Nothing when the window shows everything.
export const scrollBar = (total: number, top: number, shown: number): { above: string; thumb: string; below: string } | null => {
  if (shown <= 0 || total <= shown) return null
  const last = total - shown
  const at = Math.min(last, Math.max(0, Math.floor(top)))
  const length = Math.max(1, Math.round((shown * shown) / total))
  const above = Math.round((at / last) * (shown - length))
  const marks = (count: number, mark: string): string => Array.from({ length: Math.max(0, count) }, () => mark).join('\n')

  return { above: marks(above, TRACK), thumb: marks(length, THUMB), below: marks(shown - above - length, TRACK) }
}

const UTC_TIME = /^\d{4}-\d\d-\d\dT\d\d:\d\d(:\d\d(\.\d+)?)?Z$/
const twoDigits = (value: number): string => String(value).padStart(2, '0')

// Hour and minute of a time the feed gives (UTC), in the time of this PC, as the terminal's feed shows it.
// offset: the minutes this PC is behind UTC at that time, as Date has it, unless one is given (the tests).
export const clockOf = (time: string, offset?: number): string => {
  const utc = UTC_TIME.test(time) ? Date.parse(time) : Number.NaN
  if (Number.isNaN(utc)) return /T(\d\d:\d\d)/.exec(time)?.[1] ?? ''
  const local = new Date(utc - (offset ?? new Date(utc).getTimezoneOffset()) * 60000)

  return `${twoDigits(local.getUTCHours())}:${twoDigits(local.getUTCMinutes())}`
}

export const statusOf = (view: RelayView | null): string | undefined => {
  if (view === null) return undefined
  const waiting = view.cards.length
  const parts = [`relay ${view.room}`]
  if (waiting > 0) parts.push(`${waiting} waiting on you`)
  if (view.forCoordinator > 0) parts.push(`${view.forCoordinator} for the coordinator`)
  if (view.alarms.length > 0) parts.push(`${view.alarms.length} alarm(s)`)
  if (view.isClosed) parts.push('closed')

  return parts.join(' | ')
}

// What an agent's row says after its name and its state
export const agentLine = (agent: RelayAgent): string => {
  const marks: string[] = []
  if (agent.isCoordinator) marks.push('coordinator')
  else if (agent.role !== '' && agent.role !== 'agent') marks.push(agent.role)
  if (agent.isIntroduced && !agent.isCoordinator) {
    if (agent.model !== '') marks.push(agent.tier !== '' && agent.tier !== 'unknown' ? `${agent.model} (${agent.tier})` : agent.model)
    if (agent.rights === 'elevated') marks.push('ELEVATED')
    if (agent.rights === 'can-elevate') marks.push('not elevated')
    if (agent.rights === 'none') marks.push('no admin rights')
  }
  if (agent.owes > 0) marks.push(`owes ${agent.owes}`)
  if (agent.parts.length > 0) marks.push(`parts: ${agent.parts.join(', ')}`)

  return marks.join(', ')
}

export const stateColor = (agent: RelayAgent): string | undefined => {
  if (agent.attention !== '') return 'yellow'
  if (agent.state === 'listening' || agent.state === 'working') return 'green'

  return undefined
}

export const partColor = (status: string): string | undefined => {
  if (status === 'done') return 'green'
  if (status === 'blocked') return 'red'
  if (status === 'doing' || status === 'review') return 'yellow'

  return undefined
}

const INDENT = '  '
const CUT_NOTICE = 'This card is longer than what is shown here. Ask the coordinator for all of it before you decide.'
const SCROLL_HINT = 'Scroll: mouse wheel, or ctrl+x tab, then PgUp / PgDn'

const indented = (text: string, width: number): string[] => wrapText(text, width - INDENT.length).map(row => INDENT + row)

// One piece of a row, drawn in one style
export type PaneSpan = { text: string; bold?: true; dim?: true; color?: string }

// One row of what the pane shows of a room. A row with `card` is the row of the two buttons of that card.
export type PaneRow = { spans: PaneSpan[]; card?: string }

const BLANK: PaneRow = { spans: [] }

// A row of pieces: empty ones left out, and no blanks at its end (a row that is too long is cut with a mark)
const rowOf = (...spans: PaneSpan[]): PaneRow => {
  const kept = spans.filter(span => span.text !== '')
  for (;;) {
    const last = kept[kept.length - 1]
    if (last === undefined) break
    const text = last.text.replace(/\s+$/, '')
    if (text === last.text) break
    if (text === '') kept.pop()
    else kept[kept.length - 1] = { ...last, text }
  }

  return { spans: kept }
}

const block = (rows: readonly string[], style: Omit<PaneSpan, 'text'> = {}): PaneRow[] => rows.map(text => rowOf({ text, ...style }))

const colored = (text: string, color: string | undefined, style: Omit<PaneSpan, 'text' | 'color'> = {}): PaneSpan =>
  color === undefined ? { text, ...style } : { text, color, ...style }

// Everything the pane shows of a room above its input, row by row, in a column of that width: the room and its
// job, the agents, the plan, the conversation with the newest at the end, the alarms, and at the very end
// what waits on the owner. Every text is wrapped here, so a row is a row on the screen and the pane can show
// a window of them, and measured in the cells of a terminal. offset: as clockOf takes it.
export const paneRows = (view: RelayView, width: number, offset?: number): PaneRow[] => {
  const rows: PaneRow[] = []
  rows.push(...block(wrapText(view.room, width), { bold: true }))
  rows.push(...block(wrapText(view.job, width), { dim: true }))

  const seated = view.agents.filter(agent => !agent.isFree)
  const free = view.agents.length - seated.length
  if (seated.length > 0 || free > 0) rows.push(BLANK)
  for (const agent of seated) {
    const about = agentLine(agent)
    const name = colored(padToWidth(agent.display, 8), stateColor(agent), { bold: true })
    const attention = agent.attention === '' ? '' : `! ${agent.attention}`
    const flat = `${padToWidth(agent.display, 8)} ${padToWidth(agent.state, 11)} ${about} ${attention}`
    if (textWidth(flat.trimEnd()) <= width) {
      rows.push(rowOf(name, { text: ` ${padToWidth(agent.state, 11)} ` }, { text: about, dim: true }, { text: attention === '' ? '' : ` ${attention}`, color: 'yellow' }))
    } else {
      // What the agent is and what is wrong with it stand under its name
      rows.push(rowOf(name, { text: ` ${agent.state}` }))
      rows.push(...block(indented(about, width), { dim: true }))
      rows.push(...block(indented(attention, width), { color: 'yellow' }))
    }
    rows.push(...block(indented(agent.progress, width), { dim: true }))
  }
  if (free > 0) rows.push(rowOf({ text: `${free} free seat(s)`, dim: true }))

  if (view.plan !== null) {
    rows.push(BLANK)
    rows.push(...block(wrapText(`Plan ${view.plan.revision}: ${view.plan.goal}${view.plan.isComplete ? '' : '  (incomplete)'}`, width), { bold: true }))
    const idWidth = view.plan.parts.reduce((widest, part) => Math.max(widest, textWidth(part.id)), 12)
    for (const part of view.plan.parts) {
      const owner = part.owner === '-' ? 'nobody' : part.owner
      const status = colored(padToWidth(part.status, 8), partColor(part.status))
      const id = { text: ` ${padToWidth(part.id, idWidth)} ` }
      if (textWidth(`${padToWidth(part.status, 8)}${id.text}${owner}  ${part.title}`) <= width) {
        rows.push(rowOf(status, id, { text: `${owner}  ${part.title}`, dim: true }))
      } else {
        rows.push(rowOf(status, id, { text: owner, dim: true }))
        rows.push(...block(indented(part.title, width), { dim: true }))
      }
    }
  }

  rows.push(BLANK)
  if (view.messages.length === 0) rows.push(rowOf({ text: 'No messages yet.', dim: true }))
  for (const message of view.messages) {
    const clock = clockOf(message.time, offset)
    // The row of a message is one row: what does not fit after the sender is left out
    const left = Math.max(0, width - textWidth(clock) - 1 - textWidth(message.from))
    rows.push(rowOf({ text: clock, dim: true }, { text: ` ${message.from}`, bold: true }, { text: cutToWidth(` > ${message.to}  ${message.type}`, left), dim: true }))
    rows.push(...block(indented(message.subject, width)))
    if (message.mismatch) rows.push(...block(indented(MISMATCH_NOTICE, width), { color: 'yellow' }))
    rows.push(...block(indented(message.preview, width), { dim: true }))
  }

  const alarms = view.alarms.slice(-2)
  if (alarms.length > 0) rows.push(BLANK)
  for (const alarm of alarms) rows.push(...block(wrapText(`ALARM: ${alarm}`, width), { color: 'red' }))

  // A card is shown whole, as the feed gives it: the owner decides on what it says
  for (const card of view.cards) {
    rows.push(BLANK)
    rows.push(...block(wrapText(`Your decision: ${card.subject}`, width), { bold: true, color: 'yellow' }))
    rows.push(...block(wrapText(card.text, width)))
    if (isCutText(card.text)) rows.push(...block(wrapText(CUT_NOTICE, width), { color: 'yellow' }))
    rows.push({ spans: [], card: card.id })
  }

  return rows
}

// How the rows of the pane's window are shared out. What stands still at its foot (the feed's note, the input,
// the line that says how to scroll) takes its rows first; the rest is a window over the rows of the room.
// One row stays free, so that a row counted wrong cannot push the input out of sight.
export const paneRegions = (total: number, bodyRows: number, footRows: number, width: number): { shown: number; hint: string[] } => {
  const room = Math.max(3, Math.floor(bodyRows) - footRows - 1)
  if (total <= room) return { shown: total, hint: [] }
  const hint = wrapText(SCROLL_HINT, width)

  return { shown: Math.max(3, room - hint.length), hint }
}
