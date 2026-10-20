import Foundation
import Testing
@testable import Maintenance

@Suite struct MaintenanceTests {
    @Test func rootTasksHaveCommandsAndUserTasksDoNot() {
        for task in MaintenanceTask.all {
            #expect((task.rootCommand != nil) == task.needsAdmin, "\(task.id)")
        }
    }

    @Test func periodicScriptsOnlyBeforeSonoma() {
        let available = MaintenanceTask.available(hasFullDiskAccess: false).map(\.id)
        let isSonomaOrLater = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 14
        #expect(available.contains(.periodicScripts) != isSonomaOrLater || !FileManager.default.fileExists(atPath: "/usr/sbin/periodic"))
        #expect(!available.contains(.speedUpMail)) // needs Full Disk Access
        #expect(available.contains(.flushDNS))
    }

    @Test func memoryStatsAreConsistent() throws {
        let stats = try #require(MemoryStats.current())
        #expect(stats.total > 0 && stats.free > 0 && stats.free <= stats.total)
    }

    @Test func mailMustBeQuitBeforeCompacting() throws {
        let mail = try #require(MaintenanceTask.all.first { $0.id == .speedUpMail })
        let result = MaintenanceRunner.run([mail], isAppRunning: { $0 == "com.apple.mail" })
        #expect(result.first?.error == "Quit Mail and try again.")
    }
}
