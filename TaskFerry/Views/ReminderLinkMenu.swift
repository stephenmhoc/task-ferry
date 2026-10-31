import SwiftUI

/// Also exposes links hidden by the row's line limit, while leaving editor text selectable.
struct ReminderLinkMenu: View {
    let urls: [URL]

    var body: some View {
        if !urls.isEmpty {
            Menu {
                ForEach(urls, id: \.self) { url in
                    Link(url.absoluteString, destination: url)
                }
            } label: {
                Label("Open Link", systemImage: "link")
            }
        }
    }
}
