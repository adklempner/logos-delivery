{.push raises: [].}

import
  std/[options, json],
  results,
  chronicles,
  chronos,
  bearssl/rand
import
  ../../node/peer_manager/peer_manager,
  ../../waku_core,
  ./rpc,
  ./rpc_codec

logScope:
  topics = "waku rln-gifter"

type
  RegisterMemberHandler* = proc(
    idCommitment: string, rateLimit: uint64
  ): Future[Result[tuple[leafIndex: uint64, configAccountId: string], string]] {.
    async, gcsafe
  .}

  WakuRlnGifter* = ref object of LPProtocol
    rng*: ref rand.HmacDrbgContext
    peerManager*: PeerManager
    registerHandler*: RegisterMemberHandler

proc handleRequest(
    wg: WakuRlnGifter, peerId: PeerId, buffer: seq[byte]
): Future[RlnGifterResponse] {.async.} =
  let request = RlnGifterRequest.decode(buffer).valueOr:
    error "failed to decode RLN gifter request", error = $error
    return RlnGifterResponse(
      requestId: "N/A",
      statusCode: RlnGifterBadRequest,
      statusDesc: some("decode error: " & $error),
    )

  info "handling RLN gifter request",
    peerId = peerId,
    requestId = request.requestId,
    idCommitment = request.idCommitment[0 .. min(15, request.idCommitment.len - 1)] & "..."

  if request.idCommitment.len != 64:
    return RlnGifterResponse(
      requestId: request.requestId,
      statusCode: RlnGifterBadRequest,
      statusDesc: some("idCommitment must be 64 hex chars"),
    )

  let regResult = (await wg.registerHandler(request.idCommitment, request.rateLimit)).valueOr:
    error "RLN gifter registration failed", error = error
    return RlnGifterResponse(
      requestId: request.requestId,
      statusCode: RlnGifterRegistrationFailed,
      statusDesc: some(error),
    )

  info "RLN gifter registration succeeded",
    leafIndex = regResult.leafIndex,
    requestId = request.requestId

  return RlnGifterResponse(
    requestId: request.requestId,
    statusCode: RlnGifterSuccess,
    leafIndex: some(regResult.leafIndex),
    configAccountId: some(regResult.configAccountId),
  )

proc initProtocolHandler(wg: WakuRlnGifter) =
  proc handler(conn: Connection, proto: string) {.async: (raises: [CancelledError]).} =
    var rpc: RlnGifterResponse

    var buffer: seq[byte]
    try:
      buffer = await conn.readLp(DefaultMaxRpcSize)
    except LPStreamError:
      error "rln-gifter read stream failed", error = getCurrentExceptionMsg()
      return

    try:
      rpc = await wg.handleRequest(conn.peerId, buffer)
    except CatchableError:
      error "rln-gifter handleRequest failed", error = getCurrentExceptionMsg()
      rpc = RlnGifterResponse(
        requestId: "N/A",
        statusCode: RlnGifterInternalError,
        statusDesc: some("internal error"),
      )

    try:
      await conn.writeLp(rpc.encode().buffer)
    except LPStreamError:
      error "rln-gifter write stream failed", error = getCurrentExceptionMsg()

  wg.handler = handler
  wg.codec = WakuRlnGifterCodec

proc new*(
    T: type WakuRlnGifter,
    peerManager: PeerManager,
    rng: ref rand.HmacDrbgContext,
    registerHandler: RegisterMemberHandler,
): T =
  let wg = WakuRlnGifter(
    rng: rng,
    peerManager: peerManager,
    registerHandler: registerHandler,
  )
  wg.initProtocolHandler()
  return wg
