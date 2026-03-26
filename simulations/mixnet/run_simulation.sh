#!/usr/bin/env bash
# 5-node mix simulation using logoscore instances with embedded delivery + RLN modules.
# Each node is its own logoscore process — no standalone wakunode2 or HTTP polling.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
DELIVERY_DIR="$(cd ../.. && pwd)"
RLN_PROJECT_DIR="$(cd "$DELIVERY_DIR/.." && pwd)"

export RISC0_DEV_MODE=1
export TMPDIR=/tmp

# =============================================================================
# Utility Functions
# =============================================================================

die() {
    echo "  FATAL: $*" >&2
    exit 1
}

log() {
    echo "[$(date '+%H:%M:%S')] $*"
}

wait_for_port() {
    local port=$1 timeout=${2:-300} pid=${3:-}
    for _ in $(seq 1 "$timeout"); do
        if nc -z 127.0.0.1 "$port" 2>/dev/null; then
            return 0
        fi
        if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
            return 1
        fi
        sleep 1
    done
    return 1
}

wait_for_log_pattern() {
    local log_file=$1 pattern=$2 count=$3 timeout=${4:-90} pid=${5:-}
    for _ in $(seq 1 "$timeout"); do
        if [ -f "$log_file" ]; then
            local n
            n=$(grep "$pattern" "$log_file" 2>/dev/null | wc -l | tr -d ' ')
            [ "${n:-0}" -ge "$count" ] && return 0
        fi
        if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
            return 1
        fi
        sleep 1
    done
    return 1
}

create_module_manifest() {
    local dir=$1 name=$2 main_lib=$3 deps=$4
    local deps_json="[]"
    if [ -n "$deps" ]; then
        deps_json=$(echo "$deps" | tr ',' '\n' | sed 's/.*/"&"/' | tr '\n' ',' | sed 's/,$//' | sed 's/^/[/;s/$/]/')
    fi
    cat > "$dir/manifest.json" <<EOF
{"name":"$name","version":"1.0.0","type":"core","main":{"$PLATFORM":"$main_lib"},"dependencies":$deps_json,"capabilities":[]}
EOF
}

# --- Node identity constants (from config*.toml) ---
NODEKEYS=(
    "f98e3fba96c32e8d1967d460f1b79457380e1a895f7971cecc8528abe733781a"
    "09e9d134331953357bd38bbfce8edb377f4b6308b4f3bfbe85c610497053d684"
    "ed54db994682e857d77cd6fb81be697382dc43aa5cd78e16b0ec8098549f860e"
    "42f96f29f2d6670938b0864aced65a332dcf5774103b4c44ec4d0ea4ef3c47d6"
    "3ce887b3c34b7a92dd2868af33941ed1dbec4893b054572cd5078da09dd923d4"
    "cb6fe589db0e5d5b48f7e82d33093e4d9d35456f4aaffc2322c473a173b2ac49"
    "35eace7ccb246f20c487e05015ca77273d8ecaed0ed683de3d39bf4f69336feb"
)
MIXKEYS=(
    "a87db88246ec0eedda347b9b643864bee3d6933eb15ba41e6d58cb678d813258"
    "c86029e02c05a7e25182974b519d0d52fcbafeca6fe191fbb64857fb05be1a53"
    "b858ac16bbb551c4b2973313b1c8c8f7ea469fca03f1608d200bbf58d388ec7f"
    "d8bd379bb394b0f22dd236d63af9f1a9bc45266beffc3fbbe19e8b6575f2535b"
    "780fff09e51e98df574e266bf3266ec6a3a1ddfcf7da826a349a29c137009d49"
    "fe68e1ff4a6aa7115cfcff33f68a0c1767d6865a1fd56ec05b40dffba9653fe5"
    "88f02c1bcd8eedb697e8fd818e6f1617752488e048b37730fa18e3fb3460f57e"
)
PEER_IDS=(
    "16Uiu2HAmPiEs2ozjjJF2iN2Pe2FYeMC9w4caRHKYdLdAfjgbWM6o"
    "16Uiu2HAmLtKaFaSWDohToWhWUZFLtqzYZGPFuXwKrojFVF6az5UF"
    "16Uiu2HAmTEDHwAziWUSz6ZE23h5vxG2o4Nn7GazhMor4bVuMXTrA"
    "16Uiu2HAmPwRKZajXtfb1Qsv45VVfRZgK3ENdfmnqzSrVm3BczF6f"
    "16Uiu2HAmRhxmCHBYdXt1RibXrjAUNJbduAhzaTHwFCZT4qWnqZAu"
    "16Uiu2HAm1QxSjNvNbsT2xtLjRGAsBLVztsJiTHr9a3EK96717hpj"
    "16Uiu2HAmC9h26U1C83FJ5xpE32ghqya8CaZHX1Y7qpfHNnRABscN"
)
NUM_CHAT_CLIENTS=1
MIX_PUBKEYS=(
    "9d09ce624f76e8f606265edb9cca2b7de9b41772a6d784bddaf92ffa8fba7d2c"
    "9231e86da6432502900a84f867004ce78632ab52cd8e30b1ec322cd795710c2a"
    "275cd6889e1f29ca48e5b9edb800d1a94f49f13d393a0ecf1a07af753506de6c"
    "e0ed594a8d506681be075e8e23723478388fb182477f7a469309a25e7076fc18"
    "8fd7a1a7c19b403d231452a9b1ea40eb1cc76f455d918ef8980e7685f9eeeb1f"
)
BASE_TCP_PORT=60001
BASE_DISC_PORT=9001
NUM_NODES=4

CONTENT_TOPIC="/toy-chat/2/baixa-chiado/proto"

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) PLATFORM="darwin-arm64-dev"; EXT="dylib";;
  Linux-x86_64) PLATFORM="linux-x86_64-dev"; EXT="so";;
  Linux-aarch64) PLATFORM="linux-aarch64-dev"; EXT="so";;
  *) echo "Unsupported platform"; exit 1;;
esac

# --- Cleanup ---
SEQUENCER_PID=""
INSTANCE_PIDS=()
MODULES_DIRS=()
WORK_DIR=""
cleanup() {
    echo ""
    echo "=== Shutting down ==="
    for pid in "${INSTANCE_PIDS[@]+"${INSTANCE_PIDS[@]}"}"; do
        if [ -n "$pid" ]; then
            local children
            children=$(pgrep -P "$pid" 2>/dev/null || true)
            kill "$pid" $children 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
    done
    pkill -f 'logos_host' 2>/dev/null || true
    if [ -n "$SEQUENCER_PID" ]; then
        kill "$SEQUENCER_PID" 2>/dev/null || true
        wait "$SEQUENCER_PID" 2>/dev/null || true
    fi
    for mdir in "${MODULES_DIRS[@]}"; do
        [ -n "$mdir" ] && rm -rf "$mdir"
    done
    if [ -n "$WORK_DIR" ]; then
        echo "  Logs:       $WORK_DIR"
    fi
    echo "Done."
}
trap cleanup EXIT

echo "=== Mix Simulation (5 LogosCore Instances) ==="
echo "  RLN project: $RLN_PROJECT_DIR"
echo "  Delivery:    $DELIVERY_DIR"
echo ""

pkill -f 'logos_host' 2>/dev/null || true
sleep 1
rm -f /tmp/logos_* 2>/dev/null || true

# ---------- Phase 1: Sequencer ----------
echo "[1/7] Starting sequencer..."

(cd "$RLN_PROJECT_DIR" && git submodule update --init lssa)

if nc -z 127.0.0.1 3040 2>/dev/null; then
    OLD_PID=$(lsof -ti tcp:3040 2>/dev/null || true)
    if [ -n "$OLD_PID" ]; then
        echo "  Port 3040 in use by PID $OLD_PID. Killing..."
        kill "$OLD_PID" 2>/dev/null || true
        sleep 1
    fi
fi

rm -rf "$RLN_PROJECT_DIR/lssa/rocksdb"

log "  Building sequencer (first run may take several minutes)..."
(cd "$RLN_PROJECT_DIR/lssa" && cargo build --features standalone -p sequencer_runner 2>&1 | tail -3) || \
    die "sequencer build failed"

SEQUENCER_BIN="$RLN_PROJECT_DIR/lssa/target/debug/sequencer_runner"
(cd "$RLN_PROJECT_DIR/lssa" && env RUST_LOG=info "$SEQUENCER_BIN" sequencer_runner/configs/debug) >/dev/null 2>&1 &
SEQUENCER_PID=$!
echo "  PID: $SEQUENCER_PID"

log "  Waiting for port 3040..."
if ! wait_for_port 3040 300 "$SEQUENCER_PID"; then
    if ! kill -0 "$SEQUENCER_PID" 2>/dev/null; then
        die "Sequencer exited unexpectedly"
    else
        die "Sequencer did not start within 300s"
    fi
fi
log "  Sequencer ready."

# ---------- Phase 2: Deploy programs ----------
echo "[2/7] Deploying programs..."

# Build guest binaries if missing (required by run_setup and register_member)
LEZ_RLN_DIR="$RLN_PROJECT_DIR/lez-rln"
GUEST_BIN="$LEZ_RLN_DIR/methods/guest/target/riscv32im-risc0-zkvm-elf/docker/rln_registration.bin"
if [ ! -f "$GUEST_BIN" ]; then
    if ! command -v cargo-risczero &>/dev/null; then
        die "zkVM guest binaries not found and cargo-risczero not installed.\n  Install with: cargo install cargo-risczero && cargo risczero install\n  Requires Docker running for cross-compilation."
    fi
    log "  Building zkVM guest programs (first run may take several minutes)..."
    (cd "$LEZ_RLN_DIR" && cargo risczero build --manifest-path methods/guest/Cargo.toml 2>&1 | tail -10) || \
        die "guest program build failed. Is Docker running?"
fi

export NSSA_WALLET_HOME_DIR="$RLN_PROJECT_DIR/dev"
export WALLET_CONFIG="$NSSA_WALLET_HOME_DIR/wallet_config.json"
export WALLET_STORAGE="$NSSA_WALLET_HOME_DIR/storage.json"
rm -f "$WALLET_CONFIG" "$WALLET_STORAGE"

SETUP_OUTPUT=$(cd "$LEZ_RLN_DIR" && cargo run --bin run_setup 2>&1) || {
    echo "  FATAL: run_setup failed:"
    echo "$SETUP_OUTPUT"
    exit 1
}
echo "$SETUP_OUTPUT" | tail -5
TREE_MAIN_ACCOUNT=$(echo "$SETUP_OUTPUT" | grep "Tree main account:" | awk '{print $NF}')
if [ -z "$TREE_MAIN_ACCOUNT" ]; then
    echo "  FATAL: Could not parse tree main account from run_setup output"
    exit 1
fi
echo "  Programs deployed."
echo "  Tree main account: $TREE_MAIN_ACCOUNT"

# ---------- Phase 3: Register 5 members & generate keystores ----------
TOTAL_MEMBERS=$((NUM_NODES + NUM_CHAT_CLIENTS))
echo "[3/7] Registering $TOTAL_MEMBERS members and generating keystores..."

WORK_DIR=$(mktemp -d)

REGISTER_BIN="$LEZ_RLN_DIR/target/release/register_member"
(cd "$LEZ_RLN_DIR" && cargo build --release --bin register_member 2>&1 | tail -3)
[ -f "$REGISTER_BIN" ] || die "register_member not found at $REGISTER_BIN"

MANIFEST_FILE="$WORK_DIR/manifest.json"
LEAF_INDICES=()
IDENTITY_SECRETS=()
CONFIG_ACCOUNT=""

# Register all members in a single batch call
REG_OUTPUT="$WORK_DIR/reg_output.txt"
log "  Registering $TOTAL_MEMBERS members..."
(cd "$LEZ_RLN_DIR" && "$REGISTER_BIN" --count "$TOTAL_MEMBERS" > "$REG_OUTPUT" 2>&1) || {
    cat "$REG_OUTPUT" 2>/dev/null || true
    die "register_member failed"
}

# Parse batch output into per-member arrays
REG_OUTPUTS=()
# Split output into per-member chunks (3 lines each: CONFIG_ACCOUNT, LEAF_INDEX, IDENTITY_SECRET_HASH)
MEMBER_IDX=0
while IFS= read -r line; do
    case "$line" in
        CONFIG_ACCOUNT=*)
            REG_OUTPUTS[$MEMBER_IDX]="$WORK_DIR/reg_output_$MEMBER_IDX.txt"
            echo "$line" > "${REG_OUTPUTS[$MEMBER_IDX]}"
            ;;
        LEAF_INDEX=*|IDENTITY_SECRET_HASH=*)
            echo "$line" >> "${REG_OUTPUTS[$MEMBER_IDX]}"
            if [[ "$line" == IDENTITY_SECRET_HASH=* ]]; then
                MEMBER_IDX=$((MEMBER_IDX + 1))
            fi
            ;;
    esac
done < "$REG_OUTPUT"

# Parse outputs and build manifest (sequential to maintain order)
echo "[" > "$MANIFEST_FILE"
for i in $(seq 0 $((TOTAL_MEMBERS - 1))); do
    OUTPUT=$(cat "${REG_OUTPUTS[$i]}")
    CONFIG_ACCOUNT=$(echo "$OUTPUT" | grep "^CONFIG_ACCOUNT=" | cut -d= -f2)
    LEAF_INDEX=$(echo "$OUTPUT" | grep "^LEAF_INDEX=" | cut -d= -f2)
    IDENTITY_SECRET=$(echo "$OUTPUT" | grep "^IDENTITY_SECRET_HASH=" | cut -d= -f2)

    if [ -z "$CONFIG_ACCOUNT" ] || [ -z "$LEAF_INDEX" ] || [ -z "$IDENTITY_SECRET" ]; then
        die "Failed to parse register_member output for member $i:\n$OUTPUT"
    fi

    LEAF_INDICES+=("$LEAF_INDEX")
    IDENTITY_SECRETS+=("$IDENTITY_SECRET")

    [ "$i" -gt 0 ] && echo "," >> "$MANIFEST_FILE"
    cat >> "$MANIFEST_FILE" <<EOF
  {
    "peerId": "${PEER_IDS[$i]}",
    "leafIndex": $LEAF_INDEX,
    "identitySecretHash": "$IDENTITY_SECRET",
    "rateLimit": 100,
    "configAccount": "$CONFIG_ACCOUNT"
  }
EOF
    echo "    Member $((i+1)): leaf=$LEAF_INDEX"
    rm -f "${REG_OUTPUTS[$i]}"
done

echo "]" >> "$MANIFEST_FILE"
log "  All $TOTAL_MEMBERS members registered"
echo "  Config account: $CONFIG_ACCOUNT"

# Generate keystores
echo "  Generating keystores..."
LIBRLN_FILE="$DELIVERY_DIR/librln_v0.9.0.a"
if [ ! -f "$LIBRLN_FILE" ]; then
    echo "  Building librln..."
    (cd "$DELIVERY_DIR" && make librln 2>&1 | tail -5)
fi
if [ ! -f "$LIBRLN_FILE" ]; then
    echo "  FATAL: librln not found at $LIBRLN_FILE"
    exit 1
fi

if [ ! -f "$DELIVERY_DIR/nimbus-build-system.paths" ]; then
    echo "  Generating nim paths..."
    (cd "$DELIVERY_DIR" && make nimbus-build-system-paths 2>&1 | tail -3)
fi

NIM_PATH_ARGS=()
while IFS= read -r line; do
    line="${line//\"/}"
    [[ -n "$line" ]] && NIM_PATH_ARGS+=("$line")
done < "$DELIVERY_DIR/nimbus-build-system.paths"

SETUP_KS_BIN="$WORK_DIR/setup_keystores"
nim c -d:release --mm:refc \
    "${NIM_PATH_ARGS[@]}" \
    --passL:"$LIBRLN_FILE" --passL:"-lm" \
    -o:"$SETUP_KS_BIN" \
    "$SCRIPT_DIR/setup_keystores.nim" 2>&1 | tail -10

[ -f "$SETUP_KS_BIN" ] || die "Failed to compile setup_keystores.nim"

(cd "$WORK_DIR" && "$SETUP_KS_BIN" "$MANIFEST_FILE") || die "setup_keystores failed"
KEYSTORE_COUNT=$(ls -1 "$WORK_DIR"/rln_keystore_*.json 2>/dev/null | wc -l | tr -d ' ')
echo "  Keystores: $KEYSTORE_COUNT"

# ---------- Phase 4: Build / check modules ----------
echo "[4/7] Building modules (if needed)..."

LOGOSCORE="${LOGOSCORE:-$(nix build github:logos-co/logos-liblogos/7df6195 --override-input logos-cpp-sdk github:logos-co/logos-cpp-sdk/a4bd66c --no-link --print-out-paths)/bin/logoscore}"
WALLET_MODULE_RESULT="$RLN_PROJECT_DIR/logos-rln-module/result-wallet"

MIX_SIM_MODULE_RESULT="$RLN_PROJECT_DIR/mix-simulation-module/result"

NEED_BUILD=0
[ -f "$RLN_PROJECT_DIR/logos-rln-module/result-rln/lib/liblogos_rln_module.$EXT" ] || NEED_BUILD=1
[ -f "$WALLET_MODULE_RESULT/lib/liblogos_execution_zone_wallet_module.$EXT" ] || NEED_BUILD=1
[ -f "$RLN_PROJECT_DIR/logos-delivery-module/result/lib/delivery_module_plugin.$EXT" ] || NEED_BUILD=1
[ -f "$MIX_SIM_MODULE_RESULT/lib/libmix_simulation_module.$EXT" ] || NEED_BUILD=1

if [ "$NEED_BUILD" -eq 1 ]; then
    log "  Some modules missing — running build_modules.sh..."
    bash "$RLN_PROJECT_DIR/build_modules.sh" || die "Module build failed"
fi

[ -f "$RLN_PROJECT_DIR/logos-rln-module/result-rln/lib/liblogos_rln_module.$EXT" ] || die "RLN module not found after build"
[ -f "$WALLET_MODULE_RESULT/lib/liblogos_execution_zone_wallet_module.$EXT" ] || die "Wallet module not found after build"
[ -f "$RLN_PROJECT_DIR/logos-delivery-module/result/lib/delivery_module_plugin.$EXT" ] || die "Delivery module not found after build"
[ -f "$MIX_SIM_MODULE_RESULT/lib/libmix_simulation_module.$EXT" ] || die "Mix simulation module not found after build"
log "  All modules present."

# ---------- Phase 5: Stage modules ----------
TOTAL_NODES=$((NUM_NODES + NUM_CHAT_CLIENTS))
echo "[5/7] Staging modules for $TOTAL_NODES instances..."

stage_modules() {
    local mdir
    mdir=$(mktemp -d)

    # Wallet module
    mkdir -p "$mdir/liblogos_execution_zone_wallet_module"
    cp -L "$WALLET_MODULE_RESULT/lib/liblogos_execution_zone_wallet_module.$EXT" "$mdir/liblogos_execution_zone_wallet_module/"
    [ -f "$WALLET_MODULE_RESULT/lib/libwallet_ffi.$EXT" ] && \
      cp -L "$WALLET_MODULE_RESULT/lib/libwallet_ffi.$EXT" "$mdir/liblogos_execution_zone_wallet_module/"
    create_module_manifest "$mdir/liblogos_execution_zone_wallet_module" \
        "liblogos_execution_zone_wallet_module" "liblogos_execution_zone_wallet_module.$EXT" ""

    # RLN module
    mkdir -p "$mdir/liblogos_rln_module"
    cp -L "$RLN_PROJECT_DIR/logos-rln-module/result-rln/lib/liblogos_rln_module.$EXT" "$mdir/liblogos_rln_module/"
    cp -L "$RLN_PROJECT_DIR/logos-rln-module/result-rln/lib/liblez_rln_ffi.$EXT" "$mdir/liblogos_rln_module/" 2>/dev/null || true
    create_module_manifest "$mdir/liblogos_rln_module" \
        "liblogos_rln_module" "liblogos_rln_module.$EXT" "liblogos_execution_zone_wallet_module"

    # Delivery module
    mkdir -p "$mdir/delivery_module"
    cp -L "$RLN_PROJECT_DIR/logos-delivery-module/result/lib/delivery_module_plugin.$EXT" "$mdir/delivery_module/"
    [ -f "$RLN_PROJECT_DIR/logos-delivery-module/result/lib/liblogosdelivery.$EXT" ] && \
      cp -L "$RLN_PROJECT_DIR/logos-delivery-module/result/lib/liblogosdelivery.$EXT" "$mdir/delivery_module/"
    for pq in "$RLN_PROJECT_DIR"/logos-delivery-module/result/lib/libpq*; do
        [ -f "$pq" ] && cp -L "$pq" "$mdir/delivery_module/"
    done
    create_module_manifest "$mdir/delivery_module" \
        "delivery_module" "delivery_module_plugin.$EXT" ""

    # Mix simulation module
    mkdir -p "$mdir/mix_simulation_module"
    cp -L "$MIX_SIM_MODULE_RESULT/lib/libmix_simulation_module.$EXT" "$mdir/mix_simulation_module/"
    create_module_manifest "$mdir/mix_simulation_module" \
        "mix_simulation_module" "libmix_simulation_module.$EXT" "delivery_module,liblogos_rln_module"

    echo "$mdir"
}

# Stage modules in parallel
STAGING_PIDS=()
STAGING_OUTPUTS=()
for i in $(seq 0 $((TOTAL_NODES - 1))); do
    STAGING_OUTPUTS[$i]=$(mktemp)
    (stage_modules > "${STAGING_OUTPUTS[$i]}") &
    STAGING_PIDS+=($!)
done

# Wait for all staging to complete
for i in $(seq 0 $((TOTAL_NODES - 1))); do
    wait "${STAGING_PIDS[$i]}" || die "Module staging for node $i failed"
    MDIR=$(cat "${STAGING_OUTPUTS[$i]}")
    MODULES_DIRS+=("$MDIR")
    rm -f "${STAGING_OUTPUTS[$i]}"
    echo "  Node $i modules: $MDIR"
done

LOAD_ORDER="liblogos_execution_zone_wallet_module,liblogos_rln_module,delivery_module,mix_simulation_module"
WALLET_CALL="liblogos_execution_zone_wallet_module.open($WALLET_CONFIG,$WALLET_STORAGE)"

# ---------- Phase 6: Start logoscore instances ----------
echo "[6/7] Starting $TOTAL_NODES logoscore instances ($NUM_NODES core + $NUM_CHAT_CLIENTS edge)..."

# Helper: write node config file
write_node_config() {
    local i=$1 config_file=$2
    local tcp_port=$((BASE_TCP_PORT + i))
    local disc_port=$((BASE_DISC_PORT + i))
    local entry_nodes="[]"
    [ "$i" -gt 0 ] && entry_nodes="[\"/ip4/127.0.0.1/tcp/$BASE_TCP_PORT/p2p/${PEER_IDS[0]}\"]"

    local mix_nodes_json=""
    for j in $(seq 0 $((NUM_NODES - 1))); do
        [ "$j" -eq "$i" ] && continue
        local j_port=$((BASE_TCP_PORT + j))
        [ -n "$mix_nodes_json" ] && mix_nodes_json="$mix_nodes_json, "
        mix_nodes_json="$mix_nodes_json\"/ip4/127.0.0.1/tcp/$j_port/p2p/${PEER_IDS[$j]}:${MIX_PUBKEYS[$j]}\""
    done

    local node_mode="Core"
    [ "$i" -ge "$NUM_NODES" ] && node_mode="Edge"

    cat > "$config_file" <<EOF
{
  "mode": "$node_mode",
  "clusterId": 42,
  "numShardsInNetwork": 8,
  "entryNodes": $entry_nodes,
  "maxMessageSize": "150 KiB",
  "listenAddress": "127.0.0.1",
  "tcpPort": $tcp_port,
  "discv5UdpPort": $disc_port,
  "nodekey": "${NODEKEYS[$i]}",
  "mixkey": "${MIXKEYS[$i]}",
  "mixnodes": [$mix_nodes_json],
  "mix": true,
  "enableSpamProtection": true,
  "colocationLimit": 0,
  "maxConnsPerPeer": 2,
  "enableWarmup": false,
  "logLevel": "TRACE"
}
EOF
}

# Helper: start a single node (sets LAST_NODE_PID)
start_node() {
    local i=$1
    local node_config="$WORK_DIR/node${i}_config.json"
    local log_file="$WORK_DIR/node${i}.log"
    local leaf_index="${LEAF_INDICES[$i]}"

    write_node_config "$i" "$node_config"

    if [ "$i" -ge "$NUM_NODES" ]; then
        # Edge nodes use mix-simulation-module runner
        local runner_config="$WORK_DIR/runner${i}_config.json"
        cat > "$runner_config" <<REOF
{
  "delivery": $(cat "$node_config"),
  "contentTopic": "$CONTENT_TOPIC",
  "rln": {
    "configAccountId": "$CONFIG_ACCOUNT",
    "leafIndex": $leaf_index
  },
  "simulation": {
    "peerDiscoveryDelayMs": 45000,
    "messageCount": 3,
    "messageDelayMs": 2000,
    "payload": "e2e_mix_test"
  }
}
REOF
        TMPDIR=/tmp "$LOGOSCORE" -m "${MODULES_DIRS[$i]}" -l "$LOAD_ORDER" \
            -c "$WALLET_CALL" \
            -c "mix_simulation_module.start(@$runner_config)" \
            </dev/null >"$log_file" 2>&1 &
    else
        # Core nodes use direct -c calls
        TMPDIR=/tmp "$LOGOSCORE" -m "${MODULES_DIRS[$i]}" -l "$LOAD_ORDER" \
            -c "$WALLET_CALL" \
            -c "delivery_module.createNode(@$node_config)" \
            -c "delivery_module.start()" \
            -c "delivery_module.subscribe($CONTENT_TOPIC)" \
            -c "delivery_module.setRlnConfig($CONFIG_ACCOUNT,$leaf_index)" \
            -c "liblogos_rln_module.start_root_broadcast($CONFIG_ACCOUNT)" \
            -c "liblogos_rln_module.start_merkle_proof_broadcast($CONFIG_ACCOUNT,$leaf_index)" \
            </dev/null >"$log_file" 2>&1 &
    fi
    LAST_NODE_PID=$!
}

# Helper: wait for node to initialize
wait_for_node_init() {
    local i=$1 pid=$2
    local log_file="$WORK_DIR/node${i}.log"
    local expected_calls=7
    [ "$i" -ge "$NUM_NODES" ] && expected_calls=2

    if ! wait_for_log_pattern "$log_file" "^Method call successful" "$expected_calls" 90 "$pid"; then
        local n=0
        [ -f "$log_file" ] && n=$(grep '^Method call successful' "$log_file" 2>/dev/null | wc -l | tr -d ' ')
        if ! kill -0 "$pid" 2>/dev/null; then
            echo "  ERROR: Node $i exited after ${n:-0}/$expected_calls calls"
            grep 'Method call' "$log_file" 2>/dev/null || true
            tail -15 "$log_file" 2>/dev/null || true
        else
            echo "  ERROR: Node $i timeout (${n:-0}/$expected_calls calls)"
            grep 'Method call\|Error' "$log_file" 2>/dev/null | tail -10
        fi
        return 1
    fi
    return 0
}

# Start node 0 first (bootstrap node)
log "  Starting bootstrap node 0..."
start_node 0
INSTANCE_PIDS[0]=$LAST_NODE_PID
echo "  Node 0 PID: ${INSTANCE_PIDS[0]}"

log "  Waiting for node 0 to initialize..."
wait_for_node_init 0 "${INSTANCE_PIDS[0]}" || die "Bootstrap node 0 failed to initialize"
log "  Node 0 ready"

# Start remaining CORE nodes (1 to NUM_NODES-1) with stagger
if [ "$NUM_NODES" -gt 1 ]; then
    log "  Starting core nodes 1-$((NUM_NODES-1))..."
    for i in $(seq 1 $((NUM_NODES - 1))); do
        start_node "$i"
        INSTANCE_PIDS[$i]=$LAST_NODE_PID
        echo "  Node $i PID: ${INSTANCE_PIDS[$i]}"
        sleep 2  # Stagger to avoid resource contention
    done

    # Wait for all core nodes to initialize
    log "  Waiting for core nodes 1-$((NUM_NODES-1)) to initialize..."
    INIT_FAILED=0
    for i in $(seq 1 $((NUM_NODES - 1))); do
        if ! wait_for_node_init "$i" "${INSTANCE_PIDS[$i]}"; then
            INIT_FAILED=1
        else
            log "  Node $i ready"
        fi
    done
    [ "$INIT_FAILED" -eq 1 ] && die "One or more core nodes failed to initialize"
fi

# Start EDGE nodes (NUM_NODES to TOTAL_NODES-1) AFTER core nodes are ready
if [ "$NUM_CHAT_CLIENTS" -gt 0 ]; then
    log "  Starting edge nodes $NUM_NODES-$((TOTAL_NODES-1))..."
    for i in $(seq "$NUM_NODES" $((TOTAL_NODES - 1))); do
        start_node "$i"
        INSTANCE_PIDS[$i]=$LAST_NODE_PID
        echo "  Node $i PID: ${INSTANCE_PIDS[$i]}"
        sleep 2
    done

    # Wait for edge nodes to initialize
    log "  Waiting for edge nodes to initialize..."
    INIT_FAILED=0
    for i in $(seq "$NUM_NODES" $((TOTAL_NODES - 1))); do
        if ! wait_for_node_init "$i" "${INSTANCE_PIDS[$i]}"; then
            INIT_FAILED=1
        else
            log "  Node $i ready"
        fi
    done
    [ "$INIT_FAILED" -eq 1 ] && die "One or more edge nodes failed to initialize"
fi

# Wait for peer discovery across all nodes
log "  Waiting for peer discovery (15s)..."
sleep 15

# ---------- Phase 7: Start chat2mix receiver ----------
echo "[7/8] Starting chat2mix receiver..."

CHAT2MIX="$DELIVERY_DIR/build/chat2mix"
if [ ! -f "$CHAT2MIX" ]; then
    echo "  Building chat2mix..."
    (cd "$DELIVERY_DIR" && make chat2mix 2>&1 | tail -3) || die "chat2mix build failed"
fi

RECEIVER_LOG="$WORK_DIR/receiver.log"
RECEIVER_PORT=$((BASE_TCP_PORT + 200))

# Build mixnode flags for chat2mix
MIXNODE_FLAGS=""
for j in $(seq 0 $((NUM_NODES - 1))); do
    J_PORT=$((BASE_TCP_PORT + j))
    MIXNODE_FLAGS="$MIXNODE_FLAGS --mixnode=/ip4/127.0.0.1/tcp/$J_PORT/p2p/${PEER_IDS[$j]}:${MIX_PUBKEYS[$j]}"
done

"$CHAT2MIX" \
    --ports-shift=$((200 + NUM_NODES)) \
    --cluster-id=42 \
    --num-shards-in-network=8 \
    --shard=0 \
    --servicenode="/ip4/127.0.0.1/tcp/$BASE_TCP_PORT/p2p/${PEER_IDS[0]}" \
    --log-level=TRACE \
    --nodekey="${NODEKEYS[$((NUM_NODES + NUM_CHAT_CLIENTS))]}" \
    --kad-bootstrap-node="/ip4/127.0.0.1/tcp/$BASE_TCP_PORT/p2p/${PEER_IDS[0]}" \
    $MIXNODE_FLAGS \
    --fleet="none" \
    < <(echo "receiver"; while true; do sleep 86400; done) >"$RECEIVER_LOG" 2>&1 &
RECEIVER_PID=$!
INSTANCE_PIDS+=($RECEIVER_PID)
echo "  Receiver PID: $RECEIVER_PID (port $RECEIVER_PORT)"
echo "  Waiting for filter subscription (20s)..."
sleep 20

# ---------- Phase 8: Ready ----------
echo ""
echo "[8/8] Simulation running!"
echo ""
echo "  Sequencer:  PID $SEQUENCER_PID (port 3040)"
echo "  Config:     $CONFIG_ACCOUNT"
echo "  Logs:       $WORK_DIR/node*.log"
echo "  Receiver:   $RECEIVER_LOG"
echo ""
for i in $(seq 0 $((TOTAL_NODES - 1))); do
    TCP_PORT=$((BASE_TCP_PORT + i))
    MODE="core"
    [ "$i" -ge "$NUM_NODES" ] && MODE="edge"
    echo "  Node $i ($MODE): PID ${INSTANCE_PIDS[$i]}, port $TCP_PORT, leaf ${LEAF_INDICES[$i]}"
done
echo ""
echo "  To inspect logs:"
for i in $(seq 0 $((TOTAL_NODES - 1))); do
    echo "    grep 'Method call' $WORK_DIR/node${i}.log"
done
echo ""
echo "  Waiting for message delivery (sender delay + propagation)..."
echo ""

SENDER_LOG="$WORK_DIR/node${NUM_NODES}.log"
# Wait up to 90s for sender to fire
for t in $(seq 1 90); do
    SENT=$(rg -c 'Sending via Lightpush with mix' "$SENDER_LOG" 2>/dev/null || echo 0)
    [ "$SENT" -ge 3 ] && break
    sleep 1
done

# Give mix forwarding + relay + filter time to complete
sleep 5

echo "  === Message Delivery Report ==="
SENDS=$(rg -c 'Sending via Lightpush with mix' "$SENDER_LOG" 2>/dev/null || echo 0)
echo "  Sender:   $SENDS messages entered mix path"

TOTAL_INT=0; TOTAL_EXIT=0; TOTAL_PUB=0
i=0; while [ "$i" -lt "$NUM_NODES" ]; do
    INT=$(rg -c 'Intermediate node processing' "$WORK_DIR/node${i}.log" 2>/dev/null || echo 0)
    EXIT=$(rg -c 'Exit node - Received mix' "$WORK_DIR/node${i}.log" 2>/dev/null || echo 0)
    PUB=$(rg -c 'start publish Waku message' "$WORK_DIR/node${i}.log" 2>/dev/null || echo 0)
    TOTAL_INT=$((TOTAL_INT + INT)); TOTAL_EXIT=$((TOTAL_EXIT + EXIT)); TOTAL_PUB=$((TOTAL_PUB + PUB))
    i=$((i + 1))
done
echo "  Mix hops: $TOTAL_INT intermediate, $TOTAL_EXIT exit"
echo "  Relay:    $TOTAL_PUB gossipsub publishes"

RECV=$(rg -c '^>> <' "$RECEIVER_LOG" 2>/dev/null || echo 0)
echo "  Receiver: $RECV messages received via filter"

echo ""
if [ "$RECV" -ge 1 ]; then
    echo "  E2E delivery confirmed!"
else
    echo "  WARNING: Messages not received. Check logs for details."
fi
echo ""
echo "  Press Ctrl+C to stop everything."

wait
