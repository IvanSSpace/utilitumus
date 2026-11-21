import SwiftUI

/// Экран модуля «Студия»: состояние сервера, папка и страница Студии прямо в окне. Токена экран не видит:
/// у него только адрес с одноразовым кодом, который выдала утилита. Прав и доступа к диску у экрана нет.
struct StudioView<Model: StudioModel>: View {
    @ObservedObject var model: Model
    @State private var folderText = ""
    @State private var folderEdited = false

    init(model: Model) { self.model = model }

    var body: some View {
        DSPage(module: .studio, subtitle: "Локальная панель: включил — запустилась, выключил — остановилась") {
            statusSection
            folderSection
            if model.state.phase == .running, StudioNavigation.loginURL(model.state.page) != nil {
                StudioPageSection(model: model)
            }
        }
        .onAppear { if !folderEdited { folderText = model.state.folder } }
        .onChange(of: model.state.folder) { if !folderEdited { folderText = model.state.folder } }
    }

    private var statusSection: some View {
        let state = model.state
        return DSSection("Сервер") {
            switch state.phase {
            case .running:
                DSRow(icon: "checkmark.circle.fill", title: "Работает",
                      subtitle: state.ownsServer ? "Запущена этим модулем: выключишь модуль — остановится"
                                                 : "Была запущена не здесь: выключишь модуль — продолжит работать")
            case .starting:
                DSRow(icon: "hourglass", title: "Запускается")
            case .stopped:
                DSRow(icon: "pause.circle", title: "Остановлена", subtitle: state.message)
            case .failed:
                DSRow(icon: "exclamationmark.triangle.fill", title: "Ошибка", subtitle: state.message)
            }
        }
    }

    private var folderSection: some View {
        DSSection("Папка Студии") {
            DSRow(icon: "folder", title: "Путь", subtitle: "Абсолютный путь к папке, где лежит файл studio. Пусто — не задана") {
                TextField("", text: $folderText, prompt: Text("/путь/к/папке"))
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 260)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.08)))
                    .onChange(of: folderText) { folderEdited = folderText != model.state.folder }
                    .onSubmit(save)
                DSButton("Сохранить", small: true, action: save)
            }
        }
    }

    private func save() {
        model.setFolder(folderText.trimmingCharacters(in: .whitespacesAndNewlines))
        folderEdited = false
    }
}

/// Страница Студии и кнопки над ней. Создаётся, только пока сервер работает: страница живёт ровно столько же.
private struct StudioPageSection<Model: StudioModel>: View {
    @ObservedObject var model: Model
    @StateObject private var holder = StudioWebHolder()

    var body: some View {
        DSSection("Страница") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    DSButton("Обновить", icon: "arrow.clockwise", small: true) { model.newLogin() }
                    DSButton("Открыть в браузере", icon: "safari", small: true) { model.openInBrowser() }
                }
                StudioWebView(holder: holder)
                    .frame(minHeight: 560)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .padding(10)
        }
        .onAppear { holder.update(model) }
        .onChange(of: model.state) { holder.update(model) }
    }
}
