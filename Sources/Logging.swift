import os

/// Unified-logging channels. View with:
///   log show --last 10m --predicate 'subsystem == "com.phil.brirconvolver"'
/// All values are logged as public: they're device names, rates and counters, nothing personal.
enum Log {
    static let pipeline = Logger(subsystem: "com.phil.brirconvolver", category: "pipeline")
    static let health = Logger(subsystem: "com.phil.brirconvolver", category: "health")
    static let system = Logger(subsystem: "com.phil.brirconvolver", category: "system")
}
