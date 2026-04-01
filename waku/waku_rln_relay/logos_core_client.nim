{.push raises: [].}

## Relay RLN client: fetches roots/proofs from logos-core via C++ RLN module.
##
## Adapted from waku_mix/logos_core_client.nim for relay RLN use.
## The C++ delivery module registers an RLN fetcher at startup.
## Event-push caching provides fast access to roots/proofs.

import std/[json, strutils, locks, algorithm, options]
import chronos, chronos/threadsync
import results
import chronicles
import ./group_manager/logos_core/group_manager
import ./protocol_types

logScope:
  topics = "waku rln-relay logos-core-client"

type
  RlnFetchCallback* = proc(callerRet: cint, msg: ptr cchar, len: csize_t, userData: pointer) {.cdecl, gcsafe, raises: [].}
  RlnFetcherFunc* = proc(
    methodName: cstring, params: cstring,
    callback: RlnFetchCallback,
    callbackData: pointer, fetcherData: pointer
  ): cint {.cdecl, gcsafe, raises: [].}

var
  rlnFetcherLock: Lock
  rlnFetcher: RlnFetcherFunc
  rlnFetcherData: pointer
  rlnConfigAccountId: string
  rlnLeafIndex: int = -1
  rlnIdentitySecretHash: string
  rlnGroupManager: pointer  # Stores ref to LogosCoreGroupManager for deferred identity setting
  cachedRootsJson: string
  cachedProofJson: string

rlnFetcherLock.initLock()

proc setRlnFetcher*(fetcher: RlnFetcherFunc, fetcherData: pointer) {.gcsafe.} =
  {.gcsafe.}:
    rlnFetcherLock.acquire()
    rlnFetcher = fetcher
    rlnFetcherData = fetcherData
    rlnFetcherLock.release()

proc setRlnConfig*(configAccountId: string, leafIndex: int) {.gcsafe.} =
  {.gcsafe.}:
    rlnFetcherLock.acquire()
    rlnConfigAccountId = configAccountId
    rlnLeafIndex = leafIndex
    rlnFetcherLock.release()

proc setGroupManagerRef*(gm: pointer) {.gcsafe.} =
  {.gcsafe.}:
    rlnFetcherLock.acquire()
    rlnGroupManager = gm
    rlnFetcherLock.release()

proc setRlnIdentity*(idSecretHashHex: string) {.gcsafe.} =
  {.gcsafe.}:
    rlnFetcherLock.acquire()
    rlnIdentitySecretHash = idSecretHashHex
    let gm = rlnGroupManager
    let leafIdx = rlnLeafIndex
    rlnFetcherLock.release()

    trace "Set RLN identity secret hash", hashPrefix = idSecretHashHex[0 .. min(7, idSecretHashHex.len - 1)]

    # Set credentials on the group manager if available
    if not gm.isNil and idSecretHashHex.len == 64:
      var idSecretHash: seq[byte] = newSeq[byte](32)
      for i in 0 ..< 32:
        try:
          idSecretHash[i] = byte(parseHexInt(idSecretHashHex[i * 2 .. i * 2 + 1]))
        except ValueError:
          return
      let cred = IdentityCredential(
        idTrapdoor: newSeq[byte](32),
        idNullifier: newSeq[byte](32),
        idSecretHash: idSecretHash,
        idCommitment: newSeq[byte](32),
      )
      let gmRef = cast[LogosCoreGroupManager](gm)
      gmRef.idCredentials = some(cred)
      if leafIdx >= 0:
        gmRef.membershipIndex = some(MembershipIndex(leafIdx))
      info "Set RLN identity on group manager from deferred call"

proc getRlnIdentity*(): string {.gcsafe.} =
  {.gcsafe.}:
    rlnFetcherLock.acquire()
    result = rlnIdentitySecretHash
    rlnFetcherLock.release()

proc getRlnConfig*(): (string, int) {.gcsafe.} =
  {.gcsafe.}:
    rlnFetcherLock.acquire()
    result = (rlnConfigAccountId, rlnLeafIndex)
    rlnFetcherLock.release()

proc pushRoots*(rootsJson: string) {.gcsafe.} =
  {.gcsafe.}:
    rlnFetcherLock.acquire()
    cachedRootsJson = rootsJson
    rlnFetcherLock.release()
    trace "Received roots via event push", len = rootsJson.len

proc pushProof*(proofJson: string) {.gcsafe.} =
  {.gcsafe.}:
    rlnFetcherLock.acquire()
    cachedProofJson = proofJson
    rlnFetcherLock.release()
    trace "Received proof via event push", len = proofJson.len

proc getCachedRoots(): string {.gcsafe.} =
  {.gcsafe.}:
    rlnFetcherLock.acquire()
    result = cachedRootsJson
    rlnFetcherLock.release()

proc getCachedProof(): string {.gcsafe.} =
  {.gcsafe.}:
    rlnFetcherLock.acquire()
    result = cachedProofJson
    rlnFetcherLock.release()

type FetchResult = object
  json: string
  errMsg: string
  success: bool

proc callRlnFetcher*(methodName: string, params: string): Result[string, string] {.gcsafe.} =
  {.gcsafe.}:
    rlnFetcherLock.acquire()
    let fetcher = rlnFetcher
    let data = rlnFetcherData
    rlnFetcherLock.release()

    if fetcher.isNil:
      return err("RLN fetcher not registered")

    var fetchResult: FetchResult

    let cb: RlnFetchCallback = proc(callerRet: cint, msg: ptr cchar, len: csize_t, userData: pointer) {.cdecl, gcsafe, raises: [].} =
      let res = cast[ptr FetchResult](userData)
      if callerRet == 0 and not msg.isNil and len > 0:
        res[].json = newString(len.int)
        copyMem(addr res[].json[0], msg, len.int)
        res[].success = true
      elif not msg.isNil and len > 0:
        res[].errMsg = newString(len.int)
        copyMem(addr res[].errMsg[0], msg, len.int)
        res[].success = false
      else:
        res[].success = (callerRet == 0)

    let ret = fetcher(methodName.cstring, params.cstring, cb, addr fetchResult, data)
    if ret != 0 or not fetchResult.success:
      if fetchResult.errMsg.len > 0:
        return err(fetchResult.errMsg)
      return err("RLN fetcher returned error code: " & $ret)
    if fetchResult.json.len == 0:
      return err("RLN fetcher returned empty response")
    return ok(fetchResult.json)

type
  RegisterMemberFunc* = proc(
    paramsJson: cstring,
    callback: RlnFetchCallback,
    callbackData: pointer,
    fetcherData: pointer
  ): cint {.cdecl, gcsafe, raises: [].}

var
  registerMemberFunc: RegisterMemberFunc
  registerMemberData: pointer

proc setRegisterMemberFunc*(f: RegisterMemberFunc, data: pointer) {.gcsafe.} =
  {.gcsafe.}:
    rlnFetcherLock.acquire()
    registerMemberFunc = f
    registerMemberData = data
    rlnFetcherLock.release()

type ThreadArgs = object
  fetcher: RlnFetcherFunc
  fetcherData: pointer
  methodBuf: cstring
  paramsBuf: cstring
  res: ptr FetchResult
  sig: ThreadSignalPtr

proc fetcherThreadBody(args: ThreadArgs) {.thread.} =
  let cb: RlnFetchCallback = proc(callerRet: cint, msg: ptr cchar, len: csize_t, userData: pointer) {.cdecl, gcsafe, raises: [].} =
    let r = cast[ptr FetchResult](userData)
    if callerRet == 0 and not msg.isNil and len > 0:
      r[].json = newString(len.int)
      copyMem(addr r[].json[0], msg, len.int)
      r[].success = true
    elif not msg.isNil and len > 0:
      r[].errMsg = newString(len.int)
      copyMem(addr r[].errMsg[0], msg, len.int)
      r[].success = false
    else:
      r[].success = (callerRet == 0)

  discard args.fetcher(args.methodBuf, args.paramsBuf, cb, args.res, args.fetcherData)
  discard args.sig.fireSync()

proc callRlnFetcherAsync*(methodName: string, params: string): Future[Result[string, string]] {.async.} =
  ## Async wrapper — runs the fetcher on a dedicated thread to avoid blocking the chronos event loop.
  {.gcsafe.}:
    rlnFetcherLock.acquire()
    let fetcher = rlnFetcher
    let data = rlnFetcherData
    rlnFetcherLock.release()

    if fetcher.isNil:
      return err("RLN fetcher not registered")

    let signal = ThreadSignalPtr.new().valueOr:
      return err("failed to create thread signal")
    defer:
      discard signal.close()

    # Allocate stable copies of strings for the thread
    var methodCopy = allocShared0(methodName.len + 1)
    var paramsCopy = allocShared0(params.len + 1)
    copyMem(methodCopy, unsafeAddr methodName[0], methodName.len)
    copyMem(paramsCopy, unsafeAddr params[0], params.len)
    defer:
      deallocShared(methodCopy)
      deallocShared(paramsCopy)

    var fetchRes: FetchResult
    var thread: Thread[ThreadArgs]

    createThread(thread, fetcherThreadBody,
      ThreadArgs(
        fetcher: fetcher,
        fetcherData: data,
        methodBuf: cast[cstring](methodCopy),
        paramsBuf: cast[cstring](paramsCopy),
        res: addr fetchRes,
        sig: signal,
      ))

    await signal.wait()
    joinThread(thread)

    if not fetchRes.success:
      if fetchRes.errMsg.len > 0:
        return err(fetchRes.errMsg)
      return err("RLN fetcher async call failed")
    if fetchRes.json.len == 0:
      return err("RLN fetcher returned empty response")
    return ok(fetchRes.json)

proc hexToBytes32(hex: string): Result[array[32, byte], string] =
  var h = hex
  if h.startsWith("0x") or h.startsWith("0X"):
    h = h[2 .. ^1]
  if h.len != 64:
    return err("Expected 64 hex chars, got " & $h.len)
  var output: array[32, byte]
  for i in 0 ..< 32:
    try:
      output[i] = byte(parseHexInt(h[i * 2 .. i * 2 + 1]))
    except ValueError:
      return err("Invalid hex at position " & $i)
  ok(output)

proc hexToBytes32LE(hex: string): Result[array[32, byte], string] =
  ## Parse hex string to bytes in little-endian order (for zerokit field elements).
  ## LEZ/Ethereum return big-endian hex; zerokit expects LE internally.
  var res = hexToBytes32(hex).valueOr:
    return err(error)
  var reversed: array[32, byte]
  for i in 0 ..< 32:
    reversed[i] = res[31 - i]
  ok(reversed)

proc parseRootsJson*(snapshot: string): Result[seq[MerkleNode], string] =
  if snapshot.len == 0:
    return err("No roots data")
  try:
    let parsed = parseJson(snapshot)
    var roots: seq[MerkleNode]
    for elem in parsed:
      let root = hexToBytes32(elem.getStr()).valueOr:
        return err("Invalid root hex: " & error)
      roots.add(MerkleNode(root))
    return ok(roots)
  except CatchableError as e:
    return err("Failed to parse roots: " & e.msg)

proc parseExternalProof(snapshot: string): Result[ExternalMerkleProof, string] =
  if snapshot.len == 0:
    return err("No merkle proof data")
  try:
    let parsed = parseJson(snapshot)
    let root = hexToBytes32(parsed["root"].getStr()).valueOr:
      return err("Invalid root hex: " & error)
    var pathElements: seq[byte]
    for elem in parsed["path_elements"]:
      let elemBytes = hexToBytes32(elem.getStr()).valueOr:
        return err("Invalid pathElement hex: " & error)
      for b in elemBytes:
        pathElements.add(b)
    var identityPathIndex: seq[byte]
    for idx in parsed["path_indices"]:
      identityPathIndex.add(byte(idx.getInt()))
    ok(ExternalMerkleProof(
      pathElements: pathElements,
      identityPathIndex: identityPathIndex,
      root: MerkleNode(root),
    ))
  except CatchableError as e:
    err("Failed to parse proof: " & e.msg)

proc makeFetchLatestRoots*(): FetchLatestRootsCallback =
  return proc(): Future[Result[seq[MerkleNode], string]] {.async, gcsafe, raises: [].} =
    let cached = getCachedRoots()
    if cached.len > 0:
      let res = parseRootsJson(cached)
      if res.isOk:
        trace "Using cached roots from event push", count = res.get().len
      return res
    let (configAccount, _) = getRlnConfig()
    if configAccount.len == 0:
      return err("RLN config not set")
    let rootsJson = callRlnFetcher("get_valid_roots", configAccount)
    if rootsJson.isErr:
      return err(rootsJson.error)
    let res = parseRootsJson(rootsJson.get())
    if res.isOk:
      trace "Fetched roots from RLN module via fetcher", count = res.get().len
    return res

proc makeFetchMerkleProof*(): FetchMerkleProofCallback =
  return proc(
      index: MembershipIndex
  ): Future[Result[ExternalMerkleProof, string]] {.async, gcsafe, raises: [].} =
    let cached = getCachedProof()
    if cached.len > 0:
      let res = parseExternalProof(cached)
      if res.isOk:
        trace "Using cached proof from event push", index = index
      return res
    let (configAccount, leafIndex) = getRlnConfig()
    if configAccount.len == 0:
      return err("RLN config not set")
    let params = configAccount & "," & $leafIndex
    let proofJson = callRlnFetcher("get_merkle_proofs", params)
    if proofJson.isErr:
      return err(proofJson.error)
    let res = parseExternalProof(proofJson.get())
    if res.isOk:
      trace "Fetched merkle proof from RLN module via fetcher", index = index
    return res

{.pop.}
