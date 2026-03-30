#!/usr/bin/env bash
# 3-node relay simulation with RLN spam protection via logos-core.
# Runs nodes, sends messages, verifies proofs are generated and validated.
# Exit code 0 = all checks pass, 1 = verification failed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DELIVERY_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
RLN_PROJECT_DIR="$(cd "$DELIVERY_DIR/.." && pwd)"

export RISC0_DEV_MODE=1
export TMPDIR=/tmp

die() { echo "  FATAL: $*" >&2; exit 1; }
log() { echo "[$(date '+%H:%M:%S')] $*"; }

# --- Node identity constants ---
NODEKEYS=(
    "f98e3fba96c32e8d1967d460f1b79457380e1a895f7971cecc8528abe733781a"
    "09e9d134331953357bd38bbfce8edb377f4b6308b4f3bfbe85c610497053d684"
    "ed54db994682e857d77cd6fb81be697382dc43aa5cd78e16b0ec8098549f860e"
)
PEER_IDS=(
    "16Uiu2HAmPiEs2ozjjJF2iN2Pe2FYeMC9w4caRHKYdLdAfjgbWM6o"
    "16Uiu2HAmLtKaFaSWDohToWhWUZFLtqzYZGPFuXwKrojFVF6az5UF"
    "16Uiu2HAmTEDHwAziWUSz6ZE23h5vxG2o4Nn7GazhMor4bVuMXTrA"
)
NUM_NODES=3
BASE_TCP_PORT=60001
BASE_DISC_PORT=9001
CONTENT_TOPIC="/relay-rln-test/1/test/proto"

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) PLATFORM="darwin-arm64-dev"; EXT="dylib";;
  Linux-x86_64) PLATFORM="linux-x86_64-dev"; EXT="so";;
  Linux-aarch64) PLATFORM="linux-aarch64-dev"; EXT="so";;
  *) die "Unsupported platform";;
esac

# --- State ---
STATE_DIR="$SCRIPT_DIR/.sim_state"
FRESH=0
for arg in "$@"; do [ "$arg" = "--fresh" ] && FRESH=1; done
[ "$FRESH" -eq 1 ] && rm -rf "$STATE_DIR"
mkdir -p "$STATE_DIR"

SEQUENCER_PID=""
OWN_SEQUENCER=0
INSTANCE_PIDS=()
MODULES_DIRS=()
EXIT_CODE=0

cleanup() {
    set +u
    echo ""
    echo "=== Shutting down ==="
    for pid in "${INSTANCE_PIDS[@]+"${INSTANCE_PIDS[@]}"}"; do
        [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    done
    pkill -f 'logos_host' 2>/dev/null || true
    if [ "$OWN_SEQUENCER" -eq 1 ] && [ -n "$SEQUENCER_PID" ]; then
        kill "$SEQUENCER_PID" 2>/dev/null || true
    fi
    for mdir in "${MODULES_DIRS[@]+"${MODULES_DIRS[@]}"}"; do
        [ -n "$mdir" ] && rm -rf "$mdir"
    done
    echo "  Logs: $STATE_DIR"
    echo "Done."
    exit "$EXIT_CODE"
}
trap cleanup EXIT

echo "=== Relay RLN Simulation (3 nodes) ==="
echo "  RLN project: $RLN_PROJECT_DIR"
echo ""

pkill -f 'logos_host' 2>/dev/null || true
sleep 1

# ---------- Phase 1: Sequencer ----------
echo "[1/6] Sequencer..."
(cd "$RLN_PROJECT_DIR" && git submodule update --init lssa 2>/dev/null || true)

if nc -z 127.0.0.1 3040 2>/dev/null && [ "$FRESH" -eq 0 ]; then
    SEQUENCER_PID=$(lsof -ti tcp:3040 2>/dev/null || true)
    echo "  Already running (PID $SEQUENCER_PID)"
else
    if nc -z 127.0.0.1 3040 2>/dev/null; then
        kill "$(lsof -ti tcp:3040 2>/dev/null)" 2>/dev/null || true; sleep 1
    fi
    rm -rf "$RLN_PROJECT_DIR/lssa/rocksdb"
    log "  Building sequencer..."
    (cd "$RLN_PROJECT_DIR/lssa" && cargo build --features standalone -p sequencer_runner 2>&1 | tail -3) || die "sequencer build failed"
    (cd "$RLN_PROJECT_DIR/lssa" && env RUST_LOG=info ./target/debug/sequencer_runner sequencer_runner/configs/debug) >/dev/null 2>&1 &
    SEQUENCER_PID=$!; OWN_SEQUENCER=1
    echo "  PID: $SEQUENCER_PID"
    for _ in $(seq 1 60); do nc -z 127.0.0.1 3040 2>/dev/null && break; sleep 1; done
    nc -z 127.0.0.1 3040 2>/dev/null || die "Sequencer failed to start"
    log "  Ready."
fi

# ---------- Phase 2: Deploy + Register ----------
echo "[2/6] Programs + members..."
LEZ_RLN_DIR="$RLN_PROJECT_DIR/lez-rln"
export NSSA_WALLET_HOME_DIR="$RLN_PROJECT_DIR/dev"
export WALLET_CONFIG="$NSSA_WALLET_HOME_DIR/wallet_config.json"
export WALLET_STORAGE="$NSSA_WALLET_HOME_DIR/storage.json"

TREE_MAIN_FILE="$STATE_DIR/tree_main_account"
MANIFEST_FILE="$STATE_DIR/manifest.json"

if [ -f "$TREE_MAIN_FILE" ] && [ -f "$MANIFEST_FILE" ] && [ "$FRESH" -eq 0 ]; then
    CONFIG_ACCOUNT=$(python3 -c "import json; print(json.load(open('$MANIFEST_FILE'))[0]['configAccount'])" 2>/dev/null)
    echo "  Reusing existing state (config: $CONFIG_ACCOUNT)"
else
    rm -f "$WALLET_CONFIG" "$WALLET_STORAGE"
    SETUP_OUTPUT=$(cd "$LEZ_RLN_DIR" && cargo run --bin run_setup 2>&1) || die "run_setup failed"
    echo "$SETUP_OUTPUT" | tail -3

    REGISTER_BIN="$LEZ_RLN_DIR/target/release/register_member"
    (cd "$LEZ_RLN_DIR" && cargo build --release --bin register_member 2>&1 | tail -3)
    log "  Registering $NUM_NODES members..."
    REG_OUTPUT="$STATE_DIR/reg_output.txt"
    (cd "$LEZ_RLN_DIR" && "$REGISTER_BIN" --count "$NUM_NODES" > "$REG_OUTPUT" 2>&1) || die "register_member failed"

    echo "[" > "$MANIFEST_FILE"
    MEMBER_IDX=0
    while IFS= read -r line; do
        case "$line" in
            CONFIG_ACCOUNT=*) [ "$MEMBER_IDX" -gt 0 ] && echo "," >> "$MANIFEST_FILE"
                CONFIG_ACCOUNT="${line#CONFIG_ACCOUNT=}"
                echo -n "  {\"configAccount\": \"$CONFIG_ACCOUNT\"" >> "$MANIFEST_FILE" ;;
            LEAF_INDEX=*) echo -n ", \"leafIndex\": ${line#LEAF_INDEX=}" >> "$MANIFEST_FILE" ;;
            IDENTITY_SECRET_HASH=*) echo ", \"identitySecretHash\": \"${line#IDENTITY_SECRET_HASH=}\", \"peerId\": \"${PEER_IDS[$MEMBER_IDX]}\"}" >> "$MANIFEST_FILE"
                echo "    Member $((MEMBER_IDX+1)): leaf=${line#IDENTITY_SECRET_HASH=}" | head -c 40; echo
                MEMBER_IDX=$((MEMBER_IDX + 1)) ;;
        esac
    done < "$REG_OUTPUT"
    echo "]" >> "$MANIFEST_FILE"
    echo "$CONFIG_ACCOUNT" > "$TREE_MAIN_FILE"
    log "  $MEMBER_IDX members registered. Config: $CONFIG_ACCOUNT"
fi

# Parse manifest
LEAF_INDICES=()
ID_SECRET_HASHES=()
for i in $(seq 0 $((NUM_NODES - 1))); do
    LEAF_INDICES+=($(python3 -c "import json; print(json.load(open('$MANIFEST_FILE'))[$i]['leafIndex'])" 2>/dev/null))
    ID_SECRET_HASHES+=($(python3 -c "import json; print(json.load(open('$MANIFEST_FILE'))[$i]['identitySecretHash'])" 2>/dev/null))
done
CONFIG_ACCOUNT=$(python3 -c "import json; print(json.load(open('$MANIFEST_FILE'))[0]['configAccount'])" 2>/dev/null)

# ---------- Phase 3: Check modules ----------
echo "[3/6] Modules..."
LOGOSCORE="${LOGOSCORE:-$(nix build github:logos-co/logos-liblogos/7df6195 --override-input logos-cpp-sdk github:logos-co/logos-cpp-sdk/a4bd66c --no-link --print-out-paths)/bin/logoscore}"
WALLET_MODULE_RESULT="$RLN_PROJECT_DIR/logos-rln-module/result-wallet"

for check in \
    "$RLN_PROJECT_DIR/logos-rln-module/result-rln/lib/liblogos_rln_module.$EXT" \
    "$WALLET_MODULE_RESULT/lib/liblogos_execution_zone_wallet_module.$EXT" \
    "$RLN_PROJECT_DIR/logos-delivery-module/result/lib/delivery_module_plugin.$EXT"; do
    [ -f "$check" ] || { log "  Missing: $check — run build_modules.sh first"; die "Modules not built"; }
done
log "  All modules present."

# ---------- Phase 4: Stage + Start nodes ----------
echo "[4/6] Starting $NUM_NODES relay nodes..."

LOAD_ORDER="liblogos_execution_zone_wallet_module,liblogos_rln_module,delivery_module,mix_simulation_module"
WALLET_CALL="liblogos_execution_zone_wallet_module.open($WALLET_CONFIG,$WALLET_STORAGE)"

for i in $(seq 0 $((NUM_NODES - 1))); do
    TCP_PORT=$((BASE_TCP_PORT + i))
    DISC_PORT=$((BASE_DISC_PORT + i))
    LEAF_INDEX="${LEAF_INDICES[$i]}"
    ID_SECRET_HASH="${ID_SECRET_HASHES[$i]}"
    NODE_CONFIG="$STATE_DIR/node${i}_config.json"
    LOG_FILE="$STATE_DIR/node${i}.log"

    ENTRY_NODES="[]"
    [ "$i" -gt 0 ] && ENTRY_NODES="[\"/ip4/127.0.0.1/tcp/$BASE_TCP_PORT/p2p/${PEER_IDS[0]}\"]"

    cat > "$NODE_CONFIG" <<EOF
{
  "clusterId": 42,
  "numShardsInNetwork": 8,
  "entryNodes": $ENTRY_NODES,
  "maxMessageSize": "150 KiB",
  "listenAddress": "127.0.0.1",
  "tcpPort": $TCP_PORT,
  "discv5UdpPort": $DISC_PORT,
  "nodekey": "${NODEKEYS[$i]}",
  "relay": true,
  "rlnRelay": true,
  "rlnRelayLogosCore": true,
  "rlnRelayIdentitySecretHash": "$ID_SECRET_HASH",
  "rlnRelayCredIndex": $LEAF_INDEX,
  "rlnRelayUserMessageLimit": 100,
  "rlnEpochSizeSec": 10,
  "enableSpamProtection": false,
  "peerExchange": false,
  "rendezvous": false,
  "colocationLimit": 0,
  "logLevel": "TRACE"
}
EOF

    # Stage modules
    MDIR=$(mktemp -d)
    MODULES_DIRS+=("$MDIR")

    mkdir -p "$MDIR/liblogos_execution_zone_wallet_module"
    cp -L "$WALLET_MODULE_RESULT/lib/liblogos_execution_zone_wallet_module.$EXT" "$MDIR/liblogos_execution_zone_wallet_module/"
    [ -f "$WALLET_MODULE_RESULT/lib/libwallet_ffi.$EXT" ] && \
      cp -L "$WALLET_MODULE_RESULT/lib/libwallet_ffi.$EXT" "$MDIR/liblogos_execution_zone_wallet_module/"
    echo "{\"name\":\"liblogos_execution_zone_wallet_module\",\"version\":\"1.0.0\",\"type\":\"core\",\"main\":{\"$PLATFORM\":\"liblogos_execution_zone_wallet_module.$EXT\"},\"dependencies\":[],\"capabilities\":[]}" > "$MDIR/liblogos_execution_zone_wallet_module/manifest.json"

    mkdir -p "$MDIR/liblogos_rln_module"
    cp -L "$RLN_PROJECT_DIR/logos-rln-module/result-rln/lib/liblogos_rln_module.$EXT" "$MDIR/liblogos_rln_module/"
    cp -L "$RLN_PROJECT_DIR/logos-rln-module/result-rln/lib/liblez_rln_ffi.$EXT" "$MDIR/liblogos_rln_module/" 2>/dev/null || true
    echo "{\"name\":\"liblogos_rln_module\",\"version\":\"1.0.0\",\"type\":\"core\",\"main\":{\"$PLATFORM\":\"liblogos_rln_module.$EXT\"},\"dependencies\":[\"liblogos_execution_zone_wallet_module\"],\"capabilities\":[]}" > "$MDIR/liblogos_rln_module/manifest.json"

    if [ -d "$RLN_PROJECT_DIR/mix-simulation-module/result/lib" ]; then
        mkdir -p "$MDIR/mix_simulation_module"
        cp -L "$RLN_PROJECT_DIR/mix-simulation-module/result/lib/libmix_simulation_module.$EXT" "$MDIR/mix_simulation_module/"
        echo "{\"name\":\"mix_simulation_module\",\"version\":\"1.0.0\",\"type\":\"core\",\"main\":{\"$PLATFORM\":\"libmix_simulation_module.$EXT\"},\"dependencies\":[\"delivery_module\",\"liblogos_rln_module\"],\"capabilities\":[]}" > "$MDIR/mix_simulation_module/manifest.json"
    fi

    mkdir -p "$MDIR/delivery_module"
    cp -L "$RLN_PROJECT_DIR/logos-delivery-module/result/lib/delivery_module_plugin.$EXT" "$MDIR/delivery_module/"
    cp -L "$RLN_PROJECT_DIR/logos-delivery-module/result/lib/liblogosdelivery.$EXT" "$MDIR/delivery_module/" 2>/dev/null || true
    for pq in "$RLN_PROJECT_DIR"/logos-delivery-module/result/lib/libpq*; do [ -f "$pq" ] && cp -L "$pq" "$MDIR/delivery_module/"; done
    echo "{\"name\":\"delivery_module\",\"version\":\"1.0.0\",\"type\":\"core\",\"main\":{\"$PLATFORM\":\"delivery_module_plugin.$EXT\"},\"dependencies\":[],\"capabilities\":[]}" > "$MDIR/delivery_module/manifest.json"

    log "  Starting node $i (port $TCP_PORT, leaf $LEAF_INDEX)..."

    if [ "$i" -eq 0 ]; then
        RUNNER_CONFIG="$STATE_DIR/runner0_config.json"
        cat > "$RUNNER_CONFIG" <<REOF
{
  "delivery": $(cat "$NODE_CONFIG"),
  "contentTopic": "$CONTENT_TOPIC",
  "rln": {
    "configAccountId": "$CONFIG_ACCOUNT",
    "leafIndex": $LEAF_INDEX
  },
  "simulation": {
    "peerDiscoveryDelayMs": 60000,
    "messageCount": 10,
    "messageDelayMs": 5000,
    "payload": "relay-rln-test"
  }
}
REOF
        TMPDIR=/tmp "$LOGOSCORE" -m "$MDIR" -l "$LOAD_ORDER" \
            -c "$WALLET_CALL" \
            -c "mix_simulation_module.start(@$RUNNER_CONFIG)" \
            </dev/null >"$LOG_FILE" 2>&1 &
    else
        TMPDIR=/tmp "$LOGOSCORE" -m "$MDIR" -l "$LOAD_ORDER" \
            -c "$WALLET_CALL" \
            -c "delivery_module.createNode(@$NODE_CONFIG)" \
            -c "delivery_module.start()" \
            -c "delivery_module.subscribe($CONTENT_TOPIC)" \
            -c "delivery_module.setRlnConfig($CONFIG_ACCOUNT,$LEAF_INDEX)" \
            -c "liblogos_rln_module.start_root_broadcast($CONFIG_ACCOUNT)" \
            -c "liblogos_rln_module.start_merkle_proof_broadcast($CONFIG_ACCOUNT,$LEAF_INDEX)" \
            </dev/null >"$LOG_FILE" 2>&1 &
    fi
    INSTANCE_PIDS+=($!)
    echo "  Node $i PID: ${INSTANCE_PIDS[$i]}"

    # Wait for init
    EXPECTED_CALLS=7
    [ "$i" -eq 0 ] && EXPECTED_CALLS=2
    for t in $(seq 1 90); do
        N=$(grep -c '^Method call successful' "$LOG_FILE" 2>/dev/null || true); N=${N:-0}
        [ "$N" -ge "$EXPECTED_CALLS" ] && break
        sleep 1
    done
    if [ "${N:-0}" -lt "$EXPECTED_CALLS" ]; then
        echo "  WARNING: Node $i: $N/$EXPECTED_CALLS calls"
    else
        log "  Node $i ready ($N/$EXPECTED_CALLS calls)"
    fi

    sleep 5
done

# ---------- Phase 5: Wait for messages ----------
echo ""
echo "[5/6] Waiting for messages (node 0 sends after 60s delay + 10 msgs at 5s intervals)..."
echo ""

# Total wait: 60s peer discovery + 50s sending + 20s buffer = 130s
# Poll every 10s with progress
for tick in $(seq 1 13); do
    sleep 10
    TS=$(date '+%H:%M:%S')
    PROOFS=$(grep -c 'Proof generated successfully' "$STATE_DIR/node0.log" 2>/dev/null || true)
    PUBLISHED=$(grep -c 'Published message to peers' "$STATE_DIR/node0.log" 2>/dev/null || true)
    VALIDATED=0
    for i in 1 2; do
        V=$(grep -c 'message validity is verified' "$STATE_DIR/node${i}.log" 2>/dev/null || true)
        VALIDATED=$((VALIDATED + V))
    done
    echo "  [$TS] proofs_generated=$PROOFS published=$PUBLISHED validated_by_receivers=$VALIDATED"

    # Early exit once all messages sent and at least some validated
    [ "$PROOFS" -ge 10 ] && [ "$VALIDATED" -ge 1 ] && break
done

# ---------- Phase 6: Verify ----------
echo ""
echo "[6/6] Verification"
echo ""

PASS=0
FAIL=0

check() {
    local desc="$1" actual="$2" op="$3" expected="$4"
    case "$op" in
        -ge) if [ "$actual" -ge "$expected" ]; then
                echo "  PASS: $desc ($actual >= $expected)"
                PASS=$((PASS + 1))
             else
                echo "  FAIL: $desc ($actual < $expected)"
                FAIL=$((FAIL + 1))
             fi ;;
        -eq) if [ "$actual" -eq "$expected" ]; then
                echo "  PASS: $desc ($actual == $expected)"
                PASS=$((PASS + 1))
             else
                echo "  FAIL: $desc ($actual != $expected)"
                FAIL=$((FAIL + 1))
             fi ;;
    esac
}

# --- Node 0: sender ---
N0_PROOFS=$(grep -c 'Proof generated successfully' "$STATE_DIR/node0.log" 2>/dev/null || true)
N0_PUBLISHED=$(grep -c 'Published message to peers' "$STATE_DIR/node0.log" 2>/dev/null || true)
N0_PROPAGATED=$(grep -c 'message_propagated' "$STATE_DIR/node0.log" 2>/dev/null || true)
N0_RLN_FAIL=$(grep -c 'could not generate rln\|identity credentials not set\|no cached merkle proof' "$STATE_DIR/node0.log" 2>/dev/null || true)
N0_ROOTS=$(grep -c 'Polled valid roots\|Using cached roots' "$STATE_DIR/node0.log" 2>/dev/null || true)
N0_CREDS=$(grep -c 'Set RLN identity credentials from config' "$STATE_DIR/node0.log" 2>/dev/null || true)

echo "  --- Node 0 (sender) ---"
check "RLN identity credentials set" "$N0_CREDS" -ge 1
check "RLN proofs generated (10 messages)" "$N0_PROOFS" -ge 10
check "Messages published to gossipsub" "$N0_PUBLISHED" -ge 1
check "No RLN proof generation failures" "$N0_RLN_FAIL" -eq 0
check "Root fetching active" "$N0_ROOTS" -ge 1

# --- Receivers: at least one of node 1/2 must receive + validate ---
TOTAL_VALIDATED=0
TOTAL_RECEIVED=0
for i in 1 2; do
    V=$(grep -c 'message validity is verified' "$STATE_DIR/node${i}.log" 2>/dev/null || true)
    R=$(grep -c 'message_received' "$STATE_DIR/node${i}.log" 2>/dev/null || true)
    TOTAL_VALIDATED=$((TOTAL_VALIDATED + V))
    TOTAL_RECEIVED=$((TOTAL_RECEIVED + R))
done

echo ""
echo "  --- Receivers (nodes 1+2 combined) ---"
check "Messages received by at least one receiver" "$TOTAL_RECEIVED" -ge 1
check "RLN proofs validated on receivers" "$TOTAL_VALIDATED" -ge 1

# --- Per-receiver detail ---
echo ""
echo "  --- Per-node detail ---"
for i in $(seq 0 $((NUM_NODES - 1))); do
    LOG="$STATE_DIR/node${i}.log"
    PROOFS=$(grep -c 'Proof generated successfully' "$LOG" 2>/dev/null || true)
    PUBLISHED=$(grep -c 'Published message to peers' "$LOG" 2>/dev/null || true)
    RECV=$(grep -c 'message_received' "$LOG" 2>/dev/null || true)
    VALIDATED=$(grep -c 'message validity is verified' "$LOG" 2>/dev/null || true)
    ROOTS=$(grep -c 'Polled valid roots\|Using cached roots' "$LOG" 2>/dev/null || true)
    MESH=$(grep -c 'mesh balanced.*mesh=1' "$LOG" 2>/dev/null || true)
    echo "  Node $i: proofs=$PROOFS published=$PUBLISHED recv=$RECV validated=$VALIDATED roots=$ROOTS mesh=$MESH"
done

# --- Result ---
echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "  =========================================="
    echo "  ALL $PASS CHECKS PASSED"
    echo "  =========================================="
    EXIT_CODE=0
else
    echo "  =========================================="
    echo "  $FAIL FAILED, $PASS passed"
    echo "  =========================================="
    EXIT_CODE=1
fi
echo ""
