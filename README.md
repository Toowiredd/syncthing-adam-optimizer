# Syncthing Adam Optimizer

Adaptive Syncthing bandwidth governor using the Adam optimizer principle — exponential moving averages of system metrics with variance tracking to dynamically adjust sync speeds.

**Aggressive when idle. Invisible when working.**

## How It Works

Every 30 seconds via systemd timer:

1. **Sample** CPU%, RAM%, load avg, GPU%, disk I/O
2. **First moment** (β₁=0.7): Exponential moving average of each metric (momentum)
3. **Second moment** (β₂=0.9): Variance tracking — detects sudden spikes
4. **Busyness score** (0-100): Weighted composite of all metrics + volatility
5. **Map to tier** → adjust Syncthing bandwidth via REST API

| Score | Tier | Bandwidth | Behavior |
|-------|------|-----------|----------|
| ≤15 | idle | Unlimited | Full speed sync + cache cleanup |
| 16-35 | light | 50 Mbps | Normal work |
| 36-55 | moderate | 10 Mbps | Active dev |
| 56-75 | heavy | 2 Mbps | Compilation/inference |
| 76+ | crush | **Paused** | System maxed — zero sync I/O |

## Requirements

- Syncthing with HTTPS API enabled
- `nvidia-smi` (optional, for GPU metric)
- `curl`, `awk`, `python3`
- systemd (user timer)

## Install

```bash
cp syncthing-adam-optimizer.sh ~/bin/
chmod +x ~/bin/syncthing-adam-optimizer.sh

# Install systemd timer
cp systemd/syncthing-adam.service ~/.config/systemd/user/
cp systemd/syncthing-adam.timer ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now syncthing-adam.timer
```

## Monitor

```bash
# Live log
tail -f /tmp/syncthing-adam-optimizer.log

# Tier changes only
journalctl --user -t syncthing-adam-optimizer

# Current state
cat /tmp/syncthing-adam-optimizer-state
```

## Tuning

Edit the hyperparameters in the script:
- `BETA1=0.7` — momentum decay (higher = smoother, slower to react)
- `BETA2=0.9` — variance decay (higher = smoother volatility estimate)
- Tier thresholds and bandwidth limits in the score-to-tier mapping
