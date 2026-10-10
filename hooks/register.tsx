import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import { applyFeedLine, emptyView, paneRegions, paneRows, reasonOf, scrollBar, scrolledTo, splitOwnerText, statusOf, takeLines, windowTop, wrapText } from './feed'
import type { FeedEvent, PaneSpan } from './feed'

// The chat window of a room. It is thin on purpose: everything that knows a room lives in the scripts, and
// this module only starts the feed (which is also the room's tamper check and the coordinator's heartbeat),
// draws what it prints, and passes on what the owner types or decides.

const PANE = 'relay'
const BIND_TOOL = 'mcp__agent-relay__relay_bind'

const room = atom({ plugin: 'agent-relay', key: 'room' } as const, null)
const view = atom({ plugin: 'agent-relay', key: 'view' } as const, null)
// The first row the pane's window shows of the room; null while it follows the end, where the newest is
const scroll = atom({ plugin: 'agent-relay', key: 'scroll' } as const, null)

// Which feed loop is the current one: binding another room, or none, ends the loop before it
let feedRun = 0

// What the terminal's pane held and showed when it was drawn last: a move of its window is counted in these
let heldRows = 0
let shownRows = 0

// A width no text reaches: a surface that is no terminal wraps by itself. It also scrolls by itself, and gets
// the newest rows only: the engine draws no tree beyond a size.
const UNWRAPPED = 100000
const ROWS_ELSEWHERE = 240

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
      // A card stands at the end of what the pane shows: the window goes there
      await update($, scroll, () => null)
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
    const reason = reasonOf(error instanceof Error ? error.message : String(error))
    // The engine ends a call whose command was interrupted while it ran: said in words the owner can act on
    if (/\baborted$/.test(reason)) return { lines: [], reason: 'the look at the room was interrupted before it answered: ask for it again' }

    return { lines: [], reason: reason || 'the feed could not be started' }
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
  await update($, scroll, () => null)
  startFeed($, id, look.lines)
  // A pane that cannot be opened (a surface without one) takes nothing from the binding: the feed runs
  void $.ui.open({ id: PANE, title: `relay ${id}`, columns: 64, rows: 18 }).catch(() => undefined)

  return { id, reason: '' }
}

const unbind = async ($: EngineInterface): Promise<void> => {
  feedRun += 1
  await update($, room, () => null)
  await update($, view, () => null)
  await update($, scroll, () => null)
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

// The style of one piece of a row, as the props of the element that draws it
const styleOf = (span: PaneSpan): { bold?: true; dimColor?: true; color?: string } => {
  const style: { bold?: true; dimColor?: true; color?: string } = {}
  if (span.bold) style.bold = true
  if (span.dim) style.dimColor = true
  if (span.color !== undefined) style.color = span.color

  return style
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

  // The pane draws a window of its own over the rows of the room, so that its input stands still under it:
  // a move the owner asks for (the wheel, a page key) moves that window, and the engine's own stays where it is
  on('ui.scroll', { requestId: PANE }, async ($, e) => {
    await update($, scroll, at => scrolledTo(heldRows, shownRows, at, e.by))

    return {}
  }).catch(() => ({}))

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const bound = await read($, room)
    const current = await read($, view)
    const at = await read($, scroll)
    const columns = Math.max(30, e.props.bodyColumns)

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

    // Only the terminal draws in rows that can be counted here. There every text is wrapped by this module,
    // the pane shows a window of the rows with a scroll bar in its last two columns (a blank and the bar), and
    // what the feed says, the input and how to scroll stand still at its foot. Another surface wraps and
    // scrolls by itself.
    const isTerminal = e.surface === 'terminal'
    const width = isTerminal ? columns - 2 : UNWRAPPED
    const all = paneRows(current, width)
    const note = current.note === '' ? [] : isTerminal ? wrapText(current.note, width) : [current.note]
    let rows = all.slice(-ROWS_ELSEWHERE)
    let bar: ReturnType<typeof scrollBar> = null
    let hint: string[] = []
    if (isTerminal) {
      const foot = note.length + (current.isClosed ? 0 : 1)
      const regions = paneRegions(all.length, Math.max(8, e.props.scroll.bodyRows), foot === 0 ? 0 : foot + 1, width)
      const top = windowTop(all.length, regions.shown, at)
      rows = all.slice(top, top + regions.shown)
      bar = scrollBar(all.length, top, regions.shown)
      hint = regions.hint
      heldRows = all.length
      shownRows = regions.shown
    }

    return (
      <Box flexDirection="column" width={columns}>
        <Box flexDirection="row">
          <Box flexDirection="column" width={isTerminal ? width : columns}>
            {rows.map(row => {
              const card = row.card
              if (card !== undefined) {
                return (
                  <Box flexDirection="row" gap={2}>
                    <Button
                      key={`approve-${card}`}
                      label="Approve"
                      variant="primary"
                      onPress={() => {
                        void sendAsOwner($, bound, ['-Approve', card], '').then(answer => $.ui.toast(answer))
                      }}
                    />
                    <Button
                      key={`deny-${card}`}
                      label="Deny"
                      onPress={() => {
                        void sendAsOwner($, bound, ['-Deny', card], '').then(answer => $.ui.toast(answer))
                      }}
                    />
                  </Box>
                )
              }
              // An empty row is drawn as a blank: a row without text takes no row
              if (row.spans.length === 0) return <Text> </Text>

              return (
                <Text wrap={isTerminal ? 'truncate-end' : 'wrap'}>
                  {row.spans.map(span => (
                    <Text {...styleOf(span)}>{span.text}</Text>
                  ))}
                </Text>
              )
            })}
          </Box>
          {bar !== null && (
            <Box flexDirection="column" width={1} marginLeft={1} flexShrink={0}>
              {bar.above !== '' && <Text dimColor>{bar.above}</Text>}
              <Text>{bar.thumb}</Text>
              {bar.below !== '' && <Text dimColor>{bar.below}</Text>}
            </Box>
          )}
        </Box>

        {(note.length > 0 || !current.isClosed) && (
          <Box flexDirection="column" marginTop={1}>
            {note.length > 0 && (
              <Text color="yellow" wrap="wrap">
                {note.join('\n')}
              </Text>
            )}
            {!current.isClosed && (
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
            )}
          </Box>
        )}
        {hint.length > 0 && (
          <Text dimColor wrap="wrap">
            {hint.join('\n')}
          </Text>
        )}
      </Box>
    )
  })
}
