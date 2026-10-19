import Foundation
import PDFKit
import CZlib

public protocol EmailAttachmentExtracting: Sendable {
    func extract(data: Data, name: String, contentType: String) throws -> String
}

public struct SafeAttachmentExtractor: EmailAttachmentExtracting {
    public static let maxBytes = 5_000_000
    public init() {}
    public static func supports(name: String, contentType: String, size: Int) -> Bool {
        guard size > 0 && size <= maxBytes && !name.contains("/") && !name.contains("\\") else { return false }
        switch (name as NSString).pathExtension.lowercased() {
        case "pdf": return contentType.lowercased() == "application/pdf"
        case "docx": return contentType.lowercased() == "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        default: return false
        }
    }
    public func extract(data: Data, name: String, contentType: String) throws -> String {
        guard Self.supports(name: name, contentType: contentType, size: data.count) else { throw OutlookError.attachment }
        if name.lowercased().hasSuffix(".pdf") {
            guard data.starts(with: Data("%PDF-".utf8)) else { throw OutlookError.attachment }
            let raw = String(decoding: data, as: UTF8.self)
            guard !["/JavaScript", "/JS", "/Launch", "/EmbeddedFile", "/OpenAction"].contains(where: raw.contains),
                  let pdf = PDFDocument(data: data), !pdf.isEncrypted, (1...50).contains(pdf.pageCount) else { throw OutlookError.attachment }
            let started = Date(); var text = ""
            for page in 0..<pdf.pageCount {
                guard Date().timeIntervalSince(started) < 3, text.count < 50_000 else { throw OutlookError.attachment }
                text += (pdf.page(at: page)?.string ?? "") + "\n"
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 50_000 else { throw OutlookError.attachment }
            return text
        }
        let archive = try BoundedWordArchive(data: data)
        let document = try archive.file("word/document.xml")
        for name in archive.names where name.hasSuffix(".rels") {
            let data = try archive.file(name)
            guard !data.contains(0), let xml = String(data: data, encoding: .utf8) else { throw OutlookError.attachment }
            let relationship = xml.lowercased()
            guard relationship.range(of: #"targetmode\s*=\s*[\"']external[\"']"#, options: .regularExpression) == nil else { throw OutlookError.attachment }
        }
        return try WordTextParser.text(document)
    }
}

private struct BoundedWordArchive {
    struct Entry { let method: Int; let packed: Int; let size: Int; let offset: Int; let crc: UInt32 }
    let data: Data
    let entries: [String: Entry]
    var names: [String] { Array(entries.keys) }
    init(data: Data) throws {
        self.data = data
        func u16(_ p: Int) throws -> Int { guard p >= 0 && p+2 <= data.count else { throw OutlookError.attachment }; return Int(data[p]) | Int(data[p+1]) << 8 }
        func u32(_ p: Int) throws -> Int { try u16(p) | u16(p+2) << 16 }
        guard data.count >= 22 else { throw OutlookError.attachment }
        var end: Int?
        for p in stride(from: data.count-22, through: max(0, data.count-65557), by: -1) {
            if try u32(p) == 0x06054b50 { end = p; break }
        }
        guard let end, try u16(end+4) == 0, try u16(end+6) == 0 else { throw OutlookError.attachment }
        let count = try u16(end+10)
        guard (1...200).contains(count), try u16(end+8) == count else { throw OutlookError.attachment }
        var cursor = try u32(end+16); var entries: [String: Entry] = [:]; var total = 0
        for _ in 0..<count {
            guard try u32(cursor) == 0x02014b50 else { throw OutlookError.attachment }
            let flags = try u16(cursor+8), method = try u16(cursor+10), packed = try u32(cursor+20), size = try u32(cursor+24)
            let length = try u16(cursor+28), extra = try u16(cursor+30), comment = try u16(cursor+32), offset = try u32(cursor+42)
            guard flags & 1 == 0, [0,8].contains(method), size <= 5_000_000, size <= max(1,packed)*100,
                  cursor+46+length+extra+comment <= end else { throw OutlookError.attachment }
            let name = String(decoding: data[(cursor+46)..<(cursor+46+length)], as: UTF8.self)
            let lower = name.lowercased()
            guard !name.hasPrefix("/"), !name.contains(".."), !name.contains("\\"), entries[name] == nil,
                  !lower.contains("vba"), !lower.contains("embeddings/"), !lower.contains("activex"), !lower.hasSuffix(".exe") else { throw OutlookError.attachment }
            total += size; guard total <= 20_000_000 else { throw OutlookError.attachment }
            entries[name] = Entry(method: method, packed: packed, size: size, offset: offset, crc: UInt32(try u32(cursor+16)))
            cursor += 46+length+extra+comment
        }
        guard entries["[Content_Types].xml"] != nil, entries["word/document.xml"] != nil else { throw OutlookError.attachment }
        self.entries = entries
    }
    func file(_ name: String) throws -> Data {
        guard let e = entries[name], e.offset >= 0, e.offset+30 <= data.count else { throw OutlookError.attachment }
        func u16(_ p: Int) -> Int { Int(data[p]) | Int(data[p+1]) << 8 }
        guard data[e.offset..<(e.offset+4)].elementsEqual([0x50,0x4b,0x03,0x04]) else { throw OutlookError.attachment }
        let start = e.offset+30+u16(e.offset+26)+u16(e.offset+28)
        guard start <= data.count, e.packed <= data.count-start else { throw OutlookError.attachment }
        let input = Data(data[start..<(start+e.packed)])
        func checked(_ value: Data) throws -> Data {
            let checksum = value.withUnsafeBytes { bytes in crc32(0, bytes.bindMemory(to: Bytef.self).baseAddress, uInt(value.count)) }
            guard UInt32(checksum) == e.crc else { throw OutlookError.attachment }
            return value
        }
        if e.method == 0 { guard input.count == e.size else { throw OutlookError.attachment }; return try checked(input) }
        var stream = z_stream()
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw OutlookError.attachment }
        defer { inflateEnd(&stream) }
        var output = Data(count: max(1,e.size))
        let status: Int32 = input.withUnsafeBytes { bytes in
            output.withUnsafeMutableBytes { destination in
                stream.next_in = UnsafeMutablePointer(mutating: bytes.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(input.count)
                stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress; stream.avail_out = uInt(max(1,e.size))
                return inflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END, stream.total_out == e.size, stream.total_in == e.packed else { throw OutlookError.attachment }
        return try checked(Data(output.prefix(e.size)))
    }
}

private final class WordTextParser: NSObject, XMLParserDelegate {
    var text = ""; var inText = false
    static func text(_ data: Data) throws -> String {
        guard !data.contains(0), let raw = String(data: data, encoding: .utf8) else { throw OutlookError.attachment }
        guard !raw.localizedCaseInsensitiveContains("<!DOCTYPE"), !raw.localizedCaseInsensitiveContains("<!ENTITY") else { throw OutlookError.attachment }
        let delegate = WordTextParser(); let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse(), !delegate.text.isEmpty, delegate.text.count <= 50_000 else { throw OutlookError.attachment }
        return delegate.text
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "w:t" { inText = true }
        if elementName == "w:br" || elementName == "w:tab" { text += "\n" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { text += string; if text.count > 50_000 { parser.abortParsing() } }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "w:t" { inText = false }
        if elementName == "w:p" { text += "\n" }
    }
}
