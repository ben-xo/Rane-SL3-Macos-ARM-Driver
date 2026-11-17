// SL3ControlPanel.swift — "SL 3 Control Panel", a small app to see and set the Rane SL 3's state:
// connection, firmware and driver versions, sample rate, latency, and for each of its three decks (Aux,
// Left, Right) the LINE/PHONO switch, the output source (USB audio or analogue thru) and the phono
// sensitivity; the box's overload flags, the decks' input and output levels, and the output volume. It
// talks to the SL3Device HAL plug-in through CoreAudio, as sl3panel does:
//   'sl3s'  the driver's status (SL3StatusPacket, SL3Status.h)
//   'sl3h'  a 64-byte HID command to the box; reading it back returns the box's reply
//   'sl3m'  the peak level of each input and output channel since the last read
//   'sl3i'  the input safety offset setting, in microseconds (set with nothing streaming)
// and the device's standard output volume.
// Built by tools/controlpanel/build-app.sh.

import AppKit
import CoreAudio
import IOKit
import SwiftUI

// MARK: - The driver, through CoreAudio

enum SL3Driver {
    static let deviceUID = "com.rane.sl3.hal.device"
    static let pluginBundleID = "io.github.pepeleedj.sl3device"
    static let driverBundlePath = "/Library/Audio/Plug-Ins/HAL/SL3Device.driver"

    static let vendorID = 0x1cc5
    static let productID = 0x0001

    static let decks = 3
    static let channels = 6

    // HID commands (plugin/SL3Device.m, SL3_CMD_*). Every command and reply is one 64-byte report:
    // [0] command, [1..4] tag (echoed in the reply), [5...] arguments or results.
    static let reportLength = 64
    static let cmdGetControls: UInt8 = 0x32   // reply [5..26] the 22 control bytes
    static let cmdSetControls: UInt8 = 0x33   // [5] first index, [6] count, [7...] values

    // The control bytes: a block of six per deck, in the box's order Aux, Left, Right (SL3_CTL_*).
    static let controlsLength = 22
    /// A deck's phono sensitivity, 0-15 for 2.5 + 0.5 n mV, kept in the box's EEPROM: bytes 3, 9, 15.
    static func ctlSensitivity(_ deck: Int) -> UInt8 { UInt8(3 + 6 * deck) }
    /// A deck's output source, 1 = USB audio, 0 = analogue thru: bytes 8, 14, 20.
    static func ctlSource(_ deck: Int) -> UInt8 { UInt8(3 + 6 * deck + 5) }
    static let sensitivitySteps = 16

    static func fourCC(_ s: String) -> AudioObjectPropertySelector {
        s.utf8.reduce(0) { $0 << 8 | AudioObjectPropertySelector($1) }
    }
    static let propStatus = fourCC("sl3s")
    static let propHID = fourCC("sl3h")
    static let propInSafety = fourCC("sl3i")

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// The SL 3's CoreAudio device, listed by the driver while a box is attached.
    static func device() -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var uid = deviceUID as CFString
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = withUnsafePointer(to: &uid) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                       UInt32(MemoryLayout<CFString>.size), $0, &size, &dev)
        }
        return err == noErr && dev != kAudioObjectUnknown ? dev : nil
    }

    /// The SL3Device plug-in is loaded in coreaudiod.
    static func pluginLoaded() -> Bool {
        var addr = address(kAudioHardwarePropertyTranslateBundleIDToPlugIn)
        var bundle = pluginBundleID as CFString
        var plugin = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = withUnsafePointer(to: &bundle) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                       UInt32(MemoryLayout<CFString>.size), $0, &size, &plugin)
        }
        return err == noErr && plugin != kAudioObjectUnknown
    }

    /// An SL 3 is in the USB registry (with or without the driver).
    static func boxOnUSB() -> Bool {
        guard let match = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary? else { return false }
        match["idVendor"] = vendorID
        match["idProduct"] = productID
        let service = IOServiceGetMatchingService(kIOMainPortDefault, match)
        guard service != 0 else { return false }
        IOObjectRelease(service)
        return true
    }

    /// The installed driver's version, from its bundle.
    static func driverVersion() -> String? {
        Bundle(path: driverBundlePath)?.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    /// The driver's status packet; a shorter packet (an older driver) is zero-filled.
    static func status(_ dev: AudioObjectID) -> SL3StatusPacket? {
        var addr = address(propStatus)
        var data: Unmanaged<CFData>?
        var size = UInt32(MemoryLayout<Unmanaged<CFData>?>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &data) == noErr,
              let cf = data?.takeRetainedValue() else { return nil }
        var packet = SL3StatusPacket()
        let bytes = cf as Data
        _ = withUnsafeMutableBytes(of: &packet) { dst in
            bytes.copyBytes(to: dst.bindMemory(to: UInt8.self), count: min(bytes.count, dst.count))
        }
        return packet
    }

    /// The tag of the last HID command sent; each command gets the next one (never 0).
    @MainActor private static var lastTag: UInt32 = 0

    /// Send one HID command to the box and return its reply, or nil if it didn't take the command.
    @MainActor @discardableResult
    static func command(_ dev: AudioObjectID, _ cmd: UInt8, _ args: [UInt8] = []) -> [UInt8]? {
        // Build the report: [0] the command, [1..4] a new tag, [5...] the arguments.
        lastTag = lastTag == UInt32.max ? 1 : lastTag + 1
        var request = [UInt8](repeating: 0, count: reportLength)
        request[0] = cmd
        withUnsafeBytes(of: lastTag) { request.replaceSubrange(1...4, with: $0) }
        request.replaceSubrange(5..<(5 + args.count), with: args)
        // Writing 'sl3h' sends it.
        var addr = address(propHID)
        let cfIn = Data(request) as CFData
        var ref = Unmanaged.passUnretained(cfIn)   // the property's value is the CFDataRef itself
        let sent = withExtendedLifetime(cfIn) {
            AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Unmanaged<CFData>>.size), &ref)
        }
        guard sent == noErr else { return nil }
        // Reading 'sl3h' returns the box's reply: the same command and tag if it took the command.
        var reply: Unmanaged<CFData>?
        var size = UInt32(MemoryLayout<Unmanaged<CFData>?>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &reply) == noErr,
              let out = reply?.takeRetainedValue() as Data?, out.count >= 5 else { return nil }
        let bytes = [UInt8](out)
        return bytes[0] == cmd && Array(bytes[1...4]) == Array(request[1...4]) ? bytes : nil
    }

    /// The box's 22 control bytes (0x32), or nil if it didn't answer.
    @MainActor
    static func controls(_ dev: AudioObjectID) -> [UInt8]? {
        guard let reply = command(dev, cmdGetControls), reply.count >= 5 + controlsLength else { return nil }
        return Array(reply[5..<(5 + controlsLength)])
    }

    /// Set one control byte (0x33).
    @MainActor @discardableResult
    static func setControl(_ dev: AudioObjectID, _ index: UInt8, _ value: UInt8) -> Bool {
        command(dev, cmdSetControls, [index, 1, value]) != nil
    }

    static let propMeters = fourCC("sl3m")

    /// The peak level (0...1) of inputs 1-6 then outputs 1-6 since the last read. Reading keeps the
    /// driver measuring for another second; nil if the driver has no meters.
    static func meters(_ dev: AudioObjectID) -> [Float]? {
        var addr = address(propMeters)
        var data: Unmanaged<CFData>?
        var size = UInt32(MemoryLayout<Unmanaged<CFData>?>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &data) == noErr,
              let cf = data?.takeRetainedValue() else { return nil }
        let bytes = cf as Data
        guard bytes.count == 2 * channels * MemoryLayout<Float32>.size else { return nil }
        var peaks = [Float32](repeating: 0, count: 2 * channels)
        _ = peaks.withUnsafeMutableBytes { bytes.copyBytes(to: $0) }
        return peaks
    }

    /// The output's main volume as a slider position (0...1) and in dB, or nil if there is none.
    static func volume(_ dev: AudioObjectID) -> (scalar: Float, db: Float)? {
        var scalarAddr = address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput)
        var dbAddr = address(kAudioDevicePropertyVolumeDecibels, kAudioObjectPropertyScopeOutput)
        var scalar: Float32 = 0, db: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(dev, &scalarAddr, 0, nil, &size, &scalar) == noErr,
              AudioObjectGetPropertyData(dev, &dbAddr, 0, nil, &size, &db) == noErr else { return nil }
        return (scalar, db)
    }

    static func setVolume(_ dev: AudioObjectID, _ scalar: Float) {
        var addr = address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput)
        var value = Float32(scalar)
        AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }

    /// The output mute, or nil if there is none.
    static func muted(_ dev: AudioObjectID) -> Bool? {
        var addr = address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &value) == noErr ? value != 0 : nil
    }

    static func setMuted(_ dev: AudioObjectID, _ muted: Bool) {
        var addr = address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)
        var value: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    /// Audio MIDI Setup, where each output channel's volume is set.
    static let audioMIDISetup = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.audio.AudioMIDISetup")

    /// Set the input safety offset (microseconds). The driver takes it only with nothing streaming,
    /// then has CoreAudio set the device up again with it, which takes about half a second.
    @discardableResult
    static func setInputSafety(_ dev: AudioObjectID, _ us: Int) -> Bool {
        var addr = address(propInSafety)
        let number = us as CFNumber
        var ref = Unmanaged.passUnretained(number)   // the property's value is the CFNumberRef itself
        return withExtendedLifetime(number) {
            AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Unmanaged<CFNumber>>.size), &ref)
        } == noErr
    }

    static func setSampleRate(_ dev: AudioObjectID, _ rate: Double) {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var value = rate
        AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Float64>.size), &value)
    }

    static func uint32(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> UInt32 {
        var addr = address(selector, scope)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value) == noErr ? value : 0
    }

    /// The latency the driver reports in one direction, in frames: device latency, safety offset
    /// and the stream's latency (what an app adds to its own buffer).
    static func latencyFrames(_ dev: AudioObjectID, _ scope: AudioObjectPropertyScope) -> UInt32 {
        var total = uint32(dev, kAudioDevicePropertyLatency, scope) + uint32(dev, kAudioDevicePropertySafetyOffset, scope)
        var addr = address(kAudioDevicePropertyStreams, scope)
        var stream = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        if AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &stream) == noErr, stream != kAudioObjectUnknown {
            total += uint32(stream, kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal)
        }
        return total
    }
}

// MARK: - What the panel shows

struct BoxState: Equatable {
    var streaming: Bool
    var sampleRate: Int
    var firmware: String
    var serial: String
    var phono: [Bool]        // each deck's LINE/PHONO switch: true = Phono
    var thru: [Bool]         // each deck's output source: true = analogue thru
    var sensitivity: [Int]?  // each deck's phono sensitivity step (0-15); nil until the box has answered
    var overload: [Bool]     // the box's six overload flags
    var fullSpeed: Bool      // connected at USB full speed, which carries no audio
    var outputLatencyMs: Double
    var inputLatencyMs: Double
    var volume: Volume?      // the main output volume; nil if none
    struct Volume: Equatable {
        let scalar: Float    // as a slider position, 0...1
        let db: Float
    }
    var muted: Bool?         // the output mute; nil if none
    var input: InputHealth?  // nil from a driver too old to report it
    struct InputHealth: Equatable {
        let safetyUs: Int        // the input safety offset (the setting, as CoreAudio is using it)
        let earlyRead: UInt32    // 0 not judged yet, 1 working, 2 not working
        let hubs: Int            // USB hubs between the box and the Mac
        let dropouts: UInt64     // IO cycles in which input wasn't captured in time, since the box connected
                                 // or the input safety offset changed
    }
}

enum PanelState: Equatable {
    case driverMissing      // the plug-in isn't loaded: nothing can reach the box
    case noBox              // no SL 3 attached
    case bootloader         // attached, but with no firmware running
    case connected(BoxState)
}

/// A repeating timer on the main run loop in its common modes, so it keeps firing while a control is
/// being dragged (event tracking), which a timer in the default mode does not.
@MainActor
func repeatingTimer(every interval: TimeInterval, _ body: @escaping @MainActor () -> Void) -> Timer {
    let timer = Timer(timeInterval: interval, repeats: true) { _ in Task { @MainActor in body() } }
    RunLoop.main.add(timer, forMode: .common)
    return timer
}

@MainActor
final class PanelModel: ObservableObject {
    @Published var state: PanelState = .noBox
    @Published var driverVersion: String?
    /// A short-lived message about something the user just tried (shown with the warnings).
    @Published var notice: String?
    /// The level meters, which read the device this model finds (not published: they redraw alone).
    let meters = MeterModel()
    private var timer: Timer?
    private(set) var device: AudioObjectID?
    /// The phono sensitivities, which only the box's control bytes hold (not the status): read once
    /// per connection and after each change, not at every refresh.
    private var sensitivity: [Int]?
    private var controlsRead = false
    /// The device whose volume and mute changes we are told of, and the listener that hears them.
    private var watched: AudioObjectID?
    private lazy var volumeListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        Task { @MainActor in self?.refresh() }
    }
    private static let watchedProperties = [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute].map {
        SL3Driver.address($0, kAudioObjectPropertyScopeOutput)
    }

    init() {
        meters.device = { [weak self] in self?.device }
        refresh()
        // The status changes from outside the app (the box's switches, other apps, plugging in):
        // read it twice a second. The volume and mute are followed as they change (watch).
        timer = repeatingTimer(every: 0.5) { [weak self] in self?.refresh() }
    }

    /// Be told when the device's main volume or mute changes (the menu bar, the volume keys, Audio
    /// MIDI Setup), so the slider follows at once rather than at the next status read.
    private func watch(_ dev: AudioObjectID?) {
        guard dev != watched else { return }
        if let old = watched {
            for var addr in Self.watchedProperties {
                AudioObjectRemovePropertyListenerBlock(old, &addr, DispatchQueue.main, volumeListener)
            }
        }
        if let new = dev {
            for var addr in Self.watchedProperties {
                AudioObjectAddPropertyListenerBlock(new, &addr, DispatchQueue.main, volumeListener)
            }
        }
        watched = dev
    }

    /// Forget the phono sensitivities, so they are read again at the next connection.
    private func forgetControls() {
        sensitivity = nil
        controlsRead = false
    }

    /// Read the phono sensitivities from the box's control bytes (0x32).
    private func readControls(_ dev: AudioObjectID) {
        controlsRead = true
        guard let c = SL3Driver.controls(dev) else { return }
        sensitivity = (0..<SL3Driver.decks).map { Int(c[Int(SL3Driver.ctlSensitivity($0))]) }
    }

    func refresh() {
        driverVersion = SL3Driver.driverVersion()
        // No driver device: either no box, or no driver to list one.
        guard let dev = SL3Driver.device(), let s = SL3Driver.status(dev) else {
            device = nil
            watch(nil)
            forgetControls()
            state = SL3Driver.pluginLoaded() ? .noBox : .driverMissing
            return
        }
        if dev != device { forgetControls() }
        device = dev
        watch(dev)
        // The bundle's version can't tell a debug build (make install DEBUG=1 replaces only the
        // binary in it); the running driver says so in its status.
        if s.debug_build != 0, let version = driverVersion { driverVersion = version + " (debug build)" }
        if s.boot_mode != 0 { forgetControls(); state = .bootloader; return }
        if s.connected == 0 { forgetControls(); state = .noBox; return }
        // Newly connected: ask the box for its phono sensitivities, once.
        if !controlsRead { readControls(dev) }
        // Connected: collect what the panel shows.
        let rate = Double(s.sample_rate > 0 ? s.sample_rate : 44100)
        let volume = SL3Driver.volume(dev)
        let serial = withUnsafeBytes(of: s.serial) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        let phono = withUnsafeBytes(of: s.phono) { Array($0.prefix(SL3Driver.decks)) }
        let thru = withUnsafeBytes(of: s.thru) { Array($0.prefix(SL3Driver.decks)) }
        let overload = withUnsafeBytes(of: s.overload) { Array($0) }
        state = .connected(BoxState(
            streaming: s.streaming != 0,
            sampleRate: Int(s.sample_rate),
            firmware: s.version_maj == 0 && s.version_min == 0 ? "—" : String(format: "%u.%02u", s.version_maj, s.version_min),
            serial: serial.isEmpty ? "—" : serial,
            phono: phono.map { $0 != 0 },
            thru: thru.map { $0 != 0 },
            sensitivity: sensitivity,
            overload: overload.map { $0 != 0 },
            fullSpeed: s.usb_state == 1,
            outputLatencyMs: Double(SL3Driver.latencyFrames(dev, kAudioObjectPropertyScopeOutput)) * 1000 / rate,
            inputLatencyMs: Double(SL3Driver.latencyFrames(dev, kAudioObjectPropertyScopeInput)) * 1000 / rate,
            volume: volume.map { BoxState.Volume(scalar: $0.scalar, db: $0.db) },
            muted: SL3Driver.muted(dev),
            input: s.in_safety_us == 0 ? nil : BoxState.InputHealth(
                safetyUs: Int(s.in_safety_us), earlyRead: s.early_read,
                hubs: Int(s.hub_depth), dropouts: s.in_dropouts)))
    }

    /// Set the main output volume (a slider position, 0...1); the menu bar and Audio MIDI Setup follow.
    /// Any level above the minimum unmutes, as the macOS volume slider does. The window updates from
    /// the volume and mute listener (watch), so a slider drag costs one set per step, not a refresh.
    func setVolume(_ scalar: Float, unmuting muted: Bool) {
        guard let dev = device else { return }
        SL3Driver.setVolume(dev, scalar)
        if scalar > 0, muted { SL3Driver.setMuted(dev, false) }
    }

    func setMuted(_ muted: Bool) {
        guard let dev = device else { return }
        SL3Driver.setMuted(dev, muted)
    }

    /// Switch a deck's output (0 Aux, 1 Left, 2 Right) to analogue thru or USB audio, then show what
    /// the box reports.
    func setThru(deck: Int, on: Bool) {
        guard let dev = device else { return }
        SL3Driver.setControl(dev, SL3Driver.ctlSource(deck), on ? 0 : 1)
        // The box confirms the change with a report within a few milliseconds; the driver keeps it in
        // its status.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.refresh() }
    }

    /// Set a deck's phono sensitivity step (0-15), which the box keeps in its EEPROM, then read the
    /// control bytes back to show what the box took.
    func setSensitivity(deck: Int, step: Int) {
        guard let dev = device, (0..<SL3Driver.sensitivitySteps).contains(step) else { return }
        SL3Driver.setControl(dev, SL3Driver.ctlSensitivity(deck), UInt8(step))
        readControls(dev)
        refresh()
    }

    /// Change the input safety offset. CoreAudio sets the device up again with it (the window shows the
    /// SL 3 as gone for a moment).
    func setInputSafety(_ us: Int) {
        guard let dev = device else { return }
        // Refused if an app started using the SL 3 since the window last looked: say so, for a while.
        if !SL3Driver.setInputSafety(dev, us) {
            notice = "The input safety offset wasn't changed: an app is using the SL 3."
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.notice = nil }
            refresh()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.refresh() }
    }

    /// Change the rate through CoreAudio: the driver changes the box's rate with the HAL's.
    func setSampleRate(_ rate: Int) {
        guard let dev = device else { return }
        SL3Driver.setSampleRate(dev, Double(rate))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.refresh() }
    }
}

/// The level meters: each deck's input and output, read from the driver 60 times a second. Kept
/// apart from PanelModel so the meters redraw on their own, not the whole window. They respond fast
/// (a new peak at once, falling the full range in a third of a second), so they show how promptly
/// audio, a DVS record's timecode for one, starts and stops.
@MainActor
final class MeterModel: ObservableObject {
    /// Peak level in dB (meterFloorDb...0) of each channel: inputs 1-6 (Aux L, R, Left deck L, R,
    /// Right deck L, R), then outputs 1-6.
    @Published var levels: [Float] = Array(repeating: MeterModel.meterFloorDb, count: 2 * SL3Driver.channels)
    static let meterFloorDb: Float = -60
    private static let ticksPerSecond = 60.0
    private static let fallDbPerTick: Float = 3     // 180 dB a second
    private var timer: Timer?
    /// The device to read, from PanelModel.
    var device: () -> AudioObjectID? = { nil }

    init() {
        timer = repeatingTimer(every: 1.0 / Self.ticksPerSecond) { [weak self] in self?.tick() }
    }

    private func tick() {
        // Read the driver only while the window can be seen: once nothing reads them, the driver stops
        // measuring (after a second), so a hidden or minimised panel costs nothing.
        guard NSApp.windows.contains(where: { $0.isVisible && $0.occlusionState.contains(.visible) }) else { return }
        let peaks = device().flatMap { SL3Driver.meters($0) } ?? Array(repeating: 0, count: 2 * SL3Driver.channels)
        // A meter jumps up to a new peak and falls back fast, but not so fast that a short peak is gone
        // before it is drawn.
        let next = zip(levels, peaks).map { shown, peak in
            let db = peak > 0 ? max(20 * log10(peak), Self.meterFloorDb) : Self.meterFloorDb
            return max(db, shown - Self.fallDbPerTick)
        }
        // Publish only a change, so still meters don't redraw.
        if next != levels { levels = next }
    }
}

/// A horizontal level meter, from meterFloorDb to 0 dB: green, then yellow from -12 dB, red from -3 dB.
struct LevelMeter: View {
    let db: Float
    var label = "Level"
    var body: some View {
        GeometryReader { geo in
            let floor = MeterModel.meterFloorDb
            let fraction = CGFloat((db - floor) / -floor)
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(LinearGradient(stops: [.init(color: .green, location: 0),
                                                 .init(color: .green, location: 0.78),
                                                 .init(color: .yellow, location: 0.8),
                                                 .init(color: .yellow, location: 0.93),
                                                 .init(color: .red, location: 0.95)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width)
                    .mask(alignment: .leading) { Capsule().frame(width: geo.size.width * max(0, min(1, fraction))) }
            }
        }
        .frame(height: 6)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(db <= MeterModel.meterFloorDb ? "silent" : String(format: "%.0f dB", db))
    }
}

/// A deck's stereo meter: one bar for its left channel, one for its right.
struct StereoMeter: View {
    let left: Float, right: Float
    var body: some View {
        VStack(spacing: 3) {
            ForEach([("L", left), ("R", right)], id: \.0) { side, db in
                HStack(spacing: 6) {
                    Text(side).font(.caption2).foregroundStyle(.secondary).frame(width: 8)
                    LevelMeter(db: db, label: side == "L" ? "Left" : "Right")
                }
            }
        }
    }
}

/// The three decks' stereo meters, one row each, observing the meters themselves so that only they
/// redraw as the levels move.
struct DeckMeters: View {
    @ObservedObject var meters: MeterModel
    let first: Int   // index into meters.levels of the first deck's left channel: 0 inputs, 6 outputs
    var body: some View {
        ForEach(0..<SL3Driver.decks, id: \.self) { deck in
            LabeledContent(PanelView.deckNames[deck]) {
                StereoMeter(left: meters.levels[first + 2 * deck], right: meters.levels[first + 2 * deck + 1])
            }
        }
    }
}

/// The box's six overload flags, as a row of small lights numbered 1-6: red while a flag is set.
struct OverloadFlags: View {
    let flags: [Bool]
    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(flags.enumerated()), id: \.offset) { i, on in
                HStack(spacing: 3) {
                    Text("\(i + 1)").font(.caption2).foregroundStyle(.secondary)
                    Circle().fill(on ? AnyShapeStyle(.red) : AnyShapeStyle(.quaternary)).frame(width: 7, height: 7)
                }
                .accessibilityElement()
                .accessibilityLabel("Overload flag \(i + 1)")
                .accessibilityValue(on ? "set" : "clear")
            }
        }
    }
}

// MARK: - The window

struct PanelView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        Group {
            switch model.state {
            case .driverMissing:
                Message(symbol: "exclamationmark.triangle", title: "SL 3 driver not loaded",
                        text: "Install the Rane SL 3 driver package, then open this app again.")
            case .noBox:
                Message(symbol: "cable.connector", title: "No SL 3 connected",
                        text: "Connect the SL 3 by USB, directly or through a single hub.")
            case .bootloader:
                Message(symbol: "exclamationmark.triangle", title: "The SL 3 has no firmware running",
                        text: "The box started without its firmware and passes no audio until its firmware is restored.")
            case .connected(let box):
                connected(box)
            }
        }
        // Every piece of text can be selected and copied (a serial number, a warning to paste into a
        // report); controls' own labels stay controls.
        .textSelection(.enabled)
    }

    /// One column of the connected view: a grouped form sized to its sections, so it never scrolls.
    private func column<Content: View>(@ViewBuilder _ sections: () -> Content) -> some View {
        Form { sections() }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .scrollIndicators(.never)
            .frame(width: Self.columnWidth)
            .fixedSize(horizontal: false, vertical: true)
    }
    static let columnWidth: CGFloat = 440
    /// The decks as the box marks them, in its order: Aux is channels 1/2, the left deck 3/4, the right
    /// deck 5/6, for inputs and outputs alike.
    static let deckNames = ["Aux (1/2)", "Left deck (3/4)", "Right deck (5/6)"]

    @ViewBuilder
    private func connected(_ box: BoxState) -> some View {
        HStack(alignment: .top, spacing: 0) {
            column { boxSections(box) }
            column { levelSections(box) }
        }
    }

    /// The left column: the box, its audio settings and the decks.
    @ViewBuilder
    private func boxSections(_ box: BoxState) -> some View {
        Section("Rane SL 3") {
            LabeledContent("Status", value: box.streaming ? "Connected, streaming audio" : "Connected")
            LabeledContent("Firmware", value: box.firmware)
            LabeledContent("Serial number", value: box.serial)
            LabeledContent("Driver", value: model.driverVersion ?? "—")
            if let input = box.input {
                LabeledContent("USB", value: input.hubs == 0 ? "Connected directly" :
                                             input.hubs == 1 ? "Through 1 hub" : "Through \(input.hubs) hubs")
            }
        }
        Section {
            Picker("Sample rate", selection: Binding(get: { box.sampleRate },
                                                     set: { model.setSampleRate($0) })) {
                Text("44.1 kHz").tag(44100)
                Text("48 kHz").tag(48000)
            }
            LabeledContent("Output latency", value: String(format: "%.1f ms", box.outputLatencyMs))
            LabeledContent("Input latency", value: String(format: "%.1f ms", box.inputLatencyMs))
            if let input = box.input {
                Picker("Input safety offset", selection: Binding(get: { input.safetyUs },
                                                                 set: { model.setInputSafety($0) })) {
                    ForEach(Self.safetyChoices(input.safetyUs), id: \.self) { us in
                        Text(Self.ms(us) + Self.safetyNote(us)).tag(us)
                    }
                }
                .disabled(box.streaming)
            }
        } header: {
            Text("Audio")
        } footer: {
            Text("Latency as the driver reports it, not counting each app's own buffer (in Serato DJ: USB Buffer Size). Raise the input safety offset if you hear gaps in the input.")
                .foregroundStyle(.secondary)
        }
        Section {
            deckGrid(box)
        } header: {
            Text("Decks")
        } footer: {
            Text("Output: USB plays what an app sends; Thru sends the deck's input straight to its outputs. An app playing through the SL 3 switches every deck to USB when it starts, and back to Thru when it stops. Input is each deck's LINE / PHONO switch on the box. The box keeps each deck's phono sensitivity itself, in its memory.")
                .foregroundStyle(.secondary)
        }
    }

    /// The decks as a table, one row each: the LINE/PHONO switch, the output source and the phono
    /// sensitivity.
    private func deckGrid(_ box: BoxState) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            // The column headings.
            GridRow {
                Text("Deck")
                Text("Input")
                Text("Output")
                Text("Phono sensitivity")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            // One row per deck.
            ForEach(0..<SL3Driver.decks, id: \.self) { deck in
                GridRow {
                    Text(Self.deckNames[deck])
                    Text(box.phono[deck] ? "Phono" : "Line")
                        .foregroundStyle(.secondary)
                    Picker("\(Self.deckNames[deck]) output", selection: Binding(get: { box.thru[deck] },
                                                                                set: { model.setThru(deck: deck, on: $0) })) {
                        Text("USB").tag(false)
                        Text("Thru").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    sensitivityPicker(box, deck: deck)
                }
            }
        }
    }

    /// A deck's phono sensitivity, 2.5 to 10 mV; shown as "—" (and disabled) until the box has answered.
    @ViewBuilder
    private func sensitivityPicker(_ box: BoxState, deck: Int) -> some View {
        let step = box.sensitivity?[deck]
        Picker("\(Self.deckNames[deck]) phono sensitivity",
               selection: Binding(get: { step ?? -1 }, set: { model.setSensitivity(deck: deck, step: $0) })) {
            if step == nil { Text("—").tag(-1) }
            ForEach(0..<SL3Driver.sensitivitySteps, id: \.self) { n in
                Text(String(format: "%.1f mV", 2.5 + 0.5 * Double(n))).tag(n)
            }
        }
        .labelsHidden()
        .fixedSize()
        .disabled(step == nil)
    }

    /// The input safety offsets to choose from, with the current setting among them.
    static func safetyChoices(_ setting: Int) -> [Int] {
        let choices = [500, 1000, 1500, 2000, 3000, 4000, 8000]
        return choices.contains(setting) ? choices : (choices + [setting]).sorted()
    }
    /// Below the default, input can drop out under load.
    static func safetyNote(_ us: Int) -> String {
        us == 1500 ? " (default)" : us < 1500 ? " (not recommended)" : ""
    }
    static func ms(_ us: Int) -> String {
        us % 1000 == 0 ? "\(us / 1000) ms" : String(format: "%.1f ms", Double(us) / 1000)
    }

    /// What the panel warns about: a full-speed USB connection, input the driver couldn't read early,
    /// and input dropouts.
    static func warnings(_ box: BoxState) -> [String] {
        var w: [String] = []
        // At full speed the box enumerates without its audio interfaces.
        if box.fullSpeed {
            w.append("The SL 3 is connected at USB full speed, which carries no audio. Connect it to a USB 2.0 (high-speed) port.")
        }
        guard let input = box.input else { return w }
        // Where the early read doesn't work, input can drop out below 8 ms (completion delivery).
        if input.earlyRead == 2 && input.safetyUs < 8000 {
            w.append("Input can't be read early on this Mac, so it can drop out at \(ms(input.safetyUs)). Set the input safety offset to 8 ms.")
        }
        if input.dropouts > 0 {
            let times = input.dropouts == 1 ? "once" : "\(input.dropouts) times"
            w.append("Input dropped out \(times) since the SL 3 was connected or the input safety offset changed. If you hear gaps in the input, raise the input safety offset.")
        }
        return w
    }

    /// The Outputs footer, with "Audio MIDI Setup" a link that opens it (plain text if it can't be found).
    private var outputsFooter: AttributedString {
        var text = AttributedString("The volume applies to everything the SL 3 plays, Serato's decks included, like the volume keys. Set each output channel's own volume in ")
        var app = AttributedString("Audio MIDI Setup")
        if let url = SL3Driver.audioMIDISetup { app.link = url }
        text.append(app)
        text.append(AttributedString("."))
        return text
    }

    /// The right column: any warnings, the input levels and overload flags, and the output volume and levels.
    @ViewBuilder
    private func levelSections(_ box: BoxState) -> some View {
        let warnings = (model.notice.map { [$0] } ?? []) + Self.warnings(box)
        if !warnings.isEmpty {
            Section {
                ForEach(warnings, id: \.self) { text in
                    Label(text, systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        Section {
            DeckMeters(meters: model.meters, first: 0)
            LabeledContent("Overload flags") { OverloadFlags(flags: box.overload) }
        } header: {
            Text("Inputs")
        } footer: {
            Text("The level of each deck's input, left and right, while an app is using the SL 3. With nothing using it the decks are on thru, and the box sends the computer no audio. The overload flags are the six the box reports.")
                .foregroundStyle(.secondary)
        }
        Section {
            if let volume = box.volume {
                LabeledContent("Volume") {
                    HStack {
                        Slider(value: Binding(get: { volume.scalar },
                                              set: { model.setVolume($0, unmuting: box.muted == true) }), in: 0...1)
                        Text(box.muted == true ? "Muted" : volume.scalar <= 0 ? "Off" : String(format: "%.0f dB", volume.db))
                            .monospacedDigit()
                            .frame(width: 52, alignment: .trailing)
                    }
                }
            }
            if let muted = box.muted {
                Toggle("Mute", isOn: Binding(get: { muted }, set: { model.setMuted($0) }))
            }
            DeckMeters(meters: model.meters, first: SL3Driver.channels)
        } header: {
            Text("Outputs")
        } footer: {
            Text(outputsFooter)
                .foregroundStyle(.secondary)
                // The link is the app's bundle: launch it (the default handler does nothing with an .app).
                .environment(\.openURL, OpenURLAction { url in
                    guard url.pathExtension == "app" else { return .systemAction }
                    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                    return .handled
                })
        }
    }
}

struct Message: View {
    let symbol: String, title: String, text: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(.secondary)
            Text(title).font(.title3).bold()
            Text(text).multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(width: PanelView.columnWidth)
    }
}

// MARK: - The app

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct SL3ControlPanelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = PanelModel()

    var body: some Scene {
        Window("SL 3 Control Panel", id: "main") {
            PanelView(model: model)
        }
        .windowResizability(.contentSize)
    }
}
