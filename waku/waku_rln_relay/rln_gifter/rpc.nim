import std/options

type
  RlnGifterStatusCode* = distinct uint32

  RlnGifterRequest* = object
    requestId*: string
    idCommitment*: string # hex-encoded 32-byte commitment
    rateLimit*: uint64
    authPayload*: Option[seq[byte]] # opaque auth blob; format depends on the auth mechanism

  RlnGifterResponse* = object
    requestId*: string
    statusCode*: RlnGifterStatusCode
    statusDesc*: Option[string]
    leafIndex*: Option[uint64]
    configAccountId*: Option[string]

const
  RlnGifterSuccess* = RlnGifterStatusCode(200)
  RlnGifterBadRequest* = RlnGifterStatusCode(400)
  RlnGifterUnauthorized* = RlnGifterStatusCode(401)
  RlnGifterRateLimited* = RlnGifterStatusCode(429)
  RlnGifterInternalError* = RlnGifterStatusCode(500)
  RlnGifterRegistrationFailed* = RlnGifterStatusCode(502)

proc `==`*(a, b: RlnGifterStatusCode): bool {.borrow.}
