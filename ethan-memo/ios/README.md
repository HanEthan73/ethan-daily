# ETHAN MEMO (iOS · 개인 설치용)

메모 · 할 일 · 캘린더 통합 앱 + 홈 화면 위젯 + Claude 질문. App Store에 올리지 않고 **내 아이폰에만** 설치합니다.

## 준비물

| 항목 | 내용 |
|---|---|
| Mac | Xcode 15 이상 (16 권장) |
| iPhone | iOS 17 이상, 설정 → 개인정보 보호 및 보안 → **개발자 모드 켬** |
| Apple 계정 | 무료 Apple ID 가능(7일마다 재설치), 유료 개발자($99/년)는 1년 유지 |
| XcodeGen | 터미널에서 `brew install xcodegen` |

## 설치 순서

| # | 할 일 | 명령/위치 |
|---|---|---|
| 1 | 폴더에서 프로젝트 생성 | `cd Haru && xcodegen` |
| 2 | Xcode로 열기 | `open Haru.xcodeproj` |
| 3 | 서명 팀 선택 | Haru 타깃, HaruWidget 타깃 각각 → Signing & Capabilities → Team |
| 4 | (번들 ID 충돌 시) ID 변경 | `project.yml`의 `com.ethanhan.haru` 3곳 + `group.com.ethanhan.haru` 2곳, `Shared/Store.swift`의 `appGroup` 같이 변경 후 1번 다시 |
| 5 | 아이폰 연결 후 실행 | 상단 기기 선택 → ▶ (⌘R) |
| 6 | 신뢰 설정 | 아이폰 설정 → 일반 → VPN 및 기기 관리 → 개발자 앱 신뢰 |
| 7 | 위젯 추가 | 홈 화면 길게 누름 → 편집 → 위젯 추가 → 'ETHAN MEMO' |
| 8 | Claude 연결 | 앱 → 설정 탭 → API 키 입력 → 연결 테스트 |

## 기능

| 기능 | 사용법 |
|---|---|
| 날짜별 메모 | 날짜 탭 → [메모] → 입력 → 추가 |
| 할 일 완료 | 동그라미 탭 또는 왼쪽→오른쪽 스와이프 |
| 하루 일정 | [일정] → 시간 토글 → 추가 |
| **여러 날 일정** | 달력에서 **19일 → 20일 드래그** → 등록 창 → 저장. 달력에 이어진 파란 막대로 표시(주가 바뀌면 끊김 없이 다음 줄로 이어짐) |
| 삭제 | 항목을 오른쪽→왼쪽 스와이프 |
| Claude에게 묻기 | 메모 아래 'Claude에게 묻기' 또는 입력칸 '메모하고 묻기'. 답변은 메모 아래 저장 |
| Claude 앱으로 | API 키 없이 공유 시트로 Claude 앱에 텍스트 전달 |
| 위젯 | 남은 할 일 수 + 목록, 동그라미 탭하면 앱을 열지 않고 완료 |

## 참고

- 데이터는 아이폰 안(App Group 저장소)에만 있습니다. iCloud 동기화는 유료 계정에서 추가 가능.
- 무료 Apple ID에서 App Group이 서명되지 않으면 앱은 동작하지만 위젯이 비어 보입니다. 이 경우 유료 계정을 쓰세요.
- Claude API 사용료는 Claude 구독과 별도입니다(console.anthropic.com).
