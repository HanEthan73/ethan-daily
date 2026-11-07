import SwiftUI

struct SettingsScreen: View {
    @State private var key = ""
    @State private var hasKey = Keychain.read() != nil
    @AppStorage("claudeModel") private var model = ClaudeModel.sonnet.rawValue
    @State private var testState: String?
    @State private var testing = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if hasKey {
                        Label("API 키 저장됨", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
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

                Section("위젯") {
                    Text("홈 화면을 길게 누름 → 왼쪽 위 ‘편집’ → ‘위젯 추가’ → ‘ETHAN MEMO’ 검색. 위젯의 동그라미를 누르면 앱을 열지 않고 완료 처리됩니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("설정")
        }
    }
}
