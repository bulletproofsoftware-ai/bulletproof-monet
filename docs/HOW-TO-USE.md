# Monet — How To Use

Monet is used conversationally over **Telegram**. You send it a message; it runs a
Claude Code session with your persistent memory injected, and replies in the same
channel. Slash commands trigger specific behaviours.

## Talking to Monet

Just send a message. Monet:

- recalls relevant memories before answering,
- keeps conversation context within a session (5-minute inactivity starts a new one),
- stores preferences and facts you share so they're available next time.

Telegram messages can include **images** (analyzed and auto-tagged by type — receipt,
whiteboard, business card, document, screenshot, note), **documents**, and
**locations**. Voice notes are *not* transcribed: this build ships no speech-to-text
backend (see [Known gaps](../README.md#known-gaps)). A voice note sent with a caption
is answered from the caption.

## Slash commands

Monet's command surface is **deny by default**: these 17 commands are the whole of
it. The list lives in exactly two places, `scripts/tg-register-commands.sh` and the
`/help` handler in `bridges/monet-tg.sh`, and they are kept in sync with each other.
Anything you type that is not on this list is treated as ordinary conversation.

### Conversation
| Command | Description |
|---------|-------------|
| `/help` | Show all commands. |
| `/new` | Start a fresh conversation. |
| `/export` | Export the current session summary. |

### Reminders
| Command | Description |
|---------|-------------|
| `/remind <time> <msg>` | Set a reminder (echoes the message when due). |
| `/reminders` | List pending reminders. |

### Clips and bookmarks
| Command | Description |
|---------|-------------|
| `/clip <tag> <content>` | Save a snippet under a tag. |
| `/clips [tag]` | List saved clips, optionally filtered by tag. |
| `/find <query>` | Semantic search across your clips. |
| `/mark <label>` | Bookmark the current moment in the conversation. |
| `/marks` | List all bookmarks. |
| `/recall <label>` | Search bookmarks by label. |

### Search and memory
| Command | Description |
|---------|-------------|
| `/search <query>` | Unified search across your local data. |
| `/memory-stats` | Qdrant collection point counts. |
| `/memory-export` | Back up all Qdrant collections. |

### Utilities
| Command | Description |
|---------|-------------|
| `/ss <url>` | Screenshot a URL. |
| `/photo-log` | View auto-archived photo analyses. |
| `/usage` | Token-usage summary (7 days). |

> Everything here runs against your own machine and your own data. Monet bundles no
> external content providers, so there are no news, weather or external-feed commands
> to configure and no third-party API keys to obtain.

## Reminders vs. scheduled jobs

- **`/remind`** simply re-sends a fixed message at a due time.
- **Scheduled jobs** actually re-run a prompt through Monet on a recurrence (for example
  a daily threat brief) and deliver the freshly generated result. Ask Monet in natural
  language ("every weekday at 7am send me a threat-intel brief") and it will set one up,
  then tell you the next run time.

## Memory

Monet's memory is automatic — you don't have to manage it — but you can:

- share a fact/preference and it will be stored,
- correct it later (corrections are prioritized on recall),
- ask "why did we decide X?" to retrieve logged decisions,
- run `/memory-stats` to see collection sizes or `/memory-export` to back it up.

## Agent personas (server-side, optional)

`bin/ask-agent` dispatches to persona definitions in `$MONET_AGENTS_DIR`. **No personas
are bundled** — point that variable at your own directory of agent markdown files, or
leave it unset and the tool is a no-op. Nothing in the Telegram command surface depends
on it.

```bash
ask-agent ciso "review this architecture"
ASK_MODEL=opus ask-agent ciso "deep security review"   # override the model
```

---

Apache-2.0 © 2026 bulletproofsoftware-ai. See [LICENSE](../LICENSE) and [NOTICE](../NOTICE).
