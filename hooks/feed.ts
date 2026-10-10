import type { RelayAgent, RelayCard, RelayMessage, RelayPlan, RelayView } from '../types'

// What the room feed (Watch-RelayFeed.ps1 -Json) prints, turned into the view the pane draws. Nothing here
// touches the engine: the lines go in, the view and what is worth telling the owner come out.

export type FeedEvent =
  | { kind: 'up' }
  | { kind: 'card'; subject: string }
  | { kind: 'alarm'; text: string }
  | { kind: 'error'; text: string }
  | { kind: 'closed' }

const MESSAGE_LIMIT = 200
const ALARM_LIMIT = 20

// What an agent wrote into a room file must not steer the owner's terminal: every control character but the
// line feed becomes a blank
const CONTROL = /[\u0000-\u0009\u000b-\u001f\u007f]/g

const asText = (value: unknown): string =>
  (typeof value === 'string' ? value : value === null || value === undefined ? '' : String(value)).replace(CONTROL, ' ')

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
})

// A piece of the feed's output ends wherever the write did: whole lines are taken, the rest waits for more
export const takeLines = (text: string): { lines: string[]; rest: string } => {
  const parts = text.split('\n')
  const rest = parts.pop() ?? ''

  return { lines: parts.map(line => line.replace(/\r$/, '')).filter(line => line.trim() !== ''), rest }
}

export const applyFeedLine = (view: RelayView, line: string): { view: RelayView; events: FeedEvent[] } => {
  const events: FeedEvent[] = []
  let item: Record<string, unknown>
  try {
    item = asRecord(JSON.parse(line))
  } catch {
    return { view, events }
  }

  switch (asText(item.type)) {
    case 'snapshot': {
      // The room resolved on this PC and the feed is up: whoever bound it may say so now
      events.push({ kind: 'up' })
      // Only a card the view did not hold yet is worth telling: a feed that was started again prints a
      // snapshot of what the owner was told already
      const cards = asList(item.waitingOnOwner).map(toCard)
      const known = new Set(view.cards.map(card => card.id))
      for (const card of cards) if (!known.has(card.id)) events.push({ kind: 'card', subject: card.subject })

      return {
        view: {
          ...view,
          room: asText(item.room) || view.room,
          job: asText(item.job),
          coordinator: asText(item.coordinator),
          agents: asList(item.agents).map(toAgent),
          plan: toPlan(item.plan),
          messages: asList(item.messages).map(toMessage).slice(-MESSAGE_LIMIT),
          cards,
          forCoordinator: asList(item.waitingOnCoordinator).length,
          isClosed: false,
          note: '',
        },
        events,
      }
    }
    case 'message': {
      const message = toMessage(item.message)
      if (message.id === '' || view.messages.some(one => one.id === message.id)) return { view, events }

      return { view: { ...view, messages: [...view.messages, message].slice(-MESSAGE_LIMIT) }, events }
    }
    case 'agents':
      return { view: { ...view, agents: asList(item.agents).map(toAgent) }, events }
    case 'plan':
      return { view: { ...view, plan: toPlan(item.plan) }, events }
    case 'waiting': {
      const cards = asList(item.waitingOnOwner).map(toCard)
      const known = new Set(view.cards.map(card => card.id))
      for (const card of cards) if (!known.has(card.id)) events.push({ kind: 'card', subject: card.subject })

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

      return { view: { ...view, note: text }, events }
    }
    case 'closed':
      events.push({ kind: 'closed' })

      return { view: { ...view, isClosed: true, note: 'This room is closed.' }, events }
    default:
      return { view, events }
  }
}

// "@emma do this" is for Emma; anything else is for the coordinator
export const splitOwnerText = (typed: string): { to: string; text: string } => {
  const match = /^@([A-Za-z][A-Za-z0-9]{1,15})\s+([\s\S]+)$/.exec(typed.trim())
  if (match === null) return { to: '', text: typed.trim() }

  return { to: (match[1] ?? '').toLowerCase(), text: (match[2] ?? '').trim() }
}

// Why a script ended, from what it wrote: its message without the lines PowerShell adds about where it was
// thrown, on one line, and short enough for a toast
export const reasonOf = (output: string): string => {
  const said: string[] = []
  for (const line of asText(output).split('\n')) {
    const one = line.trim()
    if (/^(At |\+ )/.test(one)) break
    if (one !== '') said.push(one)
  }
  const reason = said.join(' ')

  return reason.length > 300 ? `${reason.slice(0, 300)} ...` : reason
}

// The feed sends a long card cut, and marks the cut with three dots after a blank: the owner must be told
// that there is more before deciding on it
export const isCutText = (text: string): boolean => text.endsWith(' ...')

// A text as the rows it takes in a column of that width: broken at a blank where there is one, inside a word
// where a word is longer than the column. The pane draws these rows as they stand, so nothing is cut off at
// its edge and the number of rows is known, which its window needs. Blank lines in a row become one, and
// none stand at the start or the end.
export const wrapText = (text: string, width: number): string[] => {
  const columns = Math.max(8, width)
  const rows: string[] = []
  for (const raw of text.split('\n')) {
    let line = raw.replace(/\s+$/, '')
    if (line === '') {
      if (rows.length > 0 && rows[rows.length - 1] !== '') rows.push('')
      continue
    }
    while (line.length > columns) {
      const blank = line.lastIndexOf(' ', columns)
      const at = blank > columns / 3 ? blank : columns
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
// rows as the whole pane has: that is a window of these rows, less the one row that stays for the eye. A
// window moved to its end follows the end again.
export const scrolledTo = (total: number, shown: number, at: number | null, by: number): number | null => {
  const last = Math.max(0, total - shown)
  const page = Math.max(1, shown - 1)
  const step = Math.abs(by) > page ? Math.sign(by) * page : Math.trunc(by)
  const to = Math.max(0, windowTop(total, shown, at) + step)

  return to >= last ? null : to
}

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

// Hour and minute of a time the feed gives (UTC)
export const clockOf = (time: string): string => /T(\d\d:\d\d)/.exec(time)?.[1] ?? ''

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
// a window of them.
export const paneRows = (view: RelayView, width: number): PaneRow[] => {
  const rows: PaneRow[] = []
  rows.push(...block(wrapText(view.room, width), { bold: true }))
  rows.push(...block(wrapText(view.job, width), { dim: true }))

  const seated = view.agents.filter(agent => !agent.isFree)
  const free = view.agents.length - seated.length
  if (seated.length > 0 || free > 0) rows.push(BLANK)
  for (const agent of seated) {
    const about = agentLine(agent)
    const name = colored(agent.display.padEnd(8), stateColor(agent), { bold: true })
    const attention = agent.attention === '' ? '' : `! ${agent.attention}`
    const flat = `${agent.display.padEnd(8)} ${agent.state.padEnd(11)} ${about} ${attention}`
    if (flat.trimEnd().length <= width) {
      rows.push(rowOf(name, { text: ` ${agent.state.padEnd(11)} ` }, { text: about, dim: true }, { text: attention === '' ? '' : ` ${attention}`, color: 'yellow' }))
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
    const idWidth = view.plan.parts.reduce((widest, part) => Math.max(widest, part.id.length), 12)
    for (const part of view.plan.parts) {
      const owner = part.owner === '-' ? 'nobody' : part.owner
      const status = colored(part.status.padEnd(8), partColor(part.status))
      const id = { text: ` ${part.id.padEnd(idWidth)} ` }
      if (`${part.status.padEnd(8)}${id.text}${owner}  ${part.title}`.length <= width) {
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
    const clock = clockOf(message.time)
    // The row of a message is one row: what does not fit after the sender is left out
    const left = Math.max(0, width - clock.length - 1 - message.from.length)
    rows.push(rowOf({ text: clock, dim: true }, { text: ` ${message.from}`, bold: true }, { text: ` > ${message.to}  ${message.type}`.slice(0, left), dim: true }))
    rows.push(...block(indented(message.subject, width)))
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
