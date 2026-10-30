import CryptoKit
import Foundation

final class Enclosures: NSObject, XMLParserDelegate {
    let filename: String
    var matches: [[String: String]] = []

    init(filename: String) { self.filename = filename }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]
    ) {
        guard elementName == "enclosure", let rawURL = attributes["url"],
              let url = URL(string: rawURL), url.scheme == "https",
              url.lastPathComponent == filename else { return }
        matches.append(attributes)
    }
}

do {
    guard CommandLine.arguments.count == 4 else {
        throw NSError(domain: "Usage: verify-update.swift INFO.plist APPCAST.xml UPDATE.dmg", code: 1)
    }
    let arguments = CommandLine.arguments
    let info = try PropertyListSerialization.propertyList(
        from: Data(contentsOf: URL(fileURLWithPath: arguments[1])), format: nil
    ) as? [String: Any]
    let dmg = URL(fileURLWithPath: arguments[3])
    let delegate = Enclosures(filename: dmg.lastPathComponent)
    let parser = XMLParser(data: try Data(contentsOf: URL(fileURLWithPath: arguments[2])))
    parser.shouldResolveExternalEntities = false
    parser.delegate = delegate
    guard parser.parse(), delegate.matches.count == 1,
          let enclosure = delegate.matches.first,
          let encodedKey = info?["SUPublicEDKey"] as? String, let key = Data(base64Encoded: encodedKey),
          let encodedSignature = enclosure["sparkle:edSignature"],
          let signature = Data(base64Encoded: encodedSignature) else {
        throw NSError(domain: "Missing update public key or signed appcast enclosure", code: 1)
    }
    let archive = try Data(contentsOf: dmg, options: .mappedIfSafe)
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: key)
    guard enclosure["length"] == String(archive.count),
          publicKey.isValidSignature(signature, for: archive) else {
        throw NSError(domain: "Update signature or length does not match the app's public key and DMG", code: 1)
    }
    print("==> Update signature verified against the app's public key")
} catch {
    fputs("error: \(error)\n", stderr)
    exit(1)
}
