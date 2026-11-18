import AppKit
import SwiftUI

/// Barre d'onglets affichée au-dessus de l'explorateur pour basculer entre sessions ouvertes.
struct BrowserTabBar: View {
    let tabs: BrowserTabsModel

    var body: some View {
        HStack(spacing: 0) {
            HorizontalTabScrollView {
                HStack(spacing: 4) {
                    ForEach(tabs.tabs) { tab in
                        TabItemView(
                            tab: tab,
                            isSelected: tab.id == tabs.selectedTabID,
                            canClose: tabs.tabs.count > 1 || !tab.isUnused,
                            onSelect: { tabs.selectTab(tab.id) },
                            onClose: { Task { await tabs.closeTab(tab.id) } }
                        )
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
            .frame(maxWidth: .infinity)

            Divider()
                .frame(height: 18)

            Button {
                tabs.newTab()
            } label: {
                Image(systemName: "plus")
                    .font(.caption.weight(.semibold))
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 6)
            .help("Nouvel onglet (⌘T)")
            .accessibilityLabel("Nouvel onglet")
        }
        .background(.bar, ignoresSafeAreaEdges: [])
    }
}

/// Défilement horizontal sans absorption de la safe area supérieure de `NavigationSplitView`
/// (un `ScrollView` SwiftUI décale son contenu de la hauteur de la barre d'outils hors de `DocumentView`).
private struct HorizontalTabScrollView<Content: View>: NSViewRepresentable {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(rootView: content)
    }

    func makeNSView(context: Context) -> TabScrollView {
        let scrollView = TabScrollView()
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets()
        scrollView.documentView = context.coordinator.hostingView
        return scrollView
    }

    func updateNSView(_ scrollView: TabScrollView, context: Context) {
        context.coordinator.hostingView.rootView = content
        scrollView.needsLayout = true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TabScrollView, context: Context) -> CGSize? {
        let fitting = context.coordinator.hostingView.fittingSize
        let width = (proposal.width?.isFinite == true) ? proposal.width! : fitting.width
        return CGSize(width: width, height: fitting.height)
    }

    @MainActor
    final class Coordinator {
        let hostingView: NSHostingView<Content>

        init(rootView: Content) {
            let hosting = NSHostingView(rootView: rootView)
            hosting.safeAreaRegions = []
            self.hostingView = hosting
        }
    }
}

private final class TabScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let documentView else { return }
        let fitting = documentView.fittingSize
        let size = CGSize(width: fitting.width, height: contentView.bounds.height)
        if documentView.frame.size != size || documentView.frame.origin != .zero {
            documentView.frame = NSRect(origin: .zero, size: size)
        }
    }
}

private struct TabItemView: View {
    let tab: BrowserTab
    let isSelected: Bool
    let canClose: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onSelect) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)

                    Text(tab.title)
                        .font(.callout)
                        .fontWeight(isSelected ? .medium : .regular)
                        .lineLimit(1)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)

            if canClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .opacity(isHovering || isSelected ? 1 : 0.45)
                .help("Fermer l'onglet")
                .accessibilityLabel("Fermer l'onglet \(tab.title)")
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, canClose ? 6 : 10)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color(nsColor: .controlBackgroundColor) : (isHovering ? Color.primary.opacity(0.06) : Color.clear))
                .allowsHitTesting(false)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(isSelected ? Color.primary.opacity(0.12) : Color.clear, lineWidth: 1)
                .allowsHitTesting(false)
        )
        .onHover { isHovering = $0 }
    }

    private var statusColor: Color {
        switch tab.browser.connectionState {
        case .connected: .green
        case .connecting: .orange
        case .disconnected: .secondary.opacity(0.4)
        }
    }
}
