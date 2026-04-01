import ffi
import std/locks
import results
import chronicles
import waku/factory/waku
import waku/waku_mix/logos_core_client as mix_rln_client
import waku/waku_rln_relay/logos_core_client as relay_rln_client

declareLibrary("logosdelivery")

var eventCallbackLock: Lock
initLock(eventCallbackLock)

template requireInitializedNode*(
    ctx: ptr FFIContext[Waku], opName: string, onError: untyped
) =
  if isNil(ctx):
    let errMsg {.inject.} = opName & " failed: invalid context"
    onError
  elif isNil(ctx.myLib) or isNil(ctx.myLib[]):
    let errMsg {.inject.} = opName & " failed: node is not initialized"
    onError

proc logosdelivery_set_event_callback(
    ctx: ptr FFIContext[Waku], callback: FFICallBack, userData: pointer
) {.dynlib, exportc, cdecl.} =
  if isNil(ctx):
    echo "error: invalid context in logosdelivery_set_event_callback"
    return

  # prevent race conditions that might happen due incorrect usage.
  eventCallbackLock.acquire()
  defer:
    eventCallbackLock.release()

  ctx[].eventCallback = cast[pointer](callback)
  ctx[].eventUserData = userData

proc logosdelivery_init(): cint {.dynlib, exportc, cdecl.} =
  initializeLibrary()
  when declared(setLogLevel):
    setLogLevel(LogLevel.WARN)
  return RET_OK

proc logosdelivery_set_rln_fetcher(
    ctx: ptr FFIContext[Waku], fetcher: mix_rln_client.RlnFetcherFunc, fetcherData: pointer
) {.dynlib, exportc, cdecl.} =
  if fetcher.isNil:
    echo "error: nil fetcher in logosdelivery_set_rln_fetcher"
    return
  mix_rln_client.setRlnFetcher(fetcher, fetcherData)
  relay_rln_client.setRlnFetcher(fetcher, fetcherData)

proc logosdelivery_set_rln_config(
    ctx: ptr FFIContext[Waku], configAccountId: cstring, leafIndex: cint
): cint {.dynlib, exportc, cdecl.} =
  if configAccountId.isNil:
    return RET_ERR
  mix_rln_client.setRlnConfig($configAccountId, leafIndex.int)
  relay_rln_client.setRlnConfig($configAccountId, leafIndex.int)
  return RET_OK

proc logosdelivery_set_rln_identity(
    ctx: ptr FFIContext[Waku], idSecretHashHex: cstring
) {.dynlib, exportc, cdecl.} =
  if idSecretHashHex.isNil:
    return
  relay_rln_client.setRlnIdentity($idSecretHashHex)

proc logosdelivery_push_roots(
    ctx: ptr FFIContext[Waku], rootsJson: cstring
) {.dynlib, exportc, cdecl.} =
  if rootsJson.isNil:
    return
  mix_rln_client.pushRoots($rootsJson)
  relay_rln_client.pushRoots($rootsJson)

proc logosdelivery_push_proof(
    ctx: ptr FFIContext[Waku], proofJson: cstring
) {.dynlib, exportc, cdecl.} =
  if proofJson.isNil:
    return
  mix_rln_client.pushProof($proofJson)
  relay_rln_client.pushProof($proofJson)

proc logosdelivery_generate_identity(
    ctx: ptr FFIContext[Waku], callback: FFICallBack, userData: pointer,
    walletAccountId: cstring
): cint {.dynlib, exportc, cdecl.} =
  if walletAccountId.isNil:
    if not callback.isNil:
      let msg = "walletAccountId is nil"
      callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](msg.len), userData)
    return RET_ERR

  # Call the fetcher with "generate_identity" method
  let result = relay_rln_client.callRlnFetcher("generate_identity", $walletAccountId)
  if result.isErr:
    if not callback.isNil:
      let errMsg = result.error
      callback(RET_ERR, unsafeAddr errMsg[0], cast[csize_t](errMsg.len), userData)
    return RET_ERR

  if not callback.isNil:
    let json = result.get()
    callback(RET_OK, unsafeAddr json[0], cast[csize_t](json.len), userData)
  return RET_OK

proc logosdelivery_register_member(
    ctx: ptr FFIContext[Waku], callback: FFICallBack, userData: pointer,
    paramsJson: cstring
): cint {.dynlib, exportc, cdecl.} =
  if paramsJson.isNil:
    if not callback.isNil:
      let msg = "paramsJson is nil"
      callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](msg.len), userData)
    return RET_ERR

  # Call the fetcher with "register_member" method
  let result = relay_rln_client.callRlnFetcher("register_member", $paramsJson)
  if result.isErr:
    if not callback.isNil:
      let errMsg = result.error
      callback(RET_ERR, unsafeAddr errMsg[0], cast[csize_t](errMsg.len), userData)
    return RET_ERR

  if not callback.isNil:
    let json = result.get()
    callback(RET_OK, unsafeAddr json[0], cast[csize_t](json.len), userData)
  return RET_OK

