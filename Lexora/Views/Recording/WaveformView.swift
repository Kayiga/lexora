import SwiftUI

// Animated waveform bars that react to the microphone signal level in real time.
struct WaveformView: View {
    var signalLevel: Float      // 0–1 normalised amplitude
    var isActive: Bool
    var color: Color = .accentColor

    private let barCount = 28
    @State private var phases: [Double] = []

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<barCount, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: 3, height: barHeight(for: i))
                    .animation(
                        isActive ? .easeInOut(duration: 0.15).repeatForever(autoreverses: true) : .default,
                        value: signalLevel
                    )
            }
        }
        .onAppear {
            phases = (0..<barCount).map { Double($0) * .pi / Double(barCount) }
        }
        .accessibilityHidden(true)    // decorative — VoiceOver sees the transcript instead
    }

    private func barHeight(for index: Int) -> CGFloat {
        guard isActive else { return 4 }
        let base: CGFloat = 4
        let maxExtra: CGFloat = 44
        let signal = CGFloat(signalLevel)
        // Create a wave shape using sine offset per bar
        let wave = sin(Double(index) * .pi / Double(barCount))
        return base + maxExtra * signal * CGFloat(wave)
    }
}

// MARK: - Rolling history waveform

/// A scrolling oscilloscope-style display that records actual signal level
/// history. Shows the last `capacity` samples as a mirrored path, giving
/// genuine audio feedback rather than an animated decoration.
struct RollingWaveformView: View {
    var signalLevel: Float   // 0–1, updated externally every ~50 ms
    var isActive: Bool
    var color: Color = .accentColor

    private let capacity = 60        // number of samples in the rolling window
    @State private var samples: [Float] = []

    var body: some View {
        Canvas { ctx, size in
            guard !samples.isEmpty else { return }
            let w = size.width
            let h = size.height
            let midY = h / 2
            let step = w / CGFloat(capacity - 1)

            // Build a mirrored waveform path (top half + bottom half)
            var path = Path()
            // Top edge (left to right)
            for (i, sample) in samples.enumerated() {
                let x = CGFloat(i) * step
                let amplitude = CGFloat(sample) * midY * 0.92
                let y = midY - amplitude
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else       { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            // Bottom edge (right to left — mirror)
            for (i, sample) in samples.reversed().enumerated() {
                let x = w - CGFloat(i) * step
                let amplitude = CGFloat(sample) * midY * 0.92
                let y = midY + amplitude
                path.addLine(to: CGPoint(x: x, y: y))
            }
            path.closeSubpath()

            // Gradient fill
            let gradient = Gradient(colors: [
                color.opacity(isActive ? 0.35 : 0.12),
                color.opacity(isActive ? 0.12 : 0.04)
            ])
            ctx.fill(
                path,
                with: .linearGradient(gradient,
                                      startPoint: CGPoint(x: 0, y: 0),
                                      endPoint: CGPoint(x: 0, y: h))
            )
            // Stroke top edge only
            var topPath = Path()
            for (i, sample) in samples.enumerated() {
                let x = CGFloat(i) * step
                let amplitude = CGFloat(sample) * midY * 0.92
                let y = midY - amplitude
                if i == 0 { topPath.move(to: CGPoint(x: x, y: y)) }
                else       { topPath.addLine(to: CGPoint(x: x, y: y)) }
            }
            ctx.stroke(topPath,
                       with: .color(color.opacity(isActive ? 0.8 : 0.3)),
                       lineWidth: 1.5)
        }
        .onChange(of: signalLevel) { _, newLevel in
            // Append new sample, drop oldest when full
            samples.append(max(0.02, newLevel))   // floor at 0.02 so flat line shows
            if samples.count > capacity { samples.removeFirst() }
        }
        .onAppear {
            // Seed with silence so the canvas has something to draw immediately
            samples = Array(repeating: 0.02, count: capacity)
        }
        .accessibilityHidden(true)
    }
}

// A minimal pulsing circle indicator used when waveform is collapsed
struct PulseIndicator: View {
    var isActive: Bool
    @State private var scale: CGFloat = 1.0

    var body: some View {
        Circle()
            .fill(isActive ? Color.red : Color.secondary)
            .frame(width: 12, height: 12)
            .scaleEffect(scale)
            .onChange(of: isActive) { _, active in
                if active {
                    withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                        scale = 1.4
                    }
                } else {
                    withAnimation { scale = 1.0 }
                }
            }
    }
}
