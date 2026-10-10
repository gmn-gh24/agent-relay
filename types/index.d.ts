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
}

declare module 'claude-code' {
  interface PluginState {
    'agent-relay': { room: string | null; view: RelayView | null }
  }
}
