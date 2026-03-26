{.used.}

## Test suite for mix protocol with lightpush integration.
## Progressively tests from basic mix routing to full lightpush-via-mix.
## Run: source env.sh && nim c -r --threads:on -d:libp2p_mix_experimental_exit_is_dest tests/test_mix_lightpush.nim

import chronos, results, stew/byteutils, options, sequtils
import
  libp2p/[
    protocols/mix,
    protocols/mix/mix_node,
    protocols/mix/mix_protocol,
    protocols/mix/sphinx,
    protocols/ping,
    peerid,
    multiaddress,
    switch,
    builders,
    crypto/crypto,
    crypto/secp,
    stream/connection,
  ]

import waku/waku_lightpush/common # for WakuLightPushCodec

import tools/lifecycle
import tools/unittest
import libp2p/mix/utils

suite "Mix + LightPush Integration":
  asyncTeardown:
    checkTrackers()
    deleteNodeInfoFolder()
    deletePubInfoFolder()

  ## Test 1: Basic mix send with exit == destination (raw bytes)
  ## This replicates test_conn.nim's working test to confirm baseline.
  asyncTest "Step 1 - basic mix send, exit == dest, raw bytes":
    let nodes = await setupMixNodes(5)

    let destNode = nodes[^1]
    let testCodec = "/test/step1/1.0.0"

    var received = newFuture[seq[byte]]()
    let destProto = LPProtocol.new()
    destProto.codec = testCodec
    destProto.handler = proc(
        conn: Connection, proto: string
    ) {.async: (raises: [CancelledError]).} =
      try:
        let data = await conn.readLp(1024)
        received.complete(data)
      except CatchableError as e:
        received.fail(e)

    destNode.switch.mount(destProto)
    destNode.registerDestReadBehavior(testCodec, readLp(1024))

    startAndDeferStop(nodes)

    let conn = nodes[0]
      .toConnection(
        MixDestination.exitNode(destNode.switch.peerInfo.peerId),
        testCodec,
      )
      .expect("could not build connection")

    let payload = "hello from mix step 1".toBytes()
    await conn.writeLp(payload)
    await conn.close()

    let result = await received.wait(10.seconds)
    check result == payload

  ## Test 2: Mix send with SURB reply, exit == destination
  ## Tests the reply path which lightpush needs.
  asyncTest "Step 2 - mix send with reply (SURB), exit == dest":
    let nodes = await setupMixNodes(
      5, destReadBehavior = Opt.some((codec: PingCodec, callback: readExactly(32)))
    )

    let destNode = nodes[^1]
    let pingProto = Ping.new()
    destNode.switch.mount(pingProto)

    startAndDeferStop(nodes)

    let conn = nodes[0]
      .toConnection(
        MixDestination.exitNode(destNode.switch.peerInfo.peerId),
        PingCodec,
        MixParameters(expectReply: Opt.some(true), numSurbs: Opt.some(byte(1))),
      )
      .expect("could not build connection")

    let response = await pingProto.ping(conn)
    await conn.close()

    check response != 0.seconds

  ## Test 3: Mix send with lightpush codec — exit node handles lightpush request
  ## Uses WakuLightPushCodec as the destination codec. This is the closest
  ## to what chat2mix does.
  asyncTest "Step 3 - mix send with lightpush codec, exit == dest":
    let nodes = await setupMixNodes(
      5,
      destReadBehavior = Opt.some(
        (codec: WakuLightPushCodec, callback: readLp(int(-1)))
      ),
    )

    let destNode = nodes[^1]

    # Track received lightpush requests
    var received = newFuture[seq[byte]]()

    # Mount a simple lightpush handler that captures the request
    let lpProto = LPProtocol.new()
    lpProto.codec = WakuLightPushCodec
    lpProto.handler = proc(
        conn: Connection, proto: string
    ) {.async: (raises: [CancelledError]).} =
      try:
        let data = await conn.readLp(65536)
        received.complete(data)
        # Send a minimal response
        let response = @[0.byte] # dummy response
        await conn.writeLp(response)
      except CatchableError as e:
        received.fail(e)

    destNode.switch.mount(lpProto)

    startAndDeferStop(nodes)

    let conn = nodes[0]
      .toConnection(
        MixDestination.exitNode(destNode.switch.peerInfo.peerId),
        WakuLightPushCodec,
        MixParameters(expectReply: Opt.some(true), numSurbs: Opt.some(byte(1))),
      )
      .expect("could not build connection")

    let payload = "lightpush request via mix".toBytes()
    await conn.writeLp(payload)

    let result = await received.wait(10.seconds)
    check result == payload

    # Read the response via SURB
    let response = await conn.readLp(1024).wait(10.seconds)
    await conn.close()

    check response == @[0.byte]

  ## Test 4: Full WakuMix integration — uses WakuMix.new() instead of raw MixProtocol
  ## This tests the Waku-level wrapping that chat2mix and wakunode2 use.
  asyncTest "Step 4 - WakuMix lightpush via mix (in-process)":
    # Create raw mix nodes for the relay path
    let nodes = await setupMixNodes(
      5,
      destReadBehavior = Opt.some(
        (codec: WakuLightPushCodec, callback: readLp(int(-1)))
      ),
    )

    let destNode = nodes[^1]

    var received = newFuture[seq[byte]]()
    let lpProto = LPProtocol.new()
    lpProto.codec = WakuLightPushCodec
    lpProto.handler = proc(
        conn: Connection, proto: string
    ) {.async: (raises: [CancelledError]).} =
      try:
        let data = await conn.readLp(65536)
        received.complete(data)
        await conn.writeLp(@[0.byte])
      except CatchableError as e:
        received.fail(e)

    destNode.switch.mount(lpProto)

    startAndDeferStop(nodes)

    # Now create a sender that goes through WakuMix wrapping
    # (This mimics what lightpush_publisher_mix does)
    let senderMix = nodes[0]

    let conn = senderMix
      .toConnection(
        MixDestination.exitNode(destNode.switch.peerInfo.peerId),
        WakuLightPushCodec,
        MixParameters(expectReply: Opt.some(true), numSurbs: Opt.some(byte(1))),
      )
      .expect("could not build connection")

    let payload = "waku lightpush via mix".toBytes()
    await conn.writeLp(payload)

    let result = await received.wait(10.seconds)
    check result == payload

    let response = await conn.readLp(1024).wait(10.seconds)
    await conn.close()
    check response == @[0.byte]

  ## Test 5: Pre-existing connection — reproduces the production bug.
  ## In production, peerManager.start() dials all peers before mix sends.
  ## This creates yamux connections. When sendPacket later opens a /mix/1.0.0
  ## stream on the existing yamux connection, it fails with "Stream Closed!".
  asyncTest "Step 5 - mix send AFTER pre-existing connection (bug repro)":
    let nodes = await setupMixNodes(
      5,
      destReadBehavior = Opt.some(
        (codec: WakuLightPushCodec, callback: readLp(int(-1)))
      ),
    )

    let destNode = nodes[^1]

    var received = newFuture[seq[byte]]()
    let lpProto = LPProtocol.new()
    lpProto.codec = WakuLightPushCodec
    lpProto.handler = proc(
        conn: Connection, proto: string
    ) {.async: (raises: [CancelledError]).} =
      try:
        let data = await conn.readLp(65536)
        received.complete(data)
        await conn.writeLp(@[0.byte])
      except CatchableError as e:
        received.fail(e)

    destNode.switch.mount(lpProto)

    startAndDeferStop(nodes)

    # KEY DIFFERENCE: establish connections to ALL mix nodes BEFORE sending
    # This mimics what peerManager.start() does in production
    let sender = nodes[0]
    for i in 1 ..< nodes.len:
      let targetPeer = nodes[i].switch.peerInfo
      try:
        discard await sender.switch.dial(
          targetPeer.peerId, targetPeer.addrs, @["/ipfs/id/1.0.0"]
        )
      except CatchableError:
        discard # OK if identify dial fails, yamux connection is still established

    # Small delay to let connections settle
    await sleepAsync(100.milliseconds)

    # Now try mix send — in production this fails with "Stream Closed!"
    let conn = sender
      .toConnection(
        MixDestination.exitNode(destNode.switch.peerInfo.peerId),
        WakuLightPushCodec,
        MixParameters(expectReply: Opt.some(true), numSurbs: Opt.some(byte(1))),
      )
      .expect("could not build connection")

    let payload = "mix after pre-existing connection".toBytes()
    await conn.writeLp(payload)

    let result = await received.wait(10.seconds)
    check result == payload

    let response = await conn.readLp(1024).wait(10.seconds)
    await conn.close()
    check response == @[0.byte]
