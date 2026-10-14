import Foundation

/// Minimal arbitrary-precision unsigned integer for SRP-6a over the 3072-bit group: just what the
/// handshake needs (+, −, ×, mod, modular power, big-endian bytes). Little-endian 32-bit limbs, normalized
/// (no high zero limbs). Not constant-time: the values are ephemeral session secrets on a local pipe.
struct BigUInt: Equatable, Comparable, CustomStringConvertible, Sendable {
    private(set) var limbs: [UInt32]

    init(_ value: UInt64 = 0) {
        limbs = [UInt32(truncatingIfNeeded: value), UInt32(truncatingIfNeeded: value >> 32)]
        normalize()
    }

    private init(limbs: [UInt32]) {
        self.limbs = limbs
        normalize()
    }

    /// From big-endian bytes.
    init<C: Collection>(bytes: C) where C.Element == UInt8 {
        var limbs = [UInt32](repeating: 0, count: (bytes.count + 3) / 4)
        for (i, byte) in bytes.reversed().enumerated() { limbs[i / 4] |= UInt32(byte) << (8 * (i % 4)) }
        self.init(limbs: limbs)
    }

    init?(hex: String) {
        let digits = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        var bytes: [UInt8] = []
        var chars = Array(digits.filter { !$0.isWhitespace })
        if chars.count % 2 == 1 { chars.insert("0", at: 0) }
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let b = UInt8(String(chars[i...i + 1]), radix: 16) else { return nil }
            bytes.append(b)
        }
        self.init(bytes: bytes)
    }

    /// Minimal big-endian bytes (empty for zero), like JavaScript's BigInt-to-bytes in Apple's extension.
    var bytes: Data {
        var out = Data()
        for limb in limbs.reversed() {
            for shift in stride(from: 24, through: 0, by: -8) { out.append(UInt8(truncatingIfNeeded: limb >> UInt32(shift))) }
        }
        return out.drop(while: { $0 == 0 }).reduce(into: Data()) { $0.append($1) }
    }

    /// Big-endian bytes left-padded with zeros to `length`.
    func bytes(paddedTo length: Int) -> Data {
        let b = bytes
        return b.count >= length ? b : Data(repeating: 0, count: length - b.count) + b
    }

    var isZero: Bool { limbs.isEmpty }
    var description: String { "0x" + bytes.map { String(format: "%02x", $0) }.joined() }

    private mutating func normalize() {
        while limbs.last == 0 { limbs.removeLast() }
    }

    // MARK: Comparison

    static func < (a: BigUInt, b: BigUInt) -> Bool {
        if a.limbs.count != b.limbs.count { return a.limbs.count < b.limbs.count }
        for i in stride(from: a.limbs.count - 1, through: 0, by: -1) where a.limbs[i] != b.limbs[i] {
            return a.limbs[i] < b.limbs[i]
        }
        return false
    }

    // MARK: Arithmetic

    static func + (a: BigUInt, b: BigUInt) -> BigUInt {
        var out = [UInt32](repeating: 0, count: max(a.limbs.count, b.limbs.count) + 1)
        var carry: UInt64 = 0
        for i in 0..<out.count - 1 {
            let sum = UInt64(i < a.limbs.count ? a.limbs[i] : 0) + UInt64(i < b.limbs.count ? b.limbs[i] : 0) + carry
            out[i] = UInt32(truncatingIfNeeded: sum)
            carry = sum >> 32
        }
        out[out.count - 1] = UInt32(carry)
        return BigUInt(limbs: out)
    }

    /// `a − b`; requires `a ≥ b`.
    static func - (a: BigUInt, b: BigUInt) -> BigUInt {
        precondition(a >= b, "BigUInt underflow")
        var out = a.limbs
        var borrow: Int64 = 0
        for i in 0..<out.count {
            var diff = Int64(out[i]) - Int64(i < b.limbs.count ? b.limbs[i] : 0) - borrow
            borrow = diff < 0 ? 1 : 0
            if diff < 0 { diff += 1 << 32 }
            out[i] = UInt32(diff)
        }
        return BigUInt(limbs: out)
    }

    static func * (a: BigUInt, b: BigUInt) -> BigUInt {
        guard !a.isZero, !b.isZero else { return BigUInt() }
        var out = [UInt32](repeating: 0, count: a.limbs.count + b.limbs.count)
        for i in 0..<a.limbs.count {
            var carry: UInt64 = 0
            let ai = UInt64(a.limbs[i])
            for j in 0..<b.limbs.count {
                let t = ai * UInt64(b.limbs[j]) + UInt64(out[i + j]) + carry
                out[i + j] = UInt32(truncatingIfNeeded: t)
                carry = t >> 32
            }
            out[i + b.limbs.count] = UInt32(carry)
        }
        return BigUInt(limbs: out)
    }

    static func % (a: BigUInt, m: BigUInt) -> BigUInt { a.quotientAndRemainder(dividingBy: m).remainder }

    /// Knuth, TAOCP vol. 2, 4.3.1, Algorithm D.
    func quotientAndRemainder(dividingBy divisor: BigUInt) -> (quotient: BigUInt, remainder: BigUInt) {
        precondition(!divisor.isZero, "division by zero")
        if self < divisor { return (BigUInt(), self) }
        if divisor.limbs.count == 1 {
            let d = UInt64(divisor.limbs[0])
            var q = [UInt32](repeating: 0, count: limbs.count)
            var r: UInt64 = 0
            for i in stride(from: limbs.count - 1, through: 0, by: -1) {
                let cur = (r << 32) | UInt64(limbs[i])
                q[i] = UInt32(cur / d)
                r = cur % d
            }
            return (BigUInt(limbs: q), BigUInt(r))
        }
        // Normalize so the divisor's top limb has its high bit set.
        let shift = UInt32(divisor.limbs.last!.leadingZeroBitCount)
        let v = divisor.shiftedLeft(shift).limbs
        var u = shiftedLeft(shift).limbs
        if u.count == limbs.count { u.append(0) }
        let n = v.count, m = u.count - n
        var q = [UInt32](repeating: 0, count: m)
        let vTop = UInt64(v[n - 1]), vNext = UInt64(v[n - 2])
        for j in stride(from: m - 1, through: 0, by: -1) {
            let numerator = (UInt64(u[j + n]) << 32) | UInt64(u[j + n - 1])
            var qhat = numerator / vTop
            var rhat = numerator % vTop
            while qhat > 0xFFFF_FFFF || qhat * vNext > ((rhat << 32) | UInt64(u[j + n - 2])) {
                qhat -= 1
                rhat += vTop
                if rhat > 0xFFFF_FFFF { break }
            }
            // u[j...j+n] −= qhat · v
            var borrow: Int64 = 0
            var carry: UInt64 = 0
            for i in 0..<n {
                let p = qhat * UInt64(v[i]) + carry
                carry = p >> 32
                let t = Int64(u[i + j]) - borrow - Int64(p & 0xFFFF_FFFF)
                u[i + j] = UInt32(truncatingIfNeeded: t)
                borrow = t < 0 ? 1 : 0
            }
            let t = Int64(u[j + n]) - borrow - Int64(carry)
            u[j + n] = UInt32(truncatingIfNeeded: t)
            if t < 0 {  // qhat was one too large: add v back
                qhat -= 1
                var c: UInt64 = 0
                for i in 0..<n {
                    let s = UInt64(u[i + j]) + UInt64(v[i]) + c
                    u[i + j] = UInt32(truncatingIfNeeded: s)
                    c = s >> 32
                }
                u[j + n] = UInt32(truncatingIfNeeded: UInt64(u[j + n]) + c)
            }
            q[j] = UInt32(qhat)
        }
        let remainder = BigUInt(limbs: Array(u[0..<n])).shiftedRight(shift)
        return (BigUInt(limbs: q), remainder)
    }

    func shiftedLeft(_ bits: UInt32) -> BigUInt {
        guard bits > 0, !isZero else { return self }
        var out = [UInt32](repeating: 0, count: limbs.count + 1)
        for i in 0..<limbs.count {
            out[i] |= limbs[i] << bits
            out[i + 1] = limbs[i] >> (32 - bits)
        }
        return BigUInt(limbs: out)
    }

    func shiftedRight(_ bits: UInt32) -> BigUInt {
        guard bits > 0, !isZero else { return self }
        var out = [UInt32](repeating: 0, count: limbs.count)
        for i in 0..<limbs.count {
            out[i] = limbs[i] >> bits
            if i + 1 < limbs.count { out[i] |= limbs[i + 1] << (32 - bits) }
        }
        return BigUInt(limbs: out)
    }

    /// `self^exponent mod modulus`: Montgomery square-and-multiply for odd moduli (the SRP group), so the
    /// pairing stays fast even in debug builds; plain long division otherwise.
    func power(_ exponent: BigUInt, modulus: BigUInt) -> BigUInt {
        guard modulus.limbs.first.map({ $0 & 1 == 1 }) == true, modulus.limbs.count > 1 else { return slowPower(exponent, modulus: modulus) }
        let m = Montgomery(modulus)
        var result = m.toMontgomery(BigUInt(1))
        let base = m.toMontgomery(self % modulus)
        var scratch = [UInt64](repeating: 0, count: m.n + 2)
        for limb in exponent.limbs.reversed() {
            for bit in stride(from: 31, through: 0, by: -1) {
                result = m.multiply(result, result, &scratch)
                if (limb >> UInt32(bit)) & 1 == 1 { result = m.multiply(result, base, &scratch) }
            }
        }
        return m.fromMontgomery(result, &scratch)
    }

    private func slowPower(_ exponent: BigUInt, modulus: BigUInt) -> BigUInt {
        var result = BigUInt(1) % modulus
        let base = self % modulus
        for limb in exponent.limbs.reversed() {
            for bit in stride(from: 31, through: 0, by: -1) {
                result = (result * result) % modulus
                if (limb >> UInt32(bit)) & 1 == 1 { result = (result * base) % modulus }
            }
        }
        return result
    }

    /// 64-bit limbs, little-endian, padded to `count`.
    func words(_ count: Int) -> [UInt64] {
        (0..<count).map { i in
            let lo = 2 * i < limbs.count ? UInt64(limbs[2 * i]) : 0
            let hi = 2 * i + 1 < limbs.count ? UInt64(limbs[2 * i + 1]) : 0
            return lo | hi << 32
        }
    }

    init(words: [UInt64]) {
        self.init(limbs: words.flatMap { [UInt32(truncatingIfNeeded: $0), UInt32(truncatingIfNeeded: $0 >> 32)] })
    }
}

/// Montgomery arithmetic modulo an odd N (CIOS), on 64-bit limbs.
private struct Montgomery {
    let N: BigUInt
    let words: [UInt64]
    let n: Int
    let inverse: UInt64  // −N⁻¹ mod 2⁶⁴

    init(_ modulus: BigUInt) {
        N = modulus
        n = (modulus.limbs.count + 1) / 2
        words = modulus.words(n)
        var x: UInt64 = 1  // Newton iteration for N⁻¹ mod 2⁶⁴
        for _ in 0..<6 { x = x &* (2 &- words[0] &* x) }
        inverse = 0 &- x
    }

    func toMontgomery(_ a: BigUInt) -> [UInt64] { ((a.shiftedLeftWords(n)) % N).words(n) }

    func fromMontgomery(_ a: [UInt64], _ t: inout [UInt64]) -> BigUInt {
        var one = [UInt64](repeating: 0, count: n)
        one[0] = 1
        return BigUInt(words: multiply(a, one, &t))
    }

    func multiply(_ a: [UInt64], _ b: [UInt64], _ t: inout [UInt64]) -> [UInt64] {
        for i in 0..<t.count { t[i] = 0 }
        for i in 0..<n {
            var carry: UInt64 = 0
            let ai = a[i]
            for j in 0..<n {
                let (hi, lo) = ai.multipliedFullWidth(by: b[j])
                let (s1, c1) = t[j].addingReportingOverflow(lo)
                let (s2, c2) = s1.addingReportingOverflow(carry)
                t[j] = s2
                carry = hi &+ (c1 ? 1 : 0) &+ (c2 ? 1 : 0)
            }
            let (s, c) = t[n].addingReportingOverflow(carry)
            t[n] = s
            t[n + 1] = c ? 1 : 0
            let m = t[0] &* inverse
            var (hi, lo) = m.multipliedFullWidth(by: words[0])
            let (_, c0) = t[0].addingReportingOverflow(lo)
            carry = hi &+ (c0 ? 1 : 0)
            for j in 1..<n {
                (hi, lo) = m.multipliedFullWidth(by: words[j])
                let (s1, c1) = t[j].addingReportingOverflow(lo)
                let (s2, c2) = s1.addingReportingOverflow(carry)
                t[j - 1] = s2
                carry = hi &+ (c1 ? 1 : 0) &+ (c2 ? 1 : 0)
            }
            let (s3, c3) = t[n].addingReportingOverflow(carry)
            t[n - 1] = s3
            t[n] = t[n + 1] &+ (c3 ? 1 : 0)
        }
        var out = Array(t[0..<n])
        if t[n] != 0 || !isLess(out, words) {  // subtract N once
            var borrow = false
            for j in 0..<n {
                let (d1, b1) = out[j].subtractingReportingOverflow(words[j])
                let (d2, b2) = d1.subtractingReportingOverflow(borrow ? 1 : 0)
                out[j] = d2
                borrow = b1 || b2
            }
        }
        return out
    }

    private func isLess(_ a: [UInt64], _ b: [UInt64]) -> Bool {
        for i in stride(from: n - 1, through: 0, by: -1) where a[i] != b[i] { return a[i] < b[i] }
        return false
    }
}

extension BigUInt {
    /// `self · 2^(64·count)`.
    func shiftedLeftWords(_ count: Int) -> BigUInt { BigUInt(words: [UInt64](repeating: 0, count: count) + words((limbs.count + 1) / 2)) }
}
