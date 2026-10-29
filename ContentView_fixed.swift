import SwiftUI
import Combine
import MapKit
import UIKit
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Model

struct SoundPin: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var artist: String
    var latitude: Double
    var longitude: Double
    var note: String
    /// File name inside AudioStorage.directory.
    var audioFileName: String? = nil
    /// Auto-play trigger radius in meters. nil falls back to the default.
    var radiusMeters: Double? = nil
    var radius: Double { radiusMeters ?? 100 }
    var isAudio: Bool { audioFileName != nil }
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
}

/// Shows a distance in feet for US locales and meters elsewhere. Values are always stored in meters.
func formatDistance(_ meters: Double) -> String {
    if Locale.current.measurementSystem == .us {
        let feet = meters * 3.28084
        let step = feet < 100 ? 5.0 : 10.0
        return "\(Int((feet / step).rounded() * step)) ft"
    }
    let step = meters < 50 ? 1.0 : 5.0
    return "\(Int((meters / step).rounded() * step)) m"
}

/// Logarithmic slider (20 ft to 3000 ft, or 5 m to 1000 m) so small radii are easy to dial in.
/// The binding is always in meters.
struct RadiusSlider: View {
    @Binding var meters: Double
    private static let feetPerMeter = 3.28084
    private var usesFeet: Bool { Locale.current.measurementSystem == .us }
    private var lo: Double { usesFeet ? 20 : 5 }
    private var hi: Double { usesFeet ? 3000 : 1000 }
    private var unitsPerMeter: Double { usesFeet ? Self.feetPerMeter : 1 }

    private var position: Binding<Double> {
        Binding(
            get: {
                let v = min(max(meters * unitsPerMeter, lo), hi)
                return log(v / lo) / log(hi / lo)
            },
            set: { t in
                let raw = lo * pow(hi / lo, t)
                let snapped: Double
                if usesFeet { snapped = raw < 100 ? (raw / 5).rounded() * 5 : (raw / 10).rounded() * 10 }
                else { snapped = raw < 50 ? raw.rounded() : (raw / 5).rounded() * 5 }
                meters = max(lo, snapped) / unitsPerMeter
            }
        )
    }

    var body: some View { Slider(value: position, in: 0...1) }
}

// MARK: - Local audio

enum AudioStorage {
    static var directory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("SoundmapAudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static func url(for name: String) -> URL { directory.appendingPathComponent(name) }

    /// Copies a user-picked file into the app's sandbox and returns the stored file name.
    static func importFile(from source: URL) throws -> String {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let ext = source.pathExtension
        let name = UUID().uuidString + (ext.isEmpty ? "" : "." + ext)
        try FileManager.default.copyItem(at: source, to: url(for: name))
        return name
    }
    static func delete(_ name: String) {
        try? FileManager.default.removeItem(at: url(for: name))
    }
}

@MainActor
final class AudioPlayerModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var playingFile: String?
    private var player: AVAudioPlayer?

    func toggle(_ fileName: String) throws {
        if playingFile == fileName { stop() } else { try play(fileName) }
    }
    func play(_ fileName: String) throws {
        stop()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback)
        try session.setActive(true)
        let p = try AVAudioPlayer(contentsOf: AudioStorage.url(for: fileName))
        p.delegate = self
        p.play()
        player = p
        playingFile = fileName
    }
    func stop() {
        player?.stop(); player = nil; playingFile = nil
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}

// MARK: - Auto-play when nearby

@MainActor
final class GeofenceManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "soundmap.autoplay"); refresh(); syncRegions() }
    }
    @Published var errorMessage: String?
    @Published private(set) var isTracking = false
    @Published private(set) var lastAccuracy: Double?          // meters
    @Published private(set) var nearestEdgeDistance: Double?   // meters to the edge of the closest pin's circle
    @Published private(set) var lastEnteredID: UUID?
    @Published private(set) var lastFixDate: Date?
    var onEnter: ((SoundPin) -> Void)?

    private let manager = CLLocationManager()
    private var pins: [SoundPin] = []
    private var inside: Set<UUID> = []
    private var askedForAlways = false
    private var lastLocation: CLLocation?
    private var regionSignature = ""

    override init() {
        isEnabled = UserDefaults.standard.object(forKey: "soundmap.autoplay") as? Bool ?? true
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 10
    }

    /// Pins under ~50 m need best-accuracy GPS and frequent updates (more battery); larger ones don't.
    private func tuneAccuracy() {
        let precise = pins.contains { $0.radius < 50 }
        manager.desiredAccuracy = precise ? kCLLocationAccuracyBest : kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = precise ? 2 : 10
    }

    /// Everything that has to be true for background auto-play to work, with a fix hint for each failure.
    var diagnosticRows: [DiagnosticRow] {
        let info = Bundle.main.infoDictionary ?? [:]
        let modes = info["UIBackgroundModes"] as? [String] ?? []
        let status = manager.authorizationStatus
        let statusText: String
        switch status {
        case .notDetermined: statusText = "Not asked yet"
        case .restricted: statusText = "Restricted"
        case .denied: statusText = "Denied"
        case .authorizedWhenInUse: statusText = "While Using"
        case .authorizedAlways: statusText = "Always"
        @unknown default: statusText = "Unknown"
        }
        let settingsPath = "Settings > Privacy & Security > Location Services > this app"
        var permissionHint = "Set it to Always in \(settingsPath)."
        if status == .notDetermined { permissionHint = "iOS never showed the prompt. Check the When In Use text below." }
        if status == .denied { permissionHint = "Turn location on in \(settingsPath)." }
        let permissionOK: Bool? = status == .authorizedAlways ? true : (status == .authorizedWhenInUse ? nil : false)

        var rows: [DiagnosticRow] = []
        rows.append(.init(label: "Location permission", value: statusText, ok: permissionOK,
                          hint: status == .authorizedWhenInUse
                            ? "Works in the foreground only. " + permissionHint : permissionHint))
        rows.append(.init(label: "Precise Location", value: manager.accuracyAuthorization == .fullAccuracy ? "On" : "Off",
                          ok: manager.accuracyAuthorization == .fullAccuracy,
                          hint: "Turn on Precise Location in \(settingsPath). Approximate location is off by about a mile."))
        rows.append(.init(label: "Info: When In Use text", value: info["NSLocationWhenInUseUsageDescription"] != nil ? "Present" : "Missing",
                          ok: info["NSLocationWhenInUseUsageDescription"] != nil,
                          hint: "Add NSLocationWhenInUseUsageDescription in the target's Info tab."))
        rows.append(.init(label: "Info: Always text", value: info["NSLocationAlwaysAndWhenInUseUsageDescription"] != nil ? "Present" : "Missing",
                          ok: info["NSLocationAlwaysAndWhenInUseUsageDescription"] != nil,
                          hint: "Add NSLocationAlwaysAndWhenInUseUsageDescription in the target's Info tab."))
        rows.append(.init(label: "Background: location", value: modes.contains("location") ? "On" : "Off",
                          ok: modes.contains("location"),
                          hint: "Add Location updates under Signing & Capabilities > Background Modes."))
        rows.append(.init(label: "Background: audio", value: modes.contains("audio") ? "On" : "Off",
                          ok: modes.contains("audio"),
                          hint: "Add Audio, AirPlay, and PiP under Signing & Capabilities > Background Modes."))
        rows.append(.init(label: "Auto-play", value: isEnabled ? "On" : "Off", ok: isEnabled, hint: "Turn it on with the switch above."))
        rows.append(.init(label: "Sound pins", value: "\(pins.count)", ok: !pins.isEmpty,
                          hint: "Tracking only runs once at least one pin has an audio file."))
        rows.append(.init(label: "Tracking", value: isTracking ? "Running" : "Stopped", ok: isTracking,
                          hint: "Needs auto-play on, at least one pin and location permission."))
        let fixText: String
        if let d = lastFixDate, let acc = lastAccuracy {
            fixText = "\(Int(max(0, -d.timeIntervalSinceNow))) s ago, ±\(formatDistance(acc))"
        } else { fixText = "None yet" }
        rows.append(.init(label: "Last GPS fix", value: fixText, ok: lastFixDate != nil,
                          hint: "No fix yet. In the Simulator, pick Features > Location > City Run, or a custom location."))
        rows.append(.init(label: "Regions watched", value: "\(manager.monitoredRegions.count)",
                          ok: status == .authorizedAlways ? !manager.monitoredRegions.isEmpty : nil,
                          hint: "Only used with Always permission; they relaunch the app after it is closed."))
        return rows
    }

    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }

    /// Lets the person trigger the system prompt by hand from the tracking sheet.
    func requestPermission() {
        manager.requestWhenInUseAuthorization()
        objectWillChange.send()
    }

    func update(pins newPins: [SoundPin]) {
        pins = newPins.filter(\.isAudio)
        inside = inside.filter { id in pins.contains { $0.id == id } }
        tuneAccuracy()
        refresh()
        syncRegions()
    }

    private var hasBackgroundLocationMode: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])?.contains("location") ?? false
    }

    private func refresh() {
        guard isEnabled && !pins.isEmpty else { stopUpdates(); return }
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            startUpdates()
            // "Always" lets tracking continue with the phone locked and lets iOS relaunch the app near a pin.
            if !askedForAlways { askedForAlways = true; manager.requestAlwaysAuthorization() }
        case .authorizedAlways:
            startUpdates()
        case .denied, .restricted:
            errorMessage = "Location access is off. Turn it on in Settings > Privacy > Location Services to auto-play sounds near pins."
            stopUpdates()
        @unknown default:
            break
        }
    }

    private func startUpdates() {
        guard !isTracking else { return }
        isTracking = true
        // Setting this without the "location" background mode in Info.plist crashes, so check first.
        if hasBackgroundLocationMode {
            manager.allowsBackgroundLocationUpdates = true
            manager.pausesLocationUpdatesAutomatically = false
            manager.showsBackgroundLocationIndicator = true
        }
        manager.startUpdatingLocation()
    }

    private func stopUpdates() {
        guard isTracking else { return }
        isTracking = false
        manager.stopUpdatingLocation()
        inside.removeAll()
        lastAccuracy = nil
        nearestEdgeDistance = nil
    }

    /// With "Always" access, iOS watches up to 20 regions for us and relaunches the app if it was quit.
    /// Regions can't be smaller than about 100 m, so they only wake the app; the exact radius is checked with GPS.
    private func syncRegions() {
        guard manager.authorizationStatus == .authorizedAlways,
              CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }
        var chosen = pins
        if let origin = lastLocation {
            chosen.sort {
                origin.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude))
                < origin.distance(from: CLLocation(latitude: $1.latitude, longitude: $1.longitude))
            }
        }
        chosen = Array(chosen.prefix(20))
        let signature = isEnabled
            ? chosen.map { "\($0.id)-\($0.latitude)-\($0.longitude)-\(max($0.radius, 100))" }.joined(separator: "|")
            : ""
        guard signature != regionSignature else { return }
        regionSignature = signature
        for region in manager.monitoredRegions { manager.stopMonitoring(for: region) }
        guard isEnabled else { return }
        for pin in chosen {
            let radius = min(max(pin.radius, 100), manager.maximumRegionMonitoringDistance)
            let region = CLCircularRegion(center: pin.coordinate, radius: radius, identifier: pin.id.uuidString)
            region.notifyOnEntry = true
            region.notifyOnExit = false
            manager.startMonitoring(for: region)
        }
    }

    private func handle(_ location: CLLocation) {
        guard location.horizontalAccuracy >= 0 else { return }
        lastLocation = location
        lastAccuracy = location.horizontalAccuracy
        lastFixDate = location.timestamp
        var nearest: Double?
        for pin in pins {
            let distance = location.distance(from: CLLocation(latitude: pin.latitude, longitude: pin.longitude))
            let edge = max(0, distance - pin.radius)
            nearest = min(nearest ?? edge, edge)
            // Tiny pins need a good fix; big pins tolerate a rough one.
            guard location.horizontalAccuracy <= min(max(15, pin.radius), 100) else { continue }
            let exitMargin = max(15, pin.radius * 0.3)   // must move this far past the edge to re-arm
            if inside.contains(pin.id) {
                if distance > pin.radius + exitMargin { inside.remove(pin.id) }
            } else if distance <= pin.radius {
                inside.insert(pin.id)
                lastEnteredID = pin.id
                onEnter?(pin)
            }
        }
        nearestEdgeDistance = nearest
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        Task { @MainActor in self.handle(last) }
    }
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.objectWillChange.send(); self.refresh(); self.syncRegions() }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        // Woken up near a pin: make sure precise tracking is running.
        Task { @MainActor in self.refresh() }
    }
}

// MARK: - Current location (one-shot)

enum LocationError: LocalizedError {
    case denied, busy, unavailable
    var errorDescription: String? {
        switch self {
        case .denied: return "Location access is off. Turn it on in Settings > Privacy > Location Services to use your current location."
        case .busy: return "Already finding your location."
        case .unavailable: return "Could not get a location fix. Try again with a clearer view of the sky."
        }
    }
}

@MainActor
final class CurrentLocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, Error>?
    private var best: CLLocation?
    private var timeout: Task<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    /// Asks for permission up front so the blue dot shows on the map.
    func requestPermissionIfNeeded() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
    }

    /// Waits for a fix accurate to about 15 m, or the best fix available after 6 seconds.
    func current() async throws -> CLLocation {
        if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted { throw LocationError.denied }
        guard continuation == nil else { throw LocationError.busy }
        best = nil
        return try await withCheckedThrowingContinuation { cont in
            continuation = cont
            if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
            else { begin() }
        }
    }

    private func begin() {
        manager.startUpdatingLocation()
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.finishWithBest()
        }
    }

    private func finishWithBest() {
        if let best { finish(.success(best)) } else { finish(.failure(LocationError.unavailable)) }
    }

    private func finish(_ result: Result<CLLocation, Error>) {
        timeout?.cancel(); timeout = nil
        manager.stopUpdatingLocation()
        continuation?.resume(with: result)
        continuation = nil
    }

    private func consider(_ locations: [CLLocation]) {
        guard continuation != nil else { return }
        for loc in locations where loc.horizontalAccuracy >= 0 && abs(loc.timestamp.timeIntervalSinceNow) < 10 {
            if best == nil || loc.horizontalAccuracy < best!.horizontalAccuracy { best = loc }
        }
        if let b = best, b.horizontalAccuracy <= 15 { finish(.success(b)) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in self.consider(locations) }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if (error as? CLError)?.code == .locationUnknown { return }   // transient, keep waiting
        Task { @MainActor in self.finish(.failure(error)) }
    }
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard self.continuation != nil else { return }
            switch self.manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways: self.begin()
            case .denied, .restricted: self.finish(.failure(LocationError.denied))
            default: break
            }
        }
    }
}

// MARK: - Pins

@MainActor final class PinStore: ObservableObject {
    @Published var pins: [SoundPin] = [] { didSet { save() } }
    private let key = "soundmap.pins.v2"
    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([SoundPin].self, from: data) {
            // Pins from before Spotify was removed have no audio file, so they are dropped.
            pins = saved.filter(\.isAudio)
        }
    }
    private func save() {
        if let data = try? JSONEncoder().encode(pins) { UserDefaults.standard.set(data, forKey: key) }
    }
}

// MARK: - Shared auto-play engine

/// Owns the pins, the player and the location tracking, so playback does not depend on a screen being open.
@MainActor
final class AutoPlayCoordinator {
    static let shared = AutoPlayCoordinator()
    let store = PinStore()
    let audio = AudioPlayerModel()
    let geo = GeofenceManager()
    private var cancellables = Set<AnyCancellable>()
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        geo.onEnter = { [weak self] pin in
            guard let self, let file = pin.audioFileName, self.audio.playingFile != file else { return }
            do { try self.audio.play(file) }
            catch { self.geo.errorMessage = "Could not play \(pin.title): \(error.localizedDescription)" }
        }
        store.$pins
            .sink { [weak self] pins in self?.geo.update(pins: pins) }
            .store(in: &cancellables)
    }
}

/// Starts tracking at launch, including when iOS relaunches the app in the background for a location event.
/// Hook it up in your @main App struct with:  @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        AutoPlayCoordinator.shared.start()
        return true
    }
}

// MARK: - Main view

struct ContentView: View {
    @ObservedObject private var store = AutoPlayCoordinator.shared.store
    @ObservedObject private var audio = AutoPlayCoordinator.shared.audio
    @ObservedObject private var geo = AutoPlayCoordinator.shared.geo
    @StateObject private var locator = CurrentLocationProvider()
    @State private var camera: MapCameraPosition = .userLocation(fallback: .region(.init(center: .init(latitude: 39.5, longitude: -98.35),
                                                                 span: .init(latitudeDelta: 30, longitudeDelta: 35))))
    @State private var query = ""
    @State private var pendingCoordinate: CLLocationCoordinate2D?
    @State private var pendingName = ""
    @State private var pendingRadius = 100.0
    @State private var selectedID: UUID?
    @State private var showingAdd = false
    @State private var showingDiagnostics = false
    @State private var aiming = false
    @State private var aimCoordinate: CLLocationCoordinate2D?
    @State private var mapSize: CGSize = .zero
    @State private var alertText: String?

    private var selectedPin: SoundPin? { store.pins.first { $0.id == selectedID } }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                MapReader { proxy in
                    Map(position: $camera, selection: $selectedID) {
                        UserAnnotation()
                        ForEach(store.pins) { pin in
                            MapCircle(center: pin.coordinate, radius: pin.radius)
                                .foregroundStyle(.purple.opacity(0.15))
                                .stroke(.purple.opacity(0.5), lineWidth: 1)
                        }
                        ForEach(store.pins) { pin in
                            Annotation(pin.title, coordinate: pin.coordinate, anchor: .center) {
                                PinDot(color: .purple, selected: selectedID == pin.id)
                            }
                            .tag(pin.id)
                        }
                        if let c = pendingCoordinate, showingAdd {
                            MapCircle(center: c, radius: pendingRadius)
                                .foregroundStyle(.orange.opacity(0.2))
                                .stroke(.orange, lineWidth: 1.5)
                        }
                        if let c = pendingCoordinate {
                            Annotation("New location", coordinate: c, anchor: .center) {
                                PinDot(color: .orange, selected: true)
                            }
                        }
                    }
                    .mapControls {
                        MapUserLocationButton()
                        MapCompass()
                        MapScaleView()
                    }
                    .gesture(
                        LongPressGesture(minimumDuration: 0.5)
                            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
                            .onEnded { value in
                                guard case .second(true, let drag?) = value,
                                      let coordinate = proxy.convert(drag.location, from: .local) else { return }
                                dropPin(at: coordinate, name: "")
                            }
                    )
                    .overlay { if aiming { Crosshair() } }
                    .onGeometryChange(for: CGSize.self, of: { $0.size }) { mapSize = $0 }
                    .onMapCameraChange(frequency: .continuous) { _ in
                        if aiming { aimCoordinate = coordinateUnderCrosshair(proxy) }
                    }
                    .onMapCameraChange(frequency: .onEnd) { _ in
                        if aiming { aimCoordinate = coordinateUnderCrosshair(proxy) }
                    }
                    .onChange(of: aiming) { _, on in
                        if on { aimCoordinate = coordinateUnderCrosshair(proxy) }
                    }
                }
                VStack(spacing: 8) {
                    HStack {
                        TextField("Search place, address, or lat, lon", text: $query)
                            .submitLabel(.search).onSubmit { searchPlace() }
                        Button("Search", action: searchPlace).fontWeight(.semibold)
                    }.padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    controlsRow
                }.padding()
            }
            .navigationTitle("soundmap").navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) { bottomBar }
            .sheet(isPresented: $showingAdd) {
                if let coordinate = pendingCoordinate {
                    AddAudioView(placeName: pendingName, radius: $pendingRadius) { fileName, title, artist, note in
                        let pin = SoundPin(title: title, artist: artist, latitude: coordinate.latitude,
                                           longitude: coordinate.longitude, note: note,
                                           audioFileName: fileName, radiusMeters: pendingRadius)
                        store.pins.append(pin)
                        selectedID = pin.id
                        pendingCoordinate = nil
                        showingAdd = false
                    }
                    .presentationDetents([.medium, .large])
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                }
            }
            .sheet(isPresented: $showingDiagnostics) {
                TrackingDiagnosticsView(geo: geo)
                    .presentationDetents([.medium, .large])
            }
            .alert("soundmap", isPresented: Binding(get: { alertText != nil }, set: { if !$0 { alertText = nil } })) {
                Button("OK", role: .cancel) { alertText = nil }
            } message: { Text(alertText ?? "") }
            .onChange(of: geo.errorMessage) { _, value in if let value { alertText = value } }
            .onChange(of: geo.lastEnteredID) { _, id in if let id { selectedID = id } }
            .onChange(of: showingAdd) { _, showing in
                if showing, let c = pendingCoordinate { focusCamera(on: c, radius: pendingRadius) }
            }
            .onChange(of: pendingRadius) { _, radius in
                if showingAdd, let c = pendingCoordinate { withAnimation { focusCamera(on: c, radius: radius) } }
            }
            .onAppear {
                AutoPlayCoordinator.shared.start()
                if Bundle.main.object(forInfoDictionaryKey: "NSLocationWhenInUseUsageDescription") == nil {
                    // Without this text iOS never shows the prompt, and the app is not listed under Location in Settings.
                    alertText = "The location permission text is missing from the app's Info settings, so iOS will not ask for location. Add \"Privacy - Location When In Use Usage Description\" in the target's Info tab, then run the app again."
                }
                locator.requestPermissionIfNeeded()
            }
        }
    }

    // MARK: Controls

    private var controlsRow: some View {
        HStack {
            Button { showingDiagnostics = true } label: {
                Label(autoPlayLabel,
                      systemImage: geo.isEnabled ? "location.circle.fill" : "location.slash")
                    .font(.caption)
                    .padding(9)
                    .background(.regularMaterial, in: Capsule())
            }
            .foregroundStyle(.primary)
            Spacer()
            aimButton
            myLocationButton
            addSoundButton
        }
    }

    private var autoPlayLabel: String {
        guard geo.isEnabled else { return "Auto-play off" }
        if geo.isTracking { return geo.lastAccuracy.map { "Tracking ±\(formatDistance($0))" } ?? "Locating…" }
        return "Auto-play on"
    }

    private var nearestText: String {
        guard let d = geo.nearestEdgeDistance else { return "Search or press and hold to add" }
        return d == 0 ? "Inside a pin's area" : "Nearest pin: \(formatDistance(d)) away"
    }

    private var aimButton: some View {
        Button { startAiming() } label: {
            Image(systemName: "scope")
                .padding(10)
                .background(.regularMaterial, in: Circle())
        }
        .accessibilityLabel("Fine-tune pin location")
    }

    private var myLocationButton: some View {
        Button { useMyLocation() } label: {
            Image(systemName: "location.fill")
                .padding(10)
                .background(.regularMaterial, in: Circle())
        }
        .accessibilityLabel("Use my location")
    }

    private var addSoundButton: some View {
        Button {
            guard pendingCoordinate != nil else {
                alertText = "Search for a place, press and hold the map, or tap the location button first."
                return
            }
            showingAdd = true
        } label: {
            Label("Add sound", systemImage: "plus")
                .fontWeight(.semibold)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.purple, in: Capsule())
                .foregroundStyle(.white)
        }
    }

    @ViewBuilder private var bottomBar: some View {
        if aiming {
            aimBar
        } else if let pin = selectedPin {
            VStack(spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pin.title).font(.subheadline.weight(.semibold))
                        Text(pin.artist.isEmpty ? "Audio file" : pin.artist)
                            .font(.caption).foregroundStyle(.secondary)
                        Text(String(format: "%.6f, %.6f", pin.latitude, pin.longitude))
                            .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { togglePlayback(pin) } label: {
                        Image(systemName: audio.playingFile == pin.audioFileName ? "stop.fill" : "play.fill")
                    }
                    .buttonStyle(.bordered)
                    Button(role: .destructive) { delete(pin) } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered)
                }
                HStack(spacing: 10) {
                    Image(systemName: "circle.dashed").foregroundStyle(.secondary)
                    RadiusSlider(meters: radiusBinding(for: pin))
                    Text(formatDistance(pin.radius))
                        .font(.caption).monospacedDigit()
                        .frame(minWidth: 60, alignment: .trailing)
                }
            }
            .padding(12).background(.regularMaterial)
        } else {
            HStack {
                Image(systemName: "music.note.map")
                Text("\(store.pins.count) sound pins")
                Spacer()
                Text(nearestText).font(.caption).foregroundStyle(.secondary)
            }
            .padding(12).background(.regularMaterial)
        }
    }

    // MARK: Actions

    private var aimBar: some View {
        VStack(spacing: 10) {
            HStack {
                Image(systemName: "scope")
                Text(aimCoordinate.map { String(format: "%.6f, %.6f", $0.latitude, $0.longitude) } ?? "Move the map")
                    .font(.subheadline).monospacedDigit()
                Spacer()
            }
            HStack {
                Button("Cancel") { aiming = false }.buttonStyle(.bordered)
                Spacer()
                Button {
                    if let c = aimCoordinate { dropPin(at: c, name: pendingName) }
                    aiming = false
                } label: { Label("Pin here", systemImage: "mappin") }
                    .buttonStyle(.borderedProminent).tint(.purple)
                    .disabled(aimCoordinate == nil)
            }
        }
        .padding(12).background(.regularMaterial)
    }

    /// Pan and zoom the map under the crosshair, then confirm. Zooming in gives sub-meter control.
    private func startAiming() {
        selectedID = nil
        if let c = pendingCoordinate {
            camera = .region(MKCoordinateRegion(center: c, latitudinalMeters: 120, longitudinalMeters: 120))
        }
        aiming = true
    }

    private func coordinateUnderCrosshair(_ proxy: MapProxy) -> CLLocationCoordinate2D? {
        guard mapSize != .zero else { return nil }
        return proxy.convert(CGPoint(x: mapSize.width / 2, y: mapSize.height / 2), from: .local)
    }

    private func radiusBinding(for pin: SoundPin) -> Binding<Double> {
        Binding(
            get: { store.pins.first { $0.id == pin.id }?.radius ?? pin.radius },
            set: { value in
                if let i = store.pins.firstIndex(where: { $0.id == pin.id }) { store.pins[i].radiusMeters = value }
            }
        )
    }

    private func togglePlayback(_ pin: SoundPin) {
        guard let file = pin.audioFileName else { return }
        do { try audio.toggle(file) }
        catch { alertText = "Could not play this file: \(error.localizedDescription)" }
    }

    private func delete(_ pin: SoundPin) {
        if let file = pin.audioFileName {
            if audio.playingFile == file { audio.stop() }
            AudioStorage.delete(file)
        }
        store.pins.removeAll { $0.id == pin.id }
        selectedID = nil
    }

    /// Frames the new pin in the top half of the screen so the radius circle stays visible above the sheet.
    private func focusCamera(on c: CLLocationCoordinate2D, radius: Double) {
        let span = max(radius * 5, 60)
        let shifted = CLLocationCoordinate2D(latitude: c.latitude - (span * 0.25) / 111_000, longitude: c.longitude)
        camera = .region(MKCoordinateRegion(center: shifted, latitudinalMeters: span, longitudinalMeters: span))
    }

    private func dropPin(at coordinate: CLLocationCoordinate2D, name: String) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        pendingCoordinate = coordinate
        pendingName = name
        selectedID = nil
    }

    private func useMyLocation() {
        Task {
            do {
                let location = try await locator.current()
                let c = location.coordinate
                dropPin(at: c, name: "")
                camera = .region(.init(center: c, span: .init(latitudeDelta: 0.005, longitudeDelta: 0.005)))
            } catch { alertText = error.localizedDescription }
        }
    }

    /// Accepts "42.2, -83.15" style input in the search box.
    private static func parseCoordinate(_ text: String) -> CLLocationCoordinate2D? {
        let tokens = text.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " })
        guard tokens.count == 2, let lat = Double(tokens[0]), let lon = Double(tokens[1]),
              abs(lat) <= 90, abs(lon) <= 180 else { return nil }
        return .init(latitude: lat, longitude: lon)
    }

    private func searchPlace() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        if let c = Self.parseCoordinate(q) {
            dropPin(at: c, name: "")
            camera = .region(.init(center: c, span: .init(latitudeDelta: 0.005, longitudeDelta: 0.005)))
            return
        }
        Task {
            do {
                let req = MKLocalSearch.Request(); req.naturalLanguageQuery = q
                let result = try await MKLocalSearch(request: req).start()
                guard let item = result.mapItems.first else { await MainActor.run { alertText = "No place found. Try a more specific search." }; return }
                let c = item.location.coordinate
                await MainActor.run {
                    pendingCoordinate = c; pendingName = item.name ?? q
                    camera = .region(.init(center: c, span: .init(latitudeDelta: 0.015, longitudeDelta: 0.015)))
                    query = pendingName
                }
            } catch { await MainActor.run { alertText = "Place search failed: \(error.localizedDescription)" } }
        }
    }
}

// MARK: - Add audio sheet

struct AddAudioView: View {
    let placeName: String
    @Binding var radius: Double
    let onSave: (_ fileName: String, _ title: String, _ artist: String, _ note: String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pickedURL: URL?
    @State private var title = ""
    @State private var artist = ""
    @State private var note = ""
    @State private var showingImporter = false
    @State private var errorText: String?

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Audio file") {
                    Button { showingImporter = true } label: {
                        Label(pickedURL?.lastPathComponent ?? "Choose audio file", systemImage: "waveform")
                    }
                }
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Auto-play radius")
                            Spacer()
                            Text(formatDistance(radius)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        RadiusSlider(meters: $radius)
                    }
                } footer: {
                    Text("The orange circle on the map shows where the sound starts playing.")
                }
                Section("Details") {
                    TextField("Title", text: $title)
                    TextField("Artist (optional)", text: $artist)
                    TextField("Optional note for \(placeName.isEmpty ? "this spot" : placeName)", text: $note, axis: .vertical)
                }
                if let errorText {
                    Section { Text(errorText).font(.caption).foregroundStyle(.red) }
                }
                Section {
                    Button("Save sound pin") { save() }
                        .disabled(pickedURL == nil || trimmedTitle.isEmpty)
                }
            }
            .navigationTitle("Add audio file").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.audio]) { result in
                switch result {
                case .success(let url):
                    pickedURL = url; errorText = nil
                    if trimmedTitle.isEmpty { title = url.deletingPathExtension().lastPathComponent }
                case .failure(let error):
                    errorText = error.localizedDescription
                }
            }
        }
    }

    private func save() {
        guard let url = pickedURL else { return }
        do {
            let fileName = try AudioStorage.importFile(from: url)
            onSave(fileName, trimmedTitle,
                   artist.trimmingCharacters(in: .whitespacesAndNewlines),
                   note.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            errorText = "Could not import that file: \(error.localizedDescription)"
        }
    }
}

// MARK: - Map pieces

/// Small dot whose center sits exactly on the coordinate.
struct PinDot: View {
    let color: Color
    var selected = false
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: selected ? 18 : 14, height: selected ? 18 : 14)
            .overlay(Circle().stroke(.white, lineWidth: 2.5))
            .shadow(radius: 2)
            .padding(10)                 // larger tap target
            .contentShape(Circle())
    }
}

struct Crosshair: View {
    var body: some View {
        ZStack {
            Circle().stroke(.red, lineWidth: 1.5).frame(width: 28, height: 28)
            Rectangle().fill(.red).frame(width: 1.5, height: 48)
            Rectangle().fill(.red).frame(width: 48, height: 1.5)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Tracking self-check

struct DiagnosticRow: Identifiable {
    var id: String { label }
    let label: String
    let value: String
    let ok: Bool?      // true = good, false = broken, nil = works with limits
    let hint: String
}

struct TrackingDiagnosticsView: View {
    @ObservedObject var geo: GeofenceManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section { Toggle("Auto-play when nearby", isOn: $geo.isEnabled) }
                if geo.authorizationStatus == .notDetermined {
                    Section {
                        Button("Ask for location permission") { geo.requestPermission() }
                    } footer: {
                        Text("If no iOS prompt appears when you tap this, the location text entry is missing from the app's Info tab.")
                    }
                }
                Section("Checks") {
                    ForEach(geo.diagnosticRows) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: icon(for: row.ok)).foregroundStyle(color(for: row.ok))
                                Text(row.label)
                                Spacer()
                                Text(row.value).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                            }
                            if row.ok != true {
                                Text(row.hint).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
            }
            .navigationTitle("Tracking").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func icon(for ok: Bool?) -> String {
        switch ok {
        case .some(true): return "checkmark.circle.fill"
        case .some(false): return "xmark.circle.fill"
        case .none: return "exclamationmark.triangle.fill"
        }
    }
    private func color(for ok: Bool?) -> Color {
        switch ok {
        case .some(true): return .green
        case .some(false): return .red
        case .none: return .orange
        }
    }
}
