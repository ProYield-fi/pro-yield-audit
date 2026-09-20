#!/usr/bin/env bash
# Anvil with state persistence — keeps deployed vault contracts across restarts.
# Usage: start_anvil.sh   (run at boot or after any anvil crash)
STATE=/home/user/hypervault/anvil_state.json
ARGS="--port 8545 --chain-id 998"
if [ -s "$STATE" ]; then
  ARGS="$ARGS --load-state $STATE --dump-state $STATE"
fi
nohup /home/user/.config/.foundry/bin/anvil $ARGS > /home/user/hypervault/anvil.log 2>&1 &
echo "anvil starting (pid $!) - log: /home/user/hypervault/anvil.log"
