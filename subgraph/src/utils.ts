import {
  BigInt,
  ipfs,
  json,
  JSONValue,
  JSONValueKind,
  log,
  TypedMap,
} from "@graphprotocol/graph-ts"

export function JSONValueToString(value: JSONValue | null): string | null {
  if (value == null || value.isNull()) {
    return null
  }

  switch (value.kind) {
    case JSONValueKind.BOOL:
      return value.toBool().toString()
    case JSONValueKind.STRING:
      return value.toString()
    case JSONValueKind.NUMBER:
      return value.toBigInt().toString()
    default:
      return null
  }
}

export function JSONValueToBool(value: JSONValue | null): boolean {
  if (value == null || value.isNull()) {
    return false
  }

  switch (value.kind) {
    case JSONValueKind.BOOL:
      return value.toBool()
    case JSONValueKind.STRING:
      if (value.toString() === "true") {
        return true
      } else {
        return false
      }
    default:
      return false
  }
}

export function JSONValueToBigInt(value: JSONValue | null): BigInt | null {
  if (value == null || value.isNull()) {
    return null
  }

  switch (value.kind) {
    case JSONValueKind.STRING:
      return BigInt.fromString(value.toString())
    case JSONValueKind.NUMBER:
      return value.toBigInt()
    default:
      return null
  }
}

export function JSONValueToObject(
  value: JSONValue | null
): TypedMap<string, JSONValue> | null {
  if (value == null || value.isNull()) {
    return null
  }

  switch (value.kind) {
    case JSONValueKind.OBJECT:
      return value.toObject()
    default:
      return null
  }
}

export function JSONValueToArray(
  value: JSONValue | null
): JSONValue[] | null {
  if (value == null || value.isNull()) {
    return null
  }

  switch (value.kind) {
    case JSONValueKind.ARRAY:
      return value.toArray()
    default:
      return null
  }
}

export function ipfsToJsonValueOrNull(uri: string): JSONValue | null {
  let jsonBytes = ipfs.cat(uri)
  // ipfsUri could be malformatted or file non-available.
  if (!jsonBytes) {
    log.error("Failed to fetch JSON from uri {}", [uri])
    return null
  }

  let jsonObjValue = json.fromBytes(jsonBytes)
  if (!jsonObjValue) {
    log.error("Error getting json object value, from uri {}", [uri])
    return null
  }

  return jsonObjValue
}
