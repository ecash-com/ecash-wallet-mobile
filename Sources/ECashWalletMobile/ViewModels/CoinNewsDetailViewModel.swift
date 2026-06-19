// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Observation
import SkipFuse
import WalletService

/// Drives the story **detail** page (CoinNews): loads the comment thread, casts an up/down vote, and
/// posts a comment. Votes + comments are signed on-chain `OP_RETURN`s (via `WalletManager`), so each
/// is broadcast + indexed (~10 min) — hence the optimistic local copies (comments shown immediately,
/// your vote highlighted from the persistent ledger) reconciled by `PendingCoinNewsStore`.
@MainActor
@Observable
final class CoinNewsDetailViewModel {
    enum State: Equatable {
        case idle, loading, loaded, failed(String)
    }

    /// The story. Starts as the feed snapshot (stale points/commentCount), refreshed via `GetItem`
    /// on load so the vote score + comment count reflect the indexer.
    private(set) var item: CoinNewsItem
    let network: WalletNetwork
    let unitLabel: String

    private(set) var state: State = .idle
    private(set) var comments: [CoinNewsComment] = []
    private(set) var pendingCommentIds: Set<String> = []
    /// Your vote on this story (nil = haven't voted). Immutable once set (first-wins on-chain).
    private(set) var myVote: VoteDirection?
    private(set) var isVoting = false
    private(set) var isPosting = false
    private(set) var actionError: String?
    var commentText: String = ""

    /// Your vote per COMMENT id (mirrors the persistent ledger; first-wins like the story vote).
    /// Comments are votable because each carries its own on-chain ItemID (`id`).
    private(set) var commentVotes: [String: VoteDirection] = [:]
    /// The comment id currently being voted on (for its inline spinner); nil if none.
    private(set) var votingCommentId: String? = nil
    /// The comment this composer is replying to (nil = a top-level comment on the story). Drives the
    /// reply banner + the parent id used at post time. Only INDEXED comments can be replied to (a
    /// pending comment has no real ItemID to address on-chain).
    private(set) var replyingTo: CoinNewsComment? = nil

    private let fetchItem: (String) async throws -> CoinNewsItem?
    private let fetchThread: (String) async throws -> [CoinNewsComment]
    private let vote: (_ targetIdHex: String, _ up: Bool) async throws -> WalletTx
    private let comment: (_ parentIdHex: String, _ body: String) async throws -> WalletTx
    private let pending: PendingCoinNewsStore
    private let authorize: (String) async -> Bool

    init(item: CoinNewsItem,
         network: WalletNetwork,
         unitLabel: String,
         fetchItem: @escaping (String) async throws -> CoinNewsItem?,
         fetchThread: @escaping (String) async throws -> [CoinNewsComment],
         vote: @escaping (_ targetIdHex: String, _ up: Bool) async throws -> WalletTx,
         comment: @escaping (_ parentIdHex: String, _ body: String) async throws -> WalletTx,
         pending: PendingCoinNewsStore,
         authorize: @escaping (String) async -> Bool = { _ in true }) {
        self.item = item
        self.network = network
        self.unitLabel = unitLabel
        self.fetchItem = fetchItem
        self.fetchThread = fetchThread
        self.vote = vote
        self.comment = comment
        self.pending = pending
        self.authorize = authorize
        self.myVote = pending.myVote(targetId: item.id, on: network)
    }

    func isPendingComment(_ id: String) -> Bool { pendingCommentIds.contains(id) }
    /// First-wins: once you've successfully voted, lock it. Votes dedup per (author, target) on-chain
    /// (§8) — a second vote can't change your first; it'd only cost another fee and do nothing. We
    /// gate on `myVote == nil` (set only after a successful broadcast), so a FAILED vote leaves you
    /// free to retry. The ▲/▼ keep showing your recorded choice.
    var canVote: Bool { myVote == nil && !isVoting }

    func load() async {
        if case .loaded = state { return }
        await reload()
    }

    func reload() async {
        state = .loading
        do {
            // Refresh the story itself (GetItem) so points + commentCount reflect the indexer, not
            // the stale feed snapshot. Best-effort — keep the snapshot if it can't be re-fetched.
            if let fresh = try? await fetchItem(item.id) { item = fresh }
            let fetched = try await fetchThread(item.id)
            pending.reconcileComments(fetched: fetched, on: network)
            // Show our optimistic comments that belong to this thread (reply to the story or to a
            // fetched comment), on top.
            let fetchedIds = Set(fetched.map { $0.id })
            let pend = pending.comments(on: network).filter {
                $0.parentHex == item.id || fetchedIds.contains($0.parentHex)
            }
            // Order so each reply sits under the comment it replies to (the view indents replies).
            comments = threadedOrder(pend + fetched)
            pendingCommentIds = Set(pend.map { $0.id })
            myVote = pending.myVote(targetId: item.id, on: network)
            // Mirror per-comment votes from the persistent ledger so each comment's arrows highlight.
            var cVotes: [String: VoteDirection] = [:]
            for c in comments {
                if let v = pending.myVote(targetId: c.id, on: network) { cVotes[c.id] = v }
            }
            commentVotes = cVotes
            state = .loaded
        } catch {
            state = .failed("Couldn't load the thread. Pull to retry.")
        }
    }

    func upvote() async { await castVote(.up) }
    func downvote() async { await castVote(.down) }

    private func castVote(_ dir: VoteDirection) async {
        guard canVote else { return }   // first-wins: one vote per item, no changes
        actionError = nil
        guard await authorize("Authorize this vote") else { return }
        isVoting = true
        do {
            _ = try await vote(item.id, dir == .up)
            pending.setVote(targetId: item.id, dir, on: network)
            myVote = dir
        } catch let error as WalletError {
            actionError = error.userMessage
        } catch {
            actionError = "Couldn't submit your vote. Please try again."
        }
        isVoting = false
    }

    func postComment() async {
        let body = commentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !isPosting else { return }
        actionError = nil
        guard await authorize("Authorize this comment") else { return }
        isPosting = true
        // Reply to a comment when one's selected (its on-chain ItemID), else the story.
        let parentId = replyingTo?.id ?? item.id
        do {
            let tx = try await comment(parentId, body)
            // Optimistic copy (local id by txid), reconciled by content when the indexer returns it.
            let local = CoinNewsComment(id: "pending:\(tx.txid)", parentHex: parentId, body: body)
            pending.addComment(local, on: network)
            // A reply goes directly under the comment it replies to; a top-level comment to the top.
            if parentId != item.id, let idx = comments.firstIndex(where: { $0.id == parentId }) {
                comments.insert(local, at: idx + 1)
            } else {
                comments.insert(local, at: 0)
            }
            pendingCommentIds.insert(local.id)
            commentText = ""
            replyingTo = nil
        } catch let error as WalletError {
            actionError = error.userMessage
        } catch {
            actionError = "Couldn't post your comment. Please try again."
        }
        isPosting = false
    }

    // MARK: - Per-comment vote + reply

    func commentVote(_ id: String) -> VoteDirection? { commentVotes[id] }
    func isVotingComment(_ id: String) -> Bool { votingCommentId == id }
    /// First-wins per comment (same rule as the story vote — §8 dedup). Locked once you've voted.
    func canVoteComment(_ id: String) -> Bool { commentVotes[id] == nil && votingCommentId == nil }

    /// Up/down vote a single comment (its own ItemID is the vote target). Same on-chain path as the
    /// story vote; first-wins (locked after a successful vote), one in flight at a time.
    func voteOnComment(_ comment: CoinNewsComment, _ dir: VoteDirection) async {
        guard canVoteComment(comment.id) else { return }
        actionError = nil
        guard await authorize("Authorize this vote") else { return }
        votingCommentId = comment.id
        do {
            _ = try await vote(comment.id, dir == .up)
            pending.setVote(targetId: comment.id, dir, on: network)
            commentVotes[comment.id] = dir
        } catch let error as WalletError {
            actionError = error.userMessage
        } catch {
            actionError = "Couldn't submit your vote. Please try again."
        }
        votingCommentId = nil
    }

    func startReply(to comment: CoinNewsComment) { replyingTo = comment }
    func cancelReply() { replyingTo = nil }

    // MARK: - Threading

    /// Flatten comments depth-first so each reply sits directly under the comment it replies to,
    /// top-level comments (parent = the story) first. The view indents replies one level. Orphans
    /// (parent not in the set) are appended so nothing is dropped.
    private func threadedOrder(_ all: [CoinNewsComment]) -> [CoinNewsComment] {
        var childrenByParent: [String: [CoinNewsComment]] = [:]
        for c in all { childrenByParent[c.parentHex, default: []].append(c) }
        var result: [CoinNewsComment] = []
        var visited = Set<String>()
        appendThread(parentId: item.id, childrenByParent: childrenByParent, into: &result, visited: &visited)
        for c in all where !visited.contains(c.id) {
            visited.insert(c.id)
            result.append(c)
        }
        return result
    }

    private func appendThread(parentId: String,
                              childrenByParent: [String: [CoinNewsComment]],
                              into result: inout [CoinNewsComment],
                              visited: inout Set<String>) {
        for c in (childrenByParent[parentId] ?? []) where !visited.contains(c.id) {
            visited.insert(c.id)
            result.append(c)
            appendThread(parentId: c.id, childrenByParent: childrenByParent, into: &result, visited: &visited)
        }
    }
}
