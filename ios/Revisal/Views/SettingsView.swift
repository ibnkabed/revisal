import SwiftUI
import UniformTypeIdentifiers

/// AI providers (a key pasted once, used by المناهج only), the review options, backup, about.
struct SettingsView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var ai: AIClient
    @State private var keys: [String: String] = [:]
    @State private var linking: String?
    @State private var aiMessage: [String: String] = [:]
    @State private var shared: SharedFile?
    @State private var restoring = false
    @State private var backupMessage: String?
    @State private var confirmRestore: URL?

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(AIProviders.all, id: \.id) { p in
                        provider(p)
                    }
                } header: {
                    Text("الذكاء الاصطناعي")
                } footer: {
                    Text("يكتب أسئلة المناهج من كتابك، أما التحصيلي والقدرات فلا يحتاجانه. افتح صفحة المفتاح، وأنشئ مفتاحًا مجانيًا، ثم الصقه هنا. يكفي واحد، وربط اثنين يجعل الثاني يراجع إجابات الأول وشرحه. والمفاتيح تبقى في هذا الجوال.")
                }

                Section {
                    Toggle("الشرح بعد كل إجابة", isOn: Binding(get: { store.db.settings.explainEach },
                                                              set: { v in var s = store.db.settings; s.explainEach = v; store.updateSettings(s) }))
                } header: {
                    Text("المراجعة")
                } footer: {
                    Text("يظهر بعد كل اختيار هل أصبت، ولماذا الإجابة الصحيحة صحيحة. وإن أطفأته ظهر الشرح كله في النتيجة.")
                }

                Section {
                    Button {
                        do {
                            shared = SharedFile(url: try store.exportBackup())
                        } catch {
                            backupMessage = error.localizedDescription
                        }
                    } label: {
                        Label("انسخ بياناتك احتياطًا", systemImage: "externaldrive.badge.icloud")
                    }
                    Button {
                        restoring = true
                    } label: {
                        Label("استعد نسخة احتياطية", systemImage: "arrow.counterclockwise")
                    }
                    if let backupMessage {
                        Text(backupMessage).font(.callout)
                    }
                } header: {
                    Text("بياناتك")
                } footer: {
                    Text("كل بياناتك في هذا الجوال وحده: الكتب ووحداتها والمراجعات وتقدّمك في البنوك. احفظ نسخة في «الملفات» أو iCloud Drive من حين لآخر.")
                }

                Section("عن التطبيق") {
                    LabeledContent("النسخة", value: appVersion)
                    Link("Revisal على GitHub", destination: URL(string: "https://github.com/ibnkabed/revisal")!)
                    Text("مجاني ومفتوح المصدر. يراجع معك أي منهج بأسئلة «اختر الإجابة الصحيحة» يكتبها الذكاء الاصطناعي من كتابك، ومعه بنكا التحصيلي والقدرات بشرح كل إجابة.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("الإعدادات")
            .sheet(item: $shared) { file in
                ShareSheet(items: [file.url])
            }
            .fileImporter(isPresented: $restoring, allowedContentTypes: [.zip]) { result in
                if case .success(let url) = result { confirmRestore = url }
            }
            .confirmationDialog("تحل النسخة الاحتياطية محل كل بياناتك الحالية؟",
                                isPresented: Binding(get: { confirmRestore != nil }, set: { if !$0 { confirmRestore = nil } }),
                                titleVisibility: .visible) {
                Button("استعدها", role: .destructive) {
                    if let url = confirmRestore {
                        do {
                            try store.restoreBackup(url)
                            backupMessage = "استُعيدت النسخة الاحتياطية."
                        } catch {
                            backupMessage = error.localizedDescription
                        }
                    }
                    confirmRestore = nil
                }
                Button("إلغاء", role: .cancel) { confirmRestore = nil }
            }
        }
    }

    @ViewBuilder
    private func provider(_ p: AIProvider) -> some View {
        let mine = ai.linked.first { $0.id == p.id }
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(p.name).font(.headline)
                Text(p.free ? "مجاني" : "رخيص")
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(p.free ? Color.green.opacity(0.15) : Color.orange.opacity(0.15)))
                Spacer()
                if mine != nil {
                    Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
                }
            }
            Text(p.note).font(.footnote).foregroundColor(.secondary)
            if let mine {
                Text("النموذج: \(mine.model)").font(.caption).foregroundColor(.secondary)
                if let err = mine.lastError {
                    Text("آخر خطأ: \(err)").font(.caption).foregroundColor(.red)
                }
                Button("ألغِ الربط", role: .destructive) { ai.unlink(p.id) }
                    .buttonStyle(.borderless)
            } else {
                Link(destination: p.keyURL) {
                    Label("افتح صفحة المفتاح", systemImage: "safari")
                }
                .buttonStyle(.borderless)
                HStack {
                    SecureField("الصق المفتاح هنا", text: Binding(get: { keys[p.id] ?? "" }, set: { keys[p.id] = $0 }))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if linking == p.id {
                        ProgressView()
                    } else {
                        Button("اربط") { link(p.id) }
                            .buttonStyle(.borderless)
                            .disabled((keys[p.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty || linking != nil)
                    }
                }
            }
            if let msg = aiMessage[p.id] {
                Text(msg).font(.caption).foregroundColor(msg.hasPrefix("رُبط") ? .green : .red)
            }
        }
        .padding(.vertical, 4)
    }

    private func link(_ id: String) {
        linking = id
        aiMessage[id] = nil
        Task {
            defer { linking = nil }
            do {
                let model = try await ai.link(id, key: keys[id] ?? "")
                keys[id] = nil
                aiMessage[id] = "رُبط بنجاح، والنموذج المختار \(model)"
            } catch {
                aiMessage[id] = error.localizedDescription
            }
        }
    }
}
