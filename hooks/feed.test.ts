import { expect, mock, test } from 'claude-code/testing'

import { applyFeedLine, clockOf, emptyView, isCutText, paneRegions, paneRows, reasonOf, scrollBar, scrolledTo, splitOwnerText, statusOf, takeLines, windowTop, wrapText } from './feed'

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

test('a card the feed cut is known by its mark', () => {
  expect(isCutText(`${'word '.repeat(120)}...`)).toBe(true)
  expect(isCutText('She asks to install it.')).toBe(false)
  expect(isCutText('It goes on...')).toBe(false)
})

test('a text is wrapped at a blank into rows no longer than the column, and a word that is longer is cut', () => {
  expect(wrapText('one line', 40)).toEqual(['one line'])
  expect(wrapText('one two three', 8)).toEqual(['one two', 'three'])
  expect(wrapText('abcdefgh ij', 8)).toEqual(['abcdefgh', 'ij'])
  expect(wrapText('x'.repeat(20), 8)).toEqual(['xxxxxxxx', 'xxxxxxxx', 'xxxx'])
  // Lines stay lines; empty lines in a row become one, and none stands first or last
  expect(wrapText('\nLine one\n\n\nLine three\n\n', 40)).toEqual(['Line one', '', 'Line three'])
  expect(wrapText('', 40)).toEqual([])
  const long = wrapText('word '.repeat(120), 37)
  expect(long).toHaveLength(18)
  expect(long.every(row => row.length <= 37 && row === row.trim())).toBe(true)
  expect(long.join(' ')).toBe('word '.repeat(120).trim())
})

test('the scroll bar has a mark for every row of the window, and its thumb stands where the window stands in the rows', () => {
  const count = (marks: string | undefined): number => (marks === undefined || marks === '' ? 0 : marks.split('\n').length)
  const counts = (bar: ReturnType<typeof scrollBar>): number[] => [count(bar?.above), count(bar?.thumb), count(bar?.below)]
  // Nothing to scroll: no bar
  expect(scrollBar(20, 0, 20)).toBe(null)
  expect(scrollBar(5, 0, 20)).toBe(null)
  expect(scrollBar(100, 0, 0)).toBe(null)
  expect(counts(scrollBar(100, 0, 20))).toEqual([0, 4, 16])
  expect(counts(scrollBar(100, 40, 20))).toEqual([8, 4, 8])
  expect(counts(scrollBar(100, 80, 20))).toEqual([16, 4, 0])
  // A window said to stand past the end stands at the end
  expect(scrollBar(100, 500, 20)).toEqual(scrollBar(100, 80, 20))
  // However many rows there are, the thumb is a row
  expect(counts(scrollBar(5000, 0, 20))).toEqual([0, 1, 19])
})

test('the window follows the end until the owner moves it, and follows it again once it is back there', () => {
  expect(windowTop(100, 20, null)).toBe(80)
  expect(windowTop(100, 20, 30)).toBe(30)
  expect(windowTop(100, 20, 500)).toBe(80)
  expect(windowTop(10, 20, null)).toBe(0)
  // A tick of the wheel toward the top, three more, and back down to the end
  expect(scrolledTo(100, 20, null, -1)).toBe(79)
  expect(scrolledTo(100, 20, 79, -3)).toBe(76)
  expect(scrolledTo(100, 20, 79, 1)).toBe(null)
  // A page key asks for the rows of the whole pane: the window moves by its own rows less one
  expect(scrolledTo(100, 20, null, -24)).toBe(61)
  expect(scrolledTo(100, 20, 5, -24)).toBe(0)
  expect(scrolledTo(100, 20, 70, 24)).toBe(null)
  // Nothing to scroll: the window keeps following the end, also for what comes later
  expect(scrolledTo(10, 20, null, -1)).toBe(null)
  // More rows since the owner scrolled: the window stays on the rows it showed
  expect(windowTop(130, 20, 76)).toBe(76)
})

test('the rows of the pane leave its foot alone: the note, the input and the line that says how to scroll', () => {
  // Twenty rows, two of them the input under an empty row, one kept free
  expect(paneRegions(10, 20, 2, 58)).toEqual({ shown: 10, hint: [] })
  expect(paneRegions(17, 20, 2, 58)).toEqual({ shown: 17, hint: [] })
  expect(paneRegions(18, 20, 2, 58)).toEqual({ shown: 16, hint: ['Scroll: mouse wheel, or ctrl+x tab, then PgUp / PgDn'] })
  // In a narrow pane the line takes two rows
  expect(paneRegions(100, 20, 2, 28)).toEqual({ shown: 15, hint: ['Scroll: mouse wheel, or', 'ctrl+x tab, then PgUp / PgDn'] })
  // A long note of the feed takes its rows from the window too; three rows of the room always show
  expect(paneRegions(100, 20, 8, 58).shown).toBe(10)
  expect(paneRegions(100, 4, 2, 58).shown).toBe(3)
})

test('the pane lays out what it holds row by row, every row within its width', () => {
  const start = applyFeedLine(emptyView('room'), SNAPSHOT).view
  const textOf = (rows: ReturnType<typeof paneRows>): string[] => rows.map(row => (row.card === undefined ? row.spans.map(span => span.text).join('') : `[buttons of ${row.card}]`))

  // Wide: an agent is one row
  const wide = paneRows(start, 100)
  expect(textOf(wide)).toEqual([
    'pester-on-training-vm',
    'Install the test tooling',
    '',
    'Olivia   listening   coordinator',
    'Sarah    listening   sonnet-5.5 (standard), ELEVATED',
    '1 free seat(s)',
    '',
    '07:05 sarah > olivia  hello',
    '  hello from Sarah',
    '  I am Sarah',
    '',
    'Your decision: May Emma install the provider?',
    'She asks to install it.',
    '[buttons of card-0001]',
  ])
  expect(wide[3]?.spans[0]).toEqual({ text: 'Olivia  ', color: 'green', bold: true })
  expect(wide[9]?.spans[0]).toEqual({ text: '  I am Sarah', dim: true })

  // Narrow: what Sarah is stands under her name, and the card's subject takes two rows
  const narrow = textOf(paneRows(start, 40))
  expect(narrow.slice(3, 7)).toEqual(['Olivia   listening   coordinator', 'Sarah    listening', '  sonnet-5.5 (standard), ELEVATED', '1 free seat(s)'])
  expect(narrow.slice(-4)).toEqual(['Your decision: May Emma install the', 'provider?', 'She asks to install it.', '[buttons of card-0001]'])
  expect(narrow.every(row => row.length <= 40)).toBe(true)

  // The plan: the id column takes the longest id; a part that does not fit one row has its title below
  const plan = { revision: 2, goal: 'A goal', isComplete: true, parts: [
    { id: 'tool-ps', owner: '-', status: 'doing', title: 'The verbs of the tool, all of them, in both editions' },
    { id: 'a-part-with-a-long-id', owner: 'emma', status: 'done', title: 'Short' },
  ] }
  const planned = textOf(paneRows({ ...start, agents: [], messages: [], cards: [], plan }, 40))
  expect(planned).toEqual([
    'pester-on-training-vm',
    'Install the test tooling',
    '',
    'Plan 2: A goal',
    `doing    ${'tool-ps'.padEnd(21)} nobody`,
    '  The verbs of the tool, all of them, in',
    '  both editions',
    'done     a-part-with-a-long-id emma',
    '  Short',
    '',
    'No messages yet.',
  ])

  // An alarm, and an agent that needs attention in a pane too narrow for one row
  const alarmed = textOf(paneRows({ ...start, cards: [], messages: [], alarms: ['one', 'two', 'three'], agents: [{ ...start.agents[1]!, attention: 'silent for 40 minutes' }] }, 40))
  expect(alarmed.slice(3, 6)).toEqual(['Sarah    listening', '  sonnet-5.5 (standard), ELEVATED', '  ! silent for 40 minutes'])
  expect(alarmed.slice(-3)).toEqual(['', 'ALARM: two', 'ALARM: three'])
})

test('the pane holds every message it was given, each wrapped to its width', () => {
  const start = applyFeedLine(emptyView('room'), SNAPSHOT).view
  const messages = Array.from({ length: 200 }, (_, index) => ({
    id: `sarah-olivia-${String(index + 1).padStart(4, '0')}`,
    from: 'sarah',
    to: 'olivia',
    type: 'note',
    subject: `Subject ${index + 1}`,
    time: '2026-10-10T07:05:00Z',
    preview: `${'word '.repeat(80)}...`,
  }))
  const rows = paneRows({ ...start, cards: [], messages }, 58)
  const texts = rows.map(row => row.spans.map(span => span.text).join(''))
  expect(texts.filter(text => /^ {2}Subject \d+$/.test(text))).toHaveLength(200)
  expect(texts.every(text => text.length <= 58)).toBe(true)
  // The newest is the last
  expect(texts.at(-1)).toBe('  word word word ...')
  expect(texts.lastIndexOf('  Subject 200')).toBeGreaterThan(texts.lastIndexOf('  Subject 199'))
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
      props: { title: 'relay', isFocused: false, bodyColumns: 60, placement: 'inline', scroll: { offset: 0, bodyRows: 40 }, view: {} },
    })
    expect(await ui.find({ type: 'Text', text: /Your decision: May she\?/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /longer than what is shown here/ })).toBeDefined()
    // The terminal's pane wraps the note; another surface wraps by itself
    expect(await ui.find({ type: 'Text', text: /Starting it again in 5 seconds \(try 1 of\s3\)/ })).toBeDefined()
    expect(await ui.find({ type: 'Button', key: 'approve-card-0001' })).toBeDefined()
    expect(await ui.find({ type: 'Input', key: 'say' })).toBeDefined()
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

test('the terminal pane shows a window of the room over an input that stands still, and the window moves when the owner scrolls', async ($, on) => {
  const snapshot = JSON.stringify({
    type: 'snapshot',
    room: 'room-b',
    job: 'A job with a description that is a good deal longer than one row of a pane sixty columns wide',
    agents: [
      { name: 'emma', display: 'Emma', state: 'working', isIntroduced: true, model: 'opus-5.5', tier: 'strong', rights: 'elevated', progress: 'Half way through the tests of the second part', parts: ['tool-ps', 'tool-sh'] },
    ],
    messages: Array.from({ length: 200 }, (_, index) => ({
      id: `emma-olivia-${String(index + 1).padStart(4, '0')}`,
      from: 'emma',
      to: 'olivia',
      type: 'note',
      subject: `Subject ${index + 1}`,
      time: '2026-10-10T07:05:00Z',
      preview: `${'word '.repeat(80)}...`,
    })),
    waitingOnOwner: [],
    waitingOnCoordinator: [],
  })
  on('process.run', () => ({ value: { exitCode: 0, stdout: `${snapshot}\n`, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }))
  on('process.spawn', async function* () {
    yield { stream: 'stdout' as const, text: `${snapshot}\n` }

    return { value: { code: 1, signal: null } }
  })
  const clock = mock.clock(on)
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('ui.status', () => ({ value: undefined }))
  on('ui.notify', () => ({ value: { isSent: true as const, channel: 'terminal_bell' as const } }))
  const answer = await $.command.run({ command: 'relay', args: 'room-b' } as Parameters<typeof $.command.run>[0])
  expect(answer.text).toBe('Relay pane bound to room room-b.')
  await clock.advance(0)

  const track = String.fromCharCode(0x2502)
  const thumb = String.fromCharCode(0x2588)
  const rowsOf = (text: string | undefined): number => (text === undefined || text === '' ? 0 : text.split('\n').length)
  const marks = new RegExp(`^[${track}\\n]+$`)
  const props = { title: 'relay', isFocused: false, bodyColumns: 60, placement: 'inline' as const, view: {} }
  const scroll = { offset: 0, bodyRows: 20 }
  const ui = await $.ui.mount({ plugin: 'agent-relay', surface: 'terminal', component: 'Pane', requestId: 'relay', props: { ...props, scroll } })
  const move = (by: number): Promise<unknown> => $.ui.scroll({ component: 'Pane', requestId: 'relay', offset: 0, by, bodyRows: 20, contentRows: 19, origin: { kind: 'person' } })

  // The window follows the end: the newest message with its text, over the note of the feed, the input and
  // the line that says how to scroll
  expect(await ui.find({ type: 'Text', text: /^ {2}Subject 200$/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /^ {2}word word word/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /^ {2}Subject 199$/ })).toBeUndefined()
  expect(await ui.find({ type: 'Input', key: 'say' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /Starting it again in 5 seconds/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /^Scroll: mouse wheel/ })).toBeDefined()
  // No row is wider than the pane less the two columns of the bar
  expect((await ui.findAll({ type: 'Text' })).every(found => found.text.split('\n').every(row => row.length <= 58))).toBe(true)
  // Twenty rows: one free, the note (2), the input under an empty row (2), how to scroll (1), and 14 of the
  // room with a bar of 14 marks, the thumb at its foot
  const thumbAtEnd = await ui.find({ type: 'Text', text: new RegExp(`^[${thumb}\\n]+$`) })
  const aboveAtEnd = await ui.findAll({ type: 'Text', text: marks })
  expect(aboveAtEnd).toHaveLength(1)
  expect(rowsOf(aboveAtEnd[0]?.text) + rowsOf(thumbAtEnd?.text)).toBe(14)

  // The wheel, ten rows toward the top: the message before comes into the window, the input stays
  await move(-10)
  expect(await ui.find({ type: 'Text', text: /^ {2}Subject 199$/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /^ {2}Subject 200$/ })).toBeUndefined()
  expect(await ui.find({ type: 'Input', key: 'say' })).toBeDefined()

  // A page key toward the top moves by a window less a row. Half way up the bar has marks above the thumb
  // and below it; far enough, and the room's name shows
  await move(-20)
  expect(await ui.find({ type: 'Text', text: /^ {2}Subject 198$/ })).toBeDefined()
  for (let pages = 0; pages < 75; pages++) await move(-20)
  const halfWay = await ui.findAll({ type: 'Text', text: marks })
  expect(halfWay).toHaveLength(2)
  expect(rowsOf(halfWay[0]?.text) + rowsOf(thumbAtEnd?.text) + rowsOf(halfWay[1]?.text)).toBe(14)
  for (let pages = 0; pages < 200; pages++) await move(-20)
  expect(await ui.find({ type: 'Text', text: /^room-b$/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /^ {2}Subject 1$/ })).toBeDefined()

  // Back at the end the window follows it again
  for (let pages = 0; pages < 200; pages++) await move(20)
  expect(await ui.find({ type: 'Text', text: /^ {2}Subject 200$/ })).toBeDefined()
  await ui.unmount()

  // Another surface wraps and scrolls by itself: a message's text is one paragraph, and there is no bar
  const desktop = await $.ui.mount({ plugin: 'agent-relay', surface: 'desktop', component: 'Pane', requestId: 'relay', props: { ...props, scroll } })
  expect(await desktop.find({ type: 'Text', text: new RegExp(thumb) })).toBeUndefined()
  expect(await desktop.find({ type: 'Text', text: /^ {2}(word ){80}\.\.\.$/ })).toBeDefined()
  expect(await desktop.find({ type: 'Input', key: 'say' })).toBeDefined()
  expect(JSON.stringify(await desktop.drawn()).length).toBeLessThan(90000)
  await desktop.unmount()
})
