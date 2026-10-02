import Crypto
import Foundation

enum OpenSSHKeyError: LocalizedError, Equatable {
    case missingPEMBody
    case invalidBase64
    case invalidFormat(String)
    case encryptedKeysUnsupported
    case unsupportedKeyType(String)
    case multipleKeysUnsupported

    var errorDescription: String? {
        switch self {
        case .missingPEMBody:
            "No OPENSSH PRIVATE KEY block found. Paste the full key file, "
                + "including the BEGIN/END lines."
        case .invalidBase64:
            "The key body is not valid base64."
        case let .invalidFormat(detail):
            "Could not parse the key — \(detail)"
        case .encryptedKeysUnsupported:
            "This key is protected by a passphrase, which the prototype cannot "
                + "use. Generate an unencrypted key with: "
                + "ssh-keygen -t ed25519 -N \"\" -f ~/.ssh/herdrcat_key"
        case let .unsupportedKeyType(kind):
            "Unsupported key type \"\(kind)\". Use an ed25519 key: "
                + "ssh-keygen -t ed25519 -N \"\" -f ~/.ssh/herdrcat_key"
        case .multipleKeysUnsupported:
            "The file contains more than one key."
        }
    }
}

/// Minimal parser for the `openssh-key-v1` private key container, covering
/// unencrypted ed25519 keys — the format `ssh-keygen -t ed25519` produces.
private struct OpenSSHKeyBuffer {
    let data: Data
    var offset: Data.Index

    init(data: Data) {
        self.data = data
        offset = data.startIndex
    }

    mutating func read(_ count: Int) throws -> Data {
        guard count >= 0, data.distance(from: offset, to: data.endIndex) >= count else {
            throw OpenSSHKeyError.invalidFormat("truncated key data")
        }
        let end = data.index(offset, offsetBy: count)
        defer { offset = end }
        return data.subdata(in: offset..<end)
    }

    mutating func readUInt32() throws -> UInt32 {
        let bytes = try read(4)
        return bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    /// Reads an SSH `string`: uint32 length + raw bytes.
    mutating func readString() throws -> Data {
        let lengthBytes = try read(4)
        let length = lengthBytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard let safeLength = Int(exactly: length) else {
            throw OpenSSHKeyError.invalidFormat("oversized string")
        }
        return try read(safeLength)
    }
}

/// Foundation-only entry points so callers (and tests) don't need CryptoKit types.
enum OpenSSHEd25519 {
    /// Parses an OpenSSH PEM private key and returns the 64-byte ed25519 raw
    /// private representation (seed || public key).
    static func parseRawPrivateKey(pem: String) throws -> Data {
        try Curve25519.Signing.PrivateKey(openSSHPEM: pem).rawRepresentation
    }

    /// Parses an OpenSSH PEM private key and returns its 32-byte raw public key.
    static func parsePublicKey(pem: String) throws -> Data {
        try Curve25519.Signing.PrivateKey(openSSHPEM: pem).publicKey.rawRepresentation
    }

    /// Formats the raw 32-byte ed25519 public key in OpenSSH wire format ("ssh-ed25519 <base64>").
    static func openSSHPublicKeyString(for rawPublicKey: Data) -> String {
        var blob = Data()
        let type = "ssh-ed25519"
        var typeLen = UInt32(type.utf8.count).bigEndian
        blob.append(Data(bytes: &typeLen, count: 4))
        blob.append(Data(type.utf8))
        var keyLen = UInt32(rawPublicKey.count).bigEndian
        blob.append(Data(bytes: &keyLen, count: 4))
        blob.append(rawPublicKey)
        return "ssh-ed25519 " + blob.base64EncodedString()
    }

    /// Parses an OpenSSH PEM private key and returns its formatted OpenSSH public key line ("ssh-ed25519 <base64>").
    static func parseOpenSSHPublicKeyString(pem: String) throws -> String {
        let pubKey = try parsePublicKey(pem: pem)
        return openSSHPublicKeyString(for: pubKey)
    }

    /// Returns the SHA256 fingerprint ("SHA256:...") of an ed25519 public key.
    static func fingerprint(for rawPublicKey: Data) -> String {
        let openSSH = openSSHPublicKeyString(for: rawPublicKey)
        let parts = openSSH.split(separator: " ")
        guard parts.count >= 2, let bytes = Data(base64Encoded: String(parts[1])) else {
            return ""
        }
        return "SHA256:" + Data(SHA256.hash(data: bytes)).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
    }

    /// Returns the SHA256 fingerprint ("SHA256:...") for an OpenSSH PEM private key.
    static func parseFingerprint(pem: String) throws -> String {
        let pubKey = try parsePublicKey(pem: pem)
        return fingerprint(for: pubKey)
    }

    /// Returns a masked display string for an OpenSSH private key, concealing
    /// the sensitive key body while preserving the trailing lines (the last 2 lines)
    /// for verification.
    static func maskPrivateKey(pem: String) -> String {
        let lines = pem
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return "" }
        if lines.count <= 2 {
            return "••••••••••••••••••••••••••••••••\n" + lines.joined(separator: "\n")
        }

        let lastTwo = lines.suffix(2).joined(separator: "\n")
        return "••••••••••••••••••••••••••••••••\n••••••••••••••••••••••••••••••••\n" + lastTwo
    }
}

extension Curve25519.Signing.PrivateKey {
    /// Initializes from an OpenSSH PEM private key (`-----BEGIN OPENSSH
    /// PRIVATE KEY-----`), ed25519 and unencrypted only.
    init(openSSHPEM pem: String) throws {
        let lines = pem
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard let beginIndex = lines.firstIndex(where: { $0.contains("BEGIN OPENSSH PRIVATE KEY") }),
              let endIndex = lines.firstIndex(where: { $0.contains("END OPENSSH PRIVATE KEY") }),
              beginIndex < endIndex else {
            throw OpenSSHKeyError.missingPEMBody
        }

        let base64 = lines[(beginIndex + 1)..<endIndex].joined()
        guard let keyData = Data(base64Encoded: base64) else {
            throw OpenSSHKeyError.invalidBase64
        }
        var buffer = OpenSSHKeyBuffer(data: keyData)

        // 1. Magic: "openssh-key-v1\0"
        let magic = Data("openssh-key-v1\u{0}".utf8)
        guard try buffer.read(magic.count) == magic else {
            throw OpenSSHKeyError.invalidFormat("bad magic header")
        }

        // 2. ciphername — must be "none" for the prototype.
        let cipherName = String(data: try buffer.readString(), encoding: .utf8) ?? ""
        guard cipherName == "none" else {
            throw OpenSSHKeyError.encryptedKeysUnsupported
        }

        // 3. KDF name + options (ignored for unencrypted keys).
        _ = try buffer.readString()
        _ = try buffer.readString()

        // 4. Number of keys.
        let keyCount = try buffer.readUInt32()
        guard keyCount == 1 else {
            throw OpenSSHKeyError.multipleKeysUnsupported
        }

        // 5. Public key blob (validated later against the private section).
        let publicBlob = try buffer.readString()

        // 6. Private key section.
        var privateSection = OpenSSHKeyBuffer(data: try buffer.readString())
        let check1 = try privateSection.readUInt32()
        let check2 = try privateSection.readUInt32()
        guard check1 == check2 else {
            throw OpenSSHKeyError.invalidFormat("check integers do not match")
        }

        let keyType = String(data: try privateSection.readString(), encoding: .utf8) ?? ""
        guard keyType == "ssh-ed25519" else {
            throw OpenSSHKeyError.unsupportedKeyType(keyType)
        }

        _ = try privateSection.readString() // public key (again)
        let privateKeyBytes = try privateSection.readString()

        // ed25519 OpenSSH private material is 64 bytes (seed || public key);
        // CryptoKit wants the 32-byte seed.
        guard privateKeyBytes.count == 64 else {
            throw OpenSSHKeyError.invalidFormat("unexpected ed25519 private key length")
        }
        let seed = privateKeyBytes.prefix(32)
        let publicKeyFromPrivate = privateKeyBytes.suffix(32)
        guard publicBlob.suffix(32) == publicKeyFromPrivate else {
            throw OpenSSHKeyError.invalidFormat("public/private key mismatch")
        }

        try self.init(rawRepresentation: seed)
    }
}
