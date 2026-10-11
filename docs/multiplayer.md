# Multiplayer (PvP) — how it works

A fight between human players, up to 6 against 6, one hero each, from a static web page plus a small relay server
(`server/`) that only passes messages between the players. The game is in `scripts/net/` (rules, session, network)
and `scripts/game/net/` (screens).

## The idea: everyone replays the same log

The battle rules are deterministic (a seeded random generator, no clock), so players do not send each other game
states, only *what was decided*:

- The match is a **log of entries**: a player joined, a hero was picked, the host chose the map, the match started,
  a hero was placed, a hero moved or cast, a turn ended, the AI took over a hero...
- One peer, the **host**, numbers each entry, checks it (is it your hero, is it your turn, is it legal) and sends it
  to everyone. Every peer applies the entries in order with the same rules, so everyone holds the same battle.
- Each entry that changes the battle carries a **fingerprint** of the state after it; a peer whose state differs stops
  with a clear "desync" message instead of playing on a wrong board.
- The screen of each player keeps its own copy of the battle and animates what the log brings; a click only becomes a
  *proposal* to the host, and nothing changes on screen until the host's entry comes back.

Code: `MatchState` (the replicated state and every entry kind), `MatchSession` (numbering, checking, host swap,
timers, AI, reconnect), `ActionCodec` and `StateHash`, `NetBattleController` (the fight screen).

## Host swap

The host is the lowest seat id still reachable. When it disappears, each peer computes the new host the same way; the
new host asks the others how far their logs go, completes its own from whoever has most (an entry the old host sent to
only some of them is not lost), brings the others up to date, and carries on numbering. Proposals that were in flight
are sent again to the new host (each carries a nonce, so none is applied twice).

## A player who leaves: the AI, and coming back

After the grace time (host setting, 20 s by default) the host puts an entry in the log that gives the player's hero to
the AI; from then on the host plays that hero's turns (the AI's moves are entries too, so every peer sees the same).
The players panel tags "(AI)" and "(away)". There is no button for a player to hand their own hero to the AI (the entry exists, and the tests use it, but the screens don't offer it).

A player who comes back opens the room again with the same browser: a token kept in the browser gets
their seat back. They replay the log, then the host returns the hero at a moment that is not its turn. A player whose
tab was only paused, or whose connection blinked (the host stopped hearing it), is asked by the host to say hello again
as soon as it is back, and gets the seat back the same way; the game also keeps its loop running while its tab is hidden, so a host looking at another
tab still answers joiners. A player who is the last one connected is told so ("Nobody else is connected").

## The relay server

Every player holds one WebSocket to the relay (`server/relay.mjs`, a Node program of about 250 lines with the `ws`
package); the network is a star. The server knows nothing about the game: a **room** is a code, its members have numbers
(the seat ids: the opener is 1, then 2, 3...), and a message goes from one member to one other member or to all the
others. It puts the sender's number on every message itself, so nobody can speak for someone else. Protocol (JSON text):

- client: `{t:"host", token}`, `{t:"join", room, token, resume?}`, `{t:"msg", to?, b}`
- server: `{t:"welcome", room, id, peers}`, `{t:"peer", id}`, `{t:"left", id}`, `{t:"msg", from, b}`, `{t:"error", why}`

The game side is `RelayTransport` (a `NetTransport`, so `MatchSession` neither knows nor cares), `RelaySocket` (the
WebSocket, faked in tests), `MultiplayerHub` (host or join, tokens, the session on top) and `RelayConfig` (the address).

- **Room code:** 6 characters from an alphabet without look-alikes, made by the server (about 29 bits). The server counts
  the wrong codes per address and answers `slow_down` after 10 a minute, so guessing is out of reach; an invite is the
  *room link* (`#room=code`) or the code read out.
- **Seats and tokens:** the server ties a seat number to a token the browser kept, so a player who reloads or loses the
  connection gets the same number back. The server only ever sees `sha256("…/relay/" + token)`; the match log keeps another
  hash of the token (`MatchState.token_hash`), which every player has, so it can't be used to take a seat on the server.
  Two tabs of one browser share the token: the second is refused with `token_in_use` and takes a fresh one.
- **A connection that breaks** (a Wi-Fi blink) is reopened by the transport with the same token (`resume`, which replaces
  the dead connection on the server). Meanwhile the session knows it is offline (`NetTransport.is_online()`): it judges
  nobody (no timeouts, no host swap, no dropped seats) and refuses to propose. Back online, the transport tells it who
  left meanwhile, and a host that was cut off (the others chose another one) asks the new host for what it missed, like any
  guest. A server restart closes everyone with code 1012 and the players reconnect; the room does not survive that if it was
  empty, but the log lives in the players' browsers, so a match whose players come back goes on.
- **Free tier:** the server runs on Render's free plan (`render.yaml`). A free service sleeps after 15 minutes without
  traffic (open WebSockets and their messages count as traffic, so a live match keeps it awake) and takes about a minute to
  wake. The multiplayer menu asks `/health` as soon as it opens, the transport keeps trying for two minutes, and the
  waiting screen says the server is waking up. 750 free instance hours a month cover one always-on service.
- **Limits** (in `relay.mjs`): 300 rooms, 12 members per room, 30 connections per address, 2 MB per message, a message rate
  per connection (a flood closes it), and a page-origin allowlist (`ALLOWED_ORIGINS`).
- **Capacity** (measured on a laptop, relay and 150 simulated players in 19 rooms of 8, messages of 300 bytes): 1 message per
  player per second took 2.7 % of one CPU core, 5 per second 7.4 %, 20 per second 18.8 %; 70-80 MB of memory; a delay under
  10 ms. A Render Starter instance (0.5 CPU) has room for far more than the 300 rooms the relay accepts; the cost to watch
  is outbound bandwidth (about 1 GB an hour for 150 players at 1 message per second). Rooms live in the server's memory, so
  run one instance only.

## Security: what is and is not protected

**Your computer and your data.** The game runs inside the browser's sandbox. Nothing a player sends is ever run as code:
messages are JSON read with strict type checks (anything malformed is dropped, never a crash), no engine object or
resource is loaded from the network, names are length-limited and shown as plain text, and the page reads or writes no
file outside the browser's own storage (saves, a name, a rejoin token). Opening a room link only opens this same page
(the address of the relay server is fixed in the game: a link can't point it elsewhere, except to a server on the
player's own machine for development). That makes the game a low risk for a laptop, but "100 % safe" is not a promise anyone can make: the browser, the
engine and the browser's WebSocket themselves can have flaws, and a lookalike site could imitate a link, so open links only when they start
with the game's own address.

**What other people learn.** The relay server sees every message (names, hero choices, every action: nothing in the
game is secret) and the IP address of each connection, and logs room events (no names). The other players do **not** see
your IP address (they only talk to the server). Players see names and hero choices. The page asks the server's `/health`
when the multiplayer menu opens (to wake it up), which tells Render's host that a browser opened the menu.

**What a player (or the host) can do to the others.** The match is only as trustworthy as the people in it:
- The **host** is the authority: it numbers and checks the entries, but it could also write entries that favour it, and
  the other players would apply them as long as the rules allow them. Play with people you would trust as host.
- A player cannot act for another player's hero (the host refuses it), cannot push entries to the others (only the
  host's entries, or entries I asked for while catching up, are taken), cannot refuse or evict anyone (a "refused"
  message counts only from the host a joiner contacted, and an "elected" message only if the receiver would have chosen
  that player too, with the old host gone), and cannot read or use another player's rejoin token (the shared log keeps
  only a hash of it). What a player proposes is rebuilt by the host field by field for its kind (a peer's hash, padding
  or flags never reach the log), with a limit on the rate of proposals per player.
- The server stamps the sender on every message, so a player cannot pass as another one. A **hostile or hacked relay
  server** could still alter messages: the worst it can do to a state-changing message is make the victim stop with a
  "desync" message (the host's entries carry a fingerprint); it cannot make players play a different game unnoticed, but
  it could spam fake emotes or cut the match. The server is the one piece of the system everybody has to trust.
- The host's **Remove** bans the player's token for that match only: someone who removed browser storage or uses another
  browser gets a new token and can come back with the room code. It is a courtesy tool, not access control.
- Any player can disrupt: send a lot of messages, leave at a bad moment. Anyone who knows
  the room code can join the lobby (a room link carries the code too, so share links like passwords). A code posted
  publicly is of course public.

## Screens

The lobby (`NetLobbyScreen`): your player (name, hero cards, Ready), the two team cards (a click anywhere on a card, or its
name as a button for the keyboard, joins the team; it says "your team" on yours; the host's Remove button is on each row),
the invite card (room code written `abc-def`, a button copies the code, one the link) and the map and rules ("new map" is a
round-arrow button). The round **top bar** (`TopBar`, owned by the Game root and shared with the single-player game) sits at the top
right: from left to right the sound, the settings cog (every screen but the title ones) and, in a fight, a hamburger
button for the menu (leaving the match). The settings open as an overlay (`Game._open_settings_overlay`), the match going on underneath. Changing the map or the rules leaves the players Ready as they are (only a change of a player's own hero or team takes
their Ready back). There are no quick messages in the lobby:
in the fight a "Say something" button above End turn opens the list in the middle of the screen
(`NetBattleController`), and a message appears above the sender's hero in a comic speech bubble (`SpeechBubble`, 5 s; a
hidden hero's bubble stays hidden too). The settings (`NetFlow._open_settings`) open as an overlay over the lobby or the
fight, with only what concerns the player's device, so a player who came straight in by a room link (and never saw the title
screen) can reach the volumes and keys; the match goes on underneath.

**One speed for everyone.** A multiplayer fight plays at x1 on every screen (`NetBattleController.play_speed`): the speed
button is hidden, the settings opened over a match don't offer it, and the player's own battle speed setting (for solo
battles) is left untouched. Two players at different speeds would see the same match at different paces, and the turn
timer (every peer counts it from the moment the entry that began the turn *arrived*; the host's clock ends the turn) runs
on real time, not on animations. Each screen still plays the entries in order, one after the other.

**The HUD of the fight** has the usual turn order at the top (the next few turns, and the whole order with Tab; a hero played
by the AI is tagged "(AI)", one who left "(away)") and the seconds left on the turn (or on the placement) after the round,
red for the last ten. The spell bar (or the card hand) always shows the player's *own* hero, not the one whose turn it is.

## Fairness and rules

- Classes: nine PvP classes of their own (`data/pvp/`, see `docs/decisions/2026-10-06-pvp-classes.md`): Knight, Ranger,
  Sorceress, Necromancer, Rogue, Priestess, Goblin, Wraith and Monk, each with five spells at a fixed strength. No levels,
  no runes, no Power (the spell numbers are what they show), so unit cards show no Power or resistances. Duplicates are
  allowed. Some classes use stealth (the Rogue's Vanish): the hero is hidden from the other
  team (its own team always sees it) until it attacks, is hurt, or an enemy **walks into it**. Standing next to it shows
  nothing, and an ambush (the Rogue's bonus damage from stealth) depends on the hero's Hidden status, not on being seen, so
  it works from the cell next to an enemy. The cells highlighted for a move are drawn as the player sees the board
  (`Movement.reach(..., as_seen := true)`): a hero they can't see leaves no hole and no shadow behind it. The walk is the
  cheapest one as the player sees it, so it may cross the hidden hero's cell: then the walker stops on the cell before it,
  pays only the steps it took, loses 10 % of its max HP (`BattleActions.Move.BUMP_DAMAGE_PERCENT`), and the hidden hero is
  found (its stealth ends). That is how a hidden hero is discovered, and its place is never given away for free. Allies see
  a hidden hero drawn see-through (about 45 % opaque, with a faint cool tint: `UnitModel.set_ghost`), with its Hidden status icon;
  it turns solid again when it is found or the status ends. This is a rule and a display choice only; every player's client
  holds the whole match.
- Maps: the same shapes as the tower's (open field, mountain, crater, islands, canyon, ruins), made *symmetric under a
  half turn* with a 3 x 3 start zone for each side (`PvpMap`), so neither side is favoured; the map is drawn again on every
  peer from three numbers (shape, size, seed), and the lobby previews it with the QA map preview.
- Turns: initiative order over all heroes; a turn timer (host setting, 45 s by default) ends an idle player's turn.
- Sudden death from round 40 (every hero loses 10 % of max HP at its turn start) so a stalled fight always ends.

## Hosting

The game is a static web export (`tools/export_web.sh`); `tools/export_web.sh --publish` commits it to the local
`gh-pages` branch, `git push origin gh-pages` publishes it, and Settings → Pages → `gh-pages` / root serves it. Saves
and settings live in the browser, separate from the original game's.

The relay is deployed from `render.yaml` (Render: New → Blueprint → this repository; it builds `server/`). Its address is
`wss://rune-ascent-relay.onrender.com` if the service keeps that name; otherwise change `RelayConfig.DEFAULT_URL` and
`ALLOWED_ORIGINS` (the page's origin, e.g. `https://<user>.github.io`). Locally: `cd server && npm ci && npm start`, then
open the game with `?relay=ws://127.0.0.1:8787` (a desktop build reads the `RELAY_URL` environment variable).

## Tests

- `tests/test_pvp_basics.gd`, `test_match_session.gd` (lobby, start, placement, turns, timer, host swap with a partly
  delivered log, AI takeover, rejoin, desync), `test_net_battle.gd`, `test_net_screens.gd`: the logic on a fake network.
- `test_relay_transport.gd`, `test_relay_join.gd` (with `tests/fake_relay.gd`, the relay's rules in memory): rooms, seats,
  messages, a sleeping server, a connection that drops and comes back, a host cut off, full and started matches.
- `server/relay.test.mjs` (`cd server && npm test`): the real server with real WebSockets.
- `tools/e2e/`: real Chrome tabs, the real web export and a relay on this machine. See its README.

## Known limits

- Up to 12 players (6 per side); no spectators; no chat (quick emotes only).
- Placement lasts at most 30 seconds (a fixed time): the host then starts the fight with the heroes where they stand.
- The relay is one free Render instance: the first game after a quiet quarter of an hour waits up to a minute for it, and a
  restart of the service drops the rooms (players reconnect by themselves; an empty room is gone).
- A match needs a human host in a visible tab (browsers slow down background tabs); if the host leaves, another player takes over.
- A host whose connection blinks is replaced at once (the others can't tell a blink from a departure); it comes back as a guest.
- If every human leaves, the match is over: the log only lives in the players' browsers.


## Card combat

A lobby setting (`cfg cards`, a boolean, host only, resets everyone's Ready like any setting). When on, `MatchState.make_battle()` calls `BattleState.enable_cards(seed)`: every unit gets a deck (`CardRules.deck_for`: each spell's slot number, once per copy; copies by rarity), a private dice (`UnitState.card_rng`, seeded from the match seed and the unit id: a hand never depends on the damage rolls) and its first hand. Everything stays in the replicated state, so nothing new travels: a peer replaying the log deals the same cards. Two details matter for the log:

- a **cast** names its spell slot as before, and is valid only while a card of that spell is in the hand (it costs one AP, the card goes to the discard pile, cooldowns are not used);
- a new action, `discard` (`{t: "discard", a: unit, s: spell slot}`), throws a card away for free (`BattleActions.DiscardCard`, event `CardDiscarded`).

The state hash includes each unit's hand, piles and dice state, and the class signature includes the card constants, so two versions that deal differently are told apart at the start. `UnitState.max_ap()` is `CardRules.PLAYS_PER_TURN` plus the AP modifiers: statuses that give or take AP give or take plays.
