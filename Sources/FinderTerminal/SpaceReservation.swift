import AppKit

/// Reserves a strip of a native fullscreen space so the fullscreen window is
/// laid out smaller — the only way to free room inside such a space, since AX
/// position/size writes there are dropped silently (verified on macOS 26).
///
/// Uses private SkyLight (`SLSSpaceSetEdgeReservation`), resolved at runtime:
/// every entry point is a no-op when a symbol is missing, so a future macOS
/// degrades to "no fullscreen support" instead of crashing. Reservations live on
/// the space, so they vanish with it when the window leaves fullscreen; they are
/// also cleared on close and at launch (crash safety net).
enum SpaceReservation {
    /// Edge bits of the reservation mask, and the order of the four inset
    /// arguments — both established by probing the real function.
    private enum Edge: UInt64 {
        case left = 1, top = 2, right = 4, bottom = 8
    }

    private typealias ConnectionFn = @convention(c) () -> Int32
    private typealias DisplaySpacesFn = @convention(c) (Int32) -> CFArray?
    private typealias SpacesForWindowsFn = @convention(c) (Int32, UInt32, CFArray) -> CFArray?
    /// (connection, space, edgeMask, left, right, top, bottom)
    private typealias SetReservationFn =
        @convention(c) (Int32, UInt64, UInt64, Double, Double, Double, Double) -> Int32

    private static let handle =
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let ptr = dlsym(handle, name) else { return nil }
        return unsafeBitCast(ptr, to: type)
    }

    private static let connection: Int32? = symbol("SLSMainConnectionID", as: ConnectionFn.self)?()
    private static let displaySpaces = symbol("SLSCopyManagedDisplaySpaces", as: DisplaySpacesFn.self)
    private static let spacesForWindows = symbol("SLSCopySpacesForWindows", as: SpacesForWindowsFn.self)
    private static let setReservation = symbol("SLSSpaceSetEdgeReservation", as: SetReservationFn.self)

    static var isAvailable: Bool { connection != nil && setReservation != nil }

    /// The space `windowID` lives in, when that space is a fullscreen one.
    static func fullScreenSpace(of windowID: CGWindowID) -> UInt64? {
        guard let connection, let spacesForWindows,
              let ids = spacesForWindows(connection, 7, [NSNumber(value: windowID)] as CFArray) as? [NSNumber],
              let space = ids.first?.uint64Value
        else { return nil }
        return fullScreenSpaceIDs().contains(space) ? space : nil
    }

    /// Lay the space's window out `points` short of the given edge. Returns false
    /// when the private API is unavailable or refuses.
    @discardableResult
    static func reserve(_ points: CGFloat, side: DockSide, space: UInt64) -> Bool {
        guard let connection, let setReservation else { return false }
        let edge: Edge = switch side {
        case .top: .top
        case .bottom: .bottom
        case .left: .left
        case .right: .right
        }
        // Whole points only — a fractional inset collapses the fullscreen space.
        let v = Double(points.rounded())
        let err = setReservation(connection, space, edge.rawValue,
                                 edge == .left ? v : 0, edge == .right ? v : 0,
                                 edge == .top ? v : 0, edge == .bottom ? v : 0)
        return err == 0
    }

    /// Give the whole space back to its window.
    static func clear(space: UInt64) {
        guard let connection, let setReservation else { return }
        _ = setReservation(connection, space, 15, 0, 0, 0, 0)
    }

    /// Safety net: a crash leaves a reservation behind, and the strip would stay
    /// empty until the user leaves fullscreen. Clear Finder's on launch.
    static func clearStaleFinderReservations() {
        guard let pid = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.finder")
            .first?.processIdentifier else { return }
        for (space, owner) in fullScreenSpaces() where owner == pid {
            clear(space: space)
        }
    }

    private static func fullScreenSpaceIDs() -> Set<UInt64> {
        Set(fullScreenSpaces().map(\.space))
    }

    /// Every fullscreen space, with the pid of the app that owns it.
    private static func fullScreenSpaces() -> [(space: UInt64, owner: pid_t)] {
        guard let connection, let displaySpaces,
              let displays = displaySpaces(connection) as? [[String: Any]] else { return [] }
        return displays.flatMap { display -> [(space: UInt64, owner: pid_t)] in
            let spaces = display["Spaces"] as? [[String: Any]] ?? []
            return spaces.compactMap { s in
                // Only fullscreen spaces carry a tile layout manager.
                guard s["TileLayoutManager"] != nil,
                      let id = (s["ManagedSpaceID"] as? NSNumber)?.uint64Value else { return nil }
                return (id, (s["pid"] as? NSNumber)?.int32Value ?? -1)
            }
        }
    }
}
