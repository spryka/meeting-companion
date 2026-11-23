import Foundation
import MeetingCompanionCore

public struct VoiceMixedClusterRescuePolicy: Equatable, Sendable {
    public let threshold: Double
    public let margin: Double

    public init?(threshold: Double, margin: Double) {
        guard (-1...1).contains(threshold), margin.isFinite, margin > 0 else { return nil }
        self.threshold = threshold
        self.margin = margin
    }
}

public struct VoiceMatchPolicy: Equatable, Sendable {
    public let threshold: Double
    public let margin: Double
    public let calendarBonus: Double
    public let maximumAcousticGap: Double
    public let mixedClusterRescue: VoiceMixedClusterRescuePolicy?

    public init?(
        threshold: Double,
        margin: Double,
        calendarBonus: Double,
        maximumAcousticGap: Double,
        mixedClusterRescue: VoiceMixedClusterRescuePolicy? = nil
    ) {
        guard (-1...1).contains(threshold), margin.isFinite, margin > 0,
              (0...2).contains(calendarBonus), (0...2).contains(maximumAcousticGap) else { return nil }
        if let mixedClusterRescue {
            guard mixedClusterRescue.threshold >= threshold,
                  mixedClusterRescue.margin >= margin else { return nil }
        }
        self.threshold = threshold
        self.margin = margin
        self.calendarBonus = calendarBonus
        self.maximumAcousticGap = maximumAcousticGap
        self.mixedClusterRescue = mixedClusterRescue
    }
}

public struct VoiceMatchWindow: Sendable {
    public let start: Double
    public let end: Double
    public let embedding: [Float]

    public init(start: Double, end: Double, embedding: [Float]) {
        self.start = start
        self.end = end
        self.embedding = embedding
    }
}

public enum VoiceProfileMatcher {
    public enum Result: Equatable, Sendable {
        case matched(UUID)
        case refused(Refusal)
    }

    public enum Refusal: Equatable, Sendable {
        case insufficientProfiles, incompleteCoverage, invalidEmbedding, weakMatch, ambiguous, conflictingWindows
    }

    public struct RankedProfile: Equatable, Sendable {
        public let personID: UUID
        public let cosine: Double
        public let rank: Double

        public init(personID: UUID, cosine: Double, rank: Double) {
            self.personID = personID
            self.cosine = cosine
            self.rank = rank
        }
    }

    public struct WindowEvaluation: Equatable, Sendable {
        public let rankings: [RankedProfile]
        public let matchedPersonID: UUID?
        public let refusal: Refusal?
        public let strongLeaderID: UUID?

        public init(rankings: [RankedProfile], matchedPersonID: UUID?, refusal: Refusal?, strongLeaderID: UUID?) {
            self.rankings = rankings
            self.matchedPersonID = matchedPersonID
            self.refusal = refusal
            self.strongLeaderID = strongLeaderID
        }
    }

    struct PreparedProfiles {
        let profiles: [VoiceProfileAggregate]
        let profileNorms: [Double]
        let confirmedContacts: Set<UUID>
    }

    enum Preparation {
        case ready(PreparedProfiles)
        case refused(Refusal)
    }

    static func prepare(
        catalogue: VoiceProfileCatalogue,
        embeddingSpaceID: String,
        invitedContacts: [String]
    ) -> Preparation {
        let profiles = catalogue.availableAggregates.filter { $0.embeddingSpaceID == embeddingSpaceID }
        guard profiles.count >= 2 else { return .refused(.insufficientProfiles) }
        let profileNorms = profiles.compactMap { norm($0.centroid) }
        guard profileNorms.count == profiles.count else { return .refused(.invalidEmbedding) }

        let invited = Dictionary(grouping: invitedContacts, by: { $0 })
        let bindings = Dictionary(grouping: catalogue.people.flatMap { person in
            Set(person.calendarBindings).map { ($0, person.id) }
        }, by: { $0.0 })
        let confirmedContacts = Set(invited.keys.compactMap { address -> UUID? in
            guard invited[address]?.count == 1, bindings[address]?.count == 1 else { return nil }
            return bindings[address]?.first?.1
        })
        return .ready(PreparedProfiles(profiles: profiles, profileNorms: profileNorms, confirmedContacts: confirmedContacts))
    }

    static func evaluate(
        embedding: [Float],
        startFrame: Int,
        endFrame: Int,
        using state: PreparedProfiles,
        policy: VoiceMatchPolicy
    ) -> WindowEvaluation {
        let minimumFrames = 3 * VoiceEmbeddingProtocol.sampleRate
        let maximumFrames = 6 * VoiceEmbeddingProtocol.sampleRate
        guard startFrame >= 0, endFrame > startFrame,
              (minimumFrames...maximumFrames).contains(endFrame - startFrame) else {
            return WindowEvaluation(rankings: [], matchedPersonID: nil, refusal: .incompleteCoverage, strongLeaderID: nil)
        }
        return evaluate(embedding: embedding, using: state, policy: policy)
    }

    static func evaluate(
        _ window: VoiceMatchWindow,
        using state: PreparedProfiles,
        policy: VoiceMatchPolicy
    ) -> WindowEvaluation {
        guard window.start.isFinite, window.start >= 0, window.end.isFinite,
              window.end > window.start, window.end - window.start <= 6 else {
            return WindowEvaluation(rankings: [], matchedPersonID: nil, refusal: .incompleteCoverage, strongLeaderID: nil)
        }
        return evaluate(embedding: window.embedding, using: state, policy: policy)
    }

    private static func evaluate(
        embedding: [Float],
        using state: PreparedProfiles,
        policy: VoiceMatchPolicy
    ) -> WindowEvaluation {
        guard let queryNorm = norm(embedding) else {
            return WindowEvaluation(rankings: [], matchedPersonID: nil, refusal: .invalidEmbedding, strongLeaderID: nil)
        }
        let rankings = zip(state.profiles, state.profileNorms).map { profile, profileNorm in
            let dot = zip(embedding, profile.centroid).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
            let cosine = max(-1, min(1, dot / (queryNorm * profileNorm)))
            let bonus = state.confirmedContacts.contains(profile.personID) ? policy.calendarBonus : 0
            return RankedProfile(personID: profile.personID, cosine: cosine, rank: cosine + bonus)
        }.sorted { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank > rhs.rank }
            if lhs.cosine != rhs.cosine { return lhs.cosine > rhs.cosine }
            return lhs.personID.uuidString < rhs.personID.uuidString
        }
        let best = rankings[0]
        let acousticLeader = rankings.max { lhs, rhs in
            if lhs.cosine != rhs.cosine { return lhs.cosine < rhs.cosine }
            if lhs.personID == best.personID { return false }
            if rhs.personID == best.personID { return true }
            return lhs.personID.uuidString > rhs.personID.uuidString
        }
        let strongestAcoustic = acousticLeader?.cosine ?? best.cosine
        let acousticStrongLeader = acousticLeader.flatMap { $0.cosine >= policy.threshold ? $0.personID : nil }

        guard best.cosine >= policy.threshold, strongestAcoustic - best.cosine <= policy.maximumAcousticGap else {
            return WindowEvaluation(rankings: rankings, matchedPersonID: nil, refusal: .weakMatch, strongLeaderID: acousticStrongLeader)
        }
        guard best.rank - rankings[1].rank >= policy.margin else {
            return WindowEvaluation(rankings: rankings, matchedPersonID: nil, refusal: .ambiguous, strongLeaderID: acousticStrongLeader)
        }
        return WindowEvaluation(rankings: rankings, matchedPersonID: best.personID, refusal: nil, strongLeaderID: acousticStrongLeader)
    }

    public static func evaluateWindow(
        _ window: VoiceMatchWindow,
        catalogue: VoiceProfileCatalogue,
        embeddingSpaceID: String,
        invitedContacts: [String],
        policy: VoiceMatchPolicy
    ) -> WindowEvaluation {
        switch prepare(catalogue: catalogue, embeddingSpaceID: embeddingSpaceID, invitedContacts: invitedContacts) {
        case .refused(let refusal):
            return WindowEvaluation(rankings: [], matchedPersonID: nil, refusal: refusal, strongLeaderID: nil)
        case .ready(let state):
            return evaluate(window, using: state, policy: policy)
        }
    }

    public static func match(
        turnStart: Double, turnEnd: Double, windows: [VoiceMatchWindow],
        catalogue: VoiceProfileCatalogue, embeddingSpaceID: String, invitedContacts: [String],
        policy: VoiceMatchPolicy
    ) -> Result {
        let state: PreparedProfiles
        switch prepare(catalogue: catalogue, embeddingSpaceID: embeddingSpaceID, invitedContacts: invitedContacts) {
        case .refused(let refusal): return .refused(refusal)
        case .ready(let prepared): state = prepared
        }

        let ordered = windows.sorted { $0.start < $1.start }
        guard turnStart.isFinite, turnStart >= 0, turnEnd.isFinite, turnEnd > turnStart,
              windows.allSatisfy({ $0.start.isFinite && $0.end.isFinite &&
                  $0.start >= turnStart && $0.end > $0.start && $0.end <= turnEnd && $0.end - $0.start <= 6 }) else {
            return .refused(.incompleteCoverage)
        }
        var coveredThrough = turnStart
        for window in ordered {
            guard window.start <= coveredThrough else { return .refused(.incompleteCoverage) }
            coveredThrough = max(coveredThrough, window.end)
        }
        guard coveredThrough == turnEnd else { return .refused(.incompleteCoverage) }

        var winner: UUID?
        for window in ordered {
            let evaluation = evaluate(window, using: state, policy: policy)
            if let refusal = evaluation.refusal {
                return .refused(refusal)
            }
            guard let bestID = evaluation.matchedPersonID else {
                return .refused(.weakMatch)
            }
            guard winner == nil || winner == bestID else { return .refused(.conflictingWindows) }
            winner = bestID
        }
        return winner.map(Result.matched) ?? .refused(.incompleteCoverage)
    }

    private static func norm(_ embedding: [Float]) -> Double? {
        guard embedding.count == 256, embedding.allSatisfy(\.isFinite) else { return nil }
        let squared = embedding.reduce(0.0) { $0 + Double($1) * Double($1) }
        return abs(squared - 1) <= 0.01 ? squared.squareRoot() : nil
    }
}
