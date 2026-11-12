import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import UIKit

struct SettingsScreen: View {
    @Environment(\.modelContext) private var ctx
    @State private var exportURL: URL?
    @State private var importing = false
    @State private var backupMsg: String?
    @State private var key = ""
    @State private var hasKey = Keychain.read() != nil
    @AppStorage("gptModel") private var model = GPTModel.gemFlash.rawValue
    @State private var gkey = ""
    @State private var hasGKey = Keychain.read(account: Keychain.gemini) != nil
    @AppStorage("botEnabled") private var botEnabled = true
    @AppStorage(CalendarBridge.showKey) private var gcalShow = false
    @AppStorage(CalendarBridge.pushKey) private var gcalPush = true
    @AppStorage(CalendarBridge.targetKey) private var gcalTarget = ""
    private var bridge = CalendarBridge.shared
    @State private var testState: String?
    @State private var testing = false
    @State private var repo = SyncService.shared.repo
    @State private var ghToken = ""
    @State private var hasToken = Keychain.read(account: "ghToken") != nil
    @State private var pasting = false
    @State private var pasteText = ""
    private var sync = SyncService.shared
    @AppStorage(ThemePrefs.accentKey, store: Store.defaults) private var accent = "orange"
    @AppStorage(ThemePrefs.lateKey, store: Store.defaults) private var lateKey = "coral"

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("강조색").font(.system(size: 14.5, weight: .semibold))
                        SwatchRow(presets: ThemePrefs.accents, selection: $accent)
                    }
                    .padding(.vertical, 4)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("지난 일 색").font(.system(size: 14.5, weight: .semibold))
                        SwatchRow(presets: ThemePrefs.lates, selection: $lateKey)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("테마 색")
                } footer: {
                    Text("강조색은 버튼·오늘·선택 표시에, 지난 일 색은 날짜가 지난 할 일에 쓰입니다. 맨 끝 무지개 동그라미로 원하는 색을 직접 고를 수 있어요.")
                }
                Section {
                    Toggle("구글 캘린더 연동", isOn: $gcalShow)
                        .onChange(of: gcalShow) { _, on in
                            guard on else { bridge.reload(); return }
                            Task {
                                if await bridge.requestAccess() { bridge.reload(); bridge.schedulePush(ctx) }
                                else { gcalShow = false }
                            }
                        }
                    if gcalShow && bridge.authorized {
                        Toggle("앱 일정을 구글 캘린더에도 추가", isOn: $gcalPush)
                            .onChange(of: gcalPush) { _, on in if on { bridge.schedulePush(ctx) } }
                        if gcalPush {
                            Picker("추가할 캘린더", selection: Binding(get: { bridge.target?.calendarIdentifier ?? "" }, set: { gcalTarget = $0; bridge.schedulePush(ctx) })) {
                                ForEach(bridge.writableCalendars, id: \.calendarIdentifier) { c in
                                    Text("\(c.title) · \(c.source.title)").tag(c.calendarIdentifier)
                                }
                            }
                        }
                        HStack {
                            Text(bridge.googleAccountFound ? "구글 계정 연결됨" : "구글 계정이 아직 없음")
                                .foregroundStyle(bridge.googleAccountFound ? Theme.todo : Theme.warn)
                            Spacer()
                            Text("일정 \(bridge.ext.count)개").foregroundStyle(.secondary)
                        }
                        .font(.footnote)
                        Button("지금 동기화") { bridge.reload(); bridge.pushAll(ctx) }
                    }
                } header: {
                    Text("구글 캘린더")
                } footer: {
                    Text("처음 한 번: 아이폰 설정 → 캘린더 → 계정 → 계정 추가 → Google 로그인 → ‘캘린더’ 켜기. 그다음 여기서 연동을 켜면 구글 일정이 달력에 ‘G’로 보이고, 앱에서 만든 일정은 고른 구글 캘린더에도 추가·수정·삭제됩니다. 키·충전 필요 없음.")
                }
                Section {
                    Toggle("GPT 챗봇 버튼", isOn: $botEnabled)
                } header: {
                    Text("GPT 챗봇")
                } footer: {
                    Text("켜 두면 왼쪽 아래 봇 버튼으로 어느 화면에서나 말하거나 써서 일정·할 일을 등록할 수 있어요. 끄면 버튼이 사라집니다.")
                }
                Section {
                    if hasGKey {
                        Label("Gemini 키 저장됨", systemImage: "checkmark.seal.fill").foregroundStyle(Theme.todo)
                    }
                    SecureField(hasGKey ? "새 키로 바꾸기" : "AIza로 시작하는 키", text: $gkey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    HStack {
                        Button("저장") {
                            Keychain.save(gkey.trimmingCharacters(in: .whitespacesAndNewlines), account: Keychain.gemini)
                            gkey = ""
                            hasGKey = Keychain.read(account: Keychain.gemini) != nil
                            if hasGKey && !hasKey { model = GPTModel.gemFlash.rawValue }
                        }
                        .disabled(gkey.isEmpty)
                        Spacer()
                        if hasGKey {
                            Button("키 삭제", role: .destructive) {
                                Keychain.save("", account: Keychain.gemini)
                                hasGKey = false
                            }
                        }
                    }
                    .buttonStyle(.borderless)
                    Link("구글 로그인하고 무료 키 받기 ↗", destination: URL(string: "https://aistudio.google.com/apikey")!)
                } header: {
                    Text("Gemini API 키 (무료 · 추천)")
                } footer: {
                    Text("충전·카드 없이 무료입니다. 링크에서 구글 계정으로 로그인 → ‘API 키 만들기’ → 복사해서 붙여넣기. 키는 이 아이폰의 Keychain에만 저장됩니다. 무료 사용분 대화는 구글 서비스 개선에 쓰일 수 있어요.")
                }
                Section {
                    if hasKey {
                        Label("API 키 저장됨", systemImage: "checkmark.seal.fill").foregroundStyle(Theme.todo)
                    }
                    SecureField(hasKey ? "새 키로 바꾸기" : "sk-로 시작하는 키", text: $key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    HStack {
                        Button("저장") {
                            Keychain.save(key.trimmingCharacters(in: .whitespacesAndNewlines))
                            key = ""
                            hasKey = Keychain.read() != nil
                        }
                        .disabled(key.isEmpty)
                        Spacer()
                        if hasKey {
                            Button("키 삭제", role: .destructive) {
                                Keychain.save("")
                                hasKey = false
                            }
                        }
                    }
                    .buttonStyle(.borderless)
                } header: {
                    Text("OpenAI API 키 (유료 · 선택)")
                } footer: {
                    Text("platform.openai.com에서 발급합니다. 키는 이 아이폰의 Keychain에만 저장됩니다. API 사용료는 ChatGPT 구독과 별도로 청구됩니다.")
                }

                Section("답변 모델") {
                    Picker("모델", selection: $model) {
                        ForEach(GPTModel.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section {
                    Button {
                        testing = true
                        testState = nil
                        Task {
                            do {
                                let a = try await GPTClient.ask("연결 확인입니다. '연결됨' 한 단어로만 답하세요.")
                                testState = "성공: \(a)"
                            } catch {
                                testState = (error as? GPTError)?.message ?? error.localizedDescription
                            }
                            testing = false
                        }
                    } label: {
                        HStack { Text("연결 테스트"); Spacer(); if testing { ProgressView() } }
                    }
                    .disabled(!hasKey || testing)
                    if let s = testState { Text(s).font(.footnote).foregroundStyle(.secondary) }
                }

                Section {
                    HStack {
                        Circle().fill(syncColor).frame(width: 7, height: 7)
                        Text(syncText).font(.subheadline)
                        Spacer()
                        Button("지금 동기화") { Task { await sync.run() } }
                            .buttonStyle(.ink)
                            .disabled(!sync.on || sync.state == .busy)
                    }
                    TextField("HanEthan73/ethan-memo-data", text: $repo)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { sync.repo = repo; repo = sync.repo; sync.schedule(0.2) }
                    SecureField(hasToken ? "토큰 저장됨 · 바꾸려면 새로 입력" : "github_pat_로 시작하는 토큰", text: $ghToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    HStack {
                        Button("저장하고 연결") {
                            sync.repo = repo
                            repo = sync.repo
                            let t = ghToken.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !t.isEmpty { Keychain.save(t, account: "ghToken") }
                            ghToken = ""
                            hasToken = Keychain.read(account: "ghToken") != nil
                            Task { await sync.run() }
                        }
                        .disabled(repo.trimmingCharacters(in: .whitespaces).isEmpty || (ghToken.isEmpty && !hasToken))
                        Spacer()
                        if hasToken {
                            Button("연결 끊기", role: .destructive) {
                                Keychain.save("", account: "ghToken")
                                hasToken = false
                                sync.state = .off
                            }
                        }
                    }
                    .buttonStyle(.borderless)
                } header: {
                    Text("PC·웹과 동기화")
                } footer: {
                    Text("비공개 저장소 하나와, 그 저장소에만 ‘Contents 읽기·쓰기’ 권한을 준 토큰을 넣으세요. 웹(PC) 버전 ⚙에도 같은 값을 넣으면 할 일·일정·위키·사진이 양쪽에 똑같이 보입니다. 토큰은 이 아이폰의 Keychain에만 저장됩니다.")
                }

                Section {
                    Button {
                        do { exportURL = try Backup.export(ctx); backupMsg = nil }
                        catch { backupMsg = "백업 파일을 만들지 못했습니다: \(error.localizedDescription)" }
                    } label: { Label("백업 파일 만들기", systemImage: "archivebox") }
                    if let u = exportURL {
                        ShareLink(item: u) {
                            Label("‘파일’에 저장하거나 보내기", systemImage: "square.and.arrow.up")
                        }
                    }
                    Button { importing = true } label: {
                        Label("백업에서 불러오기", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        if let c = UIPasteboard.general.string, c.contains("import=") { runImport(c) }
                        else { pasteText = ""; pasting = true }
                    } label: {
                        Label("가져오기 링크·코드 붙여넣기", systemImage: "doc.on.clipboard")
                    }
                    if let m = backupMsg {
                        Text(m).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("백업")
                } footer: {
                    Text("앱을 다시 서명·설치하기 전에 백업해 두세요. 웹 버전에서 만든 백업 파일도 불러올 수 있습니다. 불러오면 기존 기록은 그대로 두고 합칩니다.")
                }
                .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                    switch result {
                    case .success(let url):
                        do {
                            let r = try Backup.restore(from: url, into: ctx)
                            backupMsg = "불러왔습니다: 새 기록 \(r.added)개, 갱신 \(r.updated)개"
                        } catch {
                            backupMsg = "불러오지 못했습니다. ETHAN MEMO 백업 파일인지 확인하세요."
                        }
                    case .failure:
                        backupMsg = "파일을 열지 못했습니다."
                    }
                }

                Section("위젯") {
                    Text("홈 화면을 길게 누름 → 왼쪽 위 ‘편집’ → ‘위젯 추가’ → ‘ETHAN MEMO’ 검색. 위젯의 동그라미를 누르면 앱을 열지 않고 완료 처리됩니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .spaceGray()
            .navigationTitle("설정")
            .navigationBarTitleDisplayMode(.inline)
            .alert("가져오기 링크 붙여넣기", isPresented: $pasting) {
                TextField("https://…#import=…", text: $pasteText)
                Button("가져오기") { runImport(pasteText) }
                Button("취소", role: .cancel) {}
            }
        }
    }

    private func runImport(_ code: String) {
        do {
            let n = try Backup.importCode(code, into: ctx)
            backupMsg = n > 0 ? "옮겼습니다: 할 일 \(n)개 추가" : "이미 모두 들어와 있습니다"
            Router.shared.tab = .todo
        } catch {
            backupMsg = "가져오기 코드를 읽지 못했습니다. 링크 전체를 복사했는지 확인하세요."
        }
    }

    private var syncColor: Color {
        switch sync.state {
        case .ok: return Theme.todo
        case .busy: return Theme.memo
        case .err: return Theme.warn
        case .off: return sync.on ? Theme.hi : Color.secondary
        }
    }

    private var syncText: String {
        if !sync.on { return "꺼짐 · 이 아이폰에만 저장" }
        switch sync.state {
        case .busy: return "동기화 중…"
        case .err: return sync.error.isEmpty ? "동기화 오류" : sync.error
        default:
            if let l = sync.last { return "동기화됨 · " + Fmt.string(l, "M/d HH:mm") }
            return "연결됨"
        }
    }
}


/// 색 고르는 동그라미 줄 (프리셋 + 직접 고르기)
struct SwatchRow: View {
    let presets: [ThemePrefs.Preset]
    @Binding var selection: String
    @State private var custom = Color.orange

    var body: some View {
        let isCustom = ThemePrefs.hex(selection) != nil
        HStack(spacing: 12) {
            ForEach(presets) { p in
                Button { selection = p.id } label: {
                    Circle().fill(Theme.adaptive(Theme.rgb(p.light), Theme.rgb(p.dark)))
                        .frame(width: 32, height: 32)
                        .overlay {
                            if selection == p.id {
                                Image(systemName: "checkmark").font(.system(size: 13, weight: .heavy)).foregroundStyle(.white)
                                    .shadow(color: .black.opacity(0.4), radius: 1)
                            }
                        }
                        .overlay(Circle().stroke(selection == p.id ? Color.primary.opacity(0.7) : Color.clear, lineWidth: 2).padding(-4))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(p.name)
            }
            ColorPicker("직접 고르기", selection: $custom, supportsOpacity: false)
                .labelsHidden()
                .overlay(Circle().stroke(isCustom ? Color.primary.opacity(0.7) : Color.clear, lineWidth: 2).padding(-4).allowsHitTesting(false))
                .onChange(of: custom) { _, c in selection = ThemePrefs.uiHex(c) }
        }
        .onAppear { if let h = ThemePrefs.hex(selection) { custom = Color(Theme.rgb(h)) } }
    }
}
