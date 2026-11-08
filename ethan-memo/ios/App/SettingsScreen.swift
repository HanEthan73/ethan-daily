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
    @AppStorage("claudeModel") private var model = ClaudeModel.sonnet.rawValue
    @State private var testState: String?
    @State private var testing = false
    @State private var repo = SyncService.shared.repo
    @State private var ghToken = ""
    @State private var hasToken = Keychain.read(account: "ghToken") != nil
    @State private var pasting = false
    @State private var pasteText = ""
    private var sync = SyncService.shared

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if hasKey {
                        Label("API 키 저장됨", systemImage: "checkmark.seal.fill").foregroundStyle(Theme.todo)
                    }
                    SecureField(hasKey ? "새 키로 바꾸기" : "sk-ant-로 시작하는 키", text: $key)
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
                    Text("Claude API 키")
                } footer: {
                    Text("console.anthropic.com에서 발급합니다. 키는 이 아이폰의 Keychain에만 저장됩니다. API 사용료는 Claude 구독과 별도로 청구됩니다.")
                }

                Section("답변 모델") {
                    Picker("모델", selection: $model) {
                        ForEach(ClaudeModel.allCases) { Text($0.label).tag($0.rawValue) }
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
                                let a = try await ClaudeClient.ask("연결 확인입니다. '연결됨' 한 단어로만 답하세요.")
                                testState = "성공: \(a)"
                            } catch {
                                testState = (error as? ClaudeError)?.message ?? error.localizedDescription
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
