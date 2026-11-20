import Foundation

/// An employee supplies identity and content; the voice connection supplies delivery.
public struct EmployeeVoiceIdentity: Sendable {
    public let name: String
    public let persona: String
    public let aliases: [String]
    public init(name: String, persona: String, aliases: [String]) {
        self.name = name; self.persona = persona; self.aliases = aliases
    }
}

public enum MeetingObservation: Sendable {
    case heard(String)
    case spoken(String, played: Bool, cutAt: Double?)
    case note(String)
}

public protocol EmployeeBrain: Brain {
    var identity: EmployeeVoiceIdentity? { get }
    var onMeetingEnded: (@Sendable (String) -> Void)? { get set }
    func observe(_ observation: MeetingObservation)
}

/// One correlated employee answer permits one voice turn. Never permits speech on a
/// timeout, old answer, interruption, new request or reconnection. Content fidelity
/// inside the permitted turn is still a voice-model property, not proven by this gate.
public struct EmployeeSpeechGate {
    private var requested: String?
    public private(set) var mayPlay = false
    public init() {}
    public mutating func request(_ id: String) { requested = id; mayPlay = false }
    @discardableResult public mutating func authorize(_ id: String) -> Bool {
        guard requested == id else { return false }
        mayPlay = true
        return true
    }
    public mutating func revoke() { requested = nil; mayPlay = false }
    public mutating func voiceTurnEnded() { if mayPlay { revoke() } }
}
