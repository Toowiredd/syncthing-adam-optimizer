#!/bin/bash
# syncthing-adam-optimizer.sh v2
# True Adam optimizer: first moment (EMA) + second moment (variance)
# Adaptive Syncthing bandwidth based on system busyness
# Includes disk I/O metric, pause on crush, cache cleanup on idle

API_KEY=$(grep -oP '(?<=<apikey>).*(?=</apikey>)' ~/.local/state/syncthing/config.xml)
API="https://localhost:8384"
STATE_FILE="/tmp/syncthing-adam-optimizer-state"
LOG_FILE="/tmp/syncthing-adam-optimizer.log"

# === HYPERPARAMETERS (tune these) ===
BETA1="0.7"   # First moment decay (momentum)
BETA2="0.9"   # Second moment decay (variance tracking)
EPSILON="1"   # Prevents division by zero in variance

# === GATHER METRICS ===
CPU_PCT=$(grep 'cpu ' /proc/stat | awk '{usage=($2+$4)*100/($2+$4+$5); printf "%.0f", usage}')
RAM_PCT=$(free | awk '/Mem:/{printf "%.0f", ($3/$2)*100}')
LOAD_1M=$(awk '{printf "%.0f", $1}' /proc/loadavg)
GPU_PCT=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null || echo 0)
# Disk I/O: reads+writes per second from /proc/diskstats (all disks)
IO_OPS=$(awk '{r+=$4; w+=$8} END{printf "%.0f", (r+w)/NR}' /proc/diskstats 2>/dev/null || echo 0)

# === INIT STATE ===
M1_CPU=$CPU_PCT; M1_RAM=$RAM_PCT; M1_LOAD=$LOAD_1M; M1_GPU=$GPU_PCT; M1_IO=$IO_OPS
M2_CPU=0; M2_RAM=0; M2_LOAD=0; M2_GPU=0; M2_IO=0
PREV_TIER="unknown"; PREV_IO=$IO_OPS

# === LOAD PREVIOUS STATE ===
[ -f "$STATE_FILE" ] && source "$STATE_FILE"

# === ADAM UPDATE: First moment (mean) ===
M1_CPU=$(awk "BEGIN{printf \"%.1f\", $BETA1 * $M1_CPU + (1-$BETA1) * $CPU_PCT}")
M1_RAM=$(awk "BEGIN{printf \"%.1f\", $BETA1 * $M1_RAM + (1-$BETA1) * $RAM_PCT}")
M1_LOAD=$(awk "BEGIN{printf \"%.1f\", $BETA1 * $M1_LOAD + (1-$BETA1) * $LOAD_1M}")
M1_GPU=$(awk "BEGIN{printf \"%.1f\", $BETA1 * $M1_GPU + (1-$BETA1) * $GPU_PCT}")
M1_IO=$(awk "BEGIN{printf \"%.1f\", $BETA1 * $M1_IO + (1-$BETA1) * $IO_OPS}")

# === ADAM UPDATE: Second moment (variance — detects spikes) ===
M2_CPU=$(awk "BEGIN{printf \"%.1f\", $BETA2 * $M2_CPU + (1-$BETA2) * ($CPU_PCT - $M1_CPU)^2}")
M2_RAM=$(awk "BEGIN{printf \"%.1f\", $BETA2 * $M2_RAM + (1-$BETA2) * ($RAM_PCT - $M1_RAM)^2}")
M2_LOAD=$(awk "BEGIN{printf \"%.1f\", $BETA2 * $M2_LOAD + (1-$BETA2) * ($LOAD_1M - $M1_LOAD)^2}")
M2_GPU=$(awk "BEGIN{printf \"%.1f\", $BETA2 * $M2_GPU + (1-$BETA2) * ($GPU_PCT - $M1_GPU)^2}")

# === SPIKE DETECTION: High variance = system is volatile, be cautious ===
VOLATILITY=$(awk "BEGIN{
    v = sqrt($M2_CPU + $EPSILON) + sqrt($M2_RAM + $EPSILON) + sqrt($M2_LOAD + $EPSILON) + sqrt($M2_GPU + $EPSILON)
    printf \"%.0f\", v
}")

# === CALCULATE BUSYNESS SCORE (0-100) ===
# Weighted: CPU 25%, RAM 20%, Load 20%, GPU 15%, I/O 10%, Volatility 10%
SCORE=$(awk "BEGIN{
    cpu_norm = ($M1_CPU / 100) * 25
    ram_norm = ($M1_RAM / 100) * 20
    load_cap = $M1_LOAD > 16 ? 16 : $M1_LOAD
    load_norm = (load_cap / 16) * 20
    gpu_norm = ($M1_GPU / 100) * 15
    io_cap = $M1_IO > 10000 ? 10000 : $M1_IO
    io_norm = (io_cap / 10000) * 10
    vol_cap = $VOLATILITY > 50 ? 50 : $VOLATILITY
    vol_norm = (vol_cap / 50) * 10
    printf \"%.0f\", cpu_norm + ram_norm + load_norm + gpu_norm + io_norm + vol_norm
}")

# === MAP SCORE TO TIER ===
if [ "$SCORE" -le 15 ]; then
    TIER="idle"; SEND=0; RECV=0
elif [ "$SCORE" -le 35 ]; then
    TIER="light"; SEND=50000; RECV=50000
elif [ "$SCORE" -le 55 ]; then
    TIER="moderate"; SEND=10000; RECV=10000
elif [ "$SCORE" -le 75 ]; then
    TIER="heavy"; SEND=2000; RECV=2000
else
    TIER="crush"; SEND=0; RECV=0  # Will pause instead
fi

# === APPLY (only if tier changed) ===
if [ "$TIER" != "$PREV_TIER" ]; then
    if [ "$TIER" = "crush" ]; then
        # Pause all folders instead of throttling
        for folder_id in $(curl -sk -H "X-API-Key:$API_KEY" "$API/rest/config/folders" 2>/dev/null | python3 -c "import sys,json; [print(f['id']) for f in json.load(sys.stdin)]" 2>/dev/null); do
            curl -sk -H "X-API-Key:$API_KEY" -X PATCH -H "Content-Type: application/json" \
                -d "{\"paused\":true}" "$API/rest/config/folders/$folder_id" >/dev/null 2>&1
        done
        logger -t syncthing-adam-optimizer "PAUSED: Score $SCORE (crush tier)"
    elif [ "$PREV_TIER" = "crush" ]; then
        # Resume from pause
        for folder_id in $(curl -sk -H "X-API-Key:$API_KEY" "$API/rest/config/folders" 2>/dev/null | python3 -c "import sys,json; [print(f['id']) for f in json.load(sys.stdin)]" 2>/dev/null); do
            curl -sk -H "X-API-Key:$API_KEY" -X PATCH -H "Content-Type: application/json" \
                -d "{\"paused\":false}" "$API/rest/config/folders/$folder_id" >/dev/null 2>&1
        done
        curl -sk -H "X-API-Key:$API_KEY" -X PATCH -H "Content-Type: application/json" \
            -d "{\"maxSendKbps\":$SEND,\"maxRecvKbps\":$RECV}" "$API/rest/config/options" >/dev/null 2>&1
        logger -t syncthing-adam-optimizer "RESUMED: Score $SCORE -> $TIER"
    else
        curl -sk -H "X-API-Key:$API_KEY" -X PATCH -H "Content-Type: application/json" \
            -d "{\"maxSendKbps\":$SEND,\"maxRecvKbps\":$RECV}" "$API/rest/config/options" >/dev/null 2>&1
    fi
    logger -t syncthing-adam-optimizer "Tier: $PREV_TIER -> $TIER | Score:$SCORE Vol:$VOLATILITY"
fi

# === IDLE BONUS: Clean caches when system is idle ===
if [ "$TIER" = "idle" ] && [ "$PREV_TIER" != "idle" ]; then
    # Just entered idle — good time for maintenance
    npm cache clean --force >/dev/null 2>&1
    logger -t syncthing-adam-optimizer "IDLE: ran cache cleanup"
fi

# === SAVE STATE ===
cat > "$STATE_FILE" << EOF
M1_CPU=$M1_CPU
M1_RAM=$M1_RAM
M1_LOAD=$M1_LOAD
M1_GPU=$M1_GPU
M1_IO=$M1_IO
M2_CPU=$M2_CPU
M2_RAM=$M2_RAM
M2_LOAD=$M2_LOAD
M2_GPU=$M2_GPU
PREV_TIER=$TIER
PREV_IO=$IO_OPS
EOF

# === LOG ===
echo "$(date '+%H:%M:%S') score=$SCORE tier=$TIER vol=$VOLATILITY cpu=${M1_CPU}% ram=${M1_RAM}% load=${M1_LOAD} gpu=${M1_GPU}% io=${M1_IO} send=${SEND}kbps" >> "$LOG_FILE"
tail -1000 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
