import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let notchModel = NotchModel()
    private let stats = StatsStore()
    private let fans = FanController()
    private let agents = AgentStore()
    private var notchController: NotchWindowController?
    private var statusBar: StatusBarController?
    private var settings: SettingsWindowController?
    private let systemEvents = SystemEventMonitor()
    private let warnings = WarningAlerts()
    private let updates = UpdateChecker()
    private var notifyObserver: NSObjectProtocol?
    private var terminationSource: DispatchSourceSignal?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        stats.start()
        notchModel.$isOpen.combineLatest(notchModel.$tab)
            .sink { [weak self] isOpen, tab in
                self?.stats.isDashboardOpen = isOpen
                self?.stats.showsApps = isOpen && tab == .apps
                self?.stats.showsFans = isOpen && (tab == .fans || tab == .thermal)
                self?.agents.isVisible = isOpen && tab == .agents
            }
            .store(in: &cancellables)
        // 온도를 새로 읽을 때마다 팬 모드(고정 · 온도별)를 맞춰 둔다
        stats.$snapshot
            .map(\.thermal)
            .removeDuplicates()
            .sink { [weak self] thermal in self?.fans.temperatureChanged(thermal) }
            .store(in: &cancellables)
        notchController = NotchWindowController(model: notchModel, stats: stats, fans: fans, agents: agents)
        agents.onAlert = { [weak self] alert, id in
            self?.agents.select(id)
            // 답이 필요한 알림은 조금 더 오래 띄우고, 그동안 노치에 마우스를 올리면 그 세션이 열린다
            self?.notchModel.show(alert, duration: 6, opening: .agents)
        }
        agents.start()

        let statusBar = StatusBarController()
        statusBar.onTestAlert = { [weak self] in
            self?.notchModel.show(NotchAlert(symbol: "bell.fill", tint: .orange, text: "테스트 알림"))
        }
        statusBar.currentTheme = { [weak self] in self?.notchModel.theme ?? .basic }
        statusBar.onSelectTheme = { [weak self] theme in self?.notchModel.theme = theme }
        let settings = SettingsWindowController(model: notchModel, agents: agents, updates: updates)
        statusBar.onOpenSettings = { [weak settings] in settings?.show() }
        // 지금 확인하고, 결과가 보이는 설정 창 › 업데이트를 연다
        statusBar.onCheckUpdates = { [weak self] in
            self?.settings?.show(tab: .updates)
            self?.updates.checkNow()
        }
        self.settings = settings
        self.statusBar = statusBar
        NotificationCenter.default.publisher(for: SettingsWindowController.openNotification)
            .sink { [weak self] _ in self?.settings?.show() }
            .store(in: &cancellables)

        warnings.onAlert = { [weak self] alert in self?.notchModel.show(alert) }
        // 새 버전 알림은 누를 수 있도록 조금 더 오래 띄운다 (누르면 릴리스 페이지)
        updates.onAlert = { [weak self] alert in self?.notchModel.show(alert, duration: 8) }
        updates.start()
        systemEvents.onThermalStateChange = { [weak self] state in self?.warnings.thermalStateChanged(to: state) }
        systemEvents.onMemoryPressure = { [weak self] event in self?.warnings.memoryPressureChanged(to: event) }
        systemEvents.onBatteryChange = { [weak self] new, old in
            guard let self else { return }
            stats.powerSourceChanged()
            // 최초 1회 읽기에는 충전기 알림을 띄우지 않는다 (배터리 부족만 확인)
            guard let old else {
                warnings.batteryAtLaunch(new)
                return
            }
            guard old.isPluggedIn != new.isPluggedIn else {
                warnings.batteryChanged(new, from: old)
                return
            }
            if new.isPluggedIn {
                notchModel.show(NotchAlert(symbol: "bolt.fill", tint: .green, text: "충전 중 \(new.level)%"))
            } else {
                notchModel.show(NotchAlert(symbol: "battery.75percent", tint: .white, text: "배터리 \(new.level)%"))
            }
        }
        systemEvents.onScreenUnlocked = { [weak self] in
            self?.notchModel.show(NotchAlert(symbol: "lock.open.fill", tint: .cyan, text: "잠금 해제"))
        }
        systemEvents.start()

        // `Cheoma --notify "…"`로 보낸 알림
        notifyObserver = DistributedNotificationCenter.default().addObserver(
            forName: NotifyCommand.notificationName, object: nil, queue: .main
        ) { [weak self] notification in
            // Notification은 Sendable이 아니라 메인으로 넘기기 전에 문자열만 꺼낸다
            let info = NotifyCommand.Info(notification)
            MainActor.assumeIsolated {
                if let alert = info?.alert { self?.notchModel.show(alert) }
            }
        }

        // kill/launchctl 등으로 종료 신호를 받아도 정상 종료 절차(기록 저장, 팬 자동 복귀)를 거치게 한다
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        terminationSource = source
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 수동 팬 모드였다면 자동으로 돌려놓고, 그래프 기록을 저장하고 끝낸다
        fans.restoreAutomaticBeforeQuit()
        stats.saveHistory(synchronously: true)
    }
}
