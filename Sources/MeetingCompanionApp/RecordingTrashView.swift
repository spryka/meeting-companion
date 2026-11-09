import Foundation
import MeetingCompanionApplication
import SwiftUI

struct RecordingTrashPresentation: Identifiable {
    let id = UUID()
    let target: RecordingTrashTarget
    let title: String
    var pending = false
    var error: String?
    var retryAllowed = false
}

struct RecordingTrashCompletion: Equatable {
    let id = UUID()
    let recording: URL
}

struct RecordingTrashOverlay: View {
    @ObservedObject var model: RecorderViewModel
    var body: some View {
        GeometryReader { bounds in
            if let presentation = model.recordingTrash {
                ZStack {
                    Color.black.opacity(0.3).contentShape(Rectangle()).onTapGesture { }.accessibilityHidden(true)
                    ODDialog(title: "Переместить запись «\(presentation.title)» в Корзину?",
                        width: min(560, max(0, bounds.size.width - 32)), close: { model.cancelRecordingTrash() }) {
                        Text("Вся папка встречи, включая аудио, транскрипт и остальные файлы, будет перемещена в Корзину macOS. Восстановить её можно через Finder.")
                            .fixedSize(horizontal: false, vertical: true)
                        Text(presentation.target.folder.path).font(.system(size: 12)).foregroundStyle(ODColors.muted)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        if presentation.pending {
                            Text("Перемещаем в Корзину…").accessibilityLabel("Перемещаем в Корзину…")
                        }
                        if let reason = presentation.error {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Не удалось переместить запись в Корзину").fontWeight(.semibold)
                                Text(reason).textSelection(.enabled)
                            }.foregroundStyle(ODColors.red).fixedSize(horizontal: false, vertical: true)
                        }
                    } actions: {
                        Button("Отмена") { model.cancelRecordingTrash() }.keyboardShortcut(.cancelAction)
                        if presentation.error == nil || presentation.retryAllowed {
                            Button(role: .destructive) {
                                Task { await model.confirmRecordingTrash() }
                            } label: {
                                Text(presentation.error == nil ? "В Корзину" : "Повторить").foregroundStyle(ODColors.red)
                            }
                            .keyboardShortcut(.defaultAction)
                        }
                    }
                    .disabled(presentation.pending)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .accessibilityAddTraits(.isModal)
                    .onExitCommand { model.cancelRecordingTrash() }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
