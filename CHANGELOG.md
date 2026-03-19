# Changelog

## [2.0.0] - 2026-03-20

### Added
- Second moment (variance) tracking — true Adam optimizer, not just EMA
- Disk I/O metric (`/proc/diskstats`) as 6th input signal
- Volatility score from variance — detects system spikes, reacts faster
- Pause/resume folders on crush tier (zero I/O, not just throttled)
- Idle-triggered cache cleanup (npm cache clean when system goes idle)
- Weighted scoring: CPU 25%, RAM 20%, Load 20%, GPU 15%, I/O 10%, Volatility 10%

### Changed
- Renamed from `syncthing-adam-governor` to `syncthing-adam-optimizer`
- State file tracks M1 (mean) and M2 (variance) for all metrics
- β₁=0.7 (momentum), β₂=0.9 (variance) — configurable hyperparameters

## [1.0.0] - 2026-03-19

### Added
- Initial implementation with first moment (EMA) only
- 4 metrics: CPU, RAM, load avg, GPU
- 5 tiers: idle, light, moderate, heavy, crush
- Syncthing REST API integration (bandwidth adjustment)
- systemd user timer (30s interval)
- Log rotation (1000 lines max)
- syslog integration for tier changes
