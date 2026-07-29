import SwiftUI

/// The phren mascot, drawn from the same 24×24 pixel grid the design project
/// uses (`sprite-data.js` / `sprite.jsx`), rather than a flattened PNG.
///
/// Drawing from the grid buys three things the raster asset can't: it stays
/// crisp at any size, and it can hold a *pose* and *blink* — so the mascot can
/// react to what the screen is actually showing instead of staring blankly out
/// of every empty state.
///
/// Pixel offsets below are transcribed from `sprite.jsx`'s pose system. Per a
/// note in that file, brows are deliberately not ported: they read as mush at
/// this scale, so mood is carried by eyes and mouth.
struct PhrenSprite: View {

    /// The expressions the app has a use for. The design kit defines many more
    /// (skate, split, kick, hats, headphones…); porting only what ships keeps
    /// this honest about what's actually exercised.
    enum Pose {
        /// Resting. The default everywhere.
        case idle
        /// Arms up, mouth open, feet off the ground — a finished thing.
        case celebrate
        /// Eyes narrowed, looking down. Nothing matched.
        case searching
        /// Small frown. Something went wrong, without being alarming.
        case concerned
        /// Eyes closed. Nothing to sync, nothing to do.
        case resting
        /// On the board, feet planted, grinning. Animated by the mascot view
        /// rocking the whole sprite — the deck and wheels are part of the grid.
        case skating
        /// Mid-stride; `frame` alternates the feet.
        case walking
    }

    var pose: Pose = .idle
    var size: CGFloat = 96
    var blinking = false
    /// Animation frame for the poses that step (walking). The mascot view
    /// advances this on a timer; the sprite itself stays stateless.
    var frame: Int = 0

    private static let grid = CGFloat(PhrenSpriteData.gridSize)

    // Palette constants from sprite.jsx.
    private static let purpleMid = Color(hex: 0x755CF9)
    private static let purpleLight = Color(hex: 0x9C8FF8)
    private static let purpleFoot = Color(hex: 0x9EA1F8)
    private static let eyeNavy = Color(hex: 0x121665)
    private static let deckOrange = Color(hex: 0xD97757)
    private static let wheelViolet = Color(hex: 0x7C3AED)

    var body: some View {
        Canvas { context, canvasSize in
            let unit = min(canvasSize.width, canvasSize.height) / Self.grid
            for cell in cells {
                let rect = CGRect(
                    x: CGFloat(cell.col) * unit,
                    y: CGFloat(cell.row) * unit,
                    // Slight overdraw closes the hairline seams that appear
                    // between adjacent cells at fractional scales.
                    width: unit * 1.02,
                    height: unit * 1.02
                )
                context.fill(Path(rect), with: .color(cell.color))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    // MARK: - Pose composition

    private struct Drawn {
        let col: Int
        let row: Int
        let color: Color
    }

    /// Base grid with the pose's removals, shifts and additions applied — the
    /// same order `sprite.jsx` applies them: legs, then arms, then eyes, then
    /// mouth.
    private var cells: [Drawn] {
        var result: [Drawn] = []

        let eyesClosed = blinking || pose == .resting
        let dropsLegs = pose == .celebrate || pose == .skating || pose == .walking

        for cell in PhrenSpriteData.base {
            if dropsLegs, cell.row == 19 { continue }

            var color = Color(hex: cell.rgb)
            var row = cell.row

            if isEye(col: cell.col, row: cell.row) {
                switch pose {
                case _ where eyesClosed:
                    // A closed eye is the lid colour, not a hole.
                    color = Self.purpleMid
                case .searching:
                    continue  // replaced by narrowed dashes below
                case .concerned:
                    row += 1  // looking down
                default:
                    break
                }
            }

            result.append(Drawn(col: cell.col, row: row, color: color))
        }

        result.append(contentsOf: legs)
        result.append(contentsOf: arms)
        result.append(contentsOf: eyes(closed: eyesClosed))
        result.append(contentsOf: mouth)
        return result
    }

    private func isEye(col: Int, row: Int) -> Bool {
        row == 12 && (col == 7 || col == 11)
    }

    private var legs: [Drawn] {
        switch pose {
        case .celebrate:
            // jump: feet tucked up
            return [
                Drawn(col: 10, row: 18, color: Self.purpleLight),
                Drawn(col: 13, row: 18, color: Self.purpleLight),
            ]
        case .skating:
            // feet apart on the deck, plus the board itself: deck one row
            // below the feet, wheels below that — all in-grid so it pixelates
            // identically to the body.
            var drawn = [8, 9, 14, 15].map { Drawn(col: $0, row: 19, color: Self.purpleFoot) }
            drawn += (6...17).map { Drawn(col: $0, row: 20, color: Self.deckOrange) }
            drawn += [7, 16].map { Drawn(col: $0, row: 21, color: Self.wheelViolet) }
            return drawn
        case .walking:
            // alternating stride, straight from sprite.jsx's walk frames
            let cols = frame % 2 == 0 ? [10, 13] : [9, 14]
            return cols.map { Drawn(col: $0, row: 19, color: Self.purpleFoot) }
        default:
            return []
        }
    }

    private var arms: [Drawn] {
        guard pose == .celebrate else { return [] }
        // armsUp: both arms raised in a V.
        //
        // Mirrored about the body's centre (col 12) rather than copied from
        // sprite.jsx, whose right arm sits at cols 15-16 — inside a silhouette
        // that spans cols 6-18, so it draws over the body and disappears. Only
        // the left arm ever cleared the outline, which read as a glitch rather
        // than a pose.
        return [
            Drawn(col: 5, row: 10, color: Self.purpleMid),
            Drawn(col: 4, row: 9, color: Self.purpleLight),
            Drawn(col: 4, row: 8, color: Self.purpleLight),
            Drawn(col: 19, row: 10, color: Self.purpleMid),
            Drawn(col: 20, row: 9, color: Self.purpleLight),
            Drawn(col: 20, row: 8, color: Self.purpleLight),
        ]
    }

    private func eyes(closed: Bool) -> [Drawn] {
        guard !closed, pose == .searching else { return [] }
        // Eyes shifted a column left — scanning. The kit's `squint` puts its
        // dashes back on the eyes' own cells, which left the pose identical to
        // idle; this borrows its `lookLeft` shift instead so the pose is
        // actually visible.
        return [
            Drawn(col: 6, row: 12, color: Self.eyeNavy),
            Drawn(col: 10, row: 12, color: Self.eyeNavy),
        ]
    }

    private var mouth: [Drawn] {
        switch pose {
        case .idle, .skating, .walking:
            // smile
            return [
                Drawn(col: 8, row: 15, color: Self.eyeNavy),
                Drawn(col: 9, row: 16, color: Self.eyeNavy),
                Drawn(col: 10, row: 16, color: Self.eyeNavy),
                Drawn(col: 11, row: 15, color: Self.eyeNavy),
            ]
        case .celebrate:
            // open
            return [
                Drawn(col: 9, row: 15, color: Self.eyeNavy),
                Drawn(col: 10, row: 15, color: Self.eyeNavy),
                Drawn(col: 9, row: 16, color: Self.eyeNavy),
                Drawn(col: 10, row: 16, color: Self.eyeNavy),
            ]
        case .concerned:
            // frown
            return [
                Drawn(col: 9, row: 16, color: Self.eyeNavy),
                Drawn(col: 10, row: 16, color: Self.eyeNavy),
            ]
        case .searching, .resting:
            return []
        }
    }
}
