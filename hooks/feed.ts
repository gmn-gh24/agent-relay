import type { RelayAgent, RelayCard, RelayMessage, RelayPlan, RelayView } from '../types'

// What the room feed (Watch-RelayFeed.ps1 -Json) prints, turned into the view the pane draws. Nothing here
// touches the engine: the lines go in, the view and what is worth telling the owner come out.

export type FeedEvent =
  | { kind: 'card'; subject: string }
  | { kind: 'alarm'; text: string }
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
      const cards = asList(item.waitingOnOwner).map(toCard)
      for (const card of cards) events.push({ kind: 'card', subject: card.subject })

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
    case 'error':
      return { view: { ...view, note: asText(item.text) }, events }
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
