// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// A BIP300 deposit (M5) found in a transaction: the sidechain slot and the sidechain address it
/// credits. Module-internal; it reaches the app as two plain `WalletTx` fields.
struct DrivechainDeposit: Equatable {
    let slot: Int32
    let address: String
}

/// BIP300 script rules. Module-internal (like `Descriptors`), consensus-level, and deliberately
/// NOT remote-configurable: a wrong opcode turns a deposit into anyone-can-spend coins
/// (`docs/sidechain-deposits.md` §2a).
///
/// Mirrors the enforcer: `OpDrivechain::parse` and `try_parse_op_return_address`
/// (`bip300301_enforcer/lib/messages.rs`), and `handle_m5_m6`'s "the address OP_RETURN is the output
/// immediately after the treasury" rule (`lib/validator/task/mod.rs`).
enum Drivechain {
    /// The byte this network's consensus uses for `OP_DRIVECHAIN`, or nil where BIP300 isn't
    /// enforced. Exhaustive on purpose: a new network, the real eCash fork above all, won't compile
    /// until someone looks up its opcode. It is a node build parameter (`--op-drivechain`), NOT
    /// derivable from anything else, and the two in use today already differ.
    static func opcode(for network: WalletNetwork) -> UInt8? {
        switch network {
        case .signet: return UInt8(0xb4)      // OP_NOP5: enforcer `NetworkParams::for_network`
        case .ecash: return UInt8(0xb4)       // OP_NOP5: alphanet
        case .ecashBeta: return UInt8(0xb7)   // OP_NOP8: betanet (verified on-chain, tx f83c5c7a…)
        case .bitcoin: return nil             // no BIP300
        case .thunder: return nil             // a sidechain, not a mainchain
        }
    }

    /// The slot a treasury output belongs to, or nil if `script` isn't one. A treasury script is
    /// exactly `<opcode> OP_PUSHBYTES_1 <slot> OP_TRUE`: four bytes, nothing more.
    static func treasurySlot(fromScript script: Data, opcode: UInt8) -> Int32? {
        guard script.count == 4 else { return nil }
        guard script[0] == opcode, script[1] == UInt8(0x01), script[3] == UInt8(0x51) else { return nil }
        return Int32(script[2])
    }

    /// The sidechain address carried by a deposit's OP_RETURN: `OP_RETURN` then exactly ONE data
    /// push, and nothing after it. Returns nil for anything else, including an empty push. The
    /// enforcer accepts an empty address, but no sidechain can credit one, so it isn't labelled a
    /// deposit.
    static func depositAddress(fromScript script: Data) -> String? {
        guard script.count >= 2, script[0] == UInt8(0x6a) else { return nil }
        let op = script[1]
        var start = 2
        var length = 0
        if op >= UInt8(0x01) && op <= UInt8(0x4b) {
            length = Int(op)
        } else if op == UInt8(0x4c) {            // OP_PUSHDATA1
            guard script.count >= 3 else { return nil }
            length = Int(script[2])
            start = 3
        } else if op == UInt8(0x4d) {            // OP_PUSHDATA2, little-endian length
            guard script.count >= 4 else { return nil }
            length = Int(script[2]) + Int(script[3]) * 256
            start = 4
        } else {
            return nil
        }
        // Exactly one push: the script must end where the push ends.
        guard length > 0, start + length == script.count else { return nil }
        let bytes = script.subdata(in: start..<(start + length))
        return String(data: bytes, encoding: .utf8)
    }

    /// The deposit in a transaction's outputs, if it is one: a treasury output whose NEXT output is
    /// the address OP_RETURN. A treasury output without that address after it is a withdrawal
    /// payout (M6) or an invalid deposit, and isn't labelled.
    static func deposit(inOutputScripts scripts: [Data], opcode: UInt8) -> DrivechainDeposit? {
        var i = 0
        while i < scripts.count {
            if let slot = treasurySlot(fromScript: scripts[i], opcode: opcode) {
                guard i + 1 < scripts.count, let address = depositAddress(fromScript: scripts[i + 1]) else {
                    return nil
                }
                return DrivechainDeposit(slot: slot, address: address)
            }
            i += 1
        }
        return nil
    }

    // MARK: - Building a deposit

    /// The treasury scriptPubKey for `slot`: `<opcode> OP_PUSHBYTES_1 <slot> OP_TRUE`.
    static func treasuryScript(opcode: UInt8, slot: Int32) -> Data {
        Data([opcode, UInt8(0x01), UInt8(slot), UInt8(0x51)])
    }

    /// The bytes a deposit's OP_RETURN carries for `address`, or nil if the address can't be a
    /// bare sidechain address. The `s<slot>_<address>_<checksum>` display form is refused
    /// outright: put in the OP_RETURN verbatim, the sidechain credits an address nobody controls
    /// (BitWindow `depositDestination`). The app unwraps it before it gets here; this is the
    /// engine refusing to trust that it did.
    static func depositAddressBytes(_ address: String) -> Data? {
        guard !address.isEmpty, !address.contains("_"), !address.contains(" ") else { return nil }
        let bytes = Data(address.utf8)
        // One push, and small enough for standard relay (80 bytes of OP_RETURN data).
        guard bytes.count <= 75 else { return nil }
        return bytes
    }

    /// Whether a transaction is exactly the deposit we meant to build. Run on the unsigned
    /// transaction (to reject a bad output order before signing) and again on the signed one
    /// (before broadcast). Every way a deposit can lose money is a check here:
    /// - exactly one treasury-shaped output, for OUR slot (none for any other slot);
    /// - its value is exactly `expectedTreasuryValue` (old treasury + deposit);
    /// - the output right after it is the OP_RETURN carrying OUR address;
    /// - the current treasury, when there is one, is spent exactly once.
    ///
    /// `inputs` / `treasuryOutpoint` are `"txid:vout"` strings, lowercase txid.
    static func isValidDeposit(outputScripts: [Data], outputValues: [Int64], inputs: [String],
                               opcode: UInt8, slot: Int32, address: String,
                               expectedTreasuryValue: Int64, treasuryOutpoint: String?) -> Bool {
        guard outputScripts.count == outputValues.count else { return false }
        var treasuryIndex = -1
        var i = 0
        while i < outputScripts.count {
            if let found = treasurySlot(fromScript: outputScripts[i], opcode: opcode) {
                guard found == slot, treasuryIndex == -1 else { return false }   // wrong slot, or two
                treasuryIndex = i
            }
            i += 1
        }
        guard treasuryIndex >= 0, treasuryIndex + 1 < outputScripts.count else { return false }
        guard outputValues[treasuryIndex] == expectedTreasuryValue else { return false }
        guard depositAddress(fromScript: outputScripts[treasuryIndex + 1]) == address else { return false }
        if let expected = treasuryOutpoint {
            var spends = 0
            for input in inputs {
                if input == expected { spends += 1 }
            }
            guard spends == 1 else { return false }
        }
        return true
    }
}
