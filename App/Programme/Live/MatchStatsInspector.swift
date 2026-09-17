import ProgrammeCore
import ProgrammeUI
import SwiftUI

/// Live statistics, secondary to scoring by design.
///
/// Closing this reveals exactly the scoring state that was there before: the
/// inspector never replaces the workspace, it sits beside it.
struct MatchStatsInspector: View {
    let session: LiveMatchSession
    var onClose: () -> Void

    var body: some View {
        List {
            Section("Match Stats") {
                comparison("Score", session.snapshot.score.us, session.snapshot.score.opponent)
                if session.profile.tracks(.shots) {
                    comparison("Shots", session.snapshot.team.us.shots, session.snapshot.team.opponent.shots)
                    comparison(
                        "Shots on Goal", session.snapshot.team.us.shotsOnGoal,
                        session.snapshot.team.opponent.shotsOnGoal)
                }
                if session.profile.tracks(.corners) {
                    comparison(
                        "Corners", session.snapshot.team.us.corners, session.snapshot.team.opponent.corners)
                }
                if session.profile.tracks(.goalkeeping) {
                    comparison("Saves", session.snapshot.team.us.saves, session.snapshot.team.opponent.saves)
                }
                if session.profile.tracks(.steals) {
                    comparison("Steals", session.snapshot.team.us.steals, session.snapshot.team.opponent.steals)
                }
                if session.profile.tracks(.cards) {
                    comparison(
                        "Yellow Cards", session.snapshot.team.us.yellowCards,
                        session.snapshot.team.opponent.yellowCards)
                }
            }

            Section("Players") {
                ForEach(contributingPlayers) { player in
                    playerRow(player)
                }
                if contributingPlayers.isEmpty {
                    Text("No player statistics recorded yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if session.profile.tracks(.goalkeeping) {
                Section("Goalkeeping") {
                    ForEach(keepers, id: \.playerID) { keeper in
                        keeperRow(keeper)
                    }
                    if keepers.isEmpty {
                        Text("No goalkeeper minutes recorded yet.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.inset)
        .navigationTitle("Match Stats")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: onClose)
                    .accessibilityIdentifier("stats.close")
            }
        }
    }

    private var contributingPlayers: [PlayerSnapshot] {
        session.roster.sortedByNumber.filter { player in
            let line = session.snapshot.player(player.id)
            return line.appeared && (line.hasAnyContribution || line.secondsPlayed > 0)
        }
    }

    private var keepers: [KeeperStatLine] {
        session.snapshot.keepers.values
            .filter { $0.side == .us && $0.secondsPlayed > 0 }
            .sorted { $0.secondsPlayed > $1.secondsPlayed }
    }

    private func comparison(_ label: String, _ us: Int, _ them: Int) -> some View {
        HStack {
            Text("\(us)")
                .font(.body.weight(.semibold))
                .monospacedDigit()
                .frame(width: 40, alignment: .leading)
            Spacer()
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(them)")
                .font(.body.weight(.semibold))
                .monospacedDigit()
                .frame(width: 40, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(label), \(session.descriptor.teamShortName) \(us), \(session.descriptor.opponentShortName) \(them)"
        )
    }

    private func playerRow(_ player: PlayerSnapshot) -> some View {
        let line = session.snapshot.player(player.id)
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(player.shortLabel)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("\(line.minutesPlayed) min")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Text(contributionSummary(line))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(player.accessibilityLabel), \(line.minutesPlayed) minutes, \(contributionSummary(line))")
    }

    private func contributionSummary(_ line: PlayerStatLine) -> String {
        var parts: [String] = []
        if line.goals > 0 { parts.append("\(line.goals) G") }
        if line.assists > 0 { parts.append("\(line.assists) A") }
        if session.profile.tracks(.shots) && line.shots > 0 {
            parts.append("\(line.shots) SH · \(line.shotsOnGoal) SOG")
        }
        if session.profile.tracks(.steals) && line.steals > 0 { parts.append("\(line.steals) ST") }
        if session.profile.tracks(.corners) && line.corners > 0 { parts.append("\(line.corners) CK") }
        if line.yellowCards > 0 { parts.append("\(line.yellowCards) YC") }
        if line.redCards > 0 { parts.append("\(line.redCards) RC") }
        return parts.isEmpty ? "No statistics yet" : parts.joined(separator: " · ")
    }

    private func keeperRow(_ keeper: KeeperStatLine) -> some View {
        let name = session.roster[keeper.playerID]?.shortLabel ?? "Goalkeeper"
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(name).font(.subheadline.weight(.medium))
                Spacer()
                Text("\(keeper.minutesPlayed) min")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Text("\(keeper.saves) SV")
                Text("\(keeper.goalsAllowed) GA")
                if let percentage = keeper.savePercentage {
                    Text(String(format: "%.0f%% SV", percentage * 100))
                }
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
