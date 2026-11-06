import SwiftUI

/// Indicateur discret de la barre d'état : n'apparaît que pendant un transfert,
/// brièvement à la fin (« Terminé »), ou tant qu'un échec n'a pas été consulté.
/// Un clic ouvre la file de transferts.
struct TransferStatusView: View {
    let queue: TransferQueue
    @State private var isPresented = false
    @State private var showsCompletion = false

    var body: some View {
        Group {
            if queue.activeCount > 0 {
                button {
                    if let progress = queue.overallProgress {
                        ProgressView(value: progress)
                            .progressViewStyle(.circular)
                            .controlSize(.mini)
                        Text("\(transferCount) · \(Int(progress * 100)) %")
                    } else {
                        ProgressView().controlSize(.mini)
                        Text(transferCount)
                    }
                }
            } else if queue.failedCount > 0 {
                button {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text(queue.failedCount == 1 ? "1 échec" : "\(queue.failedCount) échecs")
                }
            } else if showsCompletion {
                button {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Transfert terminé")
                }
                .transition(.opacity)
            }
        }
        .onChange(of: queue.activeCount) { previous, current in
            guard previous > 0, current == 0, queue.failedCount == 0 else { return }
            showsCompletion = true
        }
        .task(id: showsCompletion) {
            guard showsCompletion else { return }
            try? await Task.sleep(for: .seconds(4))
            withAnimation { showsCompletion = false }
        }
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            TransferListView(queue: queue)
        }
    }

    private var transferCount: String {
        queue.activeCount == 1 ? "1 transfert" : "\(queue.activeCount) transferts"
    }

    private func button<Label: View>(@ViewBuilder label: () -> Label) -> some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 4) { label() }
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help("Afficher les transferts")
    }
}
