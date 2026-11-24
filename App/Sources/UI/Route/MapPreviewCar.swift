import DriveLoggerCore

extension MapPreviewData {
    /// Where the synthetic estimate of `-uiFakeHUD navEllipse` sits instead of its default spot
    /// (set by a DEBUG `-uiRouteStub` state whose picture must agree with the bar). Nil in the app.
    @MainActor static var carOverride: GeoPoint?
}
