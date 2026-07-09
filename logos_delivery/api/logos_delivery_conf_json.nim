{.push raises: [].}

import std/[json, options, strutils, tables]
import results

import tools/confutils/conf_from_json
import logos_delivery/api/logos_delivery_conf

const
  # Lowercased, since `collectJsonFields` keys the object case-insensitively.
  KeyMode = "mode"
  KeyPreset = "preset"
  KeyMessagingOverrides = "messagingoverrides"
  KeyChannelsOverrides = "channelsoverrides"
  KeyKernelOverrides = "kerneloverrides"

proc parseMode(s: string): Result[WakuMode, string] =
  case s.strip().toLowerAscii()
  of "core":
    return ok(WakuMode.Core)
  of "edge":
    return ok(WakuMode.Edge)
  else:
    return err("invalid mode: '" & s & "' (expected 'Core' or 'Edge')")

proc parseOverrides[T](node: JsonNode, label: string): Result[T, string] =
  if node.kind != JObject:
    return err(label & " must be a JSON object")
  var fields = ?collectJsonFields(node)
  var conf = T()
  ?applyJsonFieldsToConf(
    conf,
    fields,
    "Failed to parse " & label & " field",
    "Unrecognized " & label & " option(s) found",
  )
  return ok(conf)

proc parseLogosDeliveryConf*(jsonStr: string): ConfResult[LogosDeliveryConf] =
  var node: JsonNode
  try:
    node = parseJson(jsonStr)
  except CatchableError as e:
    return err("invalid JSON: " & e.msg)
  if node.kind != JObject:
    return err("configuration JSON must be an object")

  var top = ?collectJsonFields(node)
  var mode = WakuMode.Core
  var preset = ""
  var messagingOverrides = MessagingClientConf()
  var channelsOverrides = ReliableChannelManagerConf()

  if top.hasKey(KeyMode):
    let (_, v) = top.getOrDefault(KeyMode)
    if v.kind != JString:
      return err("mode must be a string")
    mode = ?parseMode(v.getStr())
    top.del(KeyMode)

  if top.hasKey(KeyPreset):
    let (_, v) = top.getOrDefault(KeyPreset)
    if v.kind != JString:
      return err("preset must be a string")
    preset = v.getStr().strip()
    top.del(KeyPreset)

  if top.hasKey(KeyMessagingOverrides):
    let (_, v) = top.getOrDefault(KeyMessagingOverrides)
    messagingOverrides = ?parseOverrides[MessagingClientConf](v, "messagingOverrides")
    top.del(KeyMessagingOverrides)

  if top.hasKey(KeyChannelsOverrides):
    let (_, v) = top.getOrDefault(KeyChannelsOverrides)
    channelsOverrides =
      ?parseOverrides[ReliableChannelManagerConf](v, "channelsOverrides")
    top.del(KeyChannelsOverrides)

  var kernelOverrides: Option[JsonNode]
  if top.hasKey(KeyKernelOverrides):
    let (_, v) = top.getOrDefault(KeyKernelOverrides)
    if v.kind != JObject:
      return err("kernelOverrides must be a JSON object")
    kernelOverrides = some(v)
    top.del(KeyKernelOverrides)

  if top.len > 0:
    var keys: seq[string]
    for _, (k, _) in pairs(top):
      keys.add(k)
    return err("Unrecognized configuration option(s) found: " & keys.join(", "))

  var conf = ?LogosDeliveryConf.init(mode, preset, messagingOverrides, channelsOverrides)

  # Advanced escape hatch: apply raw kernel (WakuNodeConf) fields, by field or
  # CLI name, on top of the mode/preset/messaging-derived kernel config. Needed
  # by consumers that tune kernel-only options the messaging surface does not
  # mirror (e.g. mix, static peers, discovery details).
  if kernelOverrides.isSome():
    var fields = ?collectJsonFields(kernelOverrides.get())
    ?applyJsonFieldsToConf(
      conf.kernelConf,
      fields,
      "Failed to parse kernelOverrides field",
      "Unrecognized kernelOverrides option(s) found",
    )

  return ok(conf)

{.pop.}
