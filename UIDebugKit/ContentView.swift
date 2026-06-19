import SwiftUI

@main struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .uiDebugKit()   // ← 1 line attaches the whole debug toolkit
        }
    }
}

struct ContentView: View {
    @State private var notifications = true
    @State private var darkMode = false
    @State private var volume = 0.6
    @State private var search = ""
    @State private var segment = 0

    private let skills = ["Swift", "SwiftUI", "Combine", "UIKit", "Xcode", "CoreData"]
    private let menu: [(icon: String, title: String, tint: Color)] = [
        ("bell.badge", "Notifications", .red),
        ("lock.shield", "Privacy", .blue),
        ("creditcard", "Billing", .green),
        ("questionmark.circle", "Help & Support", .orange),
    ]
    private let stats: [(value: String, label: String)] = [
        ("128", "Posts"), ("4.2k", "Followers"), ("312", "Following"),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    header
                    statsRow
                    actionButtons
                    segmentedControl
                    skillsScroller
                    settingsCard
                    searchField
                    menuList
                    cardsGrid
                }
                .padding(20)
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Image(systemName: "chevron.left")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Image(systemName: "gearshape")
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 88))
                .foregroundStyle(.tint)
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(.green)
                        .frame(width: 22, height: 22)
                        .overlay(Circle().stroke(.background, lineWidth: 3))
                }

            VStack(spacing: 4) {
                Text("Maher Salman").font(.title2.bold())
                Text("Software Engineer").foregroundStyle(.secondary)
                Label("Haifa, Israel", systemImage: "mappin.and.ellipse")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
    }

    // MARK: - Stats

    private var statsRow: some View {
        HStack {
            ForEach(Array(stats.enumerated()), id: \.offset) { index, stat in
                if index > 0 { Divider().frame(height: 32) }
                VStack(spacing: 4) {
                    Text(stat.value).font(.headline)
                    Text(stat.label).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 12)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 16))
    }

    // MARK: - Actions

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button {} label: {
                Text("Follow")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(.tint, in: .rect(cornerRadius: 12))
                    .foregroundStyle(.white)
            }
            Button {} label: {
                Text("Message")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12))
            }
            Button {} label: {
                Image(systemName: "ellipsis")
                    .frame(width: 50, height: 50)
                    .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12))
            }
        }
    }

    // MARK: - Segmented

    private var segmentedControl: some View {
        Picker("Section", selection: $segment) {
            Text("Overview").tag(0)
            Text("Activity").tag(1)
            Text("About").tag(2)
        }
        .pickerStyle(.segmented)
    }

    // MARK: - Skills chips

    private var skillsScroller: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Skills").font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(skills, id: \.self) { skill in
                        Text(skill)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.tint.opacity(0.15), in: .capsule)
                            .foregroundStyle(.tint)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Settings card

    private var settingsCard: some View {
        VStack(spacing: 14) {
            Toggle(isOn: $notifications) {
                Label("Push Notifications", systemImage: "bell.fill")
            }
            Divider()
            Toggle(isOn: $darkMode) {
                Label("Dark Appearance", systemImage: "moon.fill")
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Label("Volume", systemImage: "speaker.wave.2.fill")
                Slider(value: $volume)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 16))
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search", text: $search)
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12))
    }

    // MARK: - Menu list

    private var menuList: some View {
        VStack(spacing: 0) {
            ForEach(Array(menu.enumerated()), id: \.offset) { index, item in
                HStack(spacing: 12) {
                    Image(systemName: item.icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(item.tint, in: .rect(cornerRadius: 8))
                    Text(item.title)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 12)
                if index < menu.count - 1 {
                    Divider().padding(.leading, 44)
                }
            }
        }
        .padding(.horizontal, 16)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 16))
    }

    // MARK: - Cards grid

    private var cardsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            statCard("flame.fill", "Streak", "12 days", .orange)
            statCard("star.fill", "Rating", "4.9 / 5", .yellow)
            statCard("clock.fill", "Hours", "1,204", .blue)
            statCard("checkmark.seal.fill", "Tasks", "87 done", .green)
        }
    }

    private func statCard(_ icon: String, _ title: String, _ value: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
            Text(value).font(.headline)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 14))
    }
}

#Preview {
    ContentView()
        .uiDebugKit()
}
