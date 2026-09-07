# ServerTeleport

Generic server teleport management for Roblox: pooled reserved-server registry, heartbeat, discovery, and teleport, for games that run one or more persistent shared reserved-server hubs (e.g. a trade hub, a ranked-duel hub) alongside a standard lobby.

This package is **server-side only**. It has no client API surface beyond `getServerType`, which is safe to call from either realm. Deciding *which* reserved server a player should join (auto-match, browse-and-pick, etc.) is left entirely to the host project — this package only provides the underlying mechanism.

## Install

```toml
[dependencies]
ServerTeleport = "hollower233/serverteleport@0.1.0"
```

## Concepts

- **Pool**: a named category of reserved server (e.g. `"tradeServer"`). A pool's live servers share one MemoryStore-backed registry so any server can discover the others. There is no upfront pool registration — a `poolName` is just a string you pass to `teleport`/`getActiveReservedServers`, and the corresponding registry is created on first use.
- **Server type**: what a given running server *is* — `"standard"` for an ordinary server, or a pool name for a server that was reserved as part of that pool. Resolved once, from `TeleportData`, and published via `getServerType()`.

## API

### `ServerTeleport.server.init(studioSetServer: string?)`

Call once, from your server bootstrap script, before using any other method. Determines this server's type and — if it's a reserved server — starts its heartbeat loop (writes liveness info to the pool's MemoryStore registry every 20s, deregisters on `BindToClose`).

Resolution order:
1. `studioSetServer`, if non-empty — lets you fake a pool name in Studio. Compute this yourself from your own project's flag system (e.g. `GameFlags`) and pass the result in; this package does not read any flag directly.
2. Otherwise, checks whether this is a real TeleportService-created reserved server (`PrivateServerId` set, `PrivateServerOwnerId == 0`). If not, resolves to `"standard"`.
3. If it is, waits for the first player to join and reads `__poolName` out of their `TeleportData` (written by `server.teleport` at teleport time) to determine which pool this server belongs to.

This does not yield the calling script — the wait for a player (step 3) runs in the background. Calling `init` more than once is an error.

`game.JobId` is always empty in Studio (only real published servers get one), and `MemoryStoreService` rejects an empty key — so when a Studio session resolves to a reserved server (via `studioSetServer`), the heartbeat loop skips its `MemoryStoreService` writes (one `warn`, not per-heartbeat) instead of failing every 20s. This means `getActiveReservedServers` will never see Studio sessions as candidates — reserved-server discovery is untestable in Studio and only works on real published servers.

### `ServerTeleport.server.teleport(poolName: string, args: TeleportArgs)`

Teleports `args.plrList` to a reserved server in `poolName`. If `args.reservedServerAccessCode` is omitted and `args.targetServer` is `"reserved"` (the default), reserves a brand-new server via `TeleportService:ReserveServerAsync`. Embeds `__poolName` (and, when reserving/joining a specific reserved server, `__reservedServerAccessCode`) into the outgoing `TeleportData` so the destination server can identify itself in `init()`.

Failures are `warn`-logged and swallowed (no return value) — the caller does not currently get a programmatic failure signal.

```lua
type TeleportArgs = {
	plrList: { Player },
	teleportData: {}?,
	targetServer: ("standard" | "reserved")?, -- default "reserved"
	reservedServerAccessCode: string?,
}
```

### `ServerTeleport.server.getActiveReservedServers(poolName, sortField?, sortDesc?, cursor?)`

Queries `poolName`'s registry for other currently-active (heartbeat within the last 60s) reserved servers. Use this to build your own join policy (auto-assign to the least-full server, list servers for the player to pick, etc.).

```lua
type ReservedServerInfo = {
	accessCode: string,
	privateServerId: string,
	jobId: string,
	playerCount: number,
	updatedAt: number,
	liveTime: number,
}
```

- `sortField`: `"playerCount"` (default, sorts the "active by heartbeat time" table) or `"liveTime"` (sorts the "active by server age" table).
- `sortDesc`: defaults to `true`.
- `cursor`: pass the previously returned cursor to page; a page only returns a cursor when it was full (200 entries), otherwise there's nothing more.

### `ServerTeleport.getServerType(): string`

Returns `"standard"` or the current server's pool name. Callable from server or client. If the value isn't resolved yet (e.g. a client script running before the server has finished `init`), waits for it rather than erroring.

## What this package deliberately does not do

- No client-facing join/browse UI or remotes — build your own on top of `getActiveReservedServers`/`teleport`.
- No admin server-browser tooling.
- No disconnect/rejoin tracking.
- No notification UI on teleport start/failure.
- No networking dependency (no Net, no RemoteEvents) — everything here is either server-only calls or a replicated `Attribute` read.
