public struct TranscriptFollowState: Equatable, Sendable {
    public private(set) var isFollowing = true
    public private(set) var isClosed = false
    public private(set) var targetID: String?
    public private(set) var request: UInt64 = 0
    private var firstActiveID: String?
    private var lastRequestedID: String?
    public init() {}
    public mutating func update(activeIDs: [String], playing: Bool) {
        guard !isClosed else { return }
        firstActiveID = activeIDs.first
        if firstActiveID == nil { lastRequestedID = nil }
        guard isFollowing, playing, let id = firstActiveID, id != lastRequestedID else { return }
        requestTarget(id)
    }
    public mutating func manualScroll() {
        guard !isClosed else { return }
        isFollowing = false
    }
    public mutating func beginEditing() { manualScroll() }
    public mutating func returnToPlayback() {
        guard !isClosed else { return }
        isFollowing = true
        if let id = firstActiveID { requestTarget(id) }
    }
    public mutating func versionChanged() {
        guard !isClosed else { return }
        firstActiveID = nil
        lastRequestedID = nil
        targetID = nil
    }
    public mutating func close() {
        isClosed = true
        isFollowing = false
        firstActiveID = nil
        lastRequestedID = nil
        targetID = nil
    }
    private mutating func requestTarget(_ id: String) {
        targetID = id
        lastRequestedID = id
        request &+= 1
    }
}
