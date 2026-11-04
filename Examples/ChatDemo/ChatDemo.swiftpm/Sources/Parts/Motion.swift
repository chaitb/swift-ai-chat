import SwiftUI

enum Motion {
    static func spring(_ duration: Double, bounce: Double = 0.2, reduced: Bool) -> Animation {
        reduced ? .easeOut(duration: 0.2) : .spring(duration: duration, bounce: bounce)
    }

    static func insertion(_ transition: AnyTransition, reduced: Bool) -> AnyTransition {
        reduced ? .opacity : transition
    }
}
