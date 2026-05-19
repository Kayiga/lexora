// AppStoreScreenshots.swift
// Render-only file — excluded from release builds via conditional compilation.
// Usage: open in Xcode, set scheme to any simulator, run Canvas previews,
//        then use "Export as Image" (⌘⌃C) to save at 430×932 pt (6.9" iPhone).
//
// To include ONLY in debug: add this file to a "Screenshots" target or wrap in #if DEBUG.

#if DEBUG
import SwiftUI

// MARK: - Shared chrome helpers

private let brandPurple = Color(red: 0.29, green: 0.11, blue: 0.78)
private let brandMid    = Color(red: 0.56, green: 0.18, blue: 0.82)
private let brandBlue   = Color(red: 0.22, green: 0.49, blue: 0.98)

private struct ScreenshotFrame<Content: View>: View {
    var headline: String
    var subhead: String
    var gradient: [Color] = [brandPurple, brandMid]
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Caption strip
                VStack(spacing: 6) {
                    Text(headline)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                    Text(subhead)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 72)
                .padding(.horizontal, 28)
                .padding(.bottom, 28)

                // App chrome — simulated iPhone screen
                ZStack {
                    RoundedRectangle(cornerRadius: 44)
                        .fill(Color(.systemBackground))
                        .shadow(color: .black.opacity(0.25), radius: 30, y: 10)

                    content()
                        .clipShape(RoundedRectangle(cornerRadius: 44))
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 40)

                Spacer(minLength: 0)

                // Lexora wordmark
                HStack(spacing: 6) {
                    Image(systemName: "waveform.and.person.filled")
                        .font(.headline)
                    Text("Lexora")
                        .font(.system(size: 18, weight: .semibold))
                }
                .foregroundStyle(.white.opacity(0.9))
                .padding(.bottom, 32)
            }
        }
        .frame(width: 393, height: 852)   // 6.7" logical size (6.9" physical)
    }
}

// MARK: - Screenshot 1: Dashboard / Home

private struct Screenshot1_Dashboard: View {
    var body: some View {
        ScreenshotFrame(
            headline: "Your voice, captured perfectly",
            subhead: "Dashboard at a glance — goals, streak, and more"
        ) {
            VStack(spacing: 0) {
                // Fake nav bar
                fakeNavBar("Lexora")

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Greeting header
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Good morning, Alex 👋")
                                    .font(.title2.bold())
                                Text("You're on a 14-day streak 🔥")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Circle()
                                .fill(brandPurple)
                                .frame(width: 44, height: 44)
                                .overlay(
                                    Text("A")
                                        .font(.title3.bold())
                                        .foregroundStyle(.white)
                                )
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)

                        // Goal ring card
                        HStack(spacing: 16) {
                            ZStack {
                                Circle()
                                    .stroke(Color(.systemGray5), lineWidth: 10)
                                    .frame(width: 72, height: 72)
                                Circle()
                                    .trim(from: 0, to: 0.72)
                                    .stroke(brandPurple, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                                    .frame(width: 72, height: 72)
                                    .rotationEffect(.degrees(-90))
                                Text("72%")
                                    .font(.caption.bold())
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Daily goal")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("360 / 500 words")
                                    .font(.subheadline.bold())
                                Text("Keep going! 140 to go.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(16)
                        .background { RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)) }
                        .padding(.horizontal, 16)

                        // Stats grid
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                            statCard("Today", "3", "sessions", icon: "mic.fill", color: .blue)
                            statCard("Words", "360", "dictated today", icon: "text.word.spacing", color: .purple)
                            statCard("Accuracy", "94%", "avg confidence", icon: "checkmark.seal.fill", color: .green)
                            statCard("Pace", "128", "words / min", icon: "speedometer", color: .orange)
                        }
                        .padding(.horizontal, 16)

                        // Recent sessions
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Recent").font(.headline).padding(.horizontal, 16)
                            ForEach(demoSessions.prefix(3), id: \.title) { s in
                                fakeSessionRow(s)
                            }
                        }
                    }
                    .padding(.bottom, 20)
                }
            }
            .background(Color(.systemGroupedBackground))
        }
    }

    private func statCard(_ title: String, _ value: String, _ sub: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(color)
            Text(value)
                .font(.title2.bold())
                .monospacedDigit()
            Text(sub)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground)) }
    }
}

// MARK: - Screenshot 2: Recording in progress

private let waveHeights: [Double] = [0.3, 0.7, 0.5, 1.0, 0.6, 0.8, 0.4, 0.9, 0.5, 0.75, 0.3, 0.6, 1.0, 0.45, 0.7]

private struct Screenshot2_Recording: View {
    var body: some View {
        ScreenshotFrame(
            headline: "Dictate naturally, in any language",
            subhead: "Real-time transcription with live confidence scoring",
            gradient: [Color(red: 0.0, green: 0.25, blue: 0.65), brandBlue]
        ) {
            VStack(spacing: 0) {
                fakeNavBar("Recording")
                VStack(spacing: 20) {
                    Spacer()
                    // Waveform visualiser
                    HStack(spacing: 4) {
                        ForEach(waveHeights, id: \.self) { h in
                            waveBar(h)
                        }
                    }
                    .frame(height: 80)

                    // Live transcript preview
                    Text("The quick adoption of AI tools in creative workflows has transformed the way designers think about iteration cycles, enabling faster prototyping and more confident decision-making…")
                        .font(.system(size: 15))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .lineSpacing(4)
                        .padding(16)
                        .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 14))
                        .padding(.horizontal, 16)

                    // Stats row
                    HStack(spacing: 24) {
                        Label("2:14", systemImage: "timer")
                        Label("247 words", systemImage: "text.word.spacing")
                        Label("English", systemImage: "globe")
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                    Spacer()

                    // Record button
                    ZStack {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 80, height: 80)
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.white)
                            .frame(width: 28, height: 28)
                    }
                    .shadow(color: .red.opacity(0.4), radius: 16, y: 6)

                    Spacer()
                }
            }
            .background(Color(.systemBackground))
        }
    }

    private func waveBar(_ h: Double) -> some View {
        let waveGrad = LinearGradient(colors: [brandBlue, brandPurple], startPoint: .bottom, endPoint: .top)
        return Capsule()
            .fill(waveGrad)
            .frame(width: 5, height: max(8, h * 72))
    }
}

// MARK: - Screenshot 3: Session detail / AI Insights

private struct Screenshot3_AIInsights: View {
    var body: some View {
        ScreenshotFrame(
            headline: "AI-powered insights, on your terms",
            subhead: "Summaries, action items & follow-ups — your key, your data",
            gradient: [Color(red: 0.18, green: 0.05, blue: 0.55), brandPurple]
        ) {
            VStack(spacing: 0) {
                fakeNavBar("Morning brainstorm")
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        // Summary card (extractive)
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Auto-summary", systemImage: "sparkles")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(brandPurple)
                            Text("The discussion covered AI adoption in creative workflows, emphasising faster prototyping and confident decision-making through iterative design loops.")
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                        }
                        .padding(14)
                        .background { RoundedRectangle(cornerRadius: 12).fill(brandPurple.opacity(0.08)) }
                        .padding(.horizontal, 16)

                        // AI panel
                        VStack(alignment: .leading, spacing: 0) {
                            HStack {
                                Label("AI Insights", systemImage: "sparkles")
                                    .font(.headline)
                                Spacer()
                                Image(systemName: "chevron.up").font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(14)
                            Divider().padding(.horizontal, 14)
                            VStack(alignment: .leading, spacing: 12) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Label("Summary", systemImage: "text.quote")
                                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    Text("AI adoption is reshaping creative iteration; faster prototyping enables more confident design decisions and shorter feedback loops.")
                                        .font(.caption)
                                }
                                VStack(alignment: .leading, spacing: 6) {
                                    Label("Action Items", systemImage: "checklist")
                                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    ForEach(["Research top AI design tools", "Schedule prototype review session", "Write up findings for the team"], id: \.self) { item in
                                        HStack(alignment: .top, spacing: 6) {
                                            Image(systemName: "circle").font(.system(size: 8)).foregroundStyle(brandBlue).padding(.top, 2)
                                            Text(item).font(.caption)
                                        }
                                    }
                                }
                            }
                            .padding(14)
                        }
                        .background {
                            RoundedRectangle(cornerRadius: 14).fill(
                                LinearGradient(colors: [brandPurple.opacity(0.07), brandBlue.opacity(0.07)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing)
                            )
                        }
                        .padding(.horizontal, 16)
                    }
                    .padding(.top, 12)
                }
            }
            .background(Color(.systemBackground))
        }
    }
}

// MARK: - Screenshot 4: Analytics

private struct Screenshot4_Analytics: View {
    var body: some View {
        ScreenshotFrame(
            headline: "Track your growth over time",
            subhead: "Word volume, accuracy, languages, and streaks at a glance",
            gradient: [Color(red: 0.0, green: 0.38, blue: 0.30), Color(red: 0.05, green: 0.58, blue: 0.45)]
        ) {
            VStack(spacing: 0) {
                fakeNavBar("Analytics")

                ScrollView {
                    VStack(spacing: 14) {
                        // KPI row
                        HStack(spacing: 12) {
                            kpiCard("12,450", "words this week", color: brandPurple)
                            kpiCard("94%", "avg accuracy", color: .green)
                            kpiCard("23", "sessions", color: brandBlue)
                        }
                        .padding(.horizontal, 16)

                        // Mini heatmap
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Activity")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 16)
                            HStack(spacing: 3) {
                                ForEach(heatmapWeeks, id: \.self) { week in
                                    VStack(spacing: 3) {
                                        ForEach(week, id: \.self) { val in
                                            RoundedRectangle(cornerRadius: 2)
                                                .fill(heatColor(val))
                                                .frame(width: 22, height: 22)
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                        }

                        // Language bar chart
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Words by language")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 16)
                            VStack(spacing: 6) {
                                langBar("English", 0.72, "8.9k words", color: brandBlue)
                                langBar("Spanish", 0.45, "5.6k words", color: .orange)
                                langBar("French", 0.18, "2.2k words", color: .red)
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                    .padding(.top, 12)
                    .padding(.bottom, 20)
                }
            }
            .background(Color(.systemBackground))
        }
    }

    // Static heatmap data (12 weeks × 7 days, values 0–10)
    private let heatmapWeeks: [[Int]] = [
        [0,3,7,5,9,2,6], [8,4,1,9,6,3,7], [2,6,8,0,4,9,5],
        [7,1,5,8,3,6,2], [9,5,2,7,1,8,4], [3,7,9,2,5,1,8],
        [6,2,4,8,7,3,9], [1,8,6,3,9,5,2], [5,3,9,6,2,7,4],
        [8,6,1,4,8,2,7], [2,9,5,7,3,8,1], [7,4,8,1,6,9,3],
    ]
    private func heatColor(_ val: Int) -> Color {
        val > 1 ? brandPurple.opacity(0.2 + Double(val) * 0.08) : Color(.systemGray5)
    }

    private func kpiCard(_ value: String, _ label: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.title3.bold().monospacedDigit()).foregroundStyle(color)
            Text(label).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background { RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemGroupedBackground)) }
    }

    private func langBar(_ name: String, _ fraction: Double, _ words: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Text(name).font(.caption).frame(width: 60, alignment: .leading)
            GeometryReader { g in
                RoundedRectangle(cornerRadius: 3)
                    .fill(color.opacity(0.25 + fraction * 0.75))
                    .frame(width: g.size.width * fraction)
            }
            .frame(height: 16)
            Text(words).font(.caption2.monospacedDigit()).foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
        }
    }
}

// MARK: - Screenshot 5: Paywall / Premium

private struct PremiumFeature: Identifiable {
    let id: String
    let icon: String
    let tint: Color
    let title: String
}

private let premiumFeatures: [PremiumFeature] = [
    PremiumFeature(id: "1", icon: "clock.fill",           tint: .blue,   title: "Full session history"),
    PremiumFeature(id: "2", icon: "sparkles",             tint: .indigo, title: "AI Insights"),
    PremiumFeature(id: "3", icon: "list.number",          tint: .purple, title: "Transcript chapters"),
    PremiumFeature(id: "4", icon: "text.magnifyingglass", tint: .teal,   title: "Reading mode"),
    PremiumFeature(id: "5", icon: "doc.richtext",         tint: .orange, title: "All export formats"),
    PremiumFeature(id: "6", icon: "keyboard.fill",        tint: .pink,   title: "Keyboard extension"),
]

private struct Screenshot5_Premium: View {
    var body: some View {
        ScreenshotFrame(
            headline: "Everything, unlocked forever",
            subhead: "One-time purchase — no subscription, ever",
            gradient: [Color(red: 0.45, green: 0.10, blue: 0.65), brandMid]
        ) {
            VStack(spacing: 0) {
                fakeNavBar("Lexora Premium")
                ScrollView {
                    VStack(spacing: 16) {
                        crownIcon
                        featureList
                        ctaButton
                    }
                    .padding(.bottom, 20)
                }
            }
            .background(Color(.systemGroupedBackground))
        }
    }

    private var crownIcon: some View {
        Image(systemName: "crown.fill")
            .font(.system(size: 52))
            .foregroundStyle(.white)
            .frame(width: 88, height: 88)
            .background {
                Circle().fill(
                    LinearGradient(colors: [brandPurple, brandMid],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
            }
            .padding(.top, 8)
    }

    private var featureList: some View {
        VStack(spacing: 8) {
            ForEach(premiumFeatures) { f in
                premiumRow(f)
            }
        }
        .padding(.horizontal, 16)
    }

    private func premiumRow(_ f: PremiumFeature) -> some View {
        HStack(spacing: 12) {
            Image(systemName: f.icon)
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background { RoundedRectangle(cornerRadius: 8).fill(f.tint) }
            Text(f.title)
                .font(.subheadline.weight(.medium))
            Spacer()
            Image(systemName: "checkmark")
                .foregroundStyle(.green)
                .font(.caption.weight(.bold))
        }
        .padding(10)
        .background { RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemGroupedBackground)) }
    }

    private var ctaButton: some View {
        Text("Upgrade for $4.99")
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                LinearGradient(colors: [brandPurple, brandMid], startPoint: .leading, endPoint: .trailing)
            )
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 16)
    }
}

// MARK: - Demo data & chrome helpers

private struct DemoSession { var title: String; var words: Int; var lang: String; var dur: String }

private let demoSessions: [DemoSession] = [
    DemoSession(title: "Morning brainstorm", words: 520, lang: "English", dur: "4m 12s"),
    DemoSession(title: "Weekly team update", words: 340, lang: "English", dur: "2m 55s"),
    DemoSession(title: "Notas del proyecto",  words: 275, lang: "Spanish", dur: "2m 10s"),
]

private func fakeNavBar(_ title: String) -> some View {
    HStack {
        Text(title)
            .font(.headline)
            .frame(maxWidth: .infinity)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .background(Color(.systemBackground))
    .overlay(alignment: .bottom) { Divider() }
}

private func fakeSessionRow(_ s: DemoSession) -> some View {
    HStack(spacing: 12) {
        RoundedRectangle(cornerRadius: 8)
            .fill(brandPurple.opacity(0.15))
            .frame(width: 36, height: 36)
            .overlay(Image(systemName: "mic.fill").font(.caption).foregroundStyle(brandPurple))
        VStack(alignment: .leading, spacing: 2) {
            Text(s.title).font(.subheadline.weight(.semibold))
            Text("\(s.words) words · \(s.lang) · \(s.dur)")
                .font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 6)
}

// MARK: - Previews

#Preview("Screenshot 1 – Dashboard") {
    Screenshot1_Dashboard()
}

#Preview("Screenshot 2 – Recording") {
    Screenshot2_Recording()
}

#Preview("Screenshot 3 – AI Insights") {
    Screenshot3_AIInsights()
}

#Preview("Screenshot 4 – Analytics") {
    Screenshot4_Analytics()
}

#Preview("Screenshot 5 – Premium") {
    Screenshot5_Premium()
}
#endif
