## LogosCoreGroupManager: RLN group manager backed by logos-core (LEZ).
##
## Replaces the Ethereum-based OnchainGroupManager for deployments
## using logos-core for RLN membership management. Roots and merkle
## proofs are fetched via abstract callbacks, same pattern as mix.

import std/[deques, options, sets, hashes, sequtils, algorithm]
import chronos, results, chronicles
import stew/[arrayops]
import nimcrypto/keccak as keccak

import ../../protocol_types, ../../constants, ../../protocol_metrics
import ../../conversion_utils
import ../../rln/rln_interface, ../../rln/wrappers
import ../group_manager_base

export group_manager_base

logScope:
  topics = "waku rln-relay logos-core-gm"

type
  ExternalMerkleProof* = object
    pathElements*: seq[byte]
    identityPathIndex*: seq[byte]
    root*: MerkleNode

  FetchLatestRootsCallback* = proc(): Future[Result[seq[MerkleNode], string]] {.
    async, gcsafe, raises: []
  .}

  FetchMerkleProofCallback* = proc(
    index: MembershipIndex
  ): Future[Result[ExternalMerkleProof, string]] {.async, gcsafe, raises: [].}

  LogosCoreGroupManager* = ref object of GroupManager
    fetchLatestRoots: Option[FetchLatestRootsCallback]
    fetchMerkleProof: Option[FetchMerkleProofCallback]
    pollIntervalSeconds: float
    pollFuture: Future[void]
    isSynced: bool
    cachedProof: Option[ExternalMerkleProof]
    rootSet: HashSet[MerkleNode]

proc hash*(node: MerkleNode): Hash =
  var h: Hash = 0
  for b in node:
    h = h !& int(b)
  result = !$h

proc newLogosCoreGroupManager*(
    rlnInstance: ptr RLN,
    pollIntervalSeconds: float = 5.0,
): LogosCoreGroupManager =
  let gm = LogosCoreGroupManager(
    fetchLatestRoots: none(FetchLatestRootsCallback),
    fetchMerkleProof: none(FetchMerkleProofCallback),
    pollIntervalSeconds: pollIntervalSeconds,
    pollFuture: nil,
    isSynced: false,
    cachedProof: none(ExternalMerkleProof),
    rootSet: initHashSet[MerkleNode](),
  )
  gm.rlnInstance = rlnInstance
  gm.validRoots = initDeque[MerkleNode]()
  gm

proc setFetchLatestRoots*(
    gm: LogosCoreGroupManager, cb: FetchLatestRootsCallback
) =
  gm.fetchLatestRoots = some(cb)

proc setFetchMerkleProof*(
    gm: LogosCoreGroupManager, cb: FetchMerkleProofCallback
) =
  gm.fetchMerkleProof = some(cb)

proc addRoot(gm: LogosCoreGroupManager, root: MerkleNode) =
  if root in gm.rootSet:
    return
  if gm.validRoots.len >= AcceptableRootWindowSize:
    let old = gm.validRoots.popFirst()
    gm.rootSet.excl(old)
  gm.validRoots.addLast(root)
  gm.rootSet.incl(root)

proc pollLoop(gm: LogosCoreGroupManager) {.async.} =
  while gm.isSynced:
    if gm.fetchLatestRoots.isSome:
      let res = await gm.fetchLatestRoots.get()()
      if res.isOk:
        let roots = res.get()
        for i in countdown(roots.high, 0):
          gm.addRoot(roots[i])
        trace "Polled valid roots from logos-core", count = roots.len
      else:
        warn "Failed to fetch valid roots from logos-core", error = res.error

    if gm.fetchMerkleProof.isSome and gm.membershipIndex.isSome:
      let res = await gm.fetchMerkleProof.get()(gm.membershipIndex.get())
      if res.isOk:
        gm.cachedProof = some(res.get())
        gm.addRoot(res.get().root)
        trace "Cached merkle proof from logos-core",
          index = gm.membershipIndex.get()
      else:
        warn "Failed to fetch merkle proof from logos-core", error = res.error

    await sleepAsync(seconds(gm.pollIntervalSeconds.int64))

method init*(
    gm: LogosCoreGroupManager
): Future[GroupManagerResult[void]] {.async.} =
  if gm.initialized:
    return ok()

  if gm.fetchLatestRoots.isSome:
    let res = await gm.fetchLatestRoots.get()()
    if res.isOk:
      let roots = res.get()
      for i in countdown(roots.high, 0):
        gm.addRoot(roots[i])
      debug "Seeded root tracker from logos-core", rootCount = roots.len
    else:
      warn "Could not fetch initial roots from logos-core", error = res.error

  gm.initialized = true
  info "LogosCoreGroupManager initialized"
  ok()

method startGroupSync*(
    gm: LogosCoreGroupManager
): Future[GroupManagerResult[void]] {.async.} =
  if not gm.initialized:
    return err("Group manager not initialized")

  gm.isSynced = true
  gm.pollFuture = gm.pollLoop()

  info "LogosCoreGroupManager started polling",
    intervalSeconds = gm.pollIntervalSeconds
  ok()

method stop*(gm: LogosCoreGroupManager): Future[void] {.async.} =
  gm.isSynced = false
  if gm.pollFuture != nil and not gm.pollFuture.finished:
    await gm.pollFuture.cancelAndWait()
  info "LogosCoreGroupManager stopped"

method register*(
    gm: LogosCoreGroupManager, credentials: IdentityCredential,
    userMessageLimit: UserMessageLimit
): Future[void] {.async: (raises: [Exception]).} =
  gm.idCredentials = some(credentials)
  gm.userMessageLimit = some(userMessageLimit)
  info "Registered self with logos-core group manager",
    messageLimit = userMessageLimit

method generateProof*(
    gm: LogosCoreGroupManager,
    data: seq[byte],
    epoch: Epoch,
    messageId: MessageId,
    rlnIdentifier = DefaultRlnIdentifier,
): GroupManagerResult[RateLimitProof] =
  if gm.idCredentials.isNone():
    return err("identity credentials not set")
  if gm.userMessageLimit.isNone():
    return err("user message limit not set")
  if gm.cachedProof.isNone:
    return err("no cached merkle proof (logos-core not responding?)")

  let proof = gm.cachedProof.get()
  let identity_secret = seqToField(gm.idCredentials.get().idSecretHash)
  let user_message_limit = uint64ToField(gm.userMessageLimit.get())
  let message_id = uint64ToField(messageId)

  # Path elements are already in LE format from logos-core (LEZ stores as LE)
  let path_elements = proof.pathElements

  let x = keccak.keccak256.digest(data)
  let extNullifier = generateExternalNullifier(epoch, rlnIdentifier).valueOr:
    return err("Failed to compute external nullifier: " & error)

  let witness = RLNWitnessInput(
    identity_secret: identity_secret,
    user_message_limit: user_message_limit,
    message_id: message_id,
    path_elements: path_elements,
    identity_path_index: proof.identityPathIndex,
    x: x,
    external_nullifier: extNullifier,
  )

  let serializedWitness = serialize(witness)
  var input_witness_buffer = toBuffer(serializedWitness)
  var output_witness_buffer: Buffer

  let success = generate_proof_with_witness(
    gm.rlnInstance, addr input_witness_buffer, addr output_witness_buffer
  )
  if not success:
    return err("Failed to generate proof")

  var proofValue = cast[ptr array[320, byte]](output_witness_buffer.`ptr`)
  let proofBytes: array[320, byte] = proofValue[]

  let
    proofOffset = 128
    rootOffset = proofOffset + 32
    externalNullifierOffset = rootOffset + 32
    shareXOffset = externalNullifierOffset + 32
    shareYOffset = shareXOffset + 32
    nullifierOffset = shareYOffset + 32

  var
    zkproof: ZKSNARK
    proofRoot, shareX, shareY: MerkleNode
    externalNullifier: ExternalNullifier
    nullifier: Nullifier

  discard zkproof.copyFrom(proofBytes[0 .. proofOffset - 1])
  discard proofRoot.copyFrom(proofBytes[proofOffset .. rootOffset - 1])
  discard
    externalNullifier.copyFrom(proofBytes[rootOffset .. externalNullifierOffset - 1])
  discard shareX.copyFrom(proofBytes[externalNullifierOffset .. shareXOffset - 1])
  discard shareY.copyFrom(proofBytes[shareXOffset .. shareYOffset - 1])
  discard nullifier.copyFrom(proofBytes[shareYOffset .. nullifierOffset - 1])

  let output = RateLimitProof(
    proof: zkproof,
    merkleRoot: proofRoot,
    externalNullifier: externalNullifier,
    epoch: epoch,
    rlnIdentifier: rlnIdentifier,
    shareX: shareX,
    shareY: shareY,
    nullifier: nullifier,
  )

  info "Proof generated successfully via logos-core"
  waku_rln_remaining_proofs_per_epoch.dec()
  waku_rln_total_generated_proofs.inc()
  ok(output)

method verifyProof*(
    gm: LogosCoreGroupManager, input: seq[byte], proof: RateLimitProof
): GroupManagerResult[bool] =
  var normalizedProof = proof
  let externalNullifier =
    generateExternalNullifier(proof.epoch, proof.rlnIdentifier).valueOr:
      return err("Failed to compute external nullifier: " & error)
  normalizedProof.externalNullifier = externalNullifier

  let proofBytes = serialize(normalizedProof, input)
  let proofBuffer = proofBytes.toBuffer()

  let rootsBytes = serialize(gm.validRoots.items().toSeq())
  let rootsBuffer = rootsBytes.toBuffer()

  var validProof: bool
  let ffiOk = verify_with_roots(
    gm.rlnInstance,
    addr proofBuffer,
    addr rootsBuffer,
    addr validProof,
  )

  if not ffiOk:
    return err("could not verify the proof")

  ok(validProof)

method isReady*(gm: LogosCoreGroupManager): Future[bool] {.async.} =
  return gm.initialized and gm.isSynced and gm.idCredentials.isSome and
    gm.cachedProof.isSome
