import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { RelayAgent, RelayView } from '../types'
import { applyFeedLine, clockOf, emptyView, splitOwnerText, statusOf, takeLines } from './feed'
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

const startFeed = ($: EngineInterface, id: string): void => {
  feedRun += 1
  const run = feedRun
  void (async () => {
    await update($, view, () => ({ ...emptyView(id), note: 'Connecting to the room...' }))
    let rest = ''
    try {
      const feed = $.process.spawn({
        argv: shellOf(scriptOf($, 'Watch-RelayFeed.ps1'), ['-Room', id, '-Json', '-EndWithParent']),
        env: { PSModulePath: '' },
      })
      for await (const chunk of feed) {
        if (run !== feedRun) break
        if (chunk.stream !== 'stdout') continue
        const taken = takeLines(rest + chunk.text)
        rest = taken.rest
        for (const line of taken.lines) {
          let events: FeedEvent[] = []
          await update($, view, current => {
            const applied = applyFeedLine(current ?? emptyView(id), line)
            events = applied.events

            return applied.view
          })
          await tell($, id, events)
        }
        $.ui.status(statusOf(await read($, view)))
      }
    } catch (error) {
      const reason = error instanceof Error ? error.message : String(error)
      if (run === feedRun) await update($, view, current => ({ ...(current ?? emptyView(id)), note: `The feed failed: ${reason}` }))
    }
    if (run === feedRun) {
      await update($, view, current =>
        current === null || current.isClosed ? current : { ...current, note: `The feed has ended. /relay ${id} starts it again.` },
      )
    }
  })()
}

const bind = async ($: EngineInterface, id: string): Promise<void> => {
  await update($, room, () => id)
  startFeed($, id)
  void $.ui.open({ id: PANE, title: `relay ${id}`, columns: 64, rows: 18 })
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
      await bind($, wanted)

      return { text: `Relay pane bound to room ${wanted}.` }
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
    await bind($, wanted)

    return { result: `Bound to room ${wanted}. The chat window shows it; its feed is the room's tamper check and your heartbeat.` }
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
    const fixed = 6 + agents.length + working + planRows + current.cards.length * 4 + Math.min(2, current.alarms.length)
    const shown = Math.max(3, Math.floor((rows - fixed) / 2))
    const messages = current.messages.slice(-shown)
    const width = columns - 2

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
            <Text wrap="wrap">{card.text.slice(0, width * 3)}</Text>
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
