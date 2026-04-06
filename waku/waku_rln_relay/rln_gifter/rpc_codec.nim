{.push raises: [].}

import std/options
import ../../common/protobuf, ./rpc

const DefaultMaxRpcSize* = 4096

proc encode*(rpc: RlnGifterRequest): ProtoBuffer =
  var pb = initProtoBuffer()
  pb.write3(1, rpc.requestId)
  pb.write3(2, rpc.idCommitment)
  pb.write3(3, rpc.rateLimit)
  pb.finish3()
  return pb

proc decode*(T: type RlnGifterRequest, buffer: seq[byte]): ProtobufResult[T] =
  let pb = initProtoBuffer(buffer)
  var rpc = RlnGifterRequest()

  var requestId: string
  if not ?pb.getField(1, requestId):
    return err(ProtobufError.missingRequiredField("request_id"))
  rpc.requestId = requestId

  var idCommitment: string
  if not ?pb.getField(2, idCommitment):
    return err(ProtobufError.missingRequiredField("id_commitment"))
  rpc.idCommitment = idCommitment

  var rateLimit: uint64
  if not ?pb.getField(3, rateLimit):
    rpc.rateLimit = 100 # default
  else:
    rpc.rateLimit = rateLimit

  return ok(rpc)

proc encode*(rpc: RlnGifterResponse): ProtoBuffer =
  var pb = initProtoBuffer()
  pb.write3(1, rpc.requestId)
  pb.write3(10, rpc.statusCode.uint32)
  pb.write3(11, rpc.statusDesc)
  pb.write3(12, rpc.leafIndex)
  pb.write3(13, rpc.configAccountId)
  pb.finish3()
  return pb

proc decode*(T: type RlnGifterResponse, buffer: seq[byte]): ProtobufResult[T] =
  let pb = initProtoBuffer(buffer)
  var rpc = RlnGifterResponse()

  var requestId: string
  if not ?pb.getField(1, requestId):
    return err(ProtobufError.missingRequiredField("request_id"))
  rpc.requestId = requestId

  var statusCode: uint32
  if not ?pb.getField(10, statusCode):
    return err(ProtobufError.missingRequiredField("status_code"))
  rpc.statusCode = RlnGifterStatusCode(statusCode)

  var statusDesc: string
  if ?pb.getField(11, statusDesc):
    rpc.statusDesc = some(statusDesc)

  var leafIndex: uint64
  if ?pb.getField(12, leafIndex):
    rpc.leafIndex = some(leafIndex)

  var configAccountId: string
  if ?pb.getField(13, configAccountId):
    rpc.configAccountId = some(configAccountId)

  return ok(rpc)
