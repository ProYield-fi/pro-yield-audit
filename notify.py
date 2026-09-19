#!/usr/bin/env python3
"""ProYield Alert Notifier — delivers rate alerts to Telegram.

The 5-min rate_monitor writes rate_alerts.json; until now NOTHING read it.
This script (cron */5) picks up new HIGH/MEDIUM alerts and pushes them to
Telegram. If credentials aren't configured, alerts queue to
data/pending_notifications.log so nothing is silently lost.

Setup (one time):
  1. Create a bot with @BotFather -> get token
  2. Message the bot once, then get your chat id:
       curl "https://api.telegram.org/bot<TOKEN>/getUpdates" | python3 -m json.tool
  3. Save to ~/.hermes/secrets/telegram.json:
       {"bot_token": "<TOKEN>", "chat_id": "<CHAT_ID>"}
     (chmod 600. Env vars TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID also work.)
"""
import json, os, sys, urllib.request

YIELD = "/home/user/yield_scout"
DATA = os.path.join(YIELD, "data")
ALERTS = os.path.join(DATA, "rate_alerts.json")
STATE = os.path.join(DATA, "notifier_state.json")
QUEUE = os.path.join(DATA, "pending_notifications.log")
SECRETS = os.path.expanduser("~/.hermes/secrets/telegram.json")

MIN_SEVERITY = {"HIGH": 3, "MEDIUM": 2, "LOW": 1}
NOTIFY_AT_OR_ABOVE = 2  # MEDIUM+


def creds():
    tok = os.environ.get("TELEGRAM_BOT_TOKEN")
    chat = os.environ.get("TELEGRAM_CHAT_ID")
    if tok and chat:
        return tok, chat
    if os.path.exists(SECRETS):
        with open(SECRETS) as f:
            d = json.load(f)
        return d.get("bot_token"), d.get("chat_id")
    return None, None


def send_telegram(token, chat_id, text):
    body = json.dumps({"chat_id": chat_id, "text": text,
                       "parse_mode": "HTML"}).encode()
    req = urllib.request.Request(
        f"https://api.telegram.org/bot{token}/sendMessage",
        data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=15) as r:
        return r.status == 200


def fmt(alert):
    emoji = "🔴" if alert.get("severity") == "HIGH" else "🟡"
    return (f"{emoji} <b>{alert.get('category','?')}</b> — {alert.get('symbol','?')}"
            f" ({alert.get('project','?')})\n"
            f"  snapshot: {alert.get('snapshot_apy')}% → live: {alert.get('live_apy')}%"
            f"  ({alert.get('direction')}, {alert.get('delta_bps')}bps)\n"
            f"  severity: {alert.get('severity')} · blend at snapshot: {alert.get('blend_at_snapshot')}%")


def main():
    if not os.path.exists(ALERTS):
        return
    with open(ALERTS) as f:
        alerts = json.load(f)

    seen = set()
    first_run = not os.path.exists(STATE)
    if not first_run:
        with open(STATE) as f:
            seen = set(json.load(f).get("seen_ids", []))

    # id = timestamp+category+symbol (timestamps are microsecond-unique from monitor)
    def aid(a):
        return f"{a.get('timestamp')}|{a.get('category')}|{a.get('symbol')}"

    if first_run:
        # First deploy: mark existing history seen — never backfill-spam the channel.
        with open(STATE, "w") as f:
            json.dump({"seen_ids": sorted(set(aid(a) for a in alerts[-200:]))}, f)
        print("notifier: first run — existing alert history marked seen (no backfill)")
        return

    fresh = [a for a in alerts
             if aid(a) not in seen
             and MIN_SEVERITY.get(a.get("severity"), 0) >= NOTIFY_AT_OR_ABOVE]
    if not fresh:
        # prune seen set so it doesn't grow forever
        keep = set(aid(a) for a in alerts[-200:])
        with open(STATE, "w") as f:
            json.dump({"seen_ids": sorted(keep)}, f)
        return

    tok, chat = creds()
    delivered = 0
    if tok and chat:
        for a in fresh[:5]:  # cap burst
            try:
                if send_telegram(tok, chat, fmt(a)):
                    delivered += 1
                    seen.add(aid(a))
            except Exception as e:
                with open(QUEUE, "a") as q:
                    q.write(json.dumps({"ts": a.get("timestamp"), "error": str(e),
                                        "alert": a}) + "\n")
        print(f"notifier: sent {delivered}/{len(fresh)} alerts")
    else:
        for a in fresh:
            with open(QUEUE, "a") as q:
                q.write(json.dumps(a) + "\n")
        print(f"notifier: Telegram not configured — queued {len(fresh)} alerts to "
              f"{QUEUE} (setup: see script docstring)")
        seen.update(aid(a) for a in fresh)

    keep = set(aid(a) for a in alerts[-200:]) | seen
    with open(STATE, "w") as f:
        json.dump({"seen_ids": sorted(keep)}, f)


if __name__ == "__main__":
    main()
