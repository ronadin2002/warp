//
//  ContentView.swift
//  wrap measure
//
//  Created by Ron Adin on 28/12/2024.
//

import SwiftUI
import ARKit
import RealityKit

struct QuoteResponse: Codable {
    let quote_id: String
    let price: Price
    let charges: [Charge]
    let expiration_time_utc: Int
    let status: String
    let notes: String
    let shipmentType: String
}

struct Price: Codable {
    let amount: Double
    let currency_code: String
}

struct Charge: Codable {
    let code: String
    let description: String
    let amount: Double
}

class QuoteService: ObservableObject {
    @Published var quoteResponse: QuoteResponse?
    @Published var isLoading = false
    @Published var error: (code: Int?, message: String)?
    
    private let apiKey = "8/xYJLWjQYW+uxteE/u1G4URyL58nTmxzoy1WjLpxBPdCEUClGMgO+2n5uJDUoy7ByOXuttq6pZvVHat3abnhLOM/WC98GvGIl0jWNUON5I="
    
    func getQuote(payload: [String: Any]) {
        isLoading = true
        error = nil
        
        guard let url = URL(string: "https://stg.wearewarp.com/api/v1/freights/quote") else {
            error = (nil, "Invalid URL")
            isLoading = false
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            self.error = (nil, "Failed to encode request")
            isLoading = false
            return
        }
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.isLoading = false
                
                if let error = error {
                    self?.error = (nil, error.localizedDescription)
                    return
                }
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    self?.error = (nil, "Invalid response")
                    return
                }
                
                guard let data = data else {
                    self?.error = (httpResponse.statusCode, "No data received")
                    return
                }
                
                // Print response for debugging
                if let responseString = String(data: data, encoding: .utf8) {
                    print("Response: \(responseString)")
                }
                
                if !(200...299).contains(httpResponse.statusCode) {
                    // Try to parse error message from response
                    if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let message = errorJson["message"] as? String {
                        self?.error = (httpResponse.statusCode, message)
                    } else {
                        self?.error = (httpResponse.statusCode, "Error: HTTP \(httpResponse.statusCode)")
                    }
                    return
                }
                
                do {
                    let response = try JSONDecoder().decode(QuoteResponse.self, from: data)
                    self?.quoteResponse = response
                } catch {
                    self?.error = (httpResponse.statusCode, "Failed to decode response: \(error.localizedDescription)")
                }
            }
        }.resume()
    }
}

struct ContentView: View {
    @StateObject private var measurementManager = MeasurementManager()
    @StateObject private var quoteService = QuoteService()
    @State private var showingMeasurement = false
    @State private var pickupDate = Date()
    @State private var pickupZipCode: String = ""
    @State private var deliveryZipCode: String = ""
    @State private var temperatureRange: ClosedRange<Double> = 32...75
    @State private var pallets: [Pallet] = [Pallet()]
    @State private var pickupServices: Set<ServiceType> = [.liftgatePickup]
    @State private var deliveryServices: Set<ServiceType> = [.liftgateDelivery]
    @State private var additionalServices: Set<ServiceType> = [.photoRequired]
    
    // Add these constants for temperature range
    private let minTemp: Double = -20
    private let maxTemp: Double = 120
    
    // Service types available
    enum ServiceType: String, CaseIterable, Identifiable {
        case liftgatePickup = "liftgate-pickup"
        case liftgateDelivery = "liftgate-delivery"
        case photoRequired = "photo-required"
        case insidePickup = "inside-pickup"
        case insideDelivery = "inside-delivery"
        case notification = "notification"
        
        var id: String { self.rawValue }
        
        var displayName: String {
            switch self {
            case .liftgatePickup: return "Liftgate Pickup"
            case .liftgateDelivery: return "Liftgate Delivery"
            case .photoRequired: return "Photo Required"
            case .insidePickup: return "Inside Pickup"
            case .insideDelivery: return "Inside Delivery"
            case .notification: return "Notification"
            }
        }
    }
    
    // Function to prepare API payload
    func prepareAPIPayload() -> [String: Any] {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        
        // Create a single listItem that combines all pallets of the same dimensions
        var consolidatedPallets: [String: (dimensions: [String: Any], count: Int)] = [:]
        
        // Group pallets by their dimensions
        for pallet in pallets {
            let key = "\(Int(pallet.length))x\(Int(pallet.width))x\(Int(pallet.height))x\(Int(Double(pallet.weight) ?? 0))"
            let dimensions: [String: Any] = [
                "height": Int(pallet.height),
                "length": Int(pallet.length),
                "width": Int(pallet.width),
                "sizeUnit": "IN",
                "totalWeight": Int(Double(pallet.weight) ?? 0),
                "weightUnit": "lbs",
                "stackable": false,
                "notes": "Notes here"
            ]
            
            if let existing = consolidatedPallets[key] {
                consolidatedPallets[key] = (dimensions, existing.count + 1)
            } else {
                consolidatedPallets[key] = (dimensions, 1)
            }
        }
        
        // Convert consolidated pallets to listItems
        let listItems = consolidatedPallets.values.map { item -> [String: Any] in
            var dimensions = item.dimensions
            dimensions["quantity"] = item.count
            return dimensions
        }
        
        let payload: [String: Any] = [
            "pickupDate": dateFormatter.string(from: pickupDate),
            "pickupInfo": [
                "zipcode": pickupZipCode
            ],
            "deliveryInfo": [
                "zipcode": deliveryZipCode
            ],
            "pickupServices": pickupServices.map { [
                "quantity": 1,
                "service": $0.rawValue
            ] },
            "deliveryServices": deliveryServices.map { [
                "quantity": 1,
                "service": $0.rawValue
            ] },
            "additionalServices": additionalServices.map { [
                "quantity": 1,
                "service": $0.rawValue
            ] },
            "listItems": listItems
        ]
        
        // Print the payload for debugging
        if let jsonData = try? JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            print("Payload: \(jsonString)")
        }
        
        return payload
    }
    
    var body: some View {
        if showingMeasurement {
            measurementView
        } else {
            landingView
        }
    }
    
    var landingView: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // Logo
                    Image("WARP-Integration")
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 150)
                        .padding(.top, 40)
                    
                    Text("Cargo Measurement")
                        .font(.title)
                        .bold()
                        .foregroundColor(.blue)
                    
                    // Delivery Information Section
                    VStack(alignment: .leading, spacing: 15) {
                        Text("Delivery Information")
                            .font(.headline)
                            .foregroundColor(.blue)
                        
                        DatePicker("Pickup Date",
                                  selection: $pickupDate,
                                  displayedComponents: [.date])
                            .datePickerStyle(.compact)
                        
                        TextField("Pickup ZIP Code", text: $pickupZipCode)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .keyboardType(.numberPad)
                        
                        TextField("Delivery ZIP Code", text: $deliveryZipCode)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .keyboardType(.numberPad)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Temperature Range (°F)")
                                    .font(.subheadline)
                                Spacer()
                                Text("\(Int(temperatureRange.lowerBound))° - \(Int(temperatureRange.upperBound))°")
                                    .font(.subheadline)
                                    .foregroundColor(.gray)
                            }
                            
                            RangeSliderView(value: $temperatureRange, bounds: minTemp...maxTemp)
                                .frame(height: 30)
                        }
                        
                        // Service Options
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Pickup Services")
                                .font(.subheadline)
                            ForEach(ServiceType.allCases.filter { $0.rawValue.contains("pickup") }) { service in
                                Toggle(service.displayName, isOn: Binding(
                                    get: { pickupServices.contains(service) },
                                    set: { isOn in
                                        if isOn {
                                            pickupServices.insert(service)
                                        } else {
                                            pickupServices.remove(service)
                                        }
                                    }
                                ))
                            }
                            
                            Text("Delivery Services")
                                .font(.subheadline)
                                .padding(.top, 8)
                            ForEach(ServiceType.allCases.filter { $0.rawValue.contains("delivery") }) { service in
                                Toggle(service.displayName, isOn: Binding(
                                    get: { deliveryServices.contains(service) },
                                    set: { isOn in
                                        if isOn {
                                            deliveryServices.insert(service)
                                        } else {
                                            deliveryServices.remove(service)
                                        }
                                    }
                                ))
                            }
                            
                            Text("Additional Services")
                                .font(.subheadline)
                                .padding(.top, 8)
                            ForEach(ServiceType.allCases.filter { !$0.rawValue.contains("pickup") && !$0.rawValue.contains("delivery") }) { service in
                                Toggle(service.displayName, isOn: Binding(
                                    get: { additionalServices.contains(service) },
                                    set: { isOn in
                                        if isOn {
                                            additionalServices.insert(service)
                                        } else {
                                            additionalServices.remove(service)
                                        }
                                    }
                                ))
                            }
                        }
                    }
                    .padding()
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(10)
                    
                    // Pallets Section
                    VStack(alignment: .leading, spacing: 15) {
                        Text("Pallets")
                            .font(.headline)
                            .foregroundColor(.blue)
                        
                        ForEach(pallets.indices, id: \.self) { index in
                            PalletView(
                                pallet: $pallets[index],
                                measurementManager: measurementManager,
                                showingMeasurement: $showingMeasurement,
                                palletNumber: index + 1
                            )
                        }
                        
                        Button(action: {
                            pallets.append(Pallet())
                        }) {
                            HStack {
                                Image(systemName: "plus.circle.fill")
                                Text("Add Another Pallet")
                            }
                            .foregroundColor(.blue)
                            .padding(.vertical, 10)
                        }
                    }
                    .padding()
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(10)
                    
                    // Price Quote Section
                    if quoteService.isLoading {
                        ProgressView("Getting quote...")
                            .padding()
                    } else if let error = quoteService.error {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Error")
                                .font(.headline)
                                .foregroundColor(.red)
                            if let code = error.code {
                                Text("Status Code: \(code)")
                                    .font(.subheadline)
                                    .foregroundColor(.red)
                            }
                            Text(error.message)
                                .font(.body)
                                .foregroundColor(.red)
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(10)
                    } else if let quote = quoteService.quoteResponse {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Price Quote")
                                .font(.headline)
                                .foregroundColor(.blue)
                            
                            HStack {
                                Text("Total:")
                                    .font(.title3)
                                Text("$\(String(format: "%.2f", quote.price.amount))")
                                    .font(.title)
                                    .fontWeight(.bold)
                                    .foregroundColor(.blue)
                            }
                            
                            Text(quote.notes)
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                        .padding()
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(10)
                    }
                    
                    // Update Submit Button
                    Button(action: {
                        let payload = prepareAPIPayload()
                        quoteService.getQuote(payload: payload)
                    }) {
                        Text("Get Quote")
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .cornerRadius(10)
                    }
                    .padding(.horizontal)
                    .disabled(quoteService.isLoading)
                    
                    Spacer()
                }
                .padding()
            }
            .navigationBarHidden(true)
        }
    }
    
    var measurementView: some View {
        ZStack {
            ARViewContainer(measurementManager: measurementManager)
                .edgesIgnoringSafeArea(.all)
            
            VStack {
                HStack {
                    Button(action: {
                        showingMeasurement = false
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .foregroundColor(.white)
                            .padding()
                    }
                    
                    Spacer()
                    
                    if !measurementManager.isScanning {
                        Button(action: {
                            if let lastMeasurement = measurementManager.measurements.last,
                               let activePallet = pallets.last {
                                activePallet.length = lastMeasurement.length
                                activePallet.width = lastMeasurement.width
                                activePallet.height = lastMeasurement.height
                            }
                            showingMeasurement = false
                        }) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title)
                                .foregroundColor(.green)
                                .padding()
                        }
                        .opacity(measurementManager.measurements.isEmpty ? 0.5 : 1)
                        .disabled(measurementManager.measurements.isEmpty)
                    }
                }
                
                Text(measurementManager.messageText)
                    .padding()
                    .background(.ultraThinMaterial)
                    .cornerRadius(8)
                    .padding(.top)
                
                if measurementManager.isScanning {
                    ProgressView(value: measurementManager.scanningProgress) {
                        Text("Scanning Progress")
                    }
                    .progressViewStyle(LinearProgressViewStyle())
                    .padding()
                    .background(.ultraThinMaterial)
                    .cornerRadius(8)
                }
                
                Spacer()
                
                if !measurementManager.isScanning {
                    MeasurementInfoView(measurements: measurementManager.measurements)
                        .padding()
                }
                
                if measurementManager.measurements.isEmpty && !measurementManager.isScanning {
                    Button(action: {
                        measurementManager.startScanning()
                    }) {
                        Text("Start Scanning")
                            .foregroundColor(.white)
                            .padding()
                            .background(Color.blue)
                            .cornerRadius(8)
                    }
                    .padding()
                }
            }
        }
    }
}

struct PalletView: View {
    @Binding var pallet: Pallet
    var measurementManager: MeasurementManager
    @Binding var showingMeasurement: Bool
    let palletNumber: Int
    
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Pallet #\(palletNumber)")
                .font(.headline)
            
            TextField("Weight (lb)", text: $pallet.weight)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .keyboardType(.decimalPad)
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Measurements")
                    .font(.subheadline)
                
                HStack(spacing: 15) {
                    DimensionBox(label: "LENGTH", value: pallet.length)
                    DimensionBox(label: "WIDTH", value: pallet.width)
                    DimensionBox(label: "HEIGHT", value: pallet.height)
                }
                
                Button(action: {
                    showingMeasurement = true
                }) {
                    HStack {
                        Spacer()
                        Image(systemName: "ruler")
                            .foregroundColor(.white)
                            .padding(10)
                            .background(Color.blue)
                            .clipShape(Circle())
                    }
                }
            }
        }
        .padding()
        .background(Color.white)
        .cornerRadius(8)
        .shadow(radius: 2)
    }
}

class Pallet: Identifiable, ObservableObject {
    let id = UUID()
    @Published var weight: String = ""
    @Published var length: Double = 0
    @Published var width: Double = 0
    @Published var height: Double = 0
    @Published var notes: String = ""
    @Published var stackable: Bool = false
}

struct ARViewContainer: UIViewRepresentable {
    var measurementManager: MeasurementManager
    
    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        measurementManager.setupAR(arView)
        return arView
    }
    
    func updateUIView(_ uiView: ARView, context: Context) {}
    
    static func dismantleUIView(_ uiView: ARView, coordinator: ()) {
        uiView.session.pause()
    }
}

struct MeasurementInfoView: View {
    let measurements: [Measurement]
    
    var body: some View {
        VStack(spacing: 10) {
            ForEach(measurements) { measurement in
                HStack(spacing: 15) {
                    DimensionBox(label: "LENGTH", value: measurement.length)
                    DimensionBox(label: "WIDTH", value: measurement.width)
                    DimensionBox(label: "HEIGHT", value: measurement.height)
                }
                .padding(.horizontal)
            }
        }
    }
}

struct DimensionBox: View {
    let label: String
    let value: Double
    
    var body: some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.gray)
            
            Text(String(format: "%.1f\"", value))
                .font(.title3)
                .fontWeight(.bold)
                .foregroundColor(.blue)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .cornerRadius(8)
    }
}

class MeasurementManager: NSObject, ObservableObject, ARSessionDelegate {
    @Published var measurements: [Measurement] = []
    @Published var messageText: String = "Move around the object to start scanning"
    @Published var scanningProgress: Float = 0.0
    @Published var isScanning: Bool = false
    @Published var scanningState: ScanningState = .initial
    
    private var arView: ARView?
    private var measurementAnchors: [AnchorEntity] = []
    private var boundingBox: (min: simd_float3, max: simd_float3)?
    private var lastBoundingBox: (min: simd_float3, max: simd_float3)?
    private var stableFrameCount: Int = 0
    private let requiredStableFrames = 30
    private var scanStartTime: Date?
    private let scanTimeout = 30.0
    private var lastUpdateTime: TimeInterval = 0
    private var scannedSides = Set<ScanSide>()
    private var meshVertices: [simd_float3] = []
    private let maxVertices = 10000
    private let stabilityThreshold: Float = 0.01
    
    deinit {
        arView?.session.pause()
    }
    
    enum ScanningState {
        case initial, front, left, right, top, complete
        
        var message: String {
            switch self {
            case .initial: return "Position yourself in front of the object"
            case .front: return "Move to the left side of the object"
            case .left: return "Move to the right side of the object"
            case .right: return "Move above the object"
            case .top: return "Almost done, hold steady..."
            case .complete: return "Scan complete!"
            }
        }
    }
    
    enum ScanSide: String {
        case front, left, right, top
    }
    
    func setupAR(_ arView: ARView) {
        // Pause any existing session
        self.arView?.session.pause()
        
        self.arView = arView
        
        guard ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) else {
            messageText = "This device doesn't support mesh reconstruction"
            return
        }
        
        let config = ARWorldTrackingConfiguration()
        config.sceneReconstruction = .mesh
        config.frameSemantics = [.sceneDepth, .smoothedSceneDepth]
        config.planeDetection = [.horizontal, .vertical]
        
        arView.session.delegate = self
        arView.session.run(config)
        arView.debugOptions = [.showSceneUnderstanding]
        
        startScanning()
    }
    
    func stopSession() {
        arView?.session.pause()
        clearAnchors()
    }
    
    func startScanning() {
        isScanning = true
        scanStartTime = Date()
        scanningState = .initial
        boundingBox = nil
        lastBoundingBox = nil
        stableFrameCount = 0
        scanningProgress = 0.0
        scannedSides.removeAll()
        meshVertices.removeAll()
        measurements.removeAll() // Clear previous measurements
        clearAnchors()
        messageText = "Position yourself in front of the object" // Reset to initial message
        
        // Reset AR session to ensure fresh start
        if let arView = arView {
            let config = ARWorldTrackingConfiguration()
            config.sceneReconstruction = .mesh
            config.frameSemantics = [.sceneDepth, .smoothedSceneDepth]
            config.planeDetection = [.horizontal, .vertical]
            arView.session.run(config, options: [.removeExistingAnchors, .resetTracking])
        }
    }
    
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard isScanning else { return }
        
        // Check for timeout
        if let startTime = scanStartTime, 
           Date().timeIntervalSince(startTime) > scanTimeout {
            DispatchQueue.main.async {
                self.messageText = "Scan timeout. Please try again."
                self.isScanning = false
            }
            return
        }
        
        // Process mesh data
        processMeshData(frame)
        
        // Update scanning state using the camera transform directly
        updateScanningState(frame.camera.transform)
    }
    
    private func processMeshData(_ frame: ARFrame) {
        let meshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        
        // Process mesh vertices
        var newVertices: [simd_float3] = []
        
        // Get camera position for filtering
        let cameraPosition = simd_float3(frame.camera.transform.columns.3.x,
                                       frame.camera.transform.columns.3.y,
                                       frame.camera.transform.columns.3.z)
        
        for anchor in meshAnchors {
            let vertices = anchor.geometry.vertices
            let transform = anchor.transform
            
            // Convert ARGeometrySource to array of points
            let vertexPointer = vertices.buffer.contents()
            let stride = vertices.stride
            let count = vertices.count
            
            for index in 0..<count {
                let vertexOffset = index * stride
                let vertex = vertexPointer.advanced(by: vertexOffset)
                    .assumingMemoryBound(to: SIMD3<Float>.self).pointee
                let worldPosition = simd_mul(transform, simd_float4(vertex, 1)).xyz
                
                // Filter points: only include points within reasonable distance from camera
                let distanceToCamera = distance(worldPosition, cameraPosition)
                if distanceToCamera < 1.5 { // Reduced from 2.0 to 1.5 meters for better accuracy
                    newVertices.append(worldPosition)
                }
            }
        }
        
        // Focus on central cluster of points
        if !newVertices.isEmpty {
            // Calculate center of all points
            let center = newVertices.reduce(simd_float3(0, 0, 0), +) / Float(newVertices.count)
            
            // Filter points close to center (likely part of the main object)
            newVertices = newVertices.filter { point in
                distance(point, center) < 0.3 // Reduced from 0.5 to 0.3 meters for tighter clustering
            }
        }
        
        // Limit the number of vertices for performance
        if newVertices.count > maxVertices {
            let strideValue = newVertices.count / maxVertices
            newVertices = Array(stride(from: 0, to: newVertices.count, by: max(1, strideValue))).map { newVertices[$0] }
        }
        
        meshVertices = newVertices
        
        // Calculate new bounding box
        if !meshVertices.isEmpty {
            calculateBoundingBox()
        }
    }
    
    private func calculateBoundingBox() {
        guard !meshVertices.isEmpty else { return }
        
        // Find the main cluster of points
        let center = meshVertices.reduce(simd_float3(0, 0, 0), +) / Float(meshVertices.count)
        
        // Filter points that are likely part of the main object
        let relevantVertices = meshVertices.filter { vertex in
            distance(vertex, center) < 0.3 // Reduced from 0.5 to 0.3 meters for tighter clustering
        }
        
        guard !relevantVertices.isEmpty else { return }
        
        // Calculate bounds for filtered points
        let minX = relevantVertices.min { $0.x < $1.x }?.x ?? 0
        let minY = relevantVertices.min { $0.y < $1.y }?.y ?? 0
        let minZ = relevantVertices.min { $0.z < $1.z }?.z ?? 0
        let maxX = relevantVertices.max { $0.x < $1.x }?.x ?? 0
        let maxY = relevantVertices.max { $0.y < $1.y }?.y ?? 0
        let maxZ = relevantVertices.max { $0.z < $1.z }?.z ?? 0
        
        let newMin = simd_float3(minX, minY, minZ)
        let newMax = simd_float3(maxX, maxY, maxZ)
        
        // Apply minimum size threshold to avoid tiny measurements
        let minSize: Float = 0.03 // Reduced from 0.05 to 0.03 meters (about 1 inch minimum)
        if (newMax - newMin).x < minSize || (newMax - newMin).y < minSize || (newMax - newMin).z < minSize {
            return
        }
        
        // Check for bounding box stability
        if let lastBox = lastBoundingBox {
            let minDiff = distance(newMin, lastBox.min)
            let maxDiff = distance(newMax, lastBox.max)
            
            if minDiff < stabilityThreshold && maxDiff < stabilityThreshold {
                stableFrameCount += 1
                if stableFrameCount >= requiredStableFrames {
                    completeScan()
                }
            } else {
                stableFrameCount = 0
            }
        }
        
        lastBoundingBox = (newMin, newMax)
        boundingBox = (newMin, newMax)
    }
    
    private func updateScanningState(_ cameraTransform: simd_float4x4) {
        guard let boundingBox = boundingBox else { 
            scanningState = .initial
            messageText = "Position yourself in front of the object"
            return 
        }
        
        let center = (boundingBox.max + boundingBox.min) * 0.5
        let cameraPosition = simd_float3(cameraTransform.columns.3.x,
                                       cameraTransform.columns.3.y,
                                       cameraTransform.columns.3.z)
        let toCamera = normalize(cameraPosition - center)
        
        // Always check sides in the same order
        if !scannedSides.contains(.front) {
            if abs(toCamera.z) > 0.7 {
                scannedSides.insert(.front)
                scanningState = .left
            } else {
                scanningState = .initial
            }
        } else if !scannedSides.contains(.left) {
            if toCamera.x < -0.7 {
                scannedSides.insert(.left)
                scanningState = .right
            }
        } else if !scannedSides.contains(.right) {
            if toCamera.x > 0.7 {
                scannedSides.insert(.right)
                scanningState = .top
            }
        } else if !scannedSides.contains(.top) {
            if toCamera.y > 0.7 {
                scannedSides.insert(.top)
                scanningState = .complete
            }
        }
        
        scanningProgress = Float(scannedSides.count) / 4.0
        messageText = scanningState.message
    }
    
    private func completeScan() {
        guard let boundingBox = boundingBox,
              !measurements.contains(where: { _ in true }) else { return }
        
        let dimensions = boundingBox.max - boundingBox.min
        
        // Ensure correct dimension mapping based on orientation
        let sortedDimensions = [
            dimensions.x,
            dimensions.y,
            dimensions.z
        ].sorted(by: >)
        
        // Map dimensions to length, width, height based on size
        let measurement = Measurement(
            length: Double(metersToInches(sortedDimensions[0])), // Longest dimension
            width: Double(metersToInches(sortedDimensions[1])),  // Second longest
            height: Double(metersToInches(sortedDimensions[2]))  // Shortest (usually height)
        )
        
        DispatchQueue.main.async {
            self.measurements.append(measurement)
            self.isScanning = false
            self.messageText = "Scan complete! Tap checkmark to save measurements."
            self.scanningProgress = 1.0
            self.visualizeBoundingBox(min: boundingBox.min, max: boundingBox.max)
            self.stopSession() // Stop the session after completing the scan
        }
    }
    
    private func visualizeBoundingBox(min: simd_float3, max: simd_float3) {
        guard let arView = arView else { return }
        
        // Create wireframe box
        let dimensions = max - min
        let boxMesh = MeshResource.generateBox(size: dimensions)
        var material = SimpleMaterial()
        material.color = .init(tint: .blue.withAlphaComponent(0.3))
        let boxEntity = ModelEntity(mesh: boxMesh, materials: [material])
        
        // Position at center of bounding box
        let center = (min + max) * 0.5
        let anchor = AnchorEntity(world: center)
        anchor.addChild(boxEntity)
        
        // Add dimension labels
        let inches = simd_float3(
            metersToInches(dimensions.x),
            metersToInches(dimensions.y),
            metersToInches(dimensions.z)
        )
        
        // Add dimension text
        let textEntity = createMeasurementText(
            String(format: "%.1f\" x %.1f\" x %.1f\"",
                  inches.x, inches.y, inches.z)
        )
        textEntity.position = [0, dimensions.y/2 + 0.05, 0]
        anchor.addChild(textEntity)
        
        arView.scene.addAnchor(anchor)
        measurementAnchors.append(anchor)
    }
    
    private func metersToInches(_ meters: Float) -> Float {
        return meters * 39.3701 // Convert meters to inches
    }
    
    private func createMeasurementText(_ text: String) -> ModelEntity {
        var material = SimpleMaterial()
        material.color = .init(tint: .white)
        
        let textMesh = MeshResource.generateText(
            text,
            extrusionDepth: 0.001,
            font: .systemFont(ofSize: 0.04),
            containerFrame: .zero,
            alignment: .center,
            lineBreakMode: .byTruncatingTail
        )
        
        return ModelEntity(mesh: textMesh, materials: [material])
    }
    
    private func clearAnchors() {
        for anchor in measurementAnchors {
            anchor.removeFromParent()
        }
        measurementAnchors.removeAll()
    }
}

private extension simd_float4 {
    var xyz: simd_float3 {
        return simd_float3(x, y, z)
    }
}

private func distance(_ a: simd_float3, _ b: simd_float3) -> Float {
    let diff = a - b
    return sqrt(diff.x * diff.x + diff.y * diff.y + diff.z * diff.z)
}

struct Measurement: Identifiable {
    let id = UUID()
    let length: Double
    let width: Double
    let height: Double
}

// Helper function to normalize a vector
private func normalize(_ vector: simd_float3) -> simd_float3 {
    let length = sqrt(vector.x * vector.x + vector.y * vector.y + vector.z * vector.z)
    return vector / length
}

struct RangeSliderView: View {
    @Binding var value: ClosedRange<Double>
    let bounds: ClosedRange<Double>
    
    @State private var isDraggingMin = false
    @State private var isDraggingMax = false
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Track
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.gray.opacity(0.2))
                    .frame(height: 4)
                
                // Selected Range
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.blue)
                    .frame(width: CGFloat((value.upperBound - value.lowerBound) / (bounds.upperBound - bounds.lowerBound)) * geometry.size.width,
                           height: 4)
                    .offset(x: CGFloat((value.lowerBound - bounds.lowerBound) / (bounds.upperBound - bounds.lowerBound)) * geometry.size.width)
                
                // Minimum Thumb
                Circle()
                    .fill(Color.white)
                    .shadow(radius: 2)
                    .frame(width: 24, height: 24)
                    .offset(x: CGFloat((value.lowerBound - bounds.lowerBound) / (bounds.upperBound - bounds.lowerBound)) * geometry.size.width - 12)
                    .gesture(
                        DragGesture()
                            .onChanged { gesture in
                                isDraggingMin = true
                                let newValue = bounds.lowerBound + Double(gesture.location.x / geometry.size.width) * (bounds.upperBound - bounds.lowerBound)
                                value = max(min(newValue, value.upperBound - 1), bounds.lowerBound)...value.upperBound
                            }
                            .onEnded { _ in
                                isDraggingMin = false
                            }
                    )
                
                // Maximum Thumb
                Circle()
                    .fill(Color.white)
                    .shadow(radius: 2)
                    .frame(width: 24, height: 24)
                    .offset(x: CGFloat((value.upperBound - bounds.lowerBound) / (bounds.upperBound - bounds.lowerBound)) * geometry.size.width - 12)
                    .gesture(
                        DragGesture()
                            .onChanged { gesture in
                                isDraggingMax = true
                                let newValue = bounds.lowerBound + Double(gesture.location.x / geometry.size.width) * (bounds.upperBound - bounds.lowerBound)
                                value = value.lowerBound...min(max(newValue, value.lowerBound + 1), bounds.upperBound)
                            }
                            .onEnded { _ in
                                isDraggingMax = false
                            }
                    )
            }
        }
    }
}

#Preview {
    ContentView()
}


