import ProgrammeUI
import SwiftUI

/// Where a primary action sits, which decides which system style it gets.
enum ProgrammeActionLayer {
    /// A bar, a toolbar, or anything else floating above the content. Liquid
    /// Glass belongs here.
    case control
    /// Inside the content itself, where glass does not belong.
    case content
}

extension View {

    /// Programme's primary action.
    ///
    /// Always a stock system prominent button — nothing here draws a shape, a
    /// material or a border. The only thing Programme contributes is the tint
    /// (the brand lime) and the label colour, because the system's own label
    /// choice is built for ordinary tints and the lime is bright enough that a
    /// white label would be unreadable.
    ///
    /// There is deliberately no "make everything lime" modifier: ordinary
    /// controls stay neutral, destructive stays red, review stays orange.
    @ViewBuilder
    func programmePrimaryAction(in layer: ProgrammeActionLayer = .content) -> some View {
        switch layer {
        case .control:
            buttonStyle(.glassProminent)
                .tint(Programme.Palette.brand)
                .foregroundStyle(Programme.Palette.onBrand)
        case .content:
            buttonStyle(.borderedProminent)
                .tint(Programme.Palette.brand)
                .foregroundStyle(Programme.Palette.onBrand)
        }
    }

    /// A toolbar confirmation action that actually commits something, as opposed
    /// to a `Done` that only dismisses. The system decides the shape; Programme
    /// only says that this is the brand's primary action.
    func programmeConfirmationTint() -> some View {
        tint(Programme.Palette.brand)
            .foregroundStyle(Programme.Palette.onBrand)
    }
}

/// Programme's controls are system controls.
///
/// The scoring workspace needs large, stable targets and a selection state that
/// reads from several feet away, but none of that requires drawing our own
/// buttons. These helpers pick the right *system* button style for a state, so
/// every tile and chip gets the current platform appearance, the pressed and
/// hover behaviour, keyboard focus, Dynamic Type and Reduce Transparency for
/// free — and picks up whatever Apple does to these styles next.
extension View {

    /// A selectable tile or chip: the system's bordered button, made prominent
    /// when it is chosen.
    ///
    /// Selection is carried by the style rather than by a hand-drawn ring, which
    /// is both more legible and more honest about what the control is.
    @ViewBuilder
    func programmeSelectable(
        isSelected: Bool,
        tint: Color = .accentColor,
        shape: ButtonBorderShape = .roundedRectangle(radius: 12)
    ) -> some View {
        if isSelected {
            buttonStyle(.borderedProminent)
                .tint(tint)
                .buttonBorderShape(shape)
        } else {
            buttonStyle(.bordered)
                .tint(.secondary)
                .buttonBorderShape(shape)
        }
    }

    /// A quiet, unselected tile. The same control as above with the selection
    /// branch removed, for grids where nothing is ever "on".
    func programmeTile(
        tint: Color = .secondary,
        shape: ButtonBorderShape = .roundedRectangle(radius: 12)
    ) -> some View {
        buttonStyle(.bordered)
            .tint(tint)
            .buttonBorderShape(shape)
    }
}
