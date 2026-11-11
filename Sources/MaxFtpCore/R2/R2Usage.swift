import Foundation

/// Consommation d'un compte Cloudflare R2, telle que renvoyée par l'API d'analytique.
public struct R2Usage: Equatable, Sendable {
    /// Relevé de stockage d'un bucket à un instant donné.
    public struct StorageSample: Equatable, Sendable {
        public var bucketName: String
        public var date: Date
        public var payloadBytes: Int64
        public var metadataBytes: Int64
        public var objectCount: Int64

        public init(bucketName: String, date: Date, payloadBytes: Int64, metadataBytes: Int64, objectCount: Int64) {
            self.bucketName = bucketName
            self.date = date
            self.payloadBytes = payloadBytes
            self.metadataBytes = metadataBytes
            self.objectCount = objectCount
        }

        public var totalBytes: Int64 { payloadBytes + metadataBytes }
    }

    /// Période couverte (début du mois UTC → maintenant).
    public var period: DateInterval
    public var storageSamples: [StorageSample]
    /// Nombre de requêtes par type d'action S3 (`PutObject`, `GetObject`…).
    public var requestsByAction: [String: Int64]

    public init(period: DateInterval, storageSamples: [StorageSample], requestsByAction: [String: Int64]) {
        self.period = period
        self.storageSamples = storageSamples
        self.requestsByAction = requestsByAction
    }
}

/// Classe de facturation d'une opération R2 (grille tarifaire Cloudflare).
public enum R2OperationClass: String, CaseIterable, Sendable {
    case classA, classB, free

    public var displayName: String {
        switch self {
        case .classA: "Classe A"
        case .classB: "Classe B"
        case .free: "Gratuites"
        }
    }

    private static let classAActions: Set<String> = [
        "ListBuckets", "PutBucket", "ListObjects", "PutObject", "CopyObject", "CompleteMultipartUpload",
        "CreateMultipartUpload", "LifecycleStorageTierTransition", "ListMultipartUploads", "UploadPart",
        "UploadPartCopy", "ListParts", "PutBucketEncryption", "PutBucketCors", "PutBucketLifecycleConfiguration",
    ]
    private static let classBActions: Set<String> = [
        "HeadBucket", "HeadObject", "GetObject", "UsageSummary", "GetBucketEncryption", "GetBucketLocation",
        "GetBucketCors", "GetBucketLifecycleConfiguration",
    ]
    private static let freeActions: Set<String> = ["DeleteObject", "DeleteBucket", "AbortMultipartUpload"]

    /// Une action inconnue est comptée en classe A : mieux vaut surestimer la facture.
    public init(actionType: String) {
        if Self.classBActions.contains(actionType) {
            self = .classB
        } else if Self.freeActions.contains(actionType) {
            self = .free
        } else {
            self = .classA
        }
    }
}

/// Grille tarifaire R2 (stockage Standard), en dollars US.
public struct R2Pricing: Equatable, Sendable {
    public var freeStorageGBMonth: Double
    public var freeClassA: Int64
    public var freeClassB: Int64
    public var storagePerGBMonth: Double
    public var classAPerMillion: Double
    public var classBPerMillion: Double

    /// Tarifs publiés sur developers.cloudflare.com/r2/pricing (novembre 2026).
    public static let standard = R2Pricing(
        freeStorageGBMonth: 10, freeClassA: 1_000_000, freeClassB: 10_000_000,
        storagePerGBMonth: 0.015, classAPerMillion: 4.50, classBPerMillion: 0.36
    )

    /// Gigaoctet décimal (10⁹ octets) : la grille ne le précise pas, c'est l'hypothèse la plus prudente.
    public static let bytesPerGB: Double = 1_000_000_000
    /// Cloudflare calcule les GB-mois sur une période de 30 jours.
    public static let billingDays: Double = 30
}

/// Synthèse affichée par le tableau de bord. Logique pure.
public struct R2Bill: Equatable, Sendable {
    public struct Bucket: Equatable, Sendable, Identifiable {
        public var name: String
        public var bytes: Int64
        public var objectCount: Int64
        public var id: String { name }
    }

    /// Dernier relevé de chaque bucket, du plus gros au plus petit.
    public var buckets: [Bucket]
    /// Stockage actuel (somme des derniers relevés).
    public var currentBytes: Int64
    /// GB-mois consommés depuis le début de la période : somme des pics journaliers ÷ 30.
    public var storageGBMonth: Double
    /// Projection sur le mois entier au rythme actuel.
    public var projectedStorageGBMonth: Double
    public var requests: [R2OperationClass: Int64]
    public var pricing: R2Pricing

    public init(usage: R2Usage, pricing: R2Pricing = .standard, calendar: Calendar = .utc) {
        self.pricing = pricing

        let latest = Dictionary(grouping: usage.storageSamples, by: \.bucketName)
            .compactMapValues { $0.max { $0.date < $1.date } }
        buckets = latest.values
            .map { Bucket(name: $0.bucketName, bytes: $0.totalBytes, objectCount: $0.objectCount) }
            .sorted { $0.bytes == $1.bytes ? $0.name < $1.name : $0.bytes > $1.bytes }
        currentBytes = buckets.reduce(0) { $0 + $1.bytes }

        // Pic journalier par bucket, puis somme des buckets pour chaque jour.
        var dailyPeaks: [Date: [String: Int64]] = [:]
        for sample in usage.storageSamples {
            let day = calendar.startOfDay(for: sample.date)
            dailyPeaks[day, default: [:]][sample.bucketName] = max(
                dailyPeaks[day]?[sample.bucketName] ?? 0, sample.totalBytes
            )
        }
        let byteDays = dailyPeaks.values.reduce(0.0) { $0 + Double($1.values.reduce(0, +)) }
        storageGBMonth = byteDays / R2Pricing.bytesPerGB / R2Pricing.billingDays

        let elapsedDays = max(1, dailyPeaks.count)
        let daysInMonth = calendar.range(of: .day, in: .month, for: usage.period.start)?.count ?? 30
        projectedStorageGBMonth = storageGBMonth / Double(elapsedDays) * Double(daysInMonth)

        var requests: [R2OperationClass: Int64] = [:]
        for (action, count) in usage.requestsByAction {
            requests[R2OperationClass(actionType: action), default: 0] += count
        }
        self.requests = requests
    }

    public func requests(_ operationClass: R2OperationClass) -> Int64 { requests[operationClass] ?? 0 }

    /// Part du quota gratuit consommée (1 = quota atteint).
    public var storageRatio: Double { storageGBMonth / pricing.freeStorageGBMonth }
    public var currentStorageRatio: Double { Double(currentBytes) / R2Pricing.bytesPerGB / pricing.freeStorageGBMonth }
    public var classARatio: Double { Double(requests(.classA)) / Double(pricing.freeClassA) }
    public var classBRatio: Double { Double(requests(.classB)) / Double(pricing.freeClassB) }

    /// Coût estimé du mois au-delà du niveau gratuit, avec le stockage projeté sur le mois.
    public var estimatedCost: Double {
        let storage = max(0, projectedStorageGBMonth - pricing.freeStorageGBMonth) * pricing.storagePerGBMonth
        let classA = Double(max(0, requests(.classA) - pricing.freeClassA)) / 1_000_000 * pricing.classAPerMillion
        let classB = Double(max(0, requests(.classB) - pricing.freeClassB)) / 1_000_000 * pricing.classBPerMillion
        return storage + classA + classB
    }
}

extension Calendar {
    /// Calendrier grégorien en UTC : les périodes R2 sont exprimées en UTC.
    public static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
}

/// Compte Cloudflare déduit du point de terminaison R2.
public enum R2Account {
    /// `<id>.r2.cloudflarestorage.com` ou `<id>.eu.r2.cloudflarestorage.com` → `<id>` ;
    /// `nil` pour un autre fournisseur S3 (pas de tableau de bord).
    public static func accountID(fromHost host: String) -> String? {
        // Tolère une URL collée telle quelle (`https://…/`), comme l'adaptateur S3.
        var cleaned = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let range = cleaned.range(of: "://") { cleaned = String(cleaned[range.upperBound...]) }
        if let slash = cleaned.firstIndex(of: "/") { cleaned = String(cleaned[..<slash]) }
        let labels = cleaned.split(separator: ".").map(String.init)
        guard labels.count >= 4, labels.suffix(3) == ["r2", "cloudflarestorage", "com"] else { return nil }
        let id = labels[0]
        guard id.count == 32, id.allSatisfy(\.isHexDigit) else { return nil }
        return id
    }

    /// Début du mois UTC contenant `date` → `date` (l'API limite les requêtes à 31 jours).
    public static func currentPeriod(at date: Date, calendar: Calendar = .utc) -> DateInterval {
        let start = calendar.dateInterval(of: .month, for: date)?.start ?? date
        return DateInterval(start: start, end: date)
    }

    /// Compte du trousseau pour le jeton d'API Cloudflare (partagé par les favoris du même compte).
    public static func apiTokenSecretAccount(accountID: String) -> String {
        "cloudflare-analytics:\(accountID)"
    }
}

/// Source des métriques R2 (implémentation : API GraphQL de Cloudflare, module MaxFtpS3).
public protocol R2UsageProvider: Sendable {
    func usage(accountID: String, apiToken: String, period: DateInterval) async throws -> R2Usage
}
