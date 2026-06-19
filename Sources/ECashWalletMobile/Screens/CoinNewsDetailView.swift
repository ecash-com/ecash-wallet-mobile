// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// CoinNews story detail (pushed from the feed): full body, an up/down vote, and the comment thread
/// with a chat-style composer pinned to the bottom (Telegram-like). The story's link, if any, lives
/// as a share/open action in the top-right toolbar. Votes/comments are signed on-chain `OP_RETURN`s
/// (small fee, bio-gated) that take ~10 min to index, so your comment shows immediately
/// ("Broadcasting…") and your vote is highlighted from the local ledger. A `List` (Compose
/// `LazyColumn`) holds the dynamic comment rows; the composer sits below it in the VStack so the
/// keyboard pushes it up (SwiftUI keyboard avoidance / Compose ime padding) — `safeAreaInset` is
/// unavailable in SkipUI.
struct CoinNewsDetailView: View {
    @Environment(\.openURL) var openURL   // not `private` — Fuse bridges view properties
    @State var vm: CoinNewsDetailViewModel
    @FocusState var composerFocused: Bool   // dismiss the keyboard on send

    init(viewModel: CoinNewsDetailViewModel) {
        _vm = State(initialValue: viewModel)
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                // Plain rows (no `Section`) so there are no section-header/footer surfaces to tint.
                // `.listRowBackground(.clear)` MUST be per-row (container-level doesn't propagate to
                // rows on-device) so rows show the single bg0 layer instead of the default black cell.
                storyHeader
                    .listRowBackground(Color.clear)
                    .hideTopRowSeparator()              // kill the divider right under the nav bar
                onChainNote
                    .listRowBackground(Color.clear)
                sectionHeader("Comments")
                    .listRowBackground(Color.clear)
                commentsSection
            }
            .listStyle(.plain)                          // flat — no inset-grouped card "bubbles"
            .themedFlatListBackground()                 // scrollContentBackground(.hidden) + bg0 base
            .scrollDismissesKeyboard(.interactively)    // drag the thread to dismiss the keyboard
            .refreshable { await vm.reload() }

            composerBar
        }
        .background(Theme.Colors.bg0)
        .inlineNavigationTitle()                        // compact bar (back + share), no title text
        .hideTabBar()                                   // full-height story detail — hide the tab bar
        .toolbar {
            if let url = storyURL {
                ToolbarItem(placement: .primaryAction) {
                    Button { openURL(url) } label: { Image(icon: Icon.link) }
                }
            }
        }
        .task { await vm.load() }
    }

    /// The story's external link, if it has a valid one (drives the toolbar share/open action).
    private var storyURL: URL? {
        guard let s = vm.item.url, !s.isEmpty, let url = URL(string: s) else { return nil }
        return url
    }

    // MARK: - Story header

    @ViewBuilder private var storyHeader: some View {
        VStack(alignment: .leading, spacing: Theme.Space.x3) {
            Text(verbatim: vm.item.headline)
                .textStyle(.h2)
                .foregroundStyle(Theme.Colors.text0)

            if let body = vm.item.body, !body.isEmpty {
                Text(LocalizedStringKey(stringLiteral: body))   // Markdown (links tappable → browser)
                    .textStyle(.body)
                    .foregroundStyle(Theme.Colors.text1)
            }

            voteRow
        }
        .padding(.vertical, Theme.Space.x2)
    }

    /// Reddit-style vote control: a single pill holding ▲ score ▼, the chosen direction tinted
    /// (up = brand accent, down = negative). Larger tap targets than the old bare glyphs.
    private var voteRow: some View {
        HStack(spacing: Theme.Space.x3) {
            HStack(spacing: Theme.Space.x3) {
                voteButton(up: true)
                Text(verbatim: "\(vm.item.points ?? 0)")
                    .textStyle(.body)
                    .foregroundStyle(Theme.Colors.text0)
                voteButton(up: false)
            }
            .padding(.horizontal, Theme.Space.x3)
            .padding(.vertical, Theme.Space.x2)
            .background(Theme.Colors.bg2, in: Capsule())

            if vm.isVoting { ProgressView() }
            Spacer()
        }
    }

    private func voteButton(up: Bool) -> some View {
        let selected = vm.myVote == (up ? .up : .down)
        let tint = up ? Theme.Colors.accent : Theme.Colors.negative
        return Button {
            Task { up ? await vm.upvote() : await vm.downvote() }
        } label: {
            Text(verbatim: up ? "▲" : "▼")
                .textStyle(.sm)
                .foregroundStyle(selected ? tint : Theme.Colors.text2)
                .frame(width: 28, height: 28)   // generous tap target
        }
        .buttonStyle(.plain)
        .disabled(!vm.canVote)
    }

    private var onChainNote: some View {
        Text("Votes and comments are on-chain — a small fee, live in ~10 min.",
             bundle: .module, comment: "on-chain cost note")
            .textStyle(.xs)
            .foregroundStyle(Theme.Colors.text2)
    }

    // MARK: - Comments

    @ViewBuilder private var commentsSection: some View {
        if vm.comments.isEmpty {
            Text("No comments yet. Be the first.", bundle: .module, comment: "empty thread")
                .textStyle(.sm).foregroundStyle(Theme.Colors.text2)
                .listRowBackground(Color.clear)
        } else {
            ForEach(vm.comments) { c in
                commentRow(c).listRowBackground(Color.clear)
            }
        }
    }

    private func commentRow(_ c: CoinNewsComment) -> some View {
        let isReply = c.parentHex != vm.item.id   // a reply to another comment → indent one level
        return VStack(alignment: .leading, spacing: Theme.Space.x2) {
            Text(LocalizedStringKey(stringLiteral: c.body))
                .textStyle(.body)
                .foregroundStyle(Theme.Colors.text0)
            HStack(spacing: Theme.Space.x3) {
                if let xpk = c.authorXpkHex, xpk.count >= 8 {
                    Text(verbatim: String(xpk.prefix(8)))
                        .textStyle(.xs)
                        .foregroundStyle(Theme.Colors.text2)
                }
                if vm.isPendingComment(c.id) {
                    // Not indexed yet → no real ItemID to reply to / vote on; show the badge only.
                    Text("Broadcasting…", bundle: .module, comment: "comment not yet indexed")
                        .textStyle(.xs)
                        .foregroundStyle(Theme.Colors.warning)
                } else {
                    commentVoteControl(c)
                    replyButton(c)
                }
                Spacer()
            }
        }
        .padding(.vertical, Theme.Space.x1)
        .padding(.leading, isReply ? Theme.Space.x4 : 0)
    }

    /// Compact up/down vote on a single comment. No count — the indexer doesn't expose a per-comment
    /// vote tally — so we only highlight the user's own choice (up = accent, down = negative).
    private func commentVoteControl(_ c: CoinNewsComment) -> some View {
        let mine = vm.commentVote(c.id)
        let voting = vm.isVotingComment(c.id)
        let locked = !vm.canVoteComment(c.id)   // first-wins: disabled once you've voted (or mid-vote)
        return HStack(spacing: Theme.Space.x1) {
            commentVoteButton(c, up: true, selected: mine == .up, disabled: locked)
            commentVoteButton(c, up: false, selected: mine == .down, disabled: locked)
            if voting { ProgressView() }
        }
    }

    private func commentVoteButton(_ c: CoinNewsComment, up: Bool, selected: Bool, disabled: Bool) -> some View {
        let tint = up ? Theme.Colors.accent : Theme.Colors.negative
        return Button {
            Task { await vm.voteOnComment(c, up ? .up : .down) }
        } label: {
            Text(verbatim: up ? "▲" : "▼")
                .textStyle(.xs)
                .foregroundStyle(selected ? tint : Theme.Colors.text2)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func replyButton(_ c: CoinNewsComment) -> some View {
        Button { vm.startReply(to: c) } label: {
            Text("Reply", bundle: .module, comment: "reply to a comment")
                .textStyle(.xs)
                .foregroundStyle(Theme.Colors.text1)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Composer (chat-style, pinned to the bottom)

    private var composerBar: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.Colors.border).frame(height: 1)

            if let message = actionErrorText {
                Text(verbatim: message)
                    .textStyle(.xs)
                    .foregroundStyle(Theme.Colors.negative)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.Space.x3)
                    .padding(.top, Theme.Space.x2)
            }

            if let target = vm.replyingTo {
                replyBanner(target)
            }

            HStack(alignment: .center, spacing: Theme.Space.x2) {
                TextField(vm.replyingTo == nil ? "Add a comment" : "Reply", text: $vm.commentText)
                    .textFieldStyle(.plain)
                    .textStyle(.body)
                    .foregroundStyle(Theme.Colors.text0)
                    .focused($composerFocused)
                    .fieldBoxInset()
                    .background(Theme.Colors.bg2, in: Capsule())
                sendButton
            }
            .padding(.horizontal, Theme.Space.x3)
            .padding(.vertical, Theme.Space.x2)
        }
        .background(Theme.Colors.bg0)   // uniform with the content; the top hairline separates it
    }

    /// "Replying to <snippet> ✕" banner above the composer when a comment is selected as the target.
    private func replyBanner(_ c: CoinNewsComment) -> some View {
        HStack(spacing: Theme.Space.x2) {
            Rectangle().fill(Theme.Colors.accent).frame(width: 2, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text("Replying to", bundle: .module, comment: "reply banner label")
                    .textStyle(.xs)
                    .foregroundStyle(Theme.Colors.text2)
                Text(verbatim: replySnippet(c.body))
                    .textStyle(.sm)
                    .foregroundStyle(Theme.Colors.text1)
            }
            Spacer()
            Button { vm.cancelReply() } label: {
                Image(icon: Icon.close).foregroundStyle(Theme.Colors.text2)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Theme.Space.x3)
        .padding(.top, Theme.Space.x2)
    }

    private func replySnippet(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 50 ? String(trimmed.prefix(50)) + "…" : trimmed
    }

    private var sendButton: some View {
        let disabled = vm.commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.isPosting
        return Button {
            composerFocused = false   // close the keyboard on send
            Task { await vm.postComment() }
        } label: {
            ZStack {
                Circle()
                    .fill(disabled ? Theme.Colors.bg2 : Theme.Colors.accent)
                    .frame(width: 36, height: 36)
                if vm.isPosting {
                    ProgressView()
                } else {
                    Text(verbatim: "↑")
                        .textStyle(.body)
                        .foregroundStyle(disabled ? Theme.Colors.text2 : Theme.Colors.accentText)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private var actionErrorText: String? {
        if case .failed = vm.state { return nil }   // load error handled elsewhere
        return vm.actionError
    }

    private func sectionHeader(_ key: LocalizedStringKey) -> some View {
        Text(key, bundle: .module).textStyle(.overline).foregroundStyle(Theme.Colors.text1)
    }
}
