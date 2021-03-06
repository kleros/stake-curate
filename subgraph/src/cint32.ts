import { BigInt } from "@graphprotocol/graph-ts"

export function decompress(cint32: BigInt): BigInt {
  if (cint32.lt(BigInt.fromU32(33_554_432))) {
    return cint32
  } else {
    const shift: u8 = cint32.rightShift(24).toU32() as u8
    return BigInt.fromU32(1)
      .leftShift(shift + 23)
      .plus(
        BigInt.fromU32(1)
          .leftShift(shift - 1)
          .times(cint32.minus(BigInt.fromU32(shift).leftShift(24)))
      )
  }
}
