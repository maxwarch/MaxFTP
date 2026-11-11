import MaxFtpCore
import SwiftUI

/// Feuille « Tableau de bord R2 » : quotas gratuits, coût estimé et taille des buckets.
struct R2DashboardView: View {
    @Environment(\.dismiss) private var dismiss
    let model: R2DashboardModel
    @State private var token = ""

    private static let tokensURL = URL(string: "https://dash.cloudflare.com/profile/api-tokens")!

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            switch model.state {
            case .needsToken:
                tokenForm
            case .loading:
                ProgressView("Lecture des métriques…")
                    .frame(maxWidth: .infinity, minHeight: 200)
            case .loaded(let bill):
                BillContent(bill: bill)
            case .failed(let message):
                failure(message)
            }
            HStack {
                if model.hasToken {
                    Button("Changer de jeton…") { model.forgetToken() }
                }
                Spacer()
                Button("Fermer") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 620)
        .task { await model.refresh() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Cloudflare R2").font(.title2.bold())
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await model.refresh() }
            } label: {
                Label("Actualiser", systemImage: "arrow.clockwise")
            }
            .disabled(!model.hasToken || model.state == .loading)
        }
    }

    private var subtitle: String {
        let month = Date().formatted(.dateTime.month(.wide).year())
        var text = "Compte …\(model.accountID.suffix(6)) · \(month) (UTC)"
        if let update = model.lastUpdate {
            text += " · mis à jour à \(update.formatted(date: .omitted, time: .shortened))"
        }
        return text
    }

    private var tokenForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Les métriques viennent de l'API d'analytique de Cloudflare, qui n'accepte pas les clés S3.")
            Text("Créez un jeton d'API avec la permission **Compte › Account Analytics › Lecture**, puis collez-le ici. "
                + "Il est enregistré dans le trousseau macOS.")
                .foregroundStyle(.secondary)
            Link("Ouvrir la page des jetons d'API Cloudflare", destination: Self.tokensURL)
            HStack {
                SecureField("Jeton d'API Cloudflare", text: $token)
                    .onSubmit(save)
                Button("Enregistrer", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func save() {
        let value = token
        token = ""
        Task { await model.saveToken(value) }
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 10) {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Réessayer") { Task { await model.refresh() } }
        }
        .frame(maxWidth: .infinity, minHeight: 160)
    }
}

/// Contenu une fois les métriques chargées.
private struct BillContent: View {
    let bill: R2Bill

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                QuotaTile(
                    title: "Stockage",
                    value: bill.currentBytes.formatted(.byteCount(style: .file)),
                    limit: "sur \(bill.pricing.freeStorageGBMonth.formatted()) Go gratuits",
                    ratio: bill.currentStorageRatio
                )
                QuotaTile(
                    title: R2OperationClass.classA.displayName,
                    value: bill.requests(.classA).formatted(),
                    limit: "sur \(bill.pricing.freeClassA.formatted()) gratuites",
                    ratio: bill.classARatio
                )
                QuotaTile(
                    title: R2OperationClass.classB.displayName,
                    value: bill.requests(.classB).formatted(),
                    limit: "sur \(bill.pricing.freeClassB.formatted()) gratuites",
                    ratio: bill.classBRatio
                )
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Coût estimé ce mois-ci")
                        Spacer()
                        Text(bill.estimatedCost.formatted(.currency(code: "USD")))
                            .font(.title3.monospacedDigit().bold())
                    }
                    Text(budgetDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(4)
            }

            Text("Buckets").font(.headline)
            if bill.buckets.isEmpty {
                Text("Aucune donnée de stockage sur la période.")
                    .foregroundStyle(.secondary)
            } else {
                Table(bill.buckets) {
                    TableColumn("Bucket", value: \.name)
                    TableColumn("Taille") { Text($0.bytes.formatted(.byteCount(style: .file))).monospacedDigit() }
                    TableColumn("Objets") { Text($0.objectCount.formatted()).monospacedDigit() }
                }
                .frame(height: min(220, CGFloat(bill.buckets.count) * 24 + 32))
            }
        }
    }

    private var budgetDetail: String {
        let gbMonth = bill.projectedStorageGBMonth.formatted(.number.precision(.fractionLength(2)))
        return "Stockage facturé en GB-mois (moyenne des pics journaliers) : \(gbMonth) projetés sur le mois. "
            + "Opérations gratuites (suppressions) : \(bill.requests(.free).formatted()). "
            + "La sortie de données (egress) est gratuite. Les données Cloudflare ont quelques minutes de retard."
    }
}

/// Tuile de quota : valeur, jauge et état (icône + libellé, pas seulement la couleur).
private struct QuotaTile: View {
    let title: String
    let value: String
    let limit: String
    let ratio: Double

    private var level: QuotaLevel { QuotaLevel(ratio: ratio) }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.subheadline).foregroundStyle(.secondary)
                Text(value).font(.title2.monospacedDigit().bold())
                Text(limit).font(.caption).foregroundStyle(.secondary)
                Gauge(value: min(ratio, 1)) { EmptyView() }
                    .gaugeStyle(.accessoryLinearCapacity)
                    .tint(tint)
                    .accessibilityLabel(title)
                    .accessibilityValue(ratio.formatted(.percent.precision(.fractionLength(0))))
                Label(status, systemImage: symbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private var percent: String { ratio.formatted(.percent.precision(.fractionLength(0))) }

    private var status: String {
        switch level {
        case .comfortable: "\(percent) du gratuit"
        case .nearLimit: "\(percent) — proche de la limite"
        case .exceeded: "\(percent) — quota dépassé"
        }
    }

    private var symbol: String {
        switch level {
        case .comfortable: "checkmark.circle"
        case .nearLimit: "exclamationmark.triangle"
        case .exceeded: "xmark.octagon"
        }
    }

    private var tint: Color {
        switch level {
        case .comfortable: .accentColor
        case .nearLimit: .orange
        case .exceeded: .red
        }
    }
}
