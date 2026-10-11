import CryptoKit
import Foundation
import NaturalLanguage

nonisolated struct ServiceHit: Sendable {
    let domain: String
    let matchedActionID: String?
    let matchedAction: String?
    let score: Double
}

nonisolated private struct ActionDoc {
    let domain: String
    let actionID: String?
    let actionLabel: String?
    let tokens: [String]
    let length: Int
}

nonisolated private struct Embedder {
    nonisolated enum Backend {
        case contextual(NLContextualEmbedding)
        case sentence(NLEmbedding)
    }

    let backend: Backend
    let language: NLLanguage

    var id: String {
        switch backend {
        case let .contextual(model): return "ctx-\(language.rawValue)-\(model.dimension)"
        case .sentence: return "sent-\(language.rawValue)"
        }
    }

    // nil = no standalone semantic fallback: sentence-embedding cosines are too compressed to threshold (gibberish outscores real queries).
    var semanticFallbackFloor: Double? {
        switch backend {
        case .contextual: return 0.40
        case .sentence: return nil
        }
    }

    static func make(for locale: String?) async -> Embedder? {
        let language: NLLanguage = (locale?.hasPrefix("zh") ?? false) ? .simplifiedChinese : .english
        if let model = await contextual(language) {
            return Embedder(backend: .contextual(model), language: language)
        }
        if let model = NLEmbedding.sentenceEmbedding(for: language) {
            Log.service.info("ServiceSearchIndex.embedder sentence lang=\(language.rawValue)")
            return Embedder(backend: .sentence(model), language: language)
        }
        Log.service.error("ServiceSearchIndex.embedder unavailable lang=\(language.rawValue)")
        return nil
    }

    private static func contextual(_ language: NLLanguage) async -> NLContextualEmbedding? {
        guard let model = NLContextualEmbedding(language: language) else { return nil }
        let assets = await withCheckedContinuation { (c: CheckedContinuation<NLContextualEmbedding.AssetsResult, Never>) in
            model.requestAssets { result, _ in c.resume(returning: result) }
        }
        guard assets == .available, (try? model.load()) != nil else {
            Log.service.info("ServiceSearchIndex.embedder contextual assets=\(assets.rawValue) lang=\(language.rawValue)")
            return nil
        }
        Log.service.info("ServiceSearchIndex.embedder contextual lang=\(language.rawValue) dim=\(model.dimension)")
        return model
    }

    func vector(for text: String) -> [Float]? {
        switch backend {
        case let .contextual(model):
            guard let r = try? model.embeddingResult(for: text, language: language) else { return nil }
            let dim = model.dimension
            var sum = [Float](repeating: 0, count: dim)
            var count = 0
            r.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { v, _ in
                for i in 0..<min(v.count, dim) { sum[i] += Float(v[i]) }
                count += 1
                return true
            }
            guard count > 0 else { return nil }
            return Self.normalize(sum.map { $0 / Float(count) })
        case let .sentence(model):
            return model.vector(for: text).flatMap { Self.normalize($0.map(Float.init)) }
        }
    }

    private static func normalize(_ v: [Float]) -> [Float]? {
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return nil }
        return v.map { $0 / norm }
    }
}

nonisolated private struct VectorCache {
    private var store: [String: [Float]]

    private static var url: URL {
        AppStoragePaths.serviceSearchVectors
    }

    static func load() -> VectorCache {
        guard let data = try? Data(contentsOf: url),
              let raw = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Data]
        else { return VectorCache(store: [:]) }
        return VectorCache(store: raw.mapValues { Self.unpack($0) })
    }

    func vector(_ key: String) -> [Float]? { store[key] }
    mutating func insert(_ key: String, _ vector: [Float]) { store[key] = vector }

    func save(keeping keys: Set<String>) {
        let raw = store.filter { keys.contains($0.key) }.mapValues { Self.pack($0) }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: raw, format: .binary, options: 0) else { return }
        try? data.write(to: Self.url)
    }

    private static func unpack(_ data: Data) -> [Float] {
        var out = [Float](repeating: 0, count: data.count / MemoryLayout<Float>.size)
        _ = out.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return out
    }

    private static func pack(_ floats: [Float]) -> Data {
        floats.withUnsafeBytes { Data($0) }
    }
}

actor ServiceSearchIndex {
    struct SemanticBuild: Sendable {
        let ticket: UInt64
        let locale: String?
        let texts: [String]
    }

    struct SemanticCandidate: Sendable {
        let ticket: UInt64
        let index: SemanticIndex
        let reused: Int
        let computed: Int
    }

    actor SemanticIndex {
        private var embedder: Embedder?
        private var vectors: [[Float]?] = []

        func build(from texts: [String], locale: String?) async -> (reused: Int, computed: Int)? {
            guard !Task.isCancelled, let nextEmbedder = await Embedder.make(for: locale) else { return nil }
            var cache = VectorCache.load()
            var used: Set<String> = []
            var nextVectors: [[Float]?] = []
            var reused = 0
            var computed = 0
            nextVectors.reserveCapacity(texts.count)
            for text in texts {
                guard !Task.isCancelled else { return nil }
                let key = ServiceSearchIndex.cacheKey(nextEmbedder, text)
                used.insert(key)
                if let hit = cache.vector(key) {
                    nextVectors.append(hit)
                    reused += 1
                } else if let vector = nextEmbedder.vector(for: text) {
                    nextVectors.append(vector)
                    cache.insert(key, vector)
                    computed += 1
                } else {
                    nextVectors.append(nil)
                }
            }
            guard !Task.isCancelled else { return nil }
            cache.save(keeping: used)
            embedder = nextEmbedder
            vectors = nextVectors
            return (reused, computed)
        }

        func scores(for query: String, lexical: [(Int, Double)]) -> [Int: Double] {
            guard let embedder else { return Self.lexicalScores(lexical) }
            guard let queryVector = embedder.vector(for: query) else { return Self.lexicalScores(lexical) }
            if lexical.isEmpty {
                guard let floor = embedder.semanticFallbackFloor else { return [:] }
                let ranked = vectors.enumerated()
                    .compactMap { index, vector in vector.map { (index, Double(ServiceSearchIndex.dot(queryVector, $0))) } }
                    .filter { $0.1 >= floor }
                    .sorted { $0.1 > $1.1 }
                    .prefix(ServiceSearchIndex.semanticFallbackLimit)
                return Dictionary(uniqueKeysWithValues: ranked)
            }
            let maxScore = lexical.map(\.1).max() ?? 1
            var scored: [Int: Double] = [:]
            for (index, lexicalScore) in lexical {
                var score = lexicalScore / maxScore
                if let vector = vectors[index] {
                    score += ServiceSearchIndex.semanticWeight * Double(ServiceSearchIndex.dot(queryVector, vector))
                }
                scored[index] = score
            }
            return scored
        }

        private static func lexicalScores(_ lexical: [(Int, Double)]) -> [Int: Double] {
            let maxScore = lexical.map(\.1).max() ?? 1
            return Dictionary(uniqueKeysWithValues: lexical.map { ($0.0, $0.1 / maxScore) })
        }
    }

    private var docs: [ActionDoc] = []
    private var domains: [String] = []
    private var idf: [String: Double] = [:]
    private var avgLen: Double = 1
    private var semanticIndex: SemanticIndex?
    private var language: NLLanguage = .english
    private var rebuildTicket: UInt64 = 0

    private static let semanticWeight = 0.5
    private static let semanticFallbackLimit = 5

    func rebuildLexical(from definitions: [ServiceDefinition], locale: String?) -> SemanticBuild {
        rebuildTicket &+= 1
        let ticket = rebuildTicket
        let nextLanguage = Self.language(for: locale)
        let raw = definitions.flatMap { Self.flatten($0, language: nextLanguage) }
        let nextDocs = raw.map { r in
            return ActionDoc(
                domain: r.domain,
                actionID: r.actionID,
                actionLabel: r.label,
                tokens: r.tokens,
                length: r.tokens.count
            )
        }
        let lexical = Self.lexicalIndex(for: nextDocs)
        language = nextLanguage
        semanticIndex = nil
        domains = definitions.map(\.domain)
        docs = nextDocs
        idf = lexical.idf
        avgLen = lexical.avgLen
        Log.service.info("ServiceSearchIndex.lexical ready docs=\(nextDocs.count) ticket=\(ticket)")
        return SemanticBuild(ticket: ticket, locale: locale, texts: raw.map(\.text))
    }

    nonisolated static func buildSemantics(_ build: SemanticBuild) async -> SemanticCandidate? {
        let index = SemanticIndex()
        guard let result = await index.build(from: build.texts, locale: build.locale) else { return nil }
        return SemanticCandidate(ticket: build.ticket, index: index, reused: result.reused, computed: result.computed)
    }

    @discardableResult
    func installSemantics(_ candidate: SemanticCandidate) -> Bool {
        guard rebuildTicket == candidate.ticket else {
            Log.service.info("ServiceSearchIndex.semantic stale ticket=\(candidate.ticket) current=\(rebuildTicket)")
            return false
        }
        semanticIndex = candidate.index
        Log.service.info(
            "ServiceSearchIndex.semantic ready docs=\(docs.count) reused=\(candidate.reused) computed=\(candidate.computed) ticket=\(candidate.ticket)"
        )
        return true
    }

    private static func cacheKey(_ embedder: Embedder, _ text: String) -> String {
        SHA256.hash(data: Data("\(embedder.id)\n\(text)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func lexicalIndex(for docs: [ActionDoc]) -> (idf: [String: Double], avgLen: Double) {
        var df: [String: Int] = [:]
        var total = 0
        for d in docs {
            total += d.length
            for t in Set(d.tokens) { df[t, default: 0] += 1 }
        }
        let avgLen = docs.isEmpty ? 1 : Double(total) / Double(docs.count)
        let n = Double(docs.count)
        let idf = df.mapValues { log(1 + (n - Double($0) + 0.5) / (Double($0) + 0.5)) }
        return (idf, avgLen)
    }

    private struct RawDoc {
        let domain: String
        let actionID: String?
        let label: String?
        let text: String
        let tokens: [String]
    }

    private static func flatten(_ definition: ServiceDefinition, language: NLLanguage) -> [RawDoc] {
        let name = definition.name
        let serviceDesc = definition.description
        let prefix = [name, serviceDesc].filter { !$0.isEmpty }.joined(separator: ". ")

        func doc(_ actionID: String?, _ label: String?, _ text: String) -> RawDoc {
            RawDoc(domain: definition.domain, actionID: actionID, label: label, text: text, tokens: tokenize(text, language: language))
        }

        var docs: [RawDoc] = []
        for action in definition.exposedActions {
            let label = action.label
            let desc = action.description ?? ""
            docs.append(doc(action.id, label, [prefix, label, desc].filter { !$0.isEmpty }.joined(separator: ". ")))
        }
        if docs.isEmpty, !name.isEmpty {
            docs.append(doc(nil, nil, prefix))
        }
        return docs
    }

    private static let stopwords: Set<String> = [
        "the", "a", "an", "and", "or", "of", "to", "for", "in", "on", "is", "are",
        "your", "you", "with", "by", "this", "that", "my", "me", "it", "as", "at",
        "from", "all", "no", "via", "read", "only",
    ]

    private static func language(for locale: String?) -> NLLanguage {
        locale?.hasPrefix("zh") == true ? .simplifiedChinese : .english
    }

    private static func tokenize(_ text: String, language: NLLanguage) -> [String] {
        let normalized = text.lowercased()
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.setLanguage(language)
        tokenizer.string = normalized
        return tokenizer.tokens(for: normalized.startIndex..<normalized.endIndex)
            .map { String(normalized[$0]) }
            .filter { !stopwords.contains($0) }
    }

    private static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var s: Float = 0
        for i in 0..<min(a.count, b.count) { s += a[i] * b[i] }
        return s
    }

    // MARK: - Search

    func search(_ raw: String) async -> [ServiceHit] {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }

        let lexical = bm25(Self.tokenize(q, language: language))
        let ticket = rebuildTicket

        var scored: [Int: Double] = [:]
        if lexical.isEmpty {
            if let semanticIndex {
                scored = await semanticIndex.scores(for: q, lexical: lexical)
            } else {
                Log.service.info("ServiceSearchIndex.search semantic fallback unavailable")
            }
        } else if let semanticIndex {
            scored = await semanticIndex.scores(for: q, lexical: lexical)
        } else {
            scored = Self.lexicalScores(lexical)
        }
        guard rebuildTicket == ticket else {
            Log.service.info("ServiceSearchIndex.search retry ticket=\(ticket) current=\(rebuildTicket)")
            return await search(raw)
        }

        let hits = group(scored, domainScores: domainScores(q))
        Log.service.info("ServiceSearchIndex.search chars=\(q.count) lexical=\(lexical.count) hits=\(hits.count) top=\(hits.first?.score ?? 0)")
        return hits
    }

    private func bm25(_ queryTokens: [String]) -> [(Int, Double)] {
        guard !docs.isEmpty else { return [] }
        let k1 = 1.5, b = 0.75
        let qset = Set(queryTokens)
        guard !qset.isEmpty else { return [] }
        var scored: [(Int, Double)] = []
        for (i, d) in docs.enumerated() where d.length > 0 {
            var s = 0.0
            let dl = Double(d.length)
            for q in qset {
                var f = 0
                var termIdf = 0.0
                for t in d.tokens where t.hasPrefix(q) {
                    f += 1
                    termIdf = max(termIdf, idf[t] ?? 0)
                }
                if f == 0 { continue }
                let num = Double(f) * (k1 + 1)
                let den = Double(f) + k1 * (1 - b + b * dl / avgLen)
                s += termIdf * num / den
            }
            if s > 0 { scored.append((i, s)) }
        }
        return scored
    }

    private static func lexicalScores(_ lexical: [(Int, Double)]) -> [Int: Double] {
        let maxScore = lexical.map(\.1).max() ?? 1
        return Dictionary(uniqueKeysWithValues: lexical.map { ($0.0, $0.1 / maxScore) })
    }

    private func domainScores(_ query: String) -> [String: Double] {
        let identifier = Self.normalizedDomainIdentifier(query)
        guard !identifier.isEmpty else { return [:] }
        let queryTokens = Self.domainTokens(identifier)
        var scores: [String: Double] = [:]
        for domain in domains {
            let normalized = Self.normalizedDomainIdentifier(domain)
            if normalized == identifier {
                scores[domain] = 3
            } else if normalized.hasPrefix(identifier) {
                scores[domain] = 2
            } else if !queryTokens.isEmpty {
                let tokens = Self.domainTokens(normalized)
                if queryTokens.allSatisfy({ queryToken in tokens.contains(where: { $0.hasPrefix(queryToken) }) }) {
                    scores[domain] = 1.75
                }
            }
        }
        return scores
    }

    private static func normalizedDomainIdentifier(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !result.contains(where: \.isWhitespace) else { return result }
        if let scheme = result.range(of: "://") { result = String(result[scheme.upperBound...]) }
        result = String(result.prefix { $0 != "/" && $0 != "?" && $0 != "#" })
        if result.hasPrefix("www.") { result.removeFirst(4) }
        while result.hasSuffix(".") { result.removeLast() }
        return result
    }

    private static func domainTokens(_ value: String) -> [String] {
        let ignored = Set(["com", "org", "net", "io", "ai", "co", "cn"])
        return value
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !ignored.contains($0) }
    }

    private func group(_ scored: [Int: Double], domainScores: [String: Double]) -> [ServiceHit] {
        var best: [String: (id: String?, label: String?, score: Double)] = [:]
        for (domain, score) in domainScores {
            best[domain] = (nil, nil, score)
        }
        for (idx, score) in scored {
            let d = docs[idx]
            if let cur = best[d.domain], cur.score >= score { continue }
            best[d.domain] = (d.actionID, d.actionLabel, score)
        }
        return best
            .map {
                ServiceHit(
                    domain: $0.key,
                    matchedActionID: $0.value.id,
                    matchedAction: $0.value.label,
                    score: $0.value.score
                )
            }
            .sorted { $0.score > $1.score }
    }
}
