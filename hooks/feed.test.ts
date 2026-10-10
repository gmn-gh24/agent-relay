import { expect, mock, test } from 'claude-code/testing'

import { applyFeedLine, clockOf, emptyView, isCutText, reasonOf, splitOwnerText, statusOf, takeLines, textRows } from './feed'

const SNAPSHOT = JSON.stringify({
  type: 'snapshot',
  room: 'pester-on-training-vm',
  job: 'Install the test tooling',
  coordinator: 'olivia',
  agents: [
    { name: 'olivia', display: 'Olivia', role: 'coordinator', state: 'listening', isCoordinator: true, isIntroduced: true },
    { name: 'sarah', display: 'Sarah', role: 'agent', state: 'listening', isIntroduced: true, model: 'sonnet-5.5', tier: 'standard', rights: 'elevated', owes: 0 },
    { name: 'liam', display: 'Liam', isFree: true },
  ],
  messages: [{ id: 'sarah-olivia-0001', from: 'sarah', to: 'olivia', type: 'hello', subject: 'hello from Sarah', time: '2026-10-10T07:05:00Z', preview: 'I am Sarah' }],
  waitingOnOwner: [{ id: 'card-0001', re: 'emma-olivia-0005', subject: 'May Emma install the provider?', text: 'She asks to install it.' }],
  waitingOnCoordinator: [{ id: 'emma-olivia-0005' }],
})

test('a snapshot becomes the view, and a card that waits on the owner is worth telling', () => {
  const applied = applyFeedLine(emptyView('pester-on-training-vm'), SNAPSHOT)
  expect(applied.view.job).toBe('Install the test tooling')
  expect(applied.view.agents).toHaveLength(3)
  expect(applied.view.agents[1]?.rights).toBe('elevated')
  expect(applied.view.agents[2]?.isFree).toBe(true)
  expect(applied.view.messages).toHaveLength(1)
  expect(applied.view.cards).toHaveLength(1)
  expect(applied.view.forCoordinator).toBe(1)
  expect(applied.events).toEqual([{ kind: 'up' }, { kind: 'card', subject: 'May Emma install the provider?' }])
  expect(statusOf(applied.view)).toBe('relay pester-on-training-vm | 1 waiting on you | 1 for the coordinator')
})

test('only a snapshot says that the room is up; an error line of the feed is kept as the reason it gave', () => {
  const failed = applyFeedLine(emptyView('room'), JSON.stringify({ type: 'error', text: 'the share is gone' }))
  expect(failed.view.note).toBe('the share is gone')
  expect(failed.events).toEqual([{ kind: 'error', text: 'the share is gone' }])
  expect(applyFeedLine(emptyView('room'), JSON.stringify({ type: 'tick' })).events).toHaveLength(0)
  // The snapshot of a feed that was started again tells no card the view holds already
  const first = applyFeedLine(emptyView('room'), SNAPSHOT)
  expect(applyFeedLine(first.view, SNAPSHOT).events).toEqual([{ kind: 'up' }])
})

test('why a script ended is its message on one line, without the lines about where it was thrown', () => {
  const thrown = [
    'No room at C:\\work\\nothing: it is not in the room',
    'index of this PC',
    'At R:\\agent-relay\\skills\\agent-relay\\scripts\\RelayCommon.psm1:231 char:9',
    '+         throw "No room at $text"',
    '    + CategoryInfo          : OperationStopped: (...) [], RuntimeException',
  ].join('\r\n')
  expect(reasonOf(thrown)).toBe('No room at C:\\work\\nothing: it is not in the room index of this PC')
  expect(reasonOf('')).toBe('')
  expect(reasonOf(`first${String.fromCharCode(27)}[2J line`)).toBe('first [2J line')
  expect(reasonOf('x'.repeat(400))).toHaveLength(304)
})

test('a card the feed cut is known by its mark, and a text takes the rows its wrapped lines need', () => {
  expect(isCutText(`${'word '.repeat(120)}...`)).toBe(true)
  expect(isCutText('She asks to install it.')).toBe(false)
  expect(isCutText('It goes on...')).toBe(false)
  expect(textRows('one line', 40)).toBe(1)
  expect(textRows('x'.repeat(81), 40)).toBe(3)
  expect(textRows('Line one\n\nLine three', 40)).toBe(3)
  expect(textRows('anything', 0)).toBe(8)
})

test('a message is added once, an alarm is kept and told, a line that is no JSON changes nothing', () => {
  const start = applyFeedLine(emptyView('room'), SNAPSHOT).view
  const line = JSON.stringify({ type: 'message', message: { id: 'olivia-sarah-0001', from: 'olivia', to: 'sarah', type: 'task', subject: 'Check it', time: '2026-10-10T07:10:00Z' } })
  const once = applyFeedLine(start, line).view
  expect(once.messages).toHaveLength(2)
  expect(applyFeedLine(once, line).view.messages).toHaveLength(2)

  const alarmed = applyFeedLine(once, JSON.stringify({ type: 'alarm', text: 'tools/relay.ps1 was changed' }))
  expect(alarmed.view.alarms).toEqual(['tools/relay.ps1 was changed'])
  expect(alarmed.events).toEqual([{ kind: 'alarm', text: 'tools/relay.ps1 was changed' }])

  const same = applyFeedLine(once, 'not json at all')
  expect(same.view).toBe(once)
  expect(same.events).toHaveLength(0)
})

test('only a card the owner has not seen yet is told again, and a closed room says so', () => {
  const start = applyFeedLine(emptyView('room'), SNAPSHOT).view
  const waiting = JSON.stringify({
    type: 'waiting',
    waitingOnOwner: [
      { id: 'card-0001', subject: 'May Emma install the provider?' },
      { id: 'card-0002', subject: 'May Jack read the event log?' },
    ],
    waitingOnCoordinator: [],
  })
  const applied = applyFeedLine(start, waiting)
  expect(applied.view.cards).toHaveLength(2)
  expect(applied.view.forCoordinator).toBe(0)
  expect(applied.events).toEqual([{ kind: 'card', subject: 'May Jack read the event log?' }])

  const closed = applyFeedLine(applied.view, JSON.stringify({ type: 'closed', room: 'room' }))
  expect(closed.view.isClosed).toBe(true)
  expect(closed.events).toEqual([{ kind: 'closed' }])
})

test('a plan comes with the snapshot and changes with a plan line; an agent carries its progress and its parts', () => {
  const withPlan = JSON.stringify({
    type: 'snapshot',
    room: 'room',
    job: 'Build it in parts',
    coordinator: 'olivia',
    agents: [{ name: 'emma', display: 'Emma', state: 'working', isIntroduced: true, progress: 'Half way', parts: ['tool-ps'] }],
    plan: { revision: 3, goal: 'A team view', isComplete: true, parts: [{ id: 'tool-ps', owner: 'emma', status: 'doing', title: 'The verbs' }] },
    messages: [],
    waitingOnOwner: [],
    waitingOnCoordinator: [],
  })
  const start = applyFeedLine(emptyView('room'), withPlan).view
  expect(start.plan?.revision).toBe(3)
  expect(start.plan?.parts[0]).toEqual({ id: 'tool-ps', owner: 'emma', status: 'doing', title: 'The verbs' })
  expect(start.agents[0]?.progress).toBe('Half way')
  expect(start.agents[0]?.parts).toEqual(['tool-ps'])

  const changed = applyFeedLine(start, JSON.stringify({ type: 'plan', plan: { revision: 4, goal: 'A team view', isComplete: false, parts: [] } })).view
  expect(changed.plan?.revision).toBe(4)
  expect(changed.plan?.isComplete).toBe(false)
  expect(applyFeedLine(changed, JSON.stringify({ type: 'plan', plan: null })).view.plan).toBe(null)

  // A room without a plan, and an agent that has said nothing about its progress
  const plain = applyFeedLine(emptyView('room'), SNAPSHOT).view
  expect(plain.plan).toBe(null)
  expect(plain.agents[1]?.progress).toBe('')
  expect(plain.agents[1]?.parts).toEqual([])
})

test('a control character from a room file reaches the pane as a blank; a line feed stays', () => {
  const escape = String.fromCharCode(27)
  const line = JSON.stringify({
    type: 'snapshot',
    room: 'room',
    agents: [{ name: 'emma', display: 'Emma', state: 'working', progress: `half${escape}[2J way\tthere`, detail: `bell${String.fromCharCode(7)}` }],
    plan: { revision: 2, goal: `A goal${String.fromCharCode(127)}`, isComplete: true, parts: [{ id: 'a', owner: 'emma', status: 'doing', title: `Title${escape}]0;x` }] },
    waitingOnOwner: [{ id: 'card-0001', subject: `May${escape} she?`, text: 'Line one\nLine two' }],
  })
  const view = applyFeedLine(emptyView('room'), line).view
  expect(view.agents[0]?.progress).toBe('half [2J way there')
  expect(view.agents[0]?.detail).toBe('bell ')
  expect(view.plan?.goal).toBe('A goal ')
  expect(view.plan?.parts[0]?.title).toBe('Title ]0;x')
  expect(view.cards[0]?.subject).toBe('May  she?')
  expect(view.cards[0]?.text).toBe('Line one\nLine two')
})

test('the feed is read line by line however its pieces are cut', () => {
  const first = takeLines('{"type":"tick"}\r\n{"type":"al')
  expect(first.lines).toEqual(['{"type":"tick"}'])
  expect(first.rest).toBe('{"type":"al')
  const second = takeLines(first.rest + 'arm","text":"x"}\n\n')
  expect(second.lines).toEqual(['{"type":"alarm","text":"x"}'])
  expect(second.rest).toBe('')
})

test('what the owner types goes to the coordinator unless it names an agent', () => {
  expect(splitOwnerText('  use the staging share  ')).toEqual({ to: '', text: 'use the staging share' })
  expect(splitOwnerText('@Emma stop after the tests')).toEqual({ to: 'emma', text: 'stop after the tests' })
  expect(splitOwnerText('@emma')).toEqual({ to: '', text: '@emma' })
  expect(clockOf('2026-10-10T07:05:00Z')).toBe('07:05')
  expect(statusOf(null)).toBe(undefined)
})

test('the pane says how to bind a room while none is bound, on every surface that has an input', async $ => {
  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({
      plugin: 'agent-relay',
      surface,
      component: 'Pane',
      requestId: 'relay',
      props: { title: 'relay', isFocused: false, bodyColumns: 60, placement: 'inline', scroll: { offset: 0, bodyRows: 20 }, view: {} },
    })
    expect(await ui.find({ type: 'Text', text: /No room is bound/ })).toBeDefined()
    await ui.unmount()
  }
})

test('a name that is no room of this PC is not bound, and the reason is said', async ($, on) => {
  const asked: string[][] = []
  on('process.run', (_$, e) => {
    asked.push([...e.argv])

    return { value: { exitCode: 1, stdout: '', stderr: 'No room named nothing in the room index\r\nof this PC\r\nAt R:\\x.psm1:1 char:1', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  const answer = await $.command.run({ command: 'relay', args: 'nothing' } as Parameters<typeof $.command.run>[0])
  expect(answer.text).toBe('Not bound: No room named nothing in the room index of this PC')
  // The look checks nothing in the room and beats no heart: it only asks whether the room is one
  expect(asked[0]?.slice(-6)).toEqual(['-Room', 'nothing', '-Json', '-Once', '-NoHeartbeat', '-NoTamperCheck'])
  const ui = await $.ui.mount({
    plugin: 'agent-relay',
    surface: 'terminal',
    component: 'Pane',
    requestId: 'relay',
    props: { title: 'relay', isFocused: false, bodyColumns: 60, placement: 'inline', scroll: { offset: 0, bodyRows: 20 }, view: {} },
  })
  expect(await ui.find({ type: 'Text', text: /No room is bound/ })).toBeDefined()
  await ui.unmount()
})

test('a room that resolves is bound by its own id, a cut card says that there is more, and a feed that ends is started again', async ($, on) => {
  const snapshot = JSON.stringify({
    type: 'snapshot',
    room: 'room-a',
    job: 'A job',
    agents: [],
    messages: [],
    waitingOnOwner: [{ id: 'card-0001', re: '', subject: 'May she?', text: `${'word '.repeat(120)}...` }],
    waitingOnCoordinator: [],
  })
  on('process.run', () => ({ value: { exitCode: 0, stdout: `${snapshot}\n`, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }))
  let spawned = 0
  on('process.spawn', async function* () {
    spawned += 1
    yield { stream: 'stdout' as const, text: `${snapshot}\n` }

    return { value: { code: 1, signal: null } }
  })
  const clock = mock.clock(on)
  const told: string[] = []
  const statuses: (string | undefined)[] = []
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('ui.status', (_$, e) => {
    statuses.push(e.text)

    return { value: undefined }
  })
  on('ui.notify', (_$, e) => {
    told.push(e.text)

    return { value: { isSent: true as const, channel: 'terminal_bell' as const } }
  })
  const answer = await $.command.run({ command: 'relay', args: 'C:\\rooms\\room-a' } as Parameters<typeof $.command.run>[0])
  expect(answer.text).toBe('Relay pane bound to room room-a.')
  // The feed of this test ends as soon as it has printed its snapshot
  await clock.advance(0)
  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({
      plugin: 'agent-relay',
      surface,
      component: 'Pane',
      requestId: 'relay',
      props: { title: 'relay', isFocused: false, bodyColumns: 60, placement: 'inline', scroll: { offset: 0, bodyRows: 20 }, view: {} },
    })
    expect(await ui.find({ type: 'Text', text: /Your decision: May she\?/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /longer than what is shown here/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /Starting it again in 5 seconds \(try 1 of 3\)/ })).toBeDefined()
    await ui.unmount()
  }

  // The card was told once, when the room was bound: a feed that starts again does not tell it again
  expect(told).toEqual(['room-a: your decision is needed: May she?'])
  // The waits run out one after the other; then the owner is told where it cannot be missed
  await clock.advance(5000)
  await clock.advance(30000)
  expect(told).toHaveLength(1)
  await clock.advance(120000)
  expect(told).toHaveLength(2)
  expect(told[1]).toMatch(/^relay room-a: the feed has ended\. The tamper check and the coordinator's heartbeat have stopped with it\. \/relay room-a starts it again\.$/)
  expect(statuses.at(-1)).toBe('relay room-a | THE FEED HAS ENDED')
  expect(spawned).toBe(4)
})
