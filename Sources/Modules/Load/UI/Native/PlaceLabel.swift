import SwiftUI

/// «📁 kaiten · ~/Projects/kaiten/web»: где запущен процесс. Имя проекта жирнее, путь серым и в подсказке.
/// Из домашней папки — серое «из домашней папки» либо ничего (`showHome: false`).
struct PlaceLabel: View {
    let place: ProcessPlace
    /// В тесных списках «из домашней папки» прячут.
    var showHome = true

    var body: some View {
        if place.isHome {
            if showHome {
                HStack(spacing: 4) {
                    Image(systemName: "folder").imageScale(.small)
                    Text(place.title)
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).help(place.path)
            }
        } else {
            HStack(spacing: 4) {
                Image(systemName: "folder.fill").imageScale(.small).foregroundStyle(.secondary)
                Text(place.project).fontWeight(.semibold)
                Text("· " + place.path).foregroundStyle(.secondary).truncationMode(.middle)
            }
            .font(.caption).lineLimit(1)
            .help(place.path)
        }
    }
}
