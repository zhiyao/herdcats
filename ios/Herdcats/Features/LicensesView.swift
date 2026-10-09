import SwiftUI

struct LicensesView: View {
    private static let notices: String = {
        guard let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "License notices are unavailable in this build."
        }
        return text
    }()

    var body: some View {
        ScrollView {
            Text(verbatim: Self.notices)
                .font(.jost(.footnote))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .background(Theme.listBackground.ignoresSafeArea())
        .navigationTitle("Licenses")
        .navigationBarTitleDisplayMode(.inline)
    }
}
