import Darwin

enum OpenFiles {
    /// Rollout logs (`.jsonl`) currently open in processes named `codex`. A Codex process keeps
    /// the log of every thread it has loaded open for appending, so an open log proves that a
    /// live process can still finish the thread's turn.
    static func rolloutsOpenByCodex() -> Set<String> {
        let capacity = proc_listallpids(nil, 0) + 64
        guard capacity > 64 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity))
        let count = proc_listallpids(&pids, capacity * Int32(MemoryLayout<pid_t>.size))
        var paths: Set<String> = []
        for pid in pids.prefix(Int(max(count, 0))) where pid > 0 {
            var name = [UInt8](repeating: 0, count: 256)
            let length = proc_name(pid, &name, UInt32(name.count))
            guard length > 0, String(decoding: name.prefix(Int(length)), as: UTF8.self) == "codex" else { continue }
            let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard bytes > 0 else { continue }
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / MemoryLayout<proc_fdinfo>.size)
            let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, bytes)
            for fd in fds.prefix(Int(max(filled, 0)) / MemoryLayout<proc_fdinfo>.size) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
                var info = vnode_fdinfowithpath()
                guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, Int32(MemoryLayout<vnode_fdinfowithpath>.size)) > 0 else { continue }
                let path = withUnsafeBytes(of: info.pvip.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
                if path.hasSuffix(".jsonl") { paths.insert(path) }
            }
        }
        return paths
    }
}
