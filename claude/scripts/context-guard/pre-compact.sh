#!/bin/bash
# Context Guard - PreCompact Handler
# Fires right before compaction (auto or manual).
# Cleans up ALL state files since context is about to reset.

rm -f /tmp/.claude-context-guard
rm -f /tmp/.claude-context-guard-notified
rm -f /tmp/.claude-context-counter

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Compaction triggered" >> /tmp/.claude-context-guard.log

exit 0
