import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { RelayAgent, RelayView } from '../types'
import { applyFeedLine, clockOf, emptyView, isCutText, reasonOf, splitOwnerText, statusOf, takeLines, textRows } from './feed'
import type { FeedEvent } from './feed'

// The chat window of a room. It is thin on purpose: everything that knows a room lives in the scripts, and
// this module only starts the feed (which is also the room's tamper check and the coordinator's heartbeat),
// draws what it prints, and passes on what the owner types or decides.

const PANE = 'relay'
const BIND_TOOL = 'mcp__agent-relay__relay_bind'

const room = atom({ plugin: 'agent-relay', key: 'room' } as const, null)
const view = atom({ plugin: 'agent-relay', key: 'view' } as const, null)

// Which feed loop is the current one: binding another room, or none, ends the loop before it
let feedRun = 0

// The feed is also the room's tamper check and the coordinator's heartbeat: one that ends by itself is started
// again after these waits, and the owner is told when they are used up. A feed that ran this long before it
// ended starts the count again.
const RESTART_WAITS_MS: readonly number[] = [5000, 30000, 120000]
const STEADY_MS = 600000

type FeedEnd = { reason: string; isClosed: boolean }

const scriptOf = ($: EngineInterface, name: string): string =>
  `${$.plugin.root}/skills/agent-relay/scripts/${name}`

// Windows PowerShell, with a module path of its own: the session's may be PowerShell 7's
const shellOf = (script: string, args: readonly string[]): string[] => [
  'powershell.exe',
  '-NoProfile',
  '-NonInteractive',
  '-ExecutionPolicy',
  'Bypass',
  '-File',
  script,
  ...args,
]

const tell = async ($: EngineInterface, id: string, events: readonly FeedEvent[]): Promise<void> => {
  for (const event of events) {
    if (event.kind === 'card') {
      const text = `${id}: your decision is needed: ${event.subject}`
      const sent = await $.ui.notify(text, { title: 'agent-relay' })
      if (!sent.isSent) $.ui.toast(text)
    }
    if (event.kind === 'alarm') $.ui.toast(`${id} ALARM: ${event.text}`)
    if (event.kind === 'closed') $.ui.toast(`${id} is closed.`)
  }
}

// One run of the feed, read to its end: what it prints becomes the view, and why it ended comes back (what it
// wrote as an error, or the last error line it printed)
const readFeed = async ($: EngineInterface, id: string, run: number): Promise<FeedEnd> => {
  let rest = ''
  let errors = ''
  let said = ''
  let isClosed = false
  try {
    const feed = $.process.spawn({
      argv: shellOf(scriptOf($, 'Watch-RelayFeed.ps1'), ['-Room', id, '-Json', '-EndWithParent']),
      env: { PSModulePath: '' },
    })
    for await (const chunk of feed) {
      if (run !== feedRun) break
      if (chunk.stream === 'stderr') {
        if (errors.length < 4000) errors += chunk.text
        continue
      }
      const taken = takeLines(rest + chunk.text)
      rest = taken.rest
      for (const line of taken.lines) {
        let events: FeedEvent[] = []
        await update($, view, current => {
          const applied = applyFeedLine(current ?? emptyView(id), line)
          events = applied.events

          return applied.view
        })
        for (const event of events) {
          if (event.kind === 'error') said = event.text
          if (event.kind === 'closed') isClosed = true
        }
        await tell($, id, events)
      }
      $.ui.status(statusOf(await read($, view)))
    }
  } catch (error) {
    return { reason: reasonOf(error instanceof Error ? error.message : String(error)), isClosed }
  }

  return { reason: reasonOf(errors) || reasonOf(said), isClosed }
}

// first: the lines of a look at the room that was taken just before (bind), drawn until the feed's own arrive
const startFeed = ($: EngineInterface, id: string, first: readonly string[] = []): void => {
  feedRun += 1
  const run = feedRun
  void (async () => {
    let seen = emptyView(id)
    const found: FeedEvent[] = []
    for (const line of first) {
      const applied = applyFeedLine(seen, line)
      seen = applied.view
      found.push(...applied.events)
    }
    await update($, view, () => (seen.isClosed ? seen : { ...seen, note: 'Connecting to the room...' }))
    await tell($, id, found)
    let restarts = 0
    for (;;) {
      const startedAt = await $.clock.now()
      const ended = await readFeed($, id, run)
      // Another room was bound, or none: that loop speaks now
      if (run !== feedRun) return
      if (ended.isClosed) return
      const why = ended.reason === '' ? '' : `: ${ended.reason}`
      if ((await $.clock.now()) - startedAt >= STEADY_MS) restarts = 0
      const wait = RESTART_WAITS_MS[restarts]
      if (wait === undefined) {
        // Nothing checks the room for tampering now and no agent sees the coordinator alive: the owner is
        // told where it cannot be missed, not only in a pane that may be closed
        const text = `relay ${id}: the feed has ended${why}. The tamper check and the coordinator's heartbeat have stopped with it. /relay ${id} starts it again.`
        await update($, view, current => (current === null ? current : { ...current, note: text }))
        $.ui.status(`relay ${id} | THE FEED HAS ENDED`)
        const sent = await $.ui.notify(text, { title: 'agent-relay' })
        if (!sent.isSent) $.ui.toast(text)

        return
      }
      restarts += 1
      const again = `The feed ended${why}. Starting it again in ${wait / 1000} seconds (try ${restarts} of ${RESTART_WAITS_MS.length}).`
      await update($, view, current => (current === null ? current : { ...current, note: again }))
      await $.clock.sleep(wait)
      if (run !== feedRun) return
    }
  })().catch(async (error: unknown) => {
    // The loop itself failed: said in the pane, like a feed that ended, never swallowed
    const reason = reasonOf(error instanceof Error ? error.message : String(error))
    try {
      await update($, view, current => (current === null ? current : { ...current, note: `The feed loop failed: ${reason}. /relay ${id} starts it again.` }))
    } catch {
      // Nothing is left to say it with
    }
  })
}

// Is it a room of this PC? One snapshot of the feed says so before anything is bound: a name that is no room
// must not read as "bound". The look checks nothing and beats no heart; the feed that follows does.
const firstLook = async ($: EngineInterface, wanted: string): Promise<{ lines: string[]; reason: string }> => {
  try {
    const looked = await $.process.run(
      shellOf(scriptOf($, 'Watch-RelayFeed.ps1'), ['-Room', wanted, '-Json', '-Once', '-NoHeartbeat', '-NoTamperCheck']),
      { env: { PSModulePath: '' }, timeoutMs: 60000 },
    )
    if (looked.exitCode !== 0) {
      return { lines: [], reason: reasonOf(looked.stderr || looked.stdout) || `the feed ended with exit code ${looked.exitCode}` }
    }

    return { lines: takeLines(`${looked.stdout}\n`).lines, reason: '' }
  } catch (error) {
    return { lines: [], reason: reasonOf(error instanceof Error ? error.message : String(error)) || 'the feed could not be started' }
  }
}

// Binds the session to a room and says which, by the id the room has on this PC; or says why not, and then
// whatever was bound before stays as it is
const bind = async ($: EngineInterface, wanted: string): Promise<{ id: string; reason: string }> => {
  const look = await firstLook($, wanted)
  if (look.reason !== '') return { id: '', reason: look.reason }
  let seen = emptyView(wanted)
  let isUp = false
  for (const line of look.lines) {
    const applied = applyFeedLine(seen, line)
    seen = applied.view
    if (applied.events.some(event => event.kind === 'up' || event.kind === 'closed')) isUp = true
  }
  if (!isUp) return { id: '', reason: seen.note || 'the feed printed no snapshot of that room' }
  const id = seen.room
  await update($, room, () => id)
  startFeed($, id, look.lines)
  // A pane that cannot be opened (a surface without one) takes nothing from the binding: the feed runs
  void $.ui.open({ id: PANE, title: `relay ${id}`, columns: 64, rows: 18 }).catch(() => undefined)

  return { id, reason: '' }
}

const unbind = async ($: EngineInterface): Promise<void> => {
  feedRun += 1
  await update($, room, () => null)
  await update($, view, () => null)
  $.ui.status(undefined)
}

// The owner's words reach the room through one script, on its standard input: never on a command line
const sendAsOwner = async ($: EngineInterface, id: string, args: readonly string[], text: string): Promise<string> => {
  try {
    const sent = await $.process.run(shellOf(scriptOf($, 'Send-RelayOwner.ps1'), ['-Room', id, ...args]), {
      env: { PSModulePath: '' },
      stdin: text,
      timeoutMs: 60000,
    })
    if (sent.exitCode === 0) return sent.stdout.trim() || 'Sent.'

    return `Not sent: ${(sent.stderr || sent.stdout).trim().slice(0, 300)}`
  } catch (error) {
    return `Not sent: ${error instanceof Error ? error.message : String(error)}`
  }
}

const stateColor = (agent: RelayAgent): string | undefined => {
  if (agent.attention !== '') return 'yellow'
  if (agent.state === 'listening' || agent.state === 'working') return 'green'

  return undefined
}

const partColor = (status: string): string | undefined => {
  if (status === 'done') return 'green'
  if (status === 'blocked') return 'red'
  if (status === 'doing' || status === 'review') return 'yellow'

  return undefined
}

const agentLine = (agent: RelayAgent): string => {
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

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const started = await next(e)
    // A headless run draws nothing and has no owner at the prompt: no feed, no pane
    if (!e.isInteractive) return started
    await $.command.register({
      name: 'relay',
      description: 'Show a relay room in a pane: agents, conversation, what waits on you',
      argumentHint: '[room | off]',
    })
    await $.tool.register({
      name: 'relay_bind',
      description:
        'Binds this session to a relay room and opens its chat window for the owner: agents, the conversation, and what waits on the owner. Call it once after creating or resuming a room, with the room id.',
      inputSchema: {
        type: 'object',
        properties: { room: { type: 'string', description: 'The room id, or the word off to unbind' } },
        required: ['room'],
      },
      isDeferred: false,
    })
    // After a reload the room is still bound: the feed is not, it died with the module
    const bound = await read($, room)
    if (bound !== null) startFeed($, bound)

    return started
  })

  on('command.run', { command: 'relay' }, async ($, e) => {
    const wanted = e.args.trim()
    if (wanted === 'off') {
      await unbind($)

      return { text: 'The relay pane is unbound; its feed has stopped.' }
    }
    if (wanted !== '') {
      const done = await bind($, wanted)

      return { text: done.reason === '' ? `Relay pane bound to room ${done.id}.` : `Not bound: ${done.reason}` }
    }
    const bound = await read($, room)
    if (bound === null) return { text: 'No room is bound. Type /relay <room id>.' }
    await $.ui.open({ id: PANE, title: `relay ${bound}`, columns: 64, rows: 18 })

    return { text: `Relay pane: room ${bound}.` }
  })

  on('tool.call', { tool: BIND_TOOL }, async ($, e) => {
    const wanted = String((e as { room?: unknown }).room ?? '').trim()
    if (wanted === '') return { deny: 'relay_bind needs the room id.' }
    if (wanted === 'off') {
      await unbind($)

      return { result: 'Unbound. The feed has stopped; start Watch-RelayFeed.ps1 yourself if the room is still open.' }
    }
    const done = await bind($, wanted)
    if (done.reason !== '') {
      return { result: `Not bound: ${done.reason}. Nothing checks that room for tampering and nothing shows you alive in it until a feed runs: bind a room that exists on this PC, or run Watch-RelayFeed.ps1 for it yourself.` }
    }

    return { result: `Bound to room ${done.id}. The chat window shows it; its feed is the room's tamper check and your heartbeat.` }
  }).catch(() => ({ deny: 'relay_bind failed. Run Watch-RelayFeed.ps1 for the room yourself; /relay <room> binds the pane by hand.' }))

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const bound = await read($, room)
    const current = await read($, view)
    const columns = Math.max(30, e.props.bodyColumns)
    const rows = Math.max(10, e.viewport?.rows ?? 30)

    if (e.surface === 'mobile') {
      const { Box, Text } = $.ui.resolve(e)

      return (
        <Box flexDirection="column">
          <Text>{bound === null ? 'No relay room is bound.' : `relay ${bound}: ${current?.messages.length ?? 0} messages, ${current?.cards.length ?? 0} waiting on you`}</Text>
        </Box>
      )
    }

    const { Box, Text, Button, Input } = $.ui.resolve(e)
    if (bound === null || current === null) {
      return (
        <Box flexDirection="column">
          <Text dimColor>{'No room is bound. Type /relay <room id>.'}</Text>
        </Box>
      )
    }

    const agents = current.agents.filter(agent => !agent.isFree)
    const free = current.agents.filter(agent => agent.isFree).length
    const plan = current.plan
    const working = agents.filter(agent => agent.progress !== '').length
    // What is left for the conversation once the fixed parts have their rows; each message takes two
    const planRows = plan === null ? 0 : 2 + plan.parts.length
    const width = columns - 2
    // A card is shown whole, as the feed gives it: the owner decides on what it says. Its rows: the margin, the
    // border, the subject and the buttons, then the text, then the line that says the feed cut it.
    const cardRows = current.cards.reduce((sum, card) => sum + 5 + textRows(card.text, width - 4) + (isCutText(card.text) ? 2 : 0), 0)
    const fixed = 6 + agents.length + working + planRows + cardRows + Math.min(2, current.alarms.length)
    const shown = Math.max(3, Math.floor((rows - fixed) / 2))
    const messages = current.messages.slice(-shown)

    return (
      <Box flexDirection="column" width={columns}>
        <Text bold wrap="truncate-end">
          {current.room}
        </Text>
        {current.job !== '' && (
          <Text dimColor wrap="truncate-end">
            {current.job}
          </Text>
        )}
        {current.note !== '' && <Text color="yellow">{current.note}</Text>}

        <Box flexDirection="column" marginTop={1}>
          {agents.map(agent => (
            <Box flexDirection="column">
              <Text wrap="truncate-end">
                <Text bold color={stateColor(agent)}>
                  {agent.display.padEnd(8)}
                </Text>{' '}
                {agent.state.padEnd(11)} <Text dimColor>{agentLine(agent)}</Text>
                {agent.attention !== '' && <Text color="yellow"> ! {agent.attention}</Text>}
              </Text>
              {agent.progress !== '' && (
                <Text dimColor wrap="truncate-end">
                  {`         ${agent.progress}`}
                </Text>
              )}
            </Box>
          ))}
          {free > 0 && <Text dimColor>{`${free} free seat(s)`}</Text>}
        </Box>

        {plan !== null && (
          <Box flexDirection="column" marginTop={1}>
            <Text bold wrap="truncate-end">
              {`Plan ${plan.revision}: ${plan.goal}${plan.isComplete ? '' : '  (incomplete)'}`}
            </Text>
            {plan.parts.map(part => (
              <Text wrap="truncate-end">
                <Text color={partColor(part.status)}>{part.status.padEnd(8)}</Text> {part.id.padEnd(12)}{' '}
                <Text dimColor>{`${part.owner === '-' ? 'nobody' : part.owner}  ${part.title}`}</Text>
              </Text>
            ))}
          </Box>
        )}

        {current.cards.map(card => (
          <Box flexDirection="column" marginTop={1} borderStyle="round" borderColor="yellow" paddingX={1}>
            <Text bold wrap="truncate-end">
              {`Your decision: ${card.subject}`}
            </Text>
            <Text wrap="wrap">{card.text}</Text>
            {isCutText(card.text) && (
              <Text color="yellow" wrap="wrap">
                This card is longer than what is shown here. Ask the coordinator for all of it before you decide.
              </Text>
            )}
            <Box flexDirection="row" gap={2}>
              <Button
                key={`approve-${card.id}`}
                label="Approve"
                variant="primary"
                onPress={() => {
                  void sendAsOwner($, bound, ['-Approve', card.id], '').then(answer => $.ui.toast(answer))
                }}
              />
              <Button
                key={`deny-${card.id}`}
                label="Deny"
                onPress={() => {
                  void sendAsOwner($, bound, ['-Deny', card.id], '').then(answer => $.ui.toast(answer))
                }}
              />
            </Box>
          </Box>
        ))}

        {current.alarms.slice(-2).map(alarm => (
          <Text color="red" wrap="truncate-end">
            {`ALARM: ${alarm}`}
          </Text>
        ))}

        <Box flexDirection="column" marginTop={1}>
          {messages.length === 0 && <Text dimColor>No messages yet.</Text>}
          {messages.map(message => (
            <Box flexDirection="column">
              <Text wrap="truncate-end">
                <Text dimColor>{clockOf(message.time)}</Text> <Text bold>{message.from}</Text>
                <Text dimColor>{` > ${message.to}  ${message.type}`}</Text>
              </Text>
              <Text wrap="truncate-end">{`  ${message.subject}`}</Text>
            </Box>
          ))}
        </Box>

        {!current.isClosed && (
          <Box marginTop={1}>
            <Input
              key="say"
              placeholder="Say something as the owner (@name for one agent)"
              submitLabel="send"
              onSubmit={typed => {
                const said = splitOwnerText(typed)
                if (said.text === '') return
                const args = said.to === '' ? [] : ['-For', said.to]
                void sendAsOwner($, bound, args, said.text).then(answer => $.ui.toast(answer))
              }}
            />
          </Box>
        )}
      </Box>
    )
  })
}
