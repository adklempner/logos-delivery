## LEZ mix+RLN wiring extracted from node_factory so the upstream file only
## carries two hook calls. setupLezMix runs inside setupProtocols right after
## mountMix; startLezMix runs at the end of startNode once the switch,
## static-node connections and peer manager are up.
import logos_delivery/waku/compat/option_valueor
import
  std/[atomics, options, json, strutils, sets],
  eth/common/[addresses, keys],
  chronicles,
  chronos,
  mix_rln_spam_protection/onchain_group_manager,
  mix_rln_spam_protection/rln_interface as mix_rln_interface

import
  ./waku_conf,
  ../waku_node,
  ../waku_core,
  ../waku_core/codecs,
  ../node/peer_manager,
  ../waku_mix/logos_core_client as mix_lez_client,
  ../waku_mix/protocol as mix_protocol,
  ../waku_rln_relay/rln_gifter/protocol as rln_gifter_protocol,
  ../waku_rln_relay/rln_gifter/client as rln_gifter_client

proc setupLezMix*(
    node: WakuNode, mixConf: MixConf
): Future[Result[void, string]] {.async.} =
  ## Wire OnchainLEZGroupManager to the LEZ RLN module via the fetcher
  ## callback bridge (setRlnConfig is called later by the C++ plugin),
  ## and mount the gifter service when configured.
  if not mixConf.useOnchainLEZ or node.wakuMix.isNil:
    return ok()

  let gm = node.wakuMix.mixRlnSpamProtection.groupManager
  if not (gm of OnchainLEZGroupManager):
    return ok()

  let lezGm = OnchainLEZGroupManager(gm)
  # Adapt logos_core_client callbacks to OnchainLEZGroupManager types
  let clientFetchRoots = mix_lez_client.makeFetchLatestRoots()
  let clientFetchProof = mix_lez_client.makeFetchMerkleProof()

  let fetchRoots: onchain_group_manager.FetchRootsCallback = clientFetchRoots
  let fetchProof: onchain_group_manager.FetchProofCallback = clientFetchProof
  lezGm.setFetchCallbacks(fetchRoots, fetchProof)
  mix_lez_client.setGroupManagerRef(lezGm)
  info "Wired LEZ callbacks for mix RLN spam protection"

  # On-demand roots-window refresh: verifyProof's root-miss branch
  # (mix-hop verifier) fires this requester on the libp2p thread —
  # flag-set only, non-blocking; the drain loop picks it up on the
  # next chronos tick and pushes fresh roots into the plugin's
  # tracker via applyHostRoots. Uses SYNC callRlnFetcher (the async
  # helper crashes with a cross-thread GC bug).
  var refreshFlag {.global.}: Atomic[bool]
  proc refreshRequester() {.gcsafe, raises: [].} =
    refreshFlag.store(true, moRelaxed)

  lezGm.setHostRefreshRequester(refreshRequester)

  let gmRef = lezGm
  proc rootsDrainLoop() {.async: (raises: [CancelledError]).} =
    while true:
      await sleepAsync(200.milliseconds)
      if not refreshFlag.exchange(false, moRelaxed):
        continue
      let (configAccount, _) = mix_lez_client.getRlnConfig()
      if configAccount.len == 0:
        continue
      let rootsRes = mix_lez_client.callRlnFetcher("get_valid_roots", configAccount)
      if rootsRes.isErr:
        continue
      let roots = mix_lez_client.parseRootsJson(rootsRes.get())
      if roots.isOk:
        gmRef.applyHostRoots(roots.get())

  asyncSpawn rootsDrainLoop()

  # Mount RLN gifter server if configured
  if mixConf.gifterService:
    let walletAccount = mixConf.gifterWalletAccount

    # All gifter-initiated registrations funnel through a single
    # serialization worker so the gifter's wallet never has two
    # unconfirmed txns outstanding from the same signer — concurrent
    # submissions otherwise silently fail at the sequencer with
    # "Nonce mismatch" because the wallet refetches the chain nonce
    # per call and several submissions read the same value before
    # any commits.
    #
    # The libp2p handler enqueues a job with an optimistic
    # leaf_index taken from a local counter, returns immediately
    # (so the stream doesn't time out), and the worker drains the
    # queue one tx at a time. Clients reconcile the authoritative
    # leaf via the existing status RPC + watcher.
    type GifterJob = ref object
      identityCommitment: seq[byte]
      rateLimit: uint64
      assigned: uint64

    let gifterQueue = newAsyncQueue[GifterJob]()
    var gifterNextLeaf: uint64 = 0

    proc gifterSubmitOnce(
        idc: seq[byte], rateLimit: uint64
    ): Future[Result[uint64, string]] {.async, gcsafe.} =
      let (configAccount, _) = mix_lez_client.getRlnConfig()
      if configAccount.len == 0:
        return err("RLN config not set on gifter node")
      let holdingAccount =
        if walletAccount.len > 0: walletAccount else: configAccount
      let idCommitmentHex = mix_lez_client.bytesToHexUpper(idc)
      let params =
        "{\"configAccountId\":\"" & configAccount & "\",\"userHoldingAccountId\":\"" &
        holdingAccount & "\",\"idCommitment\":\"" & idCommitmentHex &
        "\",\"rateLimit\":" & $rateLimit & "}"
      # ASYNC off-thread submit: register_member is a 60-90s QtRO→wallet→chain
      # round-trip. Running it synchronously on the chronos loop froze the
      # gifter (node stops serving libp2p / the gift protocol for the whole
      # submit — the cause of the self-registration freeze). The off-thread
      # path keeps the event loop live.
      let regResult = await mix_lez_client.callRlnFetcherAsync("register_member", params)
      if regResult.isErr:
        return err(regResult.error)
      try:
        let parsed = parseJson(regResult.get())
        if parsed.hasKey("error"):
          return err(parsed["error"].getStr("register_member failed"))
        return ok(parsed["leaf_index"].getInt().uint64)
      except CatchableError as e:
        return err("failed to parse register_member result: " & e.msg)

    proc waitForChainCommit(
        idc: seq[byte], deadlineMs: int
    ): Future[Result[uint64, string]] {.async, gcsafe.} =
      ## Poll is_member_registered until the just-submitted tx
      ## commits. Without this gate, the worker's next iteration
      ## would race the wallet nonce-refetch against the previous
      ## tx's block inclusion and submit two txns with the same
      ## nonce.
      const pollMs = 2_000
      let (configAccount, _) = mix_lez_client.getRlnConfig()
      if configAccount.len == 0:
        return err("RLN config not set")
      let idHex = mix_lez_client.bytesToHexUpper(idc)
      let params =
        "{\"configAccountId\":\"" & configAccount & "\",\"idCommitment\":\"" & idHex &
        "\"}"
      let deadline = Moment.now() + chronos.milliseconds(deadlineMs)
      while Moment.now() < deadline:
        await sleepAsync(chronos.milliseconds(pollMs))
        # Off-thread: keep the gifter's event loop live across the whole
        # multi-minute confirmation poll (same rationale as gifterSubmitOnce).
        let raw = await mix_lez_client.callRlnFetcherAsync("is_member_registered", params)
        if raw.isErr:
          continue
        try:
          let parsed = parseJson(raw.get())
          if parsed.hasKey("registered") and parsed["registered"].getBool() and
              parsed.hasKey("leaf_index"):
            return ok(parsed["leaf_index"].getInt().uint64)
        except JsonParsingError as e:
          warn "waitForChainCommit: bad JSON from is_member_registered", error = e.msg
          continue
        except JsonKindError as e:
          warn "waitForChainCommit: unexpected JSON shape", error = e.msg
          continue
      return err("confirmation timeout")

    proc gifterWorker() {.async, gcsafe.} =
      # Confirmation deadline must cover one block-include cycle plus
      # propagation lag on the slowest chain we ship against. Testnet
      # blocks ~60-90s + finality lag → 5min headroom.
      const confirmDeadlineMs = 300_000
      while true:
        let job = await gifterQueue.popFirst()
        let res = await gifterSubmitOnce(job.identityCommitment, job.rateLimit)
        if res.isErr:
          error "Gifter worker: submission failed",
            optimistic = job.assigned, err = res.error
          continue
        # Wait until the tx commits before processing the next job
        # so the wallet's next nonce fetch sees the advanced value.
        let confRes =
          await waitForChainCommit(job.identityCommitment, confirmDeadlineMs)
        if confRes.isErr:
          warn "Gifter worker: tx did not confirm within deadline",
            optimistic = job.assigned, err = confRes.error
          continue
        let actual = confRes.get()
        if actual >= gifterNextLeaf:
          gifterNextLeaf = actual + 1
        if actual != job.assigned:
          info "Gifter worker: chain leaf differs from optimistic ack",
            optimistic = job.assigned, actual = actual
        else:
          debug "Gifter worker: submission accepted at expected leaf", leaf = actual

    let registerHandler: rln_gifter_protocol.RegisterMemberHandler = proc(
        identityCommitment: seq[byte], rateLimit: uint64
    ): Future[Result[rln_gifter_protocol.MembershipAllocationSuccess, string]] {.
        async, gcsafe
    .} =
      let (configAccount, _) = mix_lez_client.getRlnConfig()
      if configAccount.len == 0:
        return err("RLN config not set on gifter node")
      let assigned = gifterNextLeaf
      gifterNextLeaf += 1
      let job = GifterJob(
        identityCommitment: identityCommitment,
        rateLimit: rateLimit,
        assigned: assigned,
      )
      try:
        await gifterQueue.addLast(job)
      except CatchableError as e:
        return err("failed to enqueue gifter job: " & e.msg)
      return ok(
        rln_gifter_protocol.MembershipAllocationSuccess(
          leafIndex: assigned,
          merkleRoot: @[],
          blockNumber: 0'u64,
          transactionHash: @[],
          configAccountId: some(configAccount),
        )
      )

    var auth = none(rln_gifter_protocol.EthAllowlistAuth)
    if mixConf.gifterAllowlist.len > 0:
      var addrs: HashSet[Address]
      for piece in mixConf.gifterAllowlist.split(','):
        let s = piece.strip()
        if s.len == 0:
          continue
        let parsedAddr =
          try:
            Address.fromHex(s)
          except ValueError as e:
            return err("invalid gifter allowlist address '" & s & "': " & e.msg)
        addrs.incl(parsedAddr)
      if addrs.len > 0:
        auth = some(
          rln_gifter_protocol.EthAllowlistAuth(
            addresses: addrs, consumed: initHashSet[Address]()
          )
        )
        info "RLN gifter allowlist auth enabled", count = addrs.len

    let statusHandler: rln_gifter_protocol.MembershipStatusHandler = proc(
        configAccountId: string, identityCommitment: seq[byte]
    ): Future[Result[rln_gifter_protocol.MembershipStatusResponse, string]] {.
        async, gcsafe
    .} =
      let idHex = mix_lez_client.bytesToHexUpper(identityCommitment)
      let params =
        "{\"configAccountId\":\"" & configAccountId & "\",\"idCommitment\":\"" & idHex &
        "\"}"
      let raw = mix_lez_client.callRlnFetcher("is_member_registered", params)
      if raw.isErr:
        return err(raw.error)
      try:
        let parsed = parseJson(raw.get())
        var resp = rln_gifter_protocol.MembershipStatusResponse(registered: false)
        if parsed.hasKey("registered") and parsed["registered"].getBool():
          resp.registered = true
          if parsed.hasKey("leaf_index"):
            resp.leafIndex = some(parsed["leaf_index"].getInt().uint64)
        return ok(resp)
      except CatchableError as e:
        return err("failed to parse is_member_registered: " & e.msg)

    let gifter = rln_gifter_protocol.WakuRlnGifter.new(
      node.peerManager, node.rng, registerHandler, auth, statusHandler
    )
    node.switch.mount(gifter, protocolMatcher(WakuRlnGifterCodec))
    node.wakuRlnGifter = gifter
    let gifterStatus = rln_gifter_protocol.WakuRlnGifterStatus.new(statusHandler)
    node.switch.mount(gifterStatus, protocolMatcher(WakuRlnGifterStatusCodec))
    asyncSpawn gifterWorker()
    info "RLN gifter service mounted for mix", statusCodec = WakuRlnGifterStatusCodec

  # Defer client registration to startNode (needs running switch).
  if mixConf.gifterNode.len > 0:
    info "Gifter client mode: registration deferred to startNode()"

  return ok()

proc startLezMix*(
    node: WakuNode, mixConf: MixConf
): Future[Result[void, string]] {.async: (raises: []).} =
  ## Deferred LEZ startup: poll loop, gifter self/client registration and
  ## the gossipsub re-trigger. Requires a started switch.
  if not mixConf.useOnchainLEZ or node.wakuMix.isNil():
    return ok()

  # Start deferred OnchainLEZ poll loop now that the switch is fully started.
  block startPollingBlock:
    let gm = node.wakuMix.mixRlnSpamProtection.groupManager
    if gm of OnchainLEZGroupManager:
      OnchainLEZGroupManager(gm).startPolling()

  # The gifter is also a mix relay and needs its own membership to forward.
  # Deferred to startNode so the wallet RPC subprocess is wired first.
  if mixConf.gifterService and not node.wakuRlnGifter.isNil():
    let gm = node.wakuMix.mixRlnSpamProtection.groupManager
    if gm of OnchainLEZGroupManager:
      let lezGm = OnchainLEZGroupManager(gm)
      if lezGm.membershipIndex.isNone:
        let selfCred =
          if lezGm.credentials.isSome:
            lezGm.credentials.get()
          else:
            mix_rln_interface.membershipKeyGen().valueOr:
              return err("failed to generate gifter RLN identity: " & $error)
        let gifter = node.wakuRlnGifter
        asyncSpawn (
          proc(): Future[void] {.async.} =
            # Handler reads configAccount, which is set by setRlnConfig.
            while true:
              let (cfg, _) = mix_lez_client.getRlnConfig()
              if cfg.len > 0:
                break
              await sleepAsync(500.milliseconds)
            info "Self-registering gifter as mix relay",
              identityCommitmentLen = selfCred.idCommitment.len
            try:
              let selfRes = await gifter.registerHandler(
                @(selfCred.idCommitment), uint64(lezGm.userMessageLimit)
              )
              if selfRes.isErr:
                warn "Gifter self-registration failed", error = selfRes.error
                return
              let success = selfRes.get()
              if success.configAccountId.isNone:
                warn "Gifter self-registration response missing configAccountId"
                return
              let configAccount = success.configAccountId.get()
              lezGm.credentials = some(selfCred)
              lezGm.membershipIndex =
                some(onchain_group_manager.MembershipIndex(success.leafIndex))
              mix_lez_client.setRlnConfig(configAccount, success.leafIndex.int)
              info "Gifter self-registered as mix relay",
                leafIndex = success.leafIndex, configAccount = configAccount
              # The gifter's own handler now returns an optimistic leaf
              # (queued submission); poll the status RPC in-process to
              # reconcile if the chain assigned a different leaf.
              let watcherLezGm = lezGm
              let watcherConfigAccount = configAccount
              let watcherIdc = @(selfCred.idCommitment)
              let optimisticLeaf = success.leafIndex
              asyncSpawn (
                proc(): Future[void] {.async.} =
                  const selfPollMs = 5_000
                  const selfDeadlineMs = 1_800_000
                  let deadline = Moment.now() + chronos.milliseconds(selfDeadlineMs)
                  while Moment.now() < deadline:
                    try:
                      await sleepAsync(chronos.milliseconds(selfPollMs))
                    except CancelledError:
                      return
                    let qr =
                      try:
                        await gifter.statusHandler(watcherConfigAccount, watcherIdc)
                      except CancelledError:
                        return
                      except CatchableError as e:
                        debug "Gifter self-reg watcher: statusHandler raised",
                          error = e.msg
                        continue
                    if qr.isErr:
                      continue
                    let resp = qr.get()
                    if not resp.registered:
                      continue
                    if resp.leafIndex.isNone:
                      continue
                    let authLeaf = resp.leafIndex.get()
                    if some(onchain_group_manager.MembershipIndex(authLeaf)) !=
                        watcherLezGm.membershipIndex:
                      info "Gifter self-reg leaf corrected from optimistic",
                        optimistic = optimisticLeaf, authoritative = authLeaf
                      watcherLezGm.membershipIndex =
                        some(onchain_group_manager.MembershipIndex(authLeaf))
                      mix_lez_client.setRlnConfig(watcherConfigAccount, authLeaf.int)
                    else:
                      info "Gifter self-reg confirmed on-chain", leafIndex = authLeaf
                    watcherLezGm.markMembershipConfirmed()
                    return
                  warn "Gifter self-reg confirmation timed out",
                    optimisticLeaf = optimisticLeaf
              )()
            except CatchableError as e:
              warn "Gifter self-registration exception", error = e.msg
        )()

  # RLN gifter client registration — runs after switch start so the gifter
  # peer is reachable.
  if mixConf.gifterNode.len > 0:
    let gm = node.wakuMix.mixRlnSpamProtection.groupManager
    if gm of OnchainLEZGroupManager:
      let lezGm = OnchainLEZGroupManager(gm)
      let gifterClient =
        rln_gifter_client.WakuRlnGifterClient.new(node.peerManager, node.rng)
      let gifterPeer = parsePeerInfo(mixConf.gifterNode).valueOr:
        return err("failed to parse gifter peer: " & error)
      node.peerManager.addServicePeer(gifterPeer, WakuRlnGifterCodec)

      # Use keystore credentials if available, otherwise generate new ones
      let idCred =
        if lezGm.credentials.isSome:
          lezGm.credentials.get()
        else:
          mix_rln_interface.membershipKeyGen().valueOr:
            return err("failed to generate RLN identity: " & $error)
      let idCommitmentBytes = @(idCred.idCommitment)

      info "Registering via RLN gifter",
        gifterPeer = mixConf.gifterNode,
        identityCommitmentLen = idCommitmentBytes.len,
        fromKeystore = lezGm.credentials.isSome

      var authType: seq[byte]
      var authPayload: seq[byte]
      if mixConf.gifterAuthKey.len > 0:
        let seckey = PrivateKey.fromHex(mixConf.gifterAuthKey).valueOr:
          return err("invalid mix-gifter-auth-key: " & $error)
        let sig = seckey.sign(rln_gifter_protocol.eip191Message(idCommitmentBytes))
        authPayload = @(sig.toRaw())
        for c in rln_gifter_protocol.EthAllowlistAuthType:
          authType.add(byte(c))
        info "Signing gifter request with EIP-191 auth key",
          signer = seckey.toPublicKey().to(Address).to0xHex()

      var success: rln_gifter_protocol.MembershipAllocationSuccess
      try:
        let res = await gifterClient.requestMembership(
          idCommitmentBytes,
          some(uint64(lezGm.userMessageLimit)),
          gifterPeer,
          authType,
          authPayload,
        )
        if res.isErr:
          return err("failed to register via gifter: " & res.error)
        success = res.get()
      except CatchableError:
        return err("gifter registration exception: " & getCurrentExceptionMsg())

      let configAccountId = success.configAccountId.valueOr:
        return err("gifter response missing configAccountId extension")

      lezGm.credentials = some(idCred)
      lezGm.membershipIndex =
        some(onchain_group_manager.MembershipIndex(success.leafIndex))
      mix_lez_client.setRlnConfig(configAccountId, success.leafIndex.int)

      info "Registered via RLN gifter",
        leafIndex = success.leafIndex, configAccount = configAccountId

      # Correct the optimistic leaf via the status codec if a concurrent
      # registration tx beat ours to the slot. Self-verify drops bad proofs
      # until the poll loop picks up the corrected witness.
      let watcherLezGm = lezGm
      let watcherConfigAccount = configAccountId
      asyncSpawn gifterClient.watchMembershipConfirmation(
        gifterPeer,
        configAccountId,
        idCommitmentBytes,
        success.leafIndex,
        "Mix-node",
        proc(authLeaf: uint64) {.gcsafe, raises: [].} =
          if some(onchain_group_manager.MembershipIndex(authLeaf)) !=
              watcherLezGm.membershipIndex:
            watcherLezGm.membershipIndex =
              some(onchain_group_manager.MembershipIndex(authLeaf))
            mix_lez_client.setRlnConfig(watcherConfigAccount, authLeaf.int)
          watcherLezGm.markMembershipConfirmed(),
      )

  # Re-publish gossipsub trigger after switch + kademlia are up. The dummy
  # publish in WakuMix.start() fires too early in LEZ mode (0 peers on topic),
  # so SUBSCRIBE messages never propagate without this second publish.
  try:
    await node.wakuMix.publishGossipsubTrigger()
  except CatchableError:
    warn "gossipsub trigger publish failed", error = getCurrentExceptionMsg()

  return ok()
