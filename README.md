# Presence

A tiny macOS menubar app that tells your website when you're at your computer.

It posts a heartbeat to an endpoint you control every couple of minutes. Your
site reads that and renders something like:

> I'm currently **online** in Ghostty.

> I'm currently **offline**, last online 2 hours ago.

Think of it as a self-hosted Discord status, without needing Discord.

<img src="https://img.shields.io/badge/macOS-13%2B-black" alt="macOS 13+"> <img src="https://img.shields.io/badge/Swift-6.0-orange" alt="Swift 6.0">

## How it works

The app sits in your menubar and every 60 seconds POSTs a small JSON body to
your endpoint:

```json
{ "afk": false, "app": "Ghostty" }
```

- **`afk`** comes from `CGEventSource.secondsSinceLastEventType` — seconds since
  the last real keypress or mouse movement. After 5 minutes you're idle. It
  tracks physical input only, so a long build or a film still reads as away.
- **`app`** is the frontmost application's name, via `NSWorkspace`. This needs
  **no Accessibility permission** — that's only required for window _titles_.
  It's suppressed while you're idle, since it'd just be whatever was open when
  you walked off.

Your server stores that with a timestamp. If the newest heartbeat is older than
five minutes, you're offline.

The app also sends explicit beats on **sleep**, **wake** and **quit**:

```json
{ "offline": true }
```

That's what makes shutting your laptop show up on the site straight away
instead of lingering for the length of the staleness window. The timeout is
only there to catch what those can't — a crash, a dead network, a yanked cable.

### Why the heartbeat is slow

60 seconds is deliberate. Because clean shutdowns are reported explicitly, a
faster heartbeat buys you almost no accuracy — it only narrows the window on
crashes. Meanwhile the cost is linear:

| Heartbeat | Writes/month (running 24/7) |
| --------- | --------------------------- |
| 30s       | 86,400                      |
| **60s**   | **43,200**                  |
| 120s      | 21,600                      |
| 300s      | 8,640                       |

On a metered store like Upstash's free tier (500k commands/month), that's the
difference between comfortable and constantly watching the meter. Change it via
`interval` in `Sources/presence/presence.swift` if you disagree.

## Setup

### 1. Build and install the app

```bash
git clone https://github.com/dk-e/presence.git
cd presence
./scripts/bundle.sh
```

This builds a release binary and wraps it in `/Applications/Presence.app`. Pass
a path to install elsewhere: `./scripts/bundle.sh ~/Applications/Presence.app`.

The bundle is marked `LSUIElement`, so it lives in the menubar only — no dock
icon, no app switcher entry. It's ad-hoc signed, which stops macOS re-prompting
for network access on every rebuild.

### 2. Configure it

Create `~/.config/presence/config.json`:

```json
{
  "endpoint": "https://example.com/api/presence",
  "secret": "..."
}
```

Generate the secret with `openssl rand -hex 32`, and lock the file down:

```bash
chmod 600 ~/.config/presence/config.json
```

Config lives in a file rather than environment variables on purpose: an app
launched from Finder or launchd doesn't inherit your shell, so `export` wouldn't
reach it.

### 3. Build the endpoint

`examples/nextjs-route.ts` is a complete, production-ready Next.js route handler
backed by Upstash Redis — drop it in at `app/api/presence/route.ts`. It needs:

```
UPSTASH_REDIS_REST_URL=
UPSTASH_REDIS_REST_TOKEN=
PRESENCE_SECRET=          # must match your config.json
```

`POST` is bearer-authenticated against `PRESENCE_SECRET`; `GET` is public and
returns:

```json
{ "status": "online", "app": "Ghostty", "lastSeen": null }
{ "status": "idle",   "app": null,      "lastSeen": null }
{ "status": "offline","app": null,      "lastSeen": 1788647314719 }
```

`lastSeen` is a raw epoch, not a formatted string, so the client can render it
in the visitor's own clock and it stays correct as their tab ages.

Two details worth keeping if you write your own backend:

- **Store liveness and last-seen in one key.** Deriving "online" from the age of
  a timestamp, rather than from whether a key exists, means one command per read
  and per write instead of two. On a per-command biller that halves your spend.
- **Cache the read.** Read volume scales with your traffic, which you don't
  control. The example caches for 30 seconds, which caps reads at roughly 86k
  commands/month regardless of how much traffic arrives. Note this cache is
  per serverless instance — if you expect real spikes, cache at the CDN edge
  with `s-maxage` so most reads never reach your function.

### 4. Render it

Any client that polls `GET /api/presence` will do. A React example:

```tsx
const { data } = useSWR("/api/presence", fetcher, { refreshInterval: 30_000 });

// data: { status: "online" | "idle" | "offline", app, lastSeen }
```

There's no point polling faster than your server-side cache.

### 5. Keep it running

To start it at login, copy the example agent, edit the path inside it if you
installed elsewhere, and load it:

```bash
cp examples/my.dann.presence.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$UID ~/Library/LaunchAgents/my.dann.presence.plist
```

It sets `RunAtLoad` but deliberately **not** `KeepAlive`: with `KeepAlive`,
launchd would relaunch the app the instant you hit Quit or switched
broadcasting off, so you could never go dark.

Useful commands:

```bash
launchctl kickstart -k gui/$UID/my.dann.presence   # restart (after a rebuild)
launchctl bootout gui/$UID/my.dann.presence        # stop and unload
```

## Privacy

`app` broadcasts the name of your frontmost application to anyone loading your
site — including, say, a banking app or a notes app with a revealing name. The
idle case is already suppressed, but if that bothers you, either drop the field
from `beat()` or add an allowlist of apps worth reporting.

The menubar toggle switches broadcasting off and immediately marks you offline,
if you want a quick way out.

## Troubleshooting

The menubar reports the real state, so read it first:

| Menubar says                                  | Meaning                                        |
| --------------------------------------------- | ---------------------------------------------- |
| `No config at ~/.config/presence/config.json` | Missing, empty, or malformed config            |
| `Rejected — check the secret`                 | 401 — `secret` doesn't match `PRESENCE_SECRET` |
| `Error 404`                                   | The endpoint isn't deployed at that URL        |
| `Unreachable`                                 | No network, or the host is down                |
| `Online` / `Idle`                             | Working                                        |

Running `Presence` from a terminal appears to hang. It hasn't — a menubar app
runs an AppKit event loop that never returns. Use `&` if you want your prompt
back.

## Licence

MIT
