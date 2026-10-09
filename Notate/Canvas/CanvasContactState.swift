import Foundation

/// Value-only contact bookkeeping, shared by the UIKit recognizer and tests.
/// Pencil transitions are independent of finger transitions so a resting finger
/// cannot prevent viewport preparation or leave navigation locked on lift-off.
struct CanvasContactState<Token: Hashable> {
    struct Transition: Equatable {
        let began: Bool
        let ended: Bool
        let pencilBegan: Bool
        let pencilEnded: Bool
    }
    private var contacts: Set<Token> = []
    private var pencils: Set<Token> = []
    var hasContact: Bool { !contacts.isEmpty }
    var hasPencil: Bool { !pencils.isEmpty }

    mutating func begin(_ touches: [(token: Token, isPencil: Bool)]) -> Transition {
        let before = (hasContact, hasPencil)
        for touch in touches {
            contacts.insert(touch.token)
            if touch.isPencil { pencils.insert(touch.token) }
        }
        return transition(from: before)
    }
    mutating func end(_ touches: Set<Token>) -> Transition {
        let before = (hasContact, hasPencil)
        contacts.subtract(touches)
        pencils.subtract(touches)
        return transition(from: before)
    }
    mutating func reset() -> Transition {
        let before = (hasContact, hasPencil)
        contacts.removeAll(keepingCapacity: true)
        pencils.removeAll(keepingCapacity: true)
        return transition(from: before)
    }
    private func transition(from before: (contact: Bool, pencil: Bool)) -> Transition {
        Transition(began: !before.contact && hasContact, ended: before.contact && !hasContact,
                   pencilBegan: !before.pencil && hasPencil, pencilEnded: before.pencil && !hasPencil)
    }
}
