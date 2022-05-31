import { BigInt } from "@graphprotocol/graph-ts"

export function decompress(cint32: BigInt): BigInt {
  if (cint32.lt(BigInt.fromI32(33_554_432))) {
    return cint32
  } else {
    const shift: i32 = cint32.rightShift(24).toI32()
    return BigInt.fromI32(1)
      .leftShift(shift + 23)
      .plus(
        BigInt.fromI32(1)
          .leftShift(shift - 1)
          .times(cint32.minus(BigInt.fromI32(shift).leftShift(24)))
      )
  }
}
