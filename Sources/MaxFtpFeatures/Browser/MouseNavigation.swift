import AppKit
import SwiftUI

/// Sens d'un déplacement dans l'historique.
enum NavigationDirection: Equatable {
    case back, forward

    /// Boutons latéraux des souris à 5 boutons (numérotation AppKit : 0 = gauche,
    /// 1 = droit, 2 = molette, 3 = précédent, 4 = suivant).
    init?(mouseButton: Int) {
        switch mouseButton {
        case 3: self = .back
        case 4: self = .forward
        default: return nil
        }
    }

    /// Balayage du trackpad : vers la droite = précédent (comme Safari).
    init?(swipeDeltaX: CGFloat) {
        if swipeDeltaX > 0 {
            self = .back
        } else if swipeDeltaX < 0 {
            self = .forward
        } else {
            return nil
        }
    }

    init?(event: NSEvent) {
        switch event.type {
        case .otherMouseDown: self.init(mouseButton: event.buttonNumber)
        case .swipe: self.init(swipeDeltaX: event.deltaX)
        default: return nil
        }
    }
}

extension View {
    /// Boutons « précédent / suivant » de la souris et balayage du trackpad,
    /// limités à la fenêtre qui porte cette vue.
    func onMouseNavigation(perform action: @escaping @MainActor (NavigationDirection) -> Void) -> some View {
        background(MouseNavigationMonitor(action: action))
    }
}

/// Moniteur d'évènements local : SwiftUI n'expose pas les boutons latéraux de la souris.
private struct MouseNavigationMonitor: NSViewRepresentable {
    let action: @MainActor (NavigationDirection) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coordinator = context.coordinator
        coordinator.action = action
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .swipe]) { [weak view, weak coordinator] event in
            guard let view, let coordinator, let window = view.window, event.window === window,
                  let direction = NavigationDirection(event: event)
            else { return event }
            coordinator.action?(direction)
            return nil
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.action = action
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor {
            NSEvent.removeMonitor(monitor)
        }
        coordinator.monitor = nil
    }

    @MainActor
    final class Coordinator {
        var action: (@MainActor (NavigationDirection) -> Void)?
        var monitor: Any?
    }
}
