import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import { applyFeedLine, applyRoomLine, claimDecision, decisionOn, emptyView, isHomeOrEnd, openingView, paneRegions, paneRows, plainText, reasonOf, refusalOf, releaseDecision, scrollBar, scrolledTo, splitOwnerText, statusOf, takeLines, windowTop, withNote, wrapText } from './feed'
import type { FeedEvent, PaneSpan } from './feed'
import type { RelayDecision } from '../types'

// The chat window of a room. It is thin on purpose: everything that knows a room lives in the scripts, and
// this module only starts the feed (which is also the room's tamper check and the coordinator's heartbeat),
// draws what it prints, and passes on what the owner types or decides.

const PANE = 'relay'
const BIND_TOOL = 'mcp__agent-relay__relay_bind'

const room = atom({ plugin: 'agent-relay', key: 'room' } as const, null)
const view = atom({ plugin: 'agent-relay', key: 'view' } as const, null)
// The first row the pane's window shows of the room; null while it follows the end, where the newest is
const scroll = atom({ plugin: 'agent-relay', key: 'scroll' } as const, null)
// The owner's decisions on their way to the room: a card with one takes no other press until it is answered
const deciding = atom({ plugin: 'agent-relay', key: 'deciding' } as const, [])
// The owner's word, given in this session, that the host's session-to-session tools may be used while a room is
// bound: false until /relay outside on, and false again in every new session
const outside = atom({ plugin: 'agent-relay', key: 'outside' } as const, false)

// The room is the coordinator's only channel to an agent. These tools of the host reach sessions outside it
// (another session on this PC, a teammate, a session in the cloud, a subagent of its own) and are refused while
// a room is bound, unless the owner has said otherwise in this session.
const ALLOW_OUTSIDE = 'Allow'

const refusedOutside = (tool: string, bound: string): string =>
  `${tool} is refused: this session coordinates room ${bound}, and the room is its only channel to an agent. Reach an agent through your launcher's verbs; a session outside the room gets the join prompt. Only the owner can allow this, by typing /relay outside on.`

// Judges a call of one of them: through to the tool while no room is bound or the owner has allowed it, refused otherwise
async function judgeOutside<R>($: EngineInterface, tool: string, through: () => Promise<R>): Promise<R | { deny: string }> {
  const bound = await read($, room)
  if (bound === null || (await read($, outside))) return through()

  return { deny: refusedOutside(tool, bound) }
}

// The feed that runs, if any: the number of its loop, and the stream of its child while one runs. Binding a
// room (another one, or the same one again) and unbinding stop it through stopFeed and nowhere else, which
// kills the child at once; and a loop that was stopped while it waited changes nothing when it wakes, since
// every step of it asks isCurrent before it touches the view, the status or the owner.
type FeedStream = ReturnType<EngineInterface['process']['spawn']>
let feedRun = 0
let feedChild: FeedStream | null = null

const isCurrent = (run: number): boolean => run === feedRun

// Stops the feed that runs, and hands out the number of the loop that may speak from now on
const stopFeed = (): number => {
  feedRun += 1
  const child = feedChild
  feedChild = null
  // The engine kills the child when its stream is returned, also while a read of it waits
  if (child !== null) void child.return({ code: null, signal: null }).catch(() => undefined)

  return feedRun
}

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

const toast = ($: EngineInterface, text: string): void => $.ui.toast(plainText(text))

// A native notification by the owner's own channel, else a toast. One that fails (a hook of the owner's refused
// it, or the write failed) is a toast too: it costs the feed nothing.
const notify = async ($: EngineInterface, text: string): Promise<void> => {
  const said = plainText(text)
  try {
    if ((await $.ui.notify(said, { title: 'agent-relay' })).isSent) return
  } catch {
    // Said in a toast below
  }
  $.ui.toast(said)
}

// What is worth telling the owner of what the feed of this loop printed, while the loop is the current one
const tell = async ($: EngineInterface, id: string, run: number, events: readonly FeedEvent[]): Promise<void> => {
  for (const event of events) {
    if (!isCurrent(run)) return
    if (event.kind === 'card') {
      // A card stands at the end of what the pane shows: the window goes there
      await update($, scroll, at => (isCurrent(run) ? null : at))
      await notify($, `${id}: your decision is needed: ${event.subject}`)
    }
    if (event.kind === 'alarm') toast($, `${id} ALARM: ${event.text}`)
    if (event.kind === 'closed') toast($, `${id} is closed.`)
  }
}

// A note of the pane's own under the room's rows, from a loop that is the current one
const setNote = async ($: EngineInterface, run: number, text: string): Promise<void> => {
  await update($, view, current => (current === null || !isCurrent(run) ? current : withNote(current, text)))
}

// One line of the feed into the view, and what is worth telling of it: nothing from a loop that was stopped
// while it waited, and nothing into a view that is not of its room
const applyLine = async ($: EngineInterface, id: string, run: number, line: string): Promise<FeedEvent[]> => {
  let events: FeedEvent[] = []
  await update($, view, current => {
    const applied = isCurrent(run) ? applyRoomLine(current, id, line) : { view: current, events: [] }
    events = applied.events

    return applied.view
  })

  return events
}

// One run of the feed, read to its end: what it prints becomes the view, and why it ended comes back (what it
// wrote as an error, or the last error line it printed)
const readFeed = async ($: EngineInterface, id: string, run: number): Promise<FeedEnd> => {
  let rest = ''
  let errors = ''
  let said = ''
  let isClosed = false
  let feed: FeedStream | null = null
  try {
    // Stopped while it waited to start: no child, and none of another loop's is taken for this one's
    if (!isCurrent(run)) return { reason: '', isClosed }
    feed = $.process.spawn({
      argv: shellOf(scriptOf($, 'Watch-RelayFeed.ps1'), ['-Room', id, '-Json', '-EndWithParent']),
      env: { PSModulePath: '' },
    })
    feedChild = feed
    for await (const chunk of feed) {
      if (!isCurrent(run)) break
      if (chunk.stream === 'stderr') {
        if (errors.length < 4000) errors += chunk.text
        continue
      }
      const taken = takeLines(rest + chunk.text)
      rest = taken.rest
      for (const line of taken.lines) {
        if (!isCurrent(run)) break
        const events = await applyLine($, id, run, line)
        for (const event of events) {
          if (event.kind === 'error') said = event.text
          if (event.kind === 'closed') isClosed = true
        }
        await tell($, id, run, events)
      }
      const shown = await read($, view)
      if (isCurrent(run)) $.ui.status(statusOf(shown))
    }
  } catch (error) {
    return { reason: reasonOf(error instanceof Error ? error.message : String(error)), isClosed }
  } finally {
    if (feedChild === feed) feedChild = null
  }

  return { reason: reasonOf(errors) || reasonOf(said), isClosed }
}

// run: the number stopFeed handed out for this loop. first: the lines of a look at the room that was taken just
// before (bind), drawn until the feed's own arrive.
const startFeed = ($: EngineInterface, run: number, id: string, first: readonly string[] = []): void => {
  void (async () => {
    let found: FeedEvent[] = []
    await update($, view, current => {
      if (!isCurrent(run)) return current
      const opened = openingView(current, id, first)
      found = opened.events

      return opened.view
    })
    await tell($, id, run, found)
    let restarts = 0
    for (;;) {
      // Another room was bound, or none: that loop speaks now
      if (!isCurrent(run)) return
      const startedAt = await $.clock.now()
      const ended = await readFeed($, id, run)
      if (!isCurrent(run) || ended.isClosed) return
      const why = ended.reason === '' ? '' : `: ${ended.reason}`
      if ((await $.clock.now()) - startedAt >= STEADY_MS) restarts = 0
      const wait = RESTART_WAITS_MS[restarts]
      if (wait === undefined) {
        // Nothing checks the room for tampering now and no agent sees the coordinator alive: the owner is
        // told where it cannot be missed, not only in a pane that may be closed
        const text = `relay ${id}: the feed has ended${why}. The tamper check and the coordinator's heartbeat have stopped with it. /relay ${id} starts it again.`
        await setNote($, run, text)
        if (!isCurrent(run)) return
        $.ui.status(`relay ${id} | THE FEED HAS ENDED`)
        await notify($, text)

        return
      }
      restarts += 1
      await setNote($, run, `The feed ended${why}. Starting it again in ${wait / 1000} seconds (try ${restarts} of ${RESTART_WAITS_MS.length}).`)
      await $.clock.sleep(wait)
    }
  })().catch(async (error: unknown) => {
    // The loop itself failed: said in the pane, like a feed that ended, never swallowed
    const reason = reasonOf(error instanceof Error ? error.message : String(error))
    try {
      await setNote($, run, `The feed loop failed: ${reason}. /relay ${id} starts it again.`)
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
  // Whatever ran before says nothing more from here on. A room bound or unbound while these are written has the
  // last word, and these writes then change nothing.
  const run = stopFeed()
  await update($, room, current => (isCurrent(run) ? id : current))
  await update($, scroll, at => (isCurrent(run) ? null : at))
  if (!isCurrent(run)) return { id: '', reason: 'another room was bound, or none, while this one was looked at' }
  startFeed($, run, id, look.lines)
  // A pane that cannot be opened (a surface without one) takes nothing from the binding: the feed runs
  void $.ui.open({ id: PANE, title: `relay ${id}`, columns: 64, rows: 18 }).catch(() => undefined)

  return { id, reason: '' }
}

const unbind = async ($: EngineInterface): Promise<void> => {
  const run = stopFeed()
  await update($, room, current => (isCurrent(run) ? null : current))
  await update($, view, current => (isCurrent(run) ? null : current))
  await update($, scroll, at => (isCurrent(run) ? null : at))
  if (isCurrent(run)) $.ui.status(undefined)
}

// /relay outside on|off: the owner's word on the host's session tools while a room is bound. "on" is asked back
// in the engine's own dialog, which only a person at the terminal answers (a headless run has no one, and that
// counts as refused), so the word is the owner's whoever typed the command. It holds for this session only.
const outsideOf = async ($: EngineInterface, word: string): Promise<string> => {
  if (word === 'off') {
    await update($, outside, () => false)

    return 'Session-to-session tools (SendMessage, ListAgents) are refused again while a room is bound.'
  }
  if (word !== 'on') return 'Type /relay outside on to allow SendMessage and ListAgents in this session while a room is bound, or /relay outside off to refuse them again.'
  const bound = await read($, room)
  if (bound === null) return 'No room is bound, so nothing is refused: the session tools are allowed as they are.'
  const answer = await $.ui
    .ask(`Allow this session's session-to-session tools (SendMessage, ListAgents) while room ${bound} is bound? The room is otherwise the coordinator's only channel to an agent.`, {
      options: [ALLOW_OUTSIDE, 'Refuse'],
      header: 'Outside',
    })
    .catch(() => '')
  if (answer !== ALLOW_OUTSIDE) return `Not allowed: SendMessage and ListAgents stay refused while room ${bound} is bound.`
  await update($, outside, () => true)

  return `Allowed in this session until /relay outside off, /clear or the session ends: the owner's word. Have the coordinator record it with Add-RelayDecision.ps1 -Owner.`
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

    return `Not sent: ${reasonOf(sent.stderr || sent.stdout) || `exit code ${sent.exitCode}`}`
  } catch (error) {
    return `Not sent: ${reasonOf(error instanceof Error ? error.message : String(error))}`
  }
}

// What the owner typed, to the room the pane showed when they typed it, while that room is still the bound one
const sayAsOwner = async ($: EngineInterface, shown: string, typed: string): Promise<void> => {
  const said = splitOwnerText(typed)
  if (said.text === '') return
  const refusal = refusalOf(await read($, room), shown)
  if (refusal !== '') {
    toast($, refusal)

    return
  }
  const args = said.to === '' ? [] : ['-For', said.to]
  toast($, await sendAsOwner($, shown, args, said.text))
}

// The owner's decision on a card of the room the pane showed when they pressed, while that room is still the
// bound one, and while no other decision on that card is on its way
const decide = async ($: EngineInterface, shown: string, card: string, decision: RelayDecision['decision']): Promise<void> => {
  const refusal = refusalOf(await read($, room), shown)
  if (refusal !== '') {
    toast($, refusal)

    return
  }
  let isClaimed = false
  await update($, deciding, list => {
    const claimed = claimDecision(list, { room: shown, card, decision })
    isClaimed = claimed.isClaimed

    return claimed.deciding
  })
  if (!isClaimed) return
  try {
    toast($, await sendAsOwner($, shown, [decision === 'approve' ? '-Approve' : '-Deny', card], ''))
  } finally {
    await update($, deciding, list => releaseDecision(list, shown, card))
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
    // After a reload the room is still bound: the feed is not, it died with the module, and so did every
    // decision that was on its way (its card takes presses again; the script refuses a card answered twice).
    // The owner's word on the session tools does not outlive the module either: it is asked again.
    await update($, deciding, () => [])
    await update($, outside, () => false)
    const bound = await read($, room)
    if (bound !== null) startFeed($, stopFeed(), bound)

    return started
  })

  on('command.run', { command: 'relay' }, async ($, e) => {
    const wanted = e.args.trim()
    if (wanted === 'off') {
      await unbind($)

      return { text: 'The relay pane is unbound; its feed has stopped.' }
    }
    if (wanted === 'outside' || wanted.startsWith('outside ')) return { text: await outsideOf($, wanted.slice('outside'.length).trim()) }
    if (wanted !== '') {
      const done = await bind($, wanted)

      return { text: done.reason === '' ? `Relay pane bound to room ${done.id}.` : `Not bound: ${done.reason}` }
    }
    const bound = await read($, room)
    if (bound === null) return { text: 'No room is bound. Type /relay <room id>.' }
    const isOpen = await $.ui.open({ id: PANE, title: `relay ${bound}`, columns: 64, rows: 18 }).then(
      () => true,
      () => false,
    )

    return { text: isOpen ? `Relay pane: room ${bound}.` : `Relay pane: room ${bound}. The pane could not be opened here.` }
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

  // The guard on the session tools: it judges before it calls next, and a guard that fails, or is reached
  // again from beneath its own call, refuses in its place, since the room is the only channel either way
  on('tool.call', { tool: 'SendMessage' }, ($, e, next) => judgeOutside($, e.tool, () => next(e))).catch(
    (_$, e, next) => (next.called ? next(e) : { deny: refusedOutside(e.tool, 'a room of this PC') }),
  )
  on('tool.call', { tool: 'ListAgents' }, ($, e, next) => judgeOutside($, e.tool, () => next(e))).catch(
    (_$, e, next) => (next.called ? next(e) : { deny: refusedOutside(e.tool, 'a room of this PC') }),
  )

  // The pane draws a window of its own over the rows of the room, so that its input stands still under it:
  // a move the owner asks for (the wheel, a page key, Home and End) moves that window, and the engine's own
  // stays where it is
  on('ui.scroll', { requestId: PANE }, async ($, e) => {
    await update($, scroll, at => scrolledTo(heldRows, shownRows, at, e.by, isHomeOrEnd(e.by, e.bodyRows, e.contentRows)))

    return {}
  }).catch(() => ({}))

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const bound = await read($, room)
    const current = await read($, view)
    const at = await read($, scroll)
    const pending = await read($, deciding)
    const columns = Math.max(30, e.props.bodyColumns)
    // The pane draws the view of the bound room only: right after a room was bound the view may still be the
    // one of the room before, whose cards must not be decided in this one
    const shown = current !== null && current.room === bound ? current : null

    if (e.surface === 'mobile') {
      const { Box, Text } = $.ui.resolve(e)

      return (
        <Box flexDirection="column">
          <Text>{bound === null ? 'No relay room is bound.' : `relay ${bound}: ${shown?.messages.length ?? 0} messages, ${shown?.cards.length ?? 0} waiting on you`}</Text>
        </Box>
      )
    }

    const { Box, Text, Button, Input } = $.ui.resolve(e)
    if (bound === null || shown === null) {
      return (
        <Box flexDirection="column">
          <Text dimColor>{bound === null ? 'No room is bound. Type /relay <room id>.' : `Connecting to room ${bound}...`}</Text>
        </Box>
      )
    }

    // Only the terminal draws in rows that can be counted here. There every text is wrapped by this module,
    // the pane shows a window of the rows with a scroll bar in its last two columns (a blank and the bar), and
    // what the feed says, the input and how to scroll stand still at its foot. Another surface wraps and
    // scrolls by itself.
    const isTerminal = e.surface === 'terminal'
    const width = isTerminal ? columns - 2 : UNWRAPPED
    const all = paneRows(shown, width)
    const note = shown.note === '' ? [] : isTerminal ? wrapText(shown.note, width) : [shown.note]
    let rows = all.slice(-ROWS_ELSEWHERE)
    let bar: ReturnType<typeof scrollBar> = null
    let hint: string[] = []
    if (isTerminal) {
      const foot = note.length + (shown.isClosed ? 0 : 1)
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
                // A decision on its way stands in place of the two buttons until it is answered: one at a time
                const sending = decisionOn(pending, shown.room, card)
                if (sending !== undefined) return <Text dimColor>{sending.decision === 'approve' ? 'Approving...' : 'Denying...'}</Text>

                return (
                  <Box flexDirection="row" gap={2}>
                    <Button
                      key={`approve-${card}`}
                      label="Approve"
                      variant="primary"
                      onPress={() => {
                        void decide($, shown.room, card, 'approve')
                      }}
                    />
                    <Button
                      key={`deny-${card}`}
                      label="Deny"
                      onPress={() => {
                        void decide($, shown.room, card, 'deny')
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

        {(note.length > 0 || !shown.isClosed) && (
          <Box flexDirection="column" marginTop={1}>
            {note.length > 0 && (
              <Text color="yellow" wrap="wrap">
                {note.join('\n')}
              </Text>
            )}
            {!shown.isClosed && (
              <Input
                key="say"
                placeholder="Say something as the owner (@name for one agent)"
                submitLabel="send"
                onSubmit={typed => {
                  void sayAsOwner($, shown.room, typed)
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
