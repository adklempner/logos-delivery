{.push raises: [].}

import
  std/[options, json, sets],
  results,
  chronicles,
  chronos,
  bearssl/rand,
  eth/common/[addresses, keys]
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

  EthAllowlistAuth* = ref object
    addresses*: HashSet[Address]
    consumed*: HashSet[Address]

  WakuRlnGifter* = ref object of LPProtocol
    rng*: ref rand.HmacDrbgContext
    peerManager*: PeerManager
    registerHandler*: RegisterMemberHandler
    auth*: Option[EthAllowlistAuth]

proc eip191Message*(idCommitmentHex: string): seq[byte] =
  let prefix = "\x19Ethereum Signed Message:\n" & $idCommitmentHex.len
  result = newSeqOfCap[byte](prefix.len + idCommitmentHex.len)
  for c in prefix:
    result.add(byte(c))
  for c in idCommitmentHex:
    result.add(byte(c))

proc verifyEip191*(
    idCommitmentHex: string, sigBytes: openArray[byte]
): Result[Address, string] =
  if sigBytes.len != 65:
    return err("signature must be 65 bytes, got " & $sigBytes.len)
  let sig = Signature.fromRaw(sigBytes).valueOr:
    return err("invalid signature encoding: " & $error)
  let pub = sig.recover(eip191Message(idCommitmentHex)).valueOr:
    return err("signature recovery failed: " & $error)
  ok(pub.to(Address))

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

  var authorizedSigner: Option[Address]
  if wg.auth.isSome:
    let auth = wg.auth.get()
    let payloadOpt = request.authPayload
    if payloadOpt.isNone:
      return RlnGifterResponse(
        requestId: request.requestId,
        statusCode: RlnGifterUnauthorized,
        statusDesc: some("missing auth payload"),
      )
    let signer = verifyEip191(request.idCommitment, payloadOpt.get()).valueOr:
      return RlnGifterResponse(
        requestId: request.requestId,
        statusCode: RlnGifterUnauthorized,
        statusDesc: some("signature verification failed: " & error),
      )
    if signer notin auth.addresses:
      return RlnGifterResponse(
        requestId: request.requestId,
        statusCode: RlnGifterUnauthorized,
        statusDesc: some("address not allowlisted: " & signer.to0xHex()),
      )
    if signer in auth.consumed:
      return RlnGifterResponse(
        requestId: request.requestId,
        statusCode: RlnGifterUnauthorized,
        statusDesc: some("address already used: " & signer.to0xHex()),
      )
    authorizedSigner = some(signer)

  let regResult = (await wg.registerHandler(request.idCommitment, request.rateLimit)).valueOr:
    error "RLN gifter registration failed", error = error
    return RlnGifterResponse(
      requestId: request.requestId,
      statusCode: RlnGifterRegistrationFailed,
      statusDesc: some(error),
    )

  if authorizedSigner.isSome and wg.auth.isSome:
    wg.auth.get().consumed.incl(authorizedSigner.get())

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
    # NOTE: Do NOT close the connection from the server side. The client closes
    # its side after reading the response. If the server closes first, the remote
    # FIN triggers yamux cleanup on the client side after createNode returns,
    # causing a use-after-free crash in the delivery module process.

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
    auth: Option[EthAllowlistAuth] = none(EthAllowlistAuth),
): T =
  let wg = WakuRlnGifter(
    rng: rng,
    peerManager: peerManager,
    registerHandler: registerHandler,
    auth: auth,
  )
  wg.initProtocolHandler()
  return wg
