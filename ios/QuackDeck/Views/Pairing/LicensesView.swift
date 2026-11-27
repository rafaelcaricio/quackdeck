import SwiftUI

enum LegalDocument: String, CaseIterable, Identifiable {
    case apacheLicense
    case notice
    case webrtcLicense
    case thirdPartyNotices

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apacheLicense: return "Apache License 2.0"
        case .notice: return "Pollen Robotics & Trademark Notice"
        case .webrtcLicense: return "WebRTC License (BSD 3-Clause)"
        case .thirdPartyNotices: return "Third-Party Notices"
        }
    }

    var subtitle: String {
        switch self {
        case .apacheLicense: return "QuackDeck & Pollen Robotics Microduck crates"
        case .notice: return "Copyright, attribution, and non-affiliation notice"
        case .webrtcLicense: return "stasel/WebRTC and Google WebRTC"
        case .thirdPartyNotices: return "Complete third-party Rust and iOS notices"
        }
    }

    var resourceName: String {
        switch self {
        case .apacheLicense: return "LICENSE"
        case .notice: return "NOTICE"
        case .webrtcLicense: return "WebRTC-BSD-3-Clause"
        case .thirdPartyNotices: return "THIRD_PARTY_NOTICES"
        }
    }

    var resourceExtension: String? {
        switch self {
        case .apacheLicense, .notice: return nil
        case .webrtcLicense: return "txt"
        case .thirdPartyNotices: return "md"
        }
    }

    func loadText(in bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: resourceName, withExtension: resourceExtension) else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

struct LicensesView: View {
    var body: some View {
        ZStack {
            QuackTheme.inkBg.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("QUACKDECK")
                            .font(QuackTheme.condensedDisplay(size: 13))
                            .foregroundStyle(QuackTheme.duckOrange)
                            .tracking(0.6)

                        Text("Copyright 2026 Rafael Caricio. Licensed under the Apache License, Version 2.0, matching Pollen Robotics' upstream Microduck protocol crates.")
                            .font(.subheadline)
                            .foregroundStyle(QuackTheme.creamText)

                        Text("QuackDeck is an independent, unofficial project and is not affiliated with, endorsed by, or sponsored by Pollen Robotics. \"Pollen Robotics\" and \"Microduck\" are trademarks of Pollen Robotics.")
                            .font(.caption)
                            .foregroundStyle(QuackTheme.creamText.opacity(0.65))
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .quackInsetCard(cornerRadius: 18)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("LICENSES & NOTICES")
                            .font(QuackTheme.condensedDisplay(size: 13))
                            .foregroundStyle(QuackTheme.creamText.opacity(0.65))
                            .tracking(0.6)

                        VStack(spacing: 0) {
                            ForEach(Array(LegalDocument.allCases.enumerated()), id: \.element.id) { idx, doc in
                                NavigationLink {
                                    LegalDocumentDetailView(document: doc)
                                } label: {
                                    HStack(spacing: 12) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(doc.title)
                                                .font(.subheadline.weight(.semibold))
                                                .foregroundStyle(QuackTheme.creamText)
                                            Text(doc.subtitle)
                                                .font(.caption)
                                                .foregroundStyle(QuackTheme.creamText.opacity(0.55))
                                        }
                                        Spacer()
                                        Image(systemName: QuackIcon.chevronRight)
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(QuackTheme.creamText.opacity(0.45))
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 12)
                                    .frame(minHeight: 54)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.quackRow)

                                if idx < LegalDocument.allCases.count - 1 {
                                    Divider().overlay(QuackTheme.subtleBorder)
                                }
                            }
                        }
                        .quackInsetCard(cornerRadius: 18)
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle("Licenses & Notices")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
    }
}

private struct LegalDocumentDetailView: View {
    let document: LegalDocument

    var body: some View {
        ZStack {
            QuackTheme.inkBg.ignoresSafeArea()

            ScrollView {
                Text(document.loadText() ?? "Unable to load \(document.resourceName).")
                    .font(QuackTheme.monoValue(size: 11, weight: .regular))
                    .foregroundStyle(QuackTheme.creamText.opacity(0.88))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(16)
            }
        }
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
    }
}
