import SwiftUI

struct LanguageMenu: View {
    let language: AppLanguage
    var onChange: (AppLanguage) -> Void

    var body: some View {
        Menu {
            Picker(Copy.interfaceLanguage(), selection: Binding(
                get: { language },
                set: { onChange($0) }
            )) {
                ForEach(AppLanguage.allCases) { option in
                    Text(option.menuTitle).tag(option)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "globe")
                    .imageScale(.small)
                Text(language.endonym)
                    .font(.caption.weight(.medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12)))
        .foregroundStyle(.secondary)
        .contentShape(Capsule())
        .fixedSize()
        .help(Copy.interfaceLanguage())
    }
}
