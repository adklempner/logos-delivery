{.push raises: [].}

import std/options, results, chronicles, chronos, bearssl/rand
import libp2p/stream/connection
import
  ../../node/peer_manager,
  ../../waku_core,
  ../../utils/requests,
  ./rpc,
  ./rpc_codec

logScope:
  topics = "waku rln-gifter client"

type
  RlnGifterResult* = Result[tuple[leafIndex: uint64, configAccountId: string], string]

  WakuRlnGifterClient* = ref object
    rng*: ref rand.HmacDrbgContext
    peerManager*: PeerManager

proc new*(
    T: type WakuRlnGifterClient, peerManager: PeerManager, rng: ref rand.HmacDrbgContext
): T =
  WakuRlnGifterClient(peerManager: peerManager, rng: rng)

proc requestMembership*(
    wc: WakuRlnGifterClient,
    idCommitment: string,
    rateLimit: uint64,
    peer: RemotePeerInfo,
): Future[RlnGifterResult] {.async.} =
  let request = RlnGifterRequest(
    requestId: generateRequestId(wc.rng),
    idCommitment: idCommitment,
    rateLimit: rateLimit,
  )

  info "requesting RLN membership from gifter",
    requestId = request.requestId,
    idCommitment = idCommitment[0 .. min(15, idCommitment.len - 1)] & "..."

  # Retry dial with backoff (gifter node may still be initializing)
  var connection: Connection
  var dialAttempts = 0
  while true:
    let connOpt = await wc.peerManager.dialPeer(peer, WakuRlnGifterCodec)
    if connOpt.isSome:
      connection = connOpt.get()
      break
    dialAttempts += 1
    if dialAttempts >= 5:
      return err("failed to dial gifter peer after " & $dialAttempts & " attempts")
    warn "gifter dial failed, retrying", attempt = dialAttempts
    await sleepAsync(seconds(5))

  try:
    await connection.writeLP(request.encode().buffer)
  except LPStreamError:
    return err("failed to write request: " & getCurrentExceptionMsg())

  var buffer: seq[byte]
  try:
    buffer = await connection.readLp(DefaultMaxRpcSize)
  except LPStreamError:
    return err("failed to read response: " & getCurrentExceptionMsg())

  # Do NOT close the connection here. Let it leak and be cleaned up by GC.
  # Calling closeWithEOF triggers yamux cleanup that crashes the delivery module
  # process when the FFI boundary returns to C++ before yamux completes.

  let response = RlnGifterResponse.decode(buffer).valueOr:
    return err("failed to decode response: " & $error)

  if response.requestId != request.requestId:
    return err("requestId mismatch")

  if response.statusCode != RlnGifterSuccess:
    let desc = response.statusDesc.get("unknown error")
    return err("gifter returned error " & $response.statusCode.uint32 & ": " & desc)

  let leafIndex = response.leafIndex.valueOr:
    return err("response missing leaf_index")

  let configAccountId = response.configAccountId.valueOr:
    return err("response missing config_account_id")

  info "RLN membership granted",
    leafIndex = leafIndex,
    configAccountId = configAccountId[0 .. min(15, configAccountId.len - 1)] & "..."

  return ok((leafIndex: leafIndex, configAccountId: configAccountId))
