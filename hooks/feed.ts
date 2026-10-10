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

// How many rows a text takes in a column of that width, wrapped
export const textRows = (text: string, width: number): number => {
  const columns = Math.max(1, width)

  return text.split('\n').reduce((rows, line) => rows + Math.max(1, Math.ceil(line.length / columns)), 0)
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
