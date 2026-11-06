import SwiftUI

/// Fenêtre « Transferts » (⌥⌘T), ouvrable de partout : barre d'outils, menu »
/// de la barre d'outils, menu Fenêtre. Un popover ne s'afficherait pas quand le
/// bouton est replié dans le menu de débordement (il n'a plus d'ancre).
public struct TransfersWindow: View {
    public static let id = "transfers"

    let queue: TransferQueue

    public init(queue: TransferQueue) {
        self.queue = queue
    }

    public var body: some View {
        TransferListView(queue: queue, fillsWindow: true)
            .frame(minWidth: 380, idealWidth: 440, minHeight: 220, idealHeight: 360)
    }
}

/// Bouton de barre d'outils ouvrant la fenêtre des transferts.
struct TransfersToolbarButton: View {
    let queue: TransferQueue
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            openWindow(id: TransfersWindow.id)
        } label: {
            Label("Transferts", systemImage: queue.activeCount > 0 ? "arrow.up.arrow.down.circle.fill" : "arrow.up.arrow.down.circle")
        }
        .help("Transferts (⌥⌘T)")
        .badge(queue.activeCount)
    }
}

struct TransferListView: View {
    let queue: TransferQueue
    /// Dans sa fenêtre : occupe tout l'espace. En popover : taille fixe.
    var fillsWindow = false

    var body: some View {
        VStack(spacing: 0) {
            if queue.items.isEmpty {
                ContentUnavailableView("Aucun transfert", systemImage: "arrow.up.arrow.down", description: Text("Glissez des fichiers depuis le Finder pour les envoyer."))
                    .frame(maxHeight: fillsWindow ? .infinity : 160)
            } else {
                List(queue.items.reversed()) { item in
                    TransferRow(item: item)
                }
                .listStyle(.plain)
            }
            Divider()
            HStack {
                Button("Tout annuler") { queue.cancelAll() }
                    .disabled(queue.activeCount == 0)
                Spacer()
                Button("Effacer les terminés") { queue.clearFinished() }
                    .disabled(queue.items.allSatisfy { !$0.state.isFinished })
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
        .frame(width: fillsWindow ? nil : 380, height: fillsWindow || queue.items.isEmpty ? nil : 320)
    }
}

private struct TransferRow: View {
    let item: TransferItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.direction == .upload ? "arrow.up.circle" : "arrow.down.circle")
                .font(.title2)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).lineLimit(1).truncationMode(.middle)
                switch item.state {
                case .running, .preparing:
                    ProgressView(value: item.fractionCompleted ?? 0)
                        .progressViewStyle(.linear)
                    Text(progressDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                case .waiting:
                    Text("En attente").font(.caption).foregroundStyle(.secondary)
                case .completed:
                    Text("Terminé — \(Formatting.byteCount(item.totalBytes))").font(.caption).foregroundStyle(.secondary)
                case .cancelled:
                    Text("Annulé").font(.caption).foregroundStyle(.secondary)
                case .failed(let message):
                    Text(message).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
            }

            Spacer(minLength: 0)

            if !item.state.isFinished {
                Button {
                    item.cancel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Annuler")
            } else if item.state == .completed {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
        .padding(.vertical, 4)
    }

    private var progressDescription: String {
        guard item.state == .running else { return "Préparation…" }
        let done = Formatting.byteCount(item.transferredBytes)
        let total = Formatting.byteCount(item.totalBytes)
        return "\(done) sur \(total) — \(Formatting.speed(item.bytesPerSecond))"
    }
}
