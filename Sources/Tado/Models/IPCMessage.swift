import Foundation

struct IPCMessage: Codable, Identifiable {
    let id: UUID
    let from: UUID
    let fromName: String
    let to: UUID
    let timestamp: Date
    let body: String
    var status: IPCMessageStatus
}

enum IPCMessageStatus: String, Codable {
    case pending
    case delivered
}

struct IPCSessionEntry: Codable {
    let sessionID: UUID
    let name: String
    let engine: String
    let gridLabel: String
    let status: String
    let projectName: String?
    let agentName: String?
    let teamName: String?
    let teamID: String?
}

struct TopicSubscriber: Codable {
    enum SubscriberType: String, Codable { case session, project }
    let type: SubscriberType
    let id: String?
    let name: String?
}

struct TopicMessage: Codable {
    let id: UUID
    let from: UUID
    let fromName: String
    let topic: String
    let timestamp: Date
    let body: String
}
