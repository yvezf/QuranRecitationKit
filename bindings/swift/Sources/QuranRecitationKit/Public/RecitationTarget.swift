import Foundation

/// Word offsets are zero-based, ayah-relative, and half-open.
public enum RecitationTarget: Sendable, Equatable {
    case surah(Int)
    case ayahs(surah: Int, range: ClosedRange<Int>)
    case words(surah: Int, ayah: Int, range: Range<Int>)
}
