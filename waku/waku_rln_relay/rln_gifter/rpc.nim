import std/options

type
  MembershipAllocationSuccess* = object
    leafIndex*: uint64
    merkleRoot*: seq[byte]
    blockNumber*: uint64
    transactionHash*: seq[byte]
    # Extension (non-spec, high tag in the codec): the logos-LEZ config
    # account that owns the registered membership. Required by the LEZ-backed
    # RLN client to point subsequent on-chain queries at the right account.
    configAccountId*: Option[string]

  MembershipAllocationFailure* = object
    errorMessage*: string

  RlnGifterRequest* = object
    requestId*: string
    authenticationType*: seq[byte]
    authenticationPayload*: seq[byte]
    identityCommitment*: seq[byte]
    rateLimit*: Option[uint64]

  RlnGifterResponse* = object
    requestId*: string
    authSuccess*: bool
    error*: Option[string]
    success*: Option[MembershipAllocationSuccess]
    failure*: Option[MembershipAllocationFailure]

const
  EthAllowlistAuthType* = "eth-allowlist"
