import SwiftUI
import StoreKit

// MARK: - Paywall sheet

struct PremiumPaywallView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    private var store: StoreService { appState.store }

    private let features: [(icon: String, tint: Color, title: String, body: String)] = [
        ("clock.fill",             .blue,   "Full session history",
         "Access every recording you've ever made, not just the last 10."),
        ("sparkles",               .indigo, "AI Insights",
         "GPT-4o mini summaries, action items, and follow-up suggestions (bring your own API key)."),
        ("list.number",            .purple, "Transcript chapters",
         "Split long recordings into named sections for easy navigation."),
        ("text.magnifyingglass",   .teal,   "Reading mode",
         "Distraction-free reader with adjustable font, line spacing, and progress bar."),
        ("doc.richtext",           .orange, "All export formats",
         "PDF, SRT subtitles, CSV, Markdown, HTML webpages, and Obsidian vault."),
        ("chart.bar.xaxis",        .green,  "Advanced analytics",
         "Language word-volume chart, weekly digest notifications, and peak-hour nudge."),
        ("keyboard.fill",          .pink,   "Keyboard extension",
         "Dictate directly into any app with the system keyboard."),
        ("mic.badge.plus",         .red,    "Siri Shortcuts",
         "Star sessions, set goals, and export transcripts from Siri or the Shortcuts app."),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    heroSection
                    featuresSection
                    pricingSection
                    footerSection
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Lexora Premium")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Maybe later") { dismiss() }
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Sections

    private var heroSection: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.29, green: 0.11, blue: 0.78),
                                     Color(red: 0.56, green: 0.18, blue: 0.82)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 96, height: 96)
                Image(systemName: "crown.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse)
            }

            VStack(spacing: 6) {
                Text("Unlock everything")
                    .font(.title2.bold())
                Text("One payment. No subscription. Yours forever.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.top, 24)
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
    }

    private var featuresSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(features, id: \.title) { feature in
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: feature.icon)
                        .font(.body)
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(feature.tint, in: RoundedRectangle(cornerRadius: 9))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(feature.title)
                            .font(.subheadline.weight(.semibold))
                        Text(feature.body)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 16)
                .background(Color(.secondarySystemGroupedBackground))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 16)
    }

    private var pricingSection: some View {
        VStack(spacing: 12) {
            if let error = store.purchaseError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            // Buy button
            Button {
                Task { await store.purchase() }
            } label: {
                HStack(spacing: 10) {
                    if store.purchaseInProgress {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "crown.fill")
                    }
                    VStack(spacing: 1) {
                        Text(store.premiumProduct.map { "Upgrade for \($0.displayPrice)" } ?? "Upgrade — $4.99")
                            .font(.headline)
                        Text("One-time purchase · No subscription")
                            .font(.caption)
                            .opacity(0.85)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    LinearGradient(
                        colors: [Color(red: 0.29, green: 0.11, blue: 0.78),
                                 Color(red: 0.56, green: 0.18, blue: 0.82)],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)
            .disabled(store.purchaseInProgress || store.premiumProduct == nil)
            .padding(.horizontal, 16)

            // Restore button
            Button {
                Task { await store.restore() }
            } label: {
                Text("Restore purchase")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .disabled(store.purchaseInProgress)
        }
        .padding(.top, 24)
    }

    private var footerSection: some View {
        VStack(spacing: 6) {
            Text("Payment is charged to your Apple ID. The unlock is permanent and applies to all devices signed in with the same Apple ID.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }
}

// MARK: - Premium gate modifier

extension View {
    /// Overlays an upgrade button when the user isn't premium.
    /// On tap it presents the paywall. When premium, shows content as-is.
    func premiumGated(feature: String, isUnlocked: Bool, showPaywall: Binding<Bool>) -> some View {
        modifier(PremiumGateModifier(feature: feature, isUnlocked: isUnlocked, showPaywall: showPaywall))
    }
}

private struct PremiumGateModifier: ViewModifier {
    let feature: String
    let isUnlocked: Bool
    @Binding var showPaywall: Bool

    func body(content: Content) -> some View {
        if isUnlocked {
            content
        } else {
            ZStack {
                content.blur(radius: 4).allowsHitTesting(false)
                Button {
                    showPaywall = true
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "crown.fill")
                            .font(.title2)
                            .foregroundStyle(Color(red: 0.56, green: 0.18, blue: 0.82))
                        Text("Premium feature")
                            .font(.subheadline.weight(.semibold))
                        Text("Unlock \(feature) with Lexora Premium")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(16)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Premium banner (inline, compact)

struct PremiumUpgradeBanner: View {
    @Binding var showPaywall: Bool

    var body: some View {
        Button {
            showPaywall = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "crown.fill")
                    .foregroundStyle(Color(red: 0.56, green: 0.18, blue: 0.82))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Upgrade to Lexora Premium")
                        .font(.subheadline.weight(.semibold))
                    Text("One-time $4.99 · Unlock all features")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(
                LinearGradient(
                    colors: [Color(red: 0.29, green: 0.11, blue: 0.78).opacity(0.08),
                             Color(red: 0.56, green: 0.18, blue: 0.82).opacity(0.08)],
                    startPoint: .leading, endPoint: .trailing
                ),
                in: RoundedRectangle(cornerRadius: 14)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color(red: 0.56, green: 0.18, blue: 0.82).opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
