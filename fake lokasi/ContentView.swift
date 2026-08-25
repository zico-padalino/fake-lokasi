//
//  ContentView.swift
//  fake lokasi
//
//  Created by Mac on 25/08/26.
//

import SwiftUI
import MapKit
import Foundation

final class GPSLocationSpoofingService: ObservableObject {
    @Published var isSpoofing = false
    @Published var isDeviceConnected = false
    @Published var statusMessage = "Checking connection..."

    private var spoofToolPath: String {
        resolveExistingToolPath([
            "/opt/homebrew/bin/idevicesetlocation",
            "/usr/local/bin/idevicesetlocation",
            "/opt/homebrew/bin/idevicesimulatelocation",
            "/usr/local/bin/idevicesimulatelocation"
        ]) ?? "/opt/homebrew/bin/idevicesetlocation"
    }

    private var deviceCheckToolPath: String {
        resolveExistingToolPath([
            "/opt/homebrew/bin/idevice_id",
            "/usr/local/bin/idevice_id"
        ]) ?? "/usr/local/bin/idevice_id"
    }

    private var keepAliveTimer: Timer?
    private var lastLatitude: Double = 0
    private var lastLongitude: Double = 0

    private func resolveExistingToolPath(_ candidates: [String]) -> String? {
        candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    private func runTool(arguments: [String]) -> (exitCode: Int32, output: String, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: spoofToolPath)
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

            let output = String(data: outputData, encoding: .utf8) ?? ""
            let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
            return (process.terminationStatus, output, errorOutput)
        } catch {
            return (-1, "", "Command failed: \(error.localizedDescription)")
        }
    }

    private func runShellCommand(_ command: String) -> (exitCode: Int32, output: String, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

            let output = String(data: outputData, encoding: .utf8) ?? ""
            let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
            return (process.terminationStatus, output, errorOutput)
        } catch {
            return (-1, "", "Command failed: \(error.localizedDescription)")
        }
    }

    func checkDeviceConnection() {
        let toolExists = FileManager.default.fileExists(atPath: deviceCheckToolPath)

        if !toolExists {
            isDeviceConnected = false
            statusMessage = "Device tool not installed: idevice_id"
            return
        }

        let result = runShellCommand("\"\(deviceCheckToolPath)\" -l 2>&1")
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let errorOutput = result.error.trimmingCharacters(in: .whitespacesAndNewlines)

        let connected = result.exitCode == 0 && !output.isEmpty
        isDeviceConnected = connected
        statusMessage = connected ? "iPhone connected" : "iPhone not connected"

        if !connected && !errorOutput.isEmpty {
            statusMessage = errorOutput
        }

        if !connected {
            isSpoofing = false
            stopKeepAliveTimer()
        }
    }

    private func currentDeviceUDID() -> String? {
        let result = runShellCommand("\"\(deviceCheckToolPath)\" -l 2>&1")
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return output.split(whereSeparator: \.isNewline).first.map(String.init)
    }

    @discardableResult
    func startLocationSpoofing(lat: Double, lon: Double) -> Bool {
        let toolExists = FileManager.default.fileExists(atPath: spoofToolPath)

        if !toolExists {
            statusMessage = "Tool not found: idevicesetlocation / idevicesimulatelocation"
            isSpoofing = false
            stopKeepAliveTimer()
            return false
        }

        checkDeviceConnection()
        guard isDeviceConnected else {
            statusMessage = "Cannot spoof: iPhone not connected"
            isSpoofing = false
            stopKeepAliveTimer()
            return false
        }

        guard let udid = currentDeviceUDID() else {
            statusMessage = "Unable to read connected device UDID"
            isSpoofing = false
            stopKeepAliveTimer()
            return false
        }

        lastLatitude = lat
        lastLongitude = lon

        let result = runTool(arguments: ["-u", udid, "--", String(format: "%.6f", lat), String(format: "%.6f", lon)])

        let success = result.exitCode == 0
        isSpoofing = success
        statusMessage = success ? "Spoofing active" : (result.error.isEmpty ? result.output : result.error)

        if success {
            startKeepAliveTimer()
        } else {
            stopKeepAliveTimer()
        }

        return success
    }

    func stopLocationSpoofing() {
        stopKeepAliveTimer()

        let toolExists = FileManager.default.fileExists(atPath: spoofToolPath)

        if !toolExists {
            statusMessage = "Tool not found: idevicesetlocation / idevicesimulatelocation"
            isSpoofing = false
            return
        }

        guard let udid = currentDeviceUDID() else {
            statusMessage = "Unable to read connected device UDID"
            isSpoofing = false
            return
        }

        let result = runTool(arguments: ["-u", udid, "--", "reset"])
        isSpoofing = false
        statusMessage = result.exitCode == 0 ? "Spoofing stopped" : (result.error.isEmpty ? result.output : result.error)

        checkDeviceConnection()
    }

    private func startKeepAliveTimer() {
        stopKeepAliveTimer()
        keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.isSpoofing {
                _ = self.startLocationSpoofing(lat: self.lastLatitude, lon: self.lastLongitude)
            }
        }
    }

    private func stopKeepAliveTimer() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
    }
}

struct ContentView: View {
    @StateObject private var spoofingService = GPSLocationSpoofingService()
    @State private var selectedCoordinate = CLLocationCoordinate2D(latitude: -6.2088, longitude: 106.8456)
    @State private var latitudeText = "-6.208800"
    @State private var longitudeText = "106.845600"
    @State private var searchText = ""
    @State private var searchMessage = ""
    @State private var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: -6.2088, longitude: 106.8456),
            latitudinalMeters: 1000,
            longitudinalMeters: 1000
        )
    )

    private func updateSelectedCoordinate(_ coordinate: CLLocationCoordinate2D) {
        selectedCoordinate = coordinate
        latitudeText = String(format: "%.6f", coordinate.latitude)
        longitudeText = String(format: "%.6f", coordinate.longitude)
        cameraPosition = .region(
            MKCoordinateRegion(
                center: coordinate,
                latitudinalMeters: 1000,
                longitudinalMeters: 1000
            )
        )
    }

    private func performSearch() {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchMessage = "Masukkan nama tempat"
            return
        }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmed
        request.region = MKCoordinateRegion(
            center: selectedCoordinate,
            span: MKCoordinateSpan(latitudeDelta: 1.0, longitudeDelta: 1.0)
        )

        let search = MKLocalSearch(request: request)
        search.start { response, error in
            guard let mapItems = response?.mapItems, let first = mapItems.first else {
                DispatchQueue.main.async {
                    searchMessage = error?.localizedDescription ?? "Tempat tidak ditemukan"
                }
                return
            }

            DispatchQueue.main.async {
                updateSelectedCoordinate(first.placemark.coordinate)
                searchMessage = "Ditemukan: \(first.name ?? trimmed)"
            }
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("GPS Location Spoofer")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()

                let deviceColor: Color = spoofingService.isDeviceConnected ? .green : .orange
                let deviceLabel = spoofingService.isDeviceConnected ? "Connected" : "Disconnected"

                Text(deviceLabel)
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .foregroundStyle(.white)
                    .background(deviceColor)
                    .clipShape(Capsule())

                Text(spoofingService.isSpoofing ? "Active" : "Idle")
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .foregroundStyle(.white)
                    .background(spoofingService.isSpoofing ? Color.green : Color.gray)
                    .clipShape(Capsule())
            }
            .padding(.horizontal)

            HStack {
                Image(systemName: spoofingService.isDeviceConnected ? "checkmark.shield.fill" : "xmark.shield.fill")
                    .foregroundStyle(spoofingService.isDeviceConnected ? .green : .orange)
                Text(spoofingService.statusMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal)

            HStack {
                TextField("Cari tempat / kota / alamat...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        performSearch()
                    }

                Button(action: performSearch) {
                    Image(systemName: "magnifyingglass")
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(width: 44)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)

            if !searchMessage.isEmpty {
                Text(searchMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }

            MapReader { proxy in
                Map(position: $cameraPosition) {
                    Annotation("Selected", coordinate: selectedCoordinate) {
                        ZStack {
                            Circle()
                                .fill(Color.blue)
                                .frame(width: 16, height: 16)
                            Circle()
                                .fill(Color.white)
                                .frame(width: 8, height: 8)
                        }
                    }
                }
                .frame(height: 380)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .onTapGesture { position in
                    if let coordinate = proxy.convert(position, from: .local) {
                        updateSelectedCoordinate(coordinate)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Selected coordinate")
                    .font(.headline)

                TextField("Latitude", text: $latitudeText)
                    .textFieldStyle(.roundedBorder)
                    .disabled(true)

                TextField("Longitude", text: $longitudeText)
                    .textFieldStyle(.roundedBorder)
                    .disabled(true)
            }
            .padding(.horizontal)

            HStack(spacing: 14) {
                Button(action: {
                    let lat = Double(latitudeText) ?? selectedCoordinate.latitude
                    let lon = Double(longitudeText) ?? selectedCoordinate.longitude
                    _ = spoofingService.startLocationSpoofing(lat: lat, lon: lon)
                }) {
                    Text("Start Spoofing")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .background(spoofingService.isDeviceConnected ? Color.green : Color.gray)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(!spoofingService.isDeviceConnected)

                Button(action: {
                    spoofingService.stopLocationSpoofing()
                }) {
                    Text("Stop Spoofing")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .background(Color.red)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(.horizontal)

            Spacer()
        }
        .padding(.vertical)
        .frame(minWidth: 720, minHeight: 700)
        .onAppear {
            spoofingService.checkDeviceConnection()
        }
    }
}

#Preview {
    ContentView()
}
