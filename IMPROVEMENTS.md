# Improvements for later

What a review of the plugin with the plugin-dev agents (2026-10-12 and 13, releases 0.8.0 to 0.9.0) found and
did not do. Each item says what is wrong, where, and what to do. `IDEAS.md` holds the research on alternatives;
this file holds the plugin's own open work. Remove an item when it ships, and name the release in the CHANGELOG.

## Room tool changes (a room package bump, protocol tests on both engines)

Do these as one release, with a failing test for each first. They come from open lessons in
`skills/agent-relay/references/lessons.md` ("Not changed yet").

1. **A second session that introduces itself under a live agent's name replaces its card.** The board then shows
   the wrong rights for the real agent (lesson of 2026-10-11, reported and not reproduced). Reproduce it in a
   test first. Then refuse the introduction, or mark it ATTENTION, while the first session is alive. This is
   the most valuable item: it is an impersonation gap. See `Invoke-Start` in `assets/room-package/tools/relay.ps1`.
2. **The room does not hold the model and effort the owner announced for a seat.** The board marks a computer
   name mismatch but not a model or effort mismatch. Store the announced values in the answers and the seat,
   and mark the difference as ATTENTION as the computer name is.
3. **The board cannot tell a dead coordinator wait while the feed keeps the coordinator's heartbeat alive.**
   The 0.7.0 `OVERDUE` wake covers part of it. Check what is still missing before building anything.
4. **A note to all also lands in every free seat's inbox.** A late joiner is shown notes from before its time.
   A design call: keep it (context) or stop it (confusing). Decide, then record the decision in the lesson.

## References and skill

5. **Split `lessons.md`** (about 11k words, around 60 percent about the tool's own code). Keep job-design and
   coordination lessons in `lessons.md`; move tool-internals lessons (culture, `\d`, `@($list)`, Pester mocks,
   lock tokens, `$ErrorActionPreference`) to a second file read only by `self-improvement.md`. Add a topic line to
   every bullet, or an index at the top, so a search by keyword finds them.
6. **Remove or condense the sh-era lessons** (the engine is gone, `CLAUDE.md`): lines about `relay.sh`, dash
   timing, sh side by side. Keep the general lesson in one line each, for example "run race tests several
   times" and "a missing file is not an old one".
7. **Mark or delete superseded lessons:** the parking entries (parking was removed in 0.7.0), the "writer and
   reader on different machines is not measured" line, and the "still open" lists that later entries closed.
8. **Trim `protocol.md`** (about 5.5k words, mostly not for the coordinator): move the lease and lock details,
   "Details of the tool" and most of "Limits" to a `protocol-internals.md`, or add an index at the top.
9. **One statement for each repeated rule.** The hold is described in `SKILL.md`, `coordinating.md`,
   `protocol.md` and `lessons.md`; "no ssh, no sh" in five places; the exit-0 wait history three times in
   `agent-kinds.md`. Keep one and point to it. The tool-internals rows of the traps table in `transports.md`
   (BOM, JSON dates, `@($list)`) duplicate `lessons.md`.
10. **`agent-kinds.md`:** two paragraphs about wake mode sit under "Model and effort" (lines 53 to 61); the Codex
    and Claude Code notes are single long paragraphs; the model table copies an external page and will drift
    (keep the family-word rule that `scripts/model-tiers.json` holds and point to the page).
11. **Board table in `coordinating.md`:** add the status `woken by N overdue task(s)`, which `relay.ps1` writes.
12. **A ninth rule for `multi-builder.md`:** before work is handed out, check that the builders can run the gate
    where they are (it is in `lessons.md` only).
13. **The coordinator's tasks paragraph** in `coordinating.md` ("Tasks") is one long paragraph; split it into
    bullets.

## Evals

14. **`closes-with-memory-review` scores 0.60 with the skill**, the same before and after 0.8.0: the judge fails
    "reviews memory and asks once" every time. Read the answers (`--keep-temp`) and decide whether the skill or
    the grader is at fault. It is the one real gap in coverage that the evals show.
15. **`asks-about-an-open-room` and `handles-an-overdue-agent` vary between runs** (1.00 then 0.50 and 0.83).
    The eval agent reads this repo's real `.local/rooms.json`, so a live room changes the answer. Run the cases
    in a sandbox with an empty local folder, or say in the prompt that the room list is empty, and use five
    runs per case so a judge vote does not decide a score.
16. **Add evals for the rest of the workflows:** pause, hold and stop (workflow 5), the close with memory
    promotion, and a coordinator that tries to use SendMessage to reach another session (the "only the room"
    rule, which the pane also refuses).

## Plugin hygiene

17. **`marketplace.json`** has no `version` or `category` (both optional) and its description differs from
    `plugin.json`; take one from the other, or add a CI check that compares them.
18. **`CLAUDE.md` at the root** makes `claude plugin validate` warn that it is not loaded for plugin users. It is
    contributor guidance and stays; a `CONTRIBUTING.md` for the human-facing parts would clear the warning.
19. **PR flow:** 0.8.0 went to `main` directly because `gh` was not signed in. Use a branch and a pull request
    for every release, as 0.8.1 and 0.9.0 did.
20. **The `SKILL.md` description is 636 characters.** The guideline is about 500; trim again if the evals stay
    at 1.00 on the trigger and negative cases.
