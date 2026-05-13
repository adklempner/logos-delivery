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
  RlnGifterResult* = Result[MembershipAllocationSuccess, string]

  WakuRlnGifterClient* = ref object
    rng*: ref rand.HmacDrbgContext
    peerManager*: PeerManager

proc new*(
    T: type WakuRlnGifterClient, peerManager: PeerManager, rng: ref rand.HmacDrbgContext
): T =
  WakuRlnGifterClient(peerManager: peerManager, rng: rng)

proc requestMembership*(
    wc: WakuRlnGifterClient,
    identityCommitment: seq[byte],
    rateLimit: Option[uint64],
    peer: RemotePeerInfo,
    authenticationType: seq[byte] = @[],
    authenticationPayload: seq[byte] = @[],
): Future[RlnGifterResult] {.async.} =
  let request = RlnGifterRequest(
    requestId: generateRequestId(wc.rng),
    authenticationType: authenticationType,
    authenticationPayload: authenticationPayload,
    identityCommitment: identityCommitment,
    rateLimit: rateLimit,
  )

  info "requesting RLN membership from gifter",
    requestId = request.requestId,
    identityCommitmentLen = identityCommitment.len

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

  if not response.authSuccess:
    let desc = response.error.get(
      if response.failure.isSome: response.failure.get().errorMessage
      else: "authentication failed"
    )
    return err("authentication failed: " & desc)

  if response.failure.isSome:
    return err("registration failed: " & response.failure.get().errorMessage)

  let success = response.success.valueOr:
    return err("response missing success/failure result")

  info "RLN membership granted", leafIndex = success.leafIndex

  return ok(success)
