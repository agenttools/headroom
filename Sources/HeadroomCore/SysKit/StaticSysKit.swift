// A SysKit backed by fixed data, for fixture tests (and for replaying a captured
// OwnershipFixture). Never touches the live system.

import Foundation
import HeadroomContracts

public final class StaticSysKit: SysKit, @unchecked Sendable {
    public let table: ProcessTable
    public let argsByPid: [Int32: ProcArgs]
    public let cwdByPid: [Int32: String]
    public let memory: SystemMemory

    public init(table: ProcessTable, args: [Int32: ProcArgs] = [:], cwds: [Int32: String] = [:],
                memory: SystemMemory = .zero) {
        self.table = table; self.argsByPid = args; self.cwdByPid = cwds; self.memory = memory
    }

    public convenience init(fixture f: OwnershipFixture) {
        self.init(table: f.table, args: f.argsByPid, cwds: f.cwdByPid, memory: f.system ?? .zero)
    }

    public func scan() -> ProcessTable { table }
    public func args(_ k: ProcKey) -> ProcArgs? {
        guard table.byPid[k.pid]?.key == k else { return nil }
        return argsByPid[k.pid]
    }
    public func cwd(_ pid: Int32) -> String? { cwdByPid[pid] }
    public func systemMemory() -> SystemMemory { memory }
    public func isAlive(_ k: ProcKey) -> Bool { table.byPid[k.pid]?.key == k }
}
