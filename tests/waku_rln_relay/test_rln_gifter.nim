{.used.}

import std/options, results
import testutils/unittests
import eth/common/[addresses, keys]
import waku/waku_rln_relay/rln_gifter/rpc
import waku/waku_rln_relay/rln_gifter/rpc_codec
import waku/waku_rln_relay/rln_gifter/protocol as rln_gifter_protocol

proc eip191Sign(seckey: PrivateKey, idCommitmentHex: string): seq[byte] =
  @(seckey.sign(eip191Message(idCommitmentHex)).toRaw())

const
  TestSecretHex =
    "1111111111111111111111111111111111111111111111111111111111111111"
  TestCommitment =
    "abababababababababababababababababababababababababababababababab"

suite "RLN gifter EIP-191 auth":
  test "verifyEip191 recovers the signer address":
    let sk = PrivateKey.fromHex(TestSecretHex).expect("valid key")
    let expected = sk.toPublicKey().to(Address)
    let sig = eip191Sign(sk, TestCommitment)

    let recovered = verifyEip191(TestCommitment, sig).expect("recoverable")
    check recovered == expected

  test "verifyEip191 rejects wrong-length payload":
    let bad = newSeq[byte](64)
    let res = verifyEip191(TestCommitment, bad)
    check res.isErr

  test "verifyEip191 produces a different address when the message differs":
    let sk = PrivateKey.fromHex(TestSecretHex).expect("valid key")
    let expected = sk.toPublicKey().to(Address)
    let sig = eip191Sign(sk, TestCommitment)

    let tampered =
      "cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd"
    let recovered = verifyEip191(tampered, sig).expect("recoverable")
    check recovered != expected

  test "verifyEip191 rejects malformed signature bytes":
    let bogus = newSeq[byte](65)
    let res = verifyEip191(TestCommitment, bogus)
    check res.isErr

suite "RLN gifter request codec":
  test "round-trips authPayload when present":
    let payload = @[byte 0xde, 0xad, 0xbe, 0xef]
    let req = RlnGifterRequest(
      requestId: "req-1",
      idCommitment: TestCommitment,
      rateLimit: 42'u64,
      authPayload: some(payload),
    )
    let decoded = RlnGifterRequest.decode(req.encode().buffer).expect("decodes")
    check:
      decoded.requestId == "req-1"
      decoded.idCommitment == TestCommitment
      decoded.rateLimit == 42'u64
      decoded.authPayload.isSome
      decoded.authPayload.get() == payload

  test "round-trips with authPayload absent (backward compat)":
    let req = RlnGifterRequest(
      requestId: "req-2",
      idCommitment: TestCommitment,
      rateLimit: 7'u64,
      authPayload: none(seq[byte]),
    )
    let decoded = RlnGifterRequest.decode(req.encode().buffer).expect("decodes")
    check:
      decoded.requestId == "req-2"
      decoded.idCommitment == TestCommitment
      decoded.rateLimit == 7'u64
      decoded.authPayload.isNone
