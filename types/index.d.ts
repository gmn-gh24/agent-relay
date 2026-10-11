export type RelayAgent = {
  name: string
  display: string
  role: string
  state: string
  detail: string
  attention: string
  isCoordinator: boolean
  isFree: boolean
  isIntroduced: boolean
  computer: string
  product: string
  model: string
  effort: string
  tier: string
  rights: string
  owes: number
  progress: string
  parts: string[]
}

export type RelayPart = {
  id: string
  owner: string
  status: string
  title: string
}

export type RelayPlan = {
  revision: number
  goal: string
  isComplete: boolean
  parts: RelayPart[]
}

export type RelayMessage = {
  id: string
  from: string
  to: string
  type: string
  subject: string
  time: string
  preview: string
  // The header names another sender, receiver or number than the place of its file
  mismatch: boolean
}

export type RelayCard = {
  id: string
  re: string
  subject: string
  text: string
}

export type RelayView = {
  room: string
  job: string
  coordinator: string
  agents: RelayAgent[]
  plan: RelayPlan | null
  messages: RelayMessage[]
  cards: RelayCard[]
  forCoordinator: number
  alarms: string[]
  isClosed: boolean
  note: string
  // While the note is an error the feed printed: the ticks of the feed still to come before it is taken as past
  errorTicks: number
}

// A decision the owner pressed on a card, on its way to the room: until it is answered, that card takes no other
export type RelayDecision = {
  room: string
  card: string
  decision: 'approve' | 'deny'
}

declare module 'claude-code' {
  interface PluginState {
    // scroll: the first row the pane's window shows; null while it follows the end
    // deciding: the decisions on their way, each of a card of the room it names
    'agent-relay': { room: string | null; view: RelayView | null; scroll: number | null; deciding: RelayDecision[] }
  }
}
