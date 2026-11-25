// ProcessLineage.swift
// Which app this process was started from, which is who macOS's privacy checks ask about.

import Foundation
import Darwin

/// The chain of processes this one was started from.
///
/// Full Disk Access belongs to apps, and a command-line tool gets it from the app it was
/// started from: the terminal it runs in, through sudo and the shell. When the check
/// refuses, naming that app tells the user what to grant it to. A daemon started over SSH
/// has no such app, and was refused even though the session could read protected files.
/// A daemon started at boot has none either and should need the grant itself; that has
/// not been tested.
public enum ProcessLineage {
    /// Executable names from this process up to, not including, launchd.
    public static func chain(from pid: pid_t = getpid()) -> [String] {
        var names: [String] = []
        var current = pid
        for _ in 0..<32 {
            guard current > 1, let path = executablePath(of: current) else { break }
            names.append(displayName(forExecutable: path))
            guard let parent = parentPID(of: current), parent != current else { break }
            current = parent
        }
        return names
    }

    /// The app bundle this process was started from, if any.
    public static func launchingApp(from pid: pid_t = getpid()) -> String? {
        var current = pid
        for _ in 0..<32 {
            guard current > 1, let path = executablePath(of: current) else { return nil }
            if let range = path.range(of: ".app/Contents/MacOS/") {
                let bundle = String(path[..<range.lowerBound]) + ".app"
                return (bundle as NSString).lastPathComponent
            }
            guard let parent = parentPID(of: current), parent != current else { return nil }
            current = parent
        }
        return nil
    }

    /// "Terminal.app" for an app's executable, the file name for anything else.
    static func displayName(forExecutable path: String) -> String {
        if let range = path.range(of: ".app/Contents/MacOS/") {
            return (String(path[..<range.lowerBound] + ".app") as NSString).lastPathComponent
        }
        return (path as NSString).lastPathComponent
    }

    private static func executablePath(of pid: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }
}
