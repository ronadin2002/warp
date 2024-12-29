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
                
                Text(measurementManager.messageText)
                    .padding()
                    .background(.ultraThinMaterial)
                    .cornerRadius(8)
                    .padding(.top)
                
                Spacer()
                
                MeasurementInfoView(measurements: measurementManager.measurements)
                    .padding()
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
    @Published var messageText: String = "Tap first corner"
    private var arView: ARView?
    private var measurementAnchors: [AnchorEntity] = []
    private var points: [simd_float3] = []
    
    func setupAR(_ arView: ARView) {
        self.arView = arView
        
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        
        arView.session.run(config)
        arView.session.delegate = self
        
        // Add tap gesture
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        arView.addGestureRecognizer(tapGesture)
    }
    
    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard let arView = arView else { return }
        
        let location = gesture.location(in: arView)
        
        // Perform hit test with real-world surface
        let results = arView.raycast(from: location, allowing: .estimatedPlane, alignment: .any)
        
        if let firstResult = results.first {
            let worldPosition = simd_make_float3(firstResult.worldTransform.columns.3)
            addPoint(at: worldPosition)
        }
    }
    
    private func addPoint(at position: simd_float3) {
        points.append(position)
        addMarker(at: position)
        
        switch points.count {
        case 1:
            messageText = "Tap second corner (width)"
        case 2:
            messageText = "Tap third corner (length)"
            createMeasurementLine(from: points[0], to: points[1])
        case 3:
            messageText = "Tap fourth corner (height)"
            createMeasurementLine(from: points[1], to: points[2])
        case 4:
            createMeasurementLine(from: points[2], to: points[3])
            createMeasurementLine(from: points[3], to: points[0])
            calculateBoxDimensions()
            
            // Reset for next measurement
            points.removeAll()
            messageText = "Tap first corner"
        default:
            break
        }
    }
    
    private func calculateBoxDimensions() {
        guard points.count == 4 else { return }
        
        // Calculate the three edges from the first point
        let edge1 = points[1] - points[0] // First edge (width)
        let edge2 = points[2] - points[1] // Second edge (length)
        let edge3 = points[3] - points[0] // Third edge (height)
        
        // Calculate dimensions
        let width = simd_length(edge1)
        let length = simd_length(edge2)
        let height = simd_length(edge3)
        
        // Convert to inches
        let measurement = Measurement(
            length: Double(metersToInches(length)),
            width: Double(metersToInches(width)),
            height: Double(metersToInches(height))
        )
        
        measurements.append(measurement)
    }
    
    private func metersToInches(_ meters: Float) -> Float {
        return meters * 39.3701 // Convert meters to inches
    }
    
    private func addMarker(at position: simd_float3) {
        guard let arView = arView else { return }
        
        // Create a small sphere to mark the point
        let sphere = ModelEntity(mesh: .generateSphere(radius: 0.01),
                               materials: [SimpleMaterial(color: .blue, isMetallic: true)])
        
        let anchor = AnchorEntity(world: position)
        anchor.addChild(sphere)
        
        arView.scene.addAnchor(anchor)
        measurementAnchors.append(anchor)
    }
    
    private func createMeasurementLine(from start: simd_float3, to end: simd_float3) {
        guard let arView = arView else { return }
        
        let distance = simd_distance(start, end)
        let inches = metersToInches(distance)
        
        // Create line
        let lineMesh = MeshResource.generateBox(size: [distance, 0.002, 0.002])
        var material = SimpleMaterial()
        material.color = .init(tint: .white.withAlphaComponent(0.8))
        let lineEntity = ModelEntity(mesh: lineMesh, materials: [material])
        
        // Position and rotate line
        let midPoint = (start + end) / 2
        let anchor = AnchorEntity(world: midPoint)
        
        // Calculate rotation to point from start to end
        let direction = normalize(end - start)
        let rotation = simd_quatf(from: [1, 0, 0], to: direction)
        lineEntity.orientation = rotation
        
        // Add dimension label
        let dimensionText = String(format: "%.1f\"", inches)
        let textEntity = createMeasurementText(dimensionText)
        textEntity.position = [0, 0.02, 0]
        
        anchor.addChild(lineEntity)
        anchor.addChild(textEntity)
        
        arView.scene.addAnchor(anchor)
        measurementAnchors.append(anchor)
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
        measurementAnchors.forEach { $0.removeFromParent() }
        measurementAnchors.removeAll()
    }
    
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Not needed for manual measurement
    }
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


