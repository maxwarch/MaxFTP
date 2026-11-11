import Foundation
import MaxFtpCore
import Testing

@Suite("Tableau de bord R2 (calculs)")
struct R2UsageTests {
    let calendar = Calendar.utc
    let gb: Int64 = 1_000_000_000

    func day(_ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
    }

    @Test func classifiesOperationsLikeCloudflare() {
        #expect(R2OperationClass(actionType: "PutObject") == .classA)
        #expect(R2OperationClass(actionType: "ListObjects") == .classA)
        #expect(R2OperationClass(actionType: "GetObject") == .classB)
        #expect(R2OperationClass(actionType: "HeadObject") == .classB)
        #expect(R2OperationClass(actionType: "DeleteObject") == .free)
        // Inconnue : comptée en classe A pour ne pas sous-estimer la facture.
        #expect(R2OperationClass(actionType: "NouvelleOperation") == .classA)
    }

    @Test func accountIDFromEndpoint() {
        let id = "0123456789abcdef0123456789abcdef"
        #expect(R2Account.accountID(fromHost: "\(id).r2.cloudflarestorage.com") == id)
        #expect(R2Account.accountID(fromHost: "https://\(id.uppercased()).eu.r2.cloudflarestorage.com/") == id)
        #expect(R2Account.accountID(fromHost: "s3.eu-west-3.amazonaws.com") == nil)
        #expect(R2Account.accountID(fromHost: "court.r2.cloudflarestorage.com") == nil)
    }

    @Test func periodStartsAtBeginningOfUTCMonth() {
        let period = R2Account.currentPeriod(at: day(11), calendar: calendar)
        #expect(period.start == calendar.date(from: DateComponents(year: 2026, month: 11, day: 1)))
        #expect(period.end == day(11))
    }

    @Test func billUsesLatestSampleAndDailyPeaks() {
        let usage = R2Usage(
            period: DateInterval(start: day(1, hour: 0), end: day(2)),
            storageSamples: [
                .init(bucketName: "photos", date: day(1, hour: 8), payloadBytes: 4 * gb, metadataBytes: 0, objectCount: 10),
                .init(bucketName: "photos", date: day(1, hour: 20), payloadBytes: 6 * gb, metadataBytes: 0, objectCount: 12),
                .init(bucketName: "photos", date: day(2), payloadBytes: 3 * gb, metadataBytes: 0, objectCount: 9),
                .init(bucketName: "logs", date: day(2), payloadBytes: gb, metadataBytes: 0, objectCount: 1),
            ],
            requestsByAction: ["PutObject": 600_000, "ListObjects": 500_000, "GetObject": 2_000_000, "DeleteObject": 7]
        )
        let bill = R2Bill(usage: usage, calendar: calendar)

        #expect(bill.buckets.map(\.name) == ["photos", "logs"])
        #expect(bill.currentBytes == 4 * gb)
        // Pics journaliers : 6 Go le 1er, 3 + 1 Go le 2 → 10 Go·jour / 30.
        #expect(abs(bill.storageGBMonth - 10.0 / 30) < 1e-9)
        // Moyenne 5 Go/jour sur les 30 jours de novembre.
        #expect(abs(bill.projectedStorageGBMonth - 5) < 1e-9)

        #expect(bill.requests(.classA) == 1_100_000)
        #expect(bill.requests(.classB) == 2_000_000)
        #expect(bill.requests(.free) == 7)
        #expect(abs(bill.classARatio - 1.1) < 1e-9)
        // Seuls les 100 000 appels de classe A au-delà du gratuit sont facturés : 0,1 × 4,50 $.
        #expect(abs(bill.estimatedCost - 0.45) < 1e-9)
    }
}
