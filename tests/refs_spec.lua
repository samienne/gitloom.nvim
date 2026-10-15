--- Tests for gitloom.graph classify_ref — full refname → (kind, name) —
--- and group_refs — collapsing branch refs that share a short name for display.

local internal = require("gitloom.graph")._internal
local classify_ref = internal.classify_ref
local group_refs = internal.group_refs
local track_segments = internal.track_segments
local track_label = internal.track_label
local ref_picker_items = internal.ref_picker_items
local owners_from_refs = internal.owners_from_refs
local next_mode = internal.next_mode
local selected_owner_ids = internal.selected_owner_ids
local toggle_target = internal.toggle_target
local parse_worktrees = internal.parse_worktrees
local worktree_refs = internal.worktree_refs
local decoration_texts = internal.decoration_texts
local ref_decoration_index = internal.ref_decoration_index

describe("classify_ref", function()
    it("classifies a local branch", function()
        local kind, name = classify_ref("refs/heads/master")
        assert.equals("local", kind)
        assert.equals("master", name)
    end)

    it("keeps the slashes in a local branch name", function()
        local kind, name = classify_ref("refs/heads/feature/lane-model")
        assert.equals("local", kind)
        assert.equals("feature/lane-model", name)
    end)

    it("classifies a remote branch, keeping the remote prefix", function()
        local kind, name = classify_ref("refs/remotes/origin/master")
        assert.equals("remote", kind)
        assert.equals("origin/master", name)
    end)

    it("skips a remote's HEAD symref", function()
        assert.is_nil(classify_ref("refs/remotes/origin/HEAD"))
    end)

    it("classifies a tag", function()
        local kind, name = classify_ref("refs/tags/v1.0")
        assert.equals("tag", kind)
        assert.equals("v1.0", name)
    end)

    it("returns nil for refs it doesn't render", function()
        assert.is_nil(classify_ref("refs/stash"))
        assert.is_nil(classify_ref("HEAD"))
    end)
end)

describe("group_refs", function()
    local function ref(kind, name) return { kind = kind, name = name } end

    it("collapses a local branch and its remotes into one group", function()
        local g = group_refs({
            ref("local", "mybranch"),
            ref("remote", "origin/mybranch"),
            ref("remote", "otherremote/mybranch"),
        })
        assert.is_false(g.head)
        assert.equals(1, #g.branches)
        assert.equals("mybranch", g.branches[1].name)
        assert.is_true(g.branches[1].has_local)
        assert.same({ "origin", "otherremote" }, g.branches[1].remotes)
    end)

    it("marks a remote-only group as not local", function()
        local g = group_refs({
            ref("remote", "origin/feature"),
            ref("remote", "fork/feature"),
        })
        assert.equals(1, #g.branches)
        assert.is_false(g.branches[1].has_local)
        assert.same({ "origin", "fork" }, g.branches[1].remotes)
    end)

    it("keeps a slashed branch name, splitting only the remote", function()
        local g = group_refs({ ref("remote", "origin/feature/foo") })
        assert.equals("feature/foo", g.branches[1].name)
        assert.same({ "origin" }, g.branches[1].remotes)
    end)

    it("keeps branches with different names in separate groups", function()
        local g = group_refs({
            ref("local", "main"),
            ref("remote", "origin/dev"),
        })
        assert.equals(2, #g.branches)
        assert.equals("main", g.branches[1].name)
        assert.equals("dev", g.branches[2].name)
        assert.same({ "origin" }, g.branches[2].remotes)
    end)

    it("separates HEAD and tags from branch groups", function()
        local g = group_refs({
            ref("head", "HEAD"),
            ref("local", "main"),
            ref("tag", "v1.0"),
        })
        assert.is_true(g.head)
        assert.equals(1, #g.branches)
        assert.is_true(g.branches[1].has_local)
        assert.same({}, g.branches[1].remotes)
        assert.same({ "v1.0" }, g.tags)
    end)

    it("carries a local branch's upstream divergence onto its group (§6.3)", function()
        local up = { short = "origin/main", ahead = 2, behind = 3, gone = false }
        local g = group_refs({
            { kind = "local", name = "main", upstream = up },
        })
        assert.equals(up, g.branches[1].track)
    end)

    it("leaves track nil for an untracked branch or a remote-only group", function()
        local g = group_refs({
            ref("local", "feature"),
            ref("remote", "origin/other"),
        })
        for _, b in ipairs(g.branches) do assert.is_nil(b.track) end
    end)

    -- §6: HEAD's label goes first, so every consumer of this order agrees on it.
    it("moves the branch HEAD is on to the front and flags it current", function()
        local g = group_refs({
            ref("local", "alpha"),
            ref("remote", "origin/feat"),
            ref("local", "feat"),
            { kind = "head", name = "HEAD", branch = "feat" },
            ref("tag", "v1"),
        })
        assert.equals("feat", g.branches[1].name)
        assert.is_true(g.branches[1].current)
        assert.equals(g.branches[1], g.current)
        assert.same({ "origin" }, g.branches[1].remotes) -- its remotes ride along
        assert.equals("alpha", g.branches[2].name)
        assert.is_nil(g.branches[2].current)
    end)

    it("takes the current branch from the fallback when the head ref names none", function()
        local g = group_refs({ ref("local", "alpha"), ref("local", "feat"), ref("head", "HEAD") }, "feat")
        assert.equals("feat", g.current and g.current.name)
        assert.equals("feat", g.branches[1].name)
    end)

    it("has no current group on a detached HEAD or a commit HEAD is not on", function()
        assert.is_nil(group_refs({ ref("local", "main"), ref("head", "HEAD") }).current)
        -- The fallback names a branch, but no HEAD marker is on this commit.
        local g = group_refs({ ref("local", "alpha"), ref("local", "main") }, "main")
        assert.is_nil(g.current)
        assert.equals("alpha", g.branches[1].name) -- order untouched
    end)
end)

describe("head_summary (§10.4.1)", function()
    local head_summary = require("gitloom.git").head_summary
    it("names the branch and the short hash when attached", function()
        assert.equals("HEAD → main (0123456)", head_summary("main", "0123456789abcdef"))
    end)
    it("says detached with the short hash otherwise", function()
        assert.equals("HEAD detached at 0123456", head_summary(nil, "0123456789abcdef"))
    end)
    it("is nil with no HEAD commit", function()
        assert.is_nil(head_summary("main", nil))
    end)
    it("appends how far behind the upstream a checked-out branch is", function()
        local function u(a, b, gone)
            return { short = "origin/main", ref = "refs/remotes/origin/main", ahead = a, behind = b,
                gone = gone or false }
        end
        local h = "0123456789abcdef"
        assert.equals("HEAD → main (0123456) — 12 behind origin/main", head_summary("main", h, u(0, 12)))
        assert.equals("HEAD → main (0123456) — 3 ahead, 12 behind origin/main",
            head_summary("main", h, u(3, 12)))
        -- Ahead only, in sync, gone, no upstream: nothing appended.
        for _, up in ipairs({ u(3, 0), u(0, 0), u(0, 12, true) }) do
            assert.equals("HEAD → main (0123456)", head_summary("main", h, up))
        end
        assert.equals("HEAD → main (0123456)", head_summary("main", h, nil))
        -- Detached: never (a stray upstream is ignored).
        assert.equals("HEAD detached at 0123456", head_summary(nil, h, u(0, 12)))
    end)
end)

describe("track_segments / track_label (§6.3)", function()
    it("is empty for no upstream or an in-sync branch", function()
        assert.same({}, track_segments(nil))
        assert.same({}, track_segments({ short = "origin/x", ahead = 0, behind = 0 }))
        assert.equals("", track_label(nil))
        assert.equals("", track_label({ short = "origin/x", ahead = 0, behind = 0 }))
    end)

    it("shows ahead only", function()
        assert.same({ { text = " ⇡2", kind = "ahead" } },
            track_segments({ short = "o/x", ahead = 2, behind = 0 }))
        assert.equals(" ⇡2", track_label({ short = "o/x", ahead = 2, behind = 0 }))
    end)

    it("shows behind only", function()
        assert.same({ { text = " ⇣3", kind = "behind" } },
            track_segments({ short = "o/x", ahead = 0, behind = 3 }))
        assert.equals(" ⇣3", track_label({ short = "o/x", ahead = 0, behind = 3 }))
    end)

    it("shows diverged as ⇡N⇣M with no inner space", function()
        local segs = track_segments({ short = "o/x", ahead = 2, behind = 3 })
        assert.same({ { text = " ⇡2", kind = "ahead" }, { text = "⇣3", kind = "behind" } }, segs)
        -- track_label is exactly the concatenation (byte-identical for selection).
        assert.equals(" ⇡2⇣3", track_label({ short = "o/x", ahead = 2, behind = 3 }))
    end)

    it("shows a gone upstream", function()
        assert.same({ { text = " gone", kind = "gone" } },
            track_segments({ short = "o/x", ahead = 0, behind = 0, gone = true }))
        assert.equals(" gone", track_label({ short = "o/x", gone = true }))
    end)

    it("the label is the concatenation of the segment texts", function()
        local up = { short = "o/x", ahead = 5, behind = 1 }
        local cat = ""
        for _, s in ipairs(track_segments(up)) do cat = cat .. s.text end
        assert.equals(track_label(up), cat)
    end)
end)

describe("decoration_texts upstream (§6.3)", function()
    local decoration_texts = internal.decoration_texts

    it("appends the divergence indicator to a tracked branch decoration", function()
        local up = { short = "origin/main", ahead = 2, behind = 3 }
        local commit = { refs = { { kind = "local", name = "main", upstream = up } } }
        assert.same({ "(main ⇡2⇣3)" }, decoration_texts(commit))
    end)

    it("shows the indicator alongside remotes at the same commit", function()
        local up = { short = "origin/main", ahead = 1, behind = 0 }
        local commit = { refs = {
            { kind = "local", name = "main", upstream = up },
            { kind = "remote", name = "fork/main" },
        } }
        assert.same({ "(main ↑fork ⇡1)" }, decoration_texts(commit))
    end)

    it("adds nothing when the branch is in sync or untracked", function()
        local synced = { refs = { { kind = "local", name = "main",
            upstream = { short = "o/m", ahead = 0, behind = 0 } } } }
        assert.same({ "(main)" }, decoration_texts(synced))
        local untracked = { refs = { { kind = "local", name = "main" } } }
        assert.same({ "(main)" }, decoration_texts(untracked))
    end)

    it("lists the current branch FIRST as `(HEAD → name …)` (§6)", function()
        local commit = { refs = {
            { kind = "local", name = "alpha" },
            { kind = "tag", name = "v1" },
            { kind = "local", name = "main", upstream = { short = "origin/main", ahead = 1, behind = 0 } },
            { kind = "remote", name = "origin/main" },
            { kind = "head", name = "HEAD", branch = "main" },
        } }
        assert.same({ "(HEAD → main ↑origin ⇡1)", "(alpha)", "[v1]" }, decoration_texts(commit))
    end)

    it("does not list a detached HEAD (its bare `HEAD` is not selectable)", function()
        local commit = { refs = { { kind = "local", name = "alpha" }, { kind = "head", name = "HEAD" } } }
        assert.same({ "(alpha)" }, decoration_texts(commit))
    end)
end)

describe("ref_picker_items upstream (§6.3)", function()
    it("carries each ref's upstream through to the picker item", function()
        local up = { short = "origin/main", ahead = 1, behind = 0, gone = false }
        local commit = { hash = ("a"):rep(40), message = "subject" }
        local refs = {
            main = { kind = "local", name = "main", commit = commit, upstream = up },
            ["origin/main"] = { kind = "remote", name = "origin/main", commit = commit },
        }
        local items = ref_picker_items(refs, {})
        local by_name = {}
        for _, it in ipairs(items) do by_name[it.name] = it end
        assert.equals(up, by_name["main"].track)
        assert.is_nil(by_name["origin/main"].track) -- remotes don't track
    end)
end)

describe("pane_labels (header/footer §6.2)", function()
    local pane_labels = internal.pane_labels
    local function ref(kind, name) return { kind = kind, name = name } end
    -- Segments → plain text / kind lists (pane_labels returns { text, kind } so each
    -- label can be coloured by kind the same as the main view).
    local function texts(segs) local t = {} for _, s in ipairs(segs) do t[#t + 1] = s.text end return t end
    local function kinds(segs) local t = {} for _, s in ipairs(segs) do t[#t + 1] = s.kind end return t end

    it("draws the current branch as one `HEAD → name` label in the HEAD colour", function()
        -- HEAD points at `feature/topic`, both on the same commit. The pane shows
        -- one label naming both, coloured as HEAD ("you are here").
        local segs = pane_labels({ refs = {
            ref("local", "feature/topic"),
            ref("head", "HEAD"),
        } }, "feature/topic")
        assert.same({ "(HEAD → feature/topic)" }, texts(segs))
        assert.same({ "head" }, kinds(segs)) -- coloured as HEAD
    end)

    it("reads the current branch off the head ref's `branch` with no fallback", function()
        local segs = pane_labels({ refs = {
            ref("local", "alpha"),
            ref("local", "feat"),
            { kind = "head", name = "HEAD", branch = "feat" }, ---@diagnostic disable-line: missing-fields
        } })
        assert.same({ "(HEAD → feat)", "(alpha)" }, texts(segs)) -- HEAD first
        assert.same({ "head", "branch" }, kinds(segs))
    end)

    it("carries the current branch's remote-tracking ref into its head-coloured group", function()
        local segs = pane_labels({ refs = {
            ref("local", "feat"),
            ref("remote", "origin/feat"),
            ref("head", "HEAD"),
        } }, "feat")
        assert.same({ "(HEAD → feat ↑origin)" }, texts(segs))
        assert.same({ "head" }, kinds(segs))
    end)

    it("keeps ANOTHER pinned anchor on HEAD's commit beside the head-coloured branch", function()
        -- HEAD is on `feat`, but pinned `release` also lands here — show both; only
        -- `feat` takes the HEAD colour, `release` its own branch colour.
        local segs = pane_labels({ refs = {
            ref("local", "release"),
            ref("local", "feat"),
            ref("head", "HEAD"),
        } }, "feat")
        assert.same({ "(HEAD → feat)", "(release)" }, texts(segs)) -- HEAD's label first
        assert.same({ "head", "branch" }, kinds(segs))
    end)

    it("colours a remote-only branch and a tag by their own kind", function()
        local segs = pane_labels({ refs = {
            ref("remote", "origin/feat"),
            ref("tag", "v1.0"),
        } })
        assert.same({ "(feat ↑origin)", "[v1.0]" }, texts(segs))
        assert.same({ "remote", "tag" }, kinds(segs))
    end)

    it("shows a detached HEAD as HEAD even with no branch on the commit", function()
        local segs = pane_labels({ refs = { ref("head", "HEAD") } }, nil)
        assert.same({ "HEAD" }, texts(segs))
    end)

    it("omits HEAD when the commit has no HEAD marker (just branches/tags)", function()
        local segs = pane_labels({ refs = { ref("local", "feat"), ref("tag", "v1.0") } })
        assert.same({ "(feat)", "[v1.0]" }, texts(segs)) -- same text as decoration_texts
    end)
end)

describe("owners_from_refs", function()
    -- The view builder's owner list (spec §10): one owner per ref, keyed by ref
    -- name, carrying its current mode; the HEAD symref is skipped.
    local function refs(spec)
        local out = {}
        for name, r in pairs(spec) do
            out[name] = { name = name, kind = r.kind, commit = { hash = r.hash } }
        end
        return out
    end

    it("emits one owner per ref, defaulting to normal", function()
        local owners = owners_from_refs(refs({
            main = { kind = "local", hash = "a" },
            ["origin/main"] = { kind = "remote", hash = "a" },
        }), {})
        assert.equals(2, #owners)
        local by_id = {}
        for _, o in ipairs(owners) do by_id[o.id] = o end
        assert.equals("a", by_id.main.tip.hash)
        assert.equals("normal", by_id.main.mode)
        assert.equals("normal", by_id["origin/main"].mode)
    end)

    it("applies the mode keyed by ref name", function()
        local owners = owners_from_refs(refs({
            feat = { kind = "local", hash = "f" },
            main = { kind = "local", hash = "m" },
        }), { feat = "collapsed" })
        local mode = {}
        for _, o in ipairs(owners) do mode[o.id] = o.mode end
        assert.equals("collapsed", mode.feat)
        assert.equals("normal", mode.main)
    end)

    it("skips an attached HEAD marker (it is a symref onto a branch already present)", function()
        local r = refs({
            HEAD = { kind = "head", hash = "m" },
            main = { kind = "local", hash = "m" },
        })
        r.HEAD.branch = "main"
        local owners = owners_from_refs(r, {})
        assert.equals(1, #owners)
        assert.equals("main", owners[1].id)
    end)

    it("makes a detached HEAD an owner of its own, id `HEAD` (§10.6)", function()
        local owners = owners_from_refs(refs({
            HEAD = { kind = "head", hash = "d" },
            main = { kind = "local", hash = "m" },
        }), { HEAD = "collapsed" })
        local by_id = {}
        for _, o in ipairs(owners) do by_id[o.id] = o end
        assert.equals(2, #owners)
        assert.equals("d", by_id.HEAD.tip.hash)
        assert.equals("collapsed", by_id.HEAD.mode) -- an override keyed `HEAD` applies
    end)
end)

describe("branch-mode toggle helpers", function()
    local function commit(spec)
        local out = {}
        for _, r in ipairs(spec) do out[#out + 1] = { kind = r[1], name = r[2] } end
        return { refs = out }
    end

    it("next_mode cycles normal → collapsed → hidden → normal", function()
        assert.equals("collapsed", next_mode(nil))
        assert.equals("collapsed", next_mode("normal"))
        assert.equals("hidden", next_mode("collapsed"))
        assert.equals("normal", next_mode("hidden"))
    end)

    it("selected_owner_ids maps a branch group to its local + remote owners", function()
        local c = commit({ { "local", "main" }, { "remote", "origin/main" } })
        assert.same({ "main", "origin/main" }, selected_owner_ids(c, 1))
    end)

    it("selected_owner_ids maps a remote-only group to its remote owner", function()
        local c = commit({ { "remote", "origin/feature" } })
        assert.same({ "origin/feature" }, selected_owner_ids(c, 1))
    end)

    it("selected_owner_ids maps a tag decoration (after the branches)", function()
        local c = commit({ { "local", "main" }, { "tag", "v1.0" } })
        assert.same({ "v1.0" }, selected_owner_ids(c, 2))
    end)

    it("selected_owner_ids is nil out of range", function()
        assert.is_nil(selected_owner_ids(commit({ { "local", "main" } }), 5))
    end)

    -- The collapse target (§10.4) on a plain table of sets: `toggle_target`
    -- with every owner tipped at the row itself (so every owner is own).
    local function target(sig, pinned, effective)
        local tip_of = {}
        for oid in pairs(sig) do tip_of[oid] = "c" end
        return toggle_target({ c = sig }, "c", tip_of, pinned, effective, false)
    end

    it("toggle_target is mainline for a commit an anchor reaches", function()
        local t = target({ trunk = true, feat = true }, { trunk = true }, { trunk = "normal", feat = "normal" })
        assert.equals("mainline", t.state)
        assert.same({ "trunk" }, t.anchors)
    end)

    it("toggle_target collapses the non-anchor normal own owners off the mainline", function()
        -- feat is normal (keeps it visible); the merge owner is already collapsed
        local t = target({ feat = true, ["merge:m:2"] = true }, { trunk = true },
            { feat = "normal", ["merge:m:2"] = "collapsed" })
        assert.equals("expanded", t.state)
        assert.same({ "feat" }, t.owners)
    end)

    it("toggle_target has nothing to collapse when nothing normal keeps the commit visible", function()
        assert.same({}, target({ feat = true }, { trunk = true }, { feat = "collapsed" }).owners)
    end)

    it("toggle_target treats every pinned anchor as mainline (§10.6)", function()
        -- two anchors; a commit reached by either is mainline (not collapsible),
        -- even if a non-anchor ref also reaches it.
        assert.equals("mainline", target({ dev = true, feat = true }, { trunk = true, dev = true },
            { dev = "normal", feat = "normal" }).state)
        -- off both anchors: feat alone keeps it visible, so it is collapsible.
        assert.same({ "feat" }, target({ feat = true }, { trunk = true, dev = true },
            { feat = "normal" }).owners)
    end)
end)

describe("parse_worktrees (§3.2)", function()
    -- `git worktree list --porcelain`: blank-line-separated stanzas, each opening
    -- with `worktree <path>`.
    local PORCELAIN = {
        "worktree /repo",
        "HEAD 1111111111111111111111111111111111111111",
        "branch refs/heads/master",
        "",
        "worktree /repo/wt/feature",
        "HEAD 2222222222222222222222222222222222222222",
        "branch refs/heads/feature",
        "",
        "worktree /repo/wt/scratch",
        "HEAD 3333333333333333333333333333333333333333",
        "detached",
        "",
        "worktree /repo/wt/bare",
        "bare",
        "",
    }

    it("splits the stanzas, marking the first as the main worktree", function()
        local w = parse_worktrees(PORCELAIN)
        assert.equals(4, #w)
        assert.is_true(w[1].main)
        assert.is_false(w[2].main)
        assert.same({ "/repo", "/repo/wt/feature", "/repo/wt/scratch", "/repo/wt/bare" },
            { w[1].path, w[2].path, w[3].path, w[4].path })
    end)

    it("takes the name from the path basename", function()
        local w = parse_worktrees(PORCELAIN)
        assert.same({ "repo", "feature", "scratch", "bare" },
            { w[1].name, w[2].name, w[3].name, w[4].name })
    end)

    it("parses a Windows path the same way", function()
        local w = parse_worktrees({ "worktree C:/src/reactive-wt/stackA-clean",
            "HEAD 4444444444444444444444444444444444444444", "detached" })
        assert.equals("stackA-clean", w[1].name)
    end)

    it("backslashes are a separator too", function()
        local w = parse_worktrees({ [[worktree C:\src\wt\thing]], "detached" })
        assert.equals("thing", w[1].name)
    end)

    it("derives detached from a HEAD with no branch", function()
        local w = parse_worktrees(PORCELAIN)
        assert.is_false(w[2].detached) -- on a branch
        assert.is_true(w[3].detached)  -- detached
        assert.is_false(w[4].detached) -- bare: no HEAD at all
    end)

    it("flags a bare worktree and gives it no HEAD", function()
        local w = parse_worktrees(PORCELAIN)
        assert.is_true(w[4].bare)
        assert.is_nil(w[4].head)
        assert.is_false(w[1].bare)
    end)

    it("reads the branch refname and the HEAD hash", function()
        local w = parse_worktrees(PORCELAIN)
        assert.equals("refs/heads/master", w[1].branch)
        assert.equals(("1"):rep(40), w[1].head)
        assert.is_nil(w[3].branch)
    end)

    it("is empty for no input", function()
        assert.same({}, parse_worktrees(nil))
        assert.same({}, parse_worktrees({}))
    end)
end)

describe("worktree_refs — linked worktree HEADs as refs (§3.2)", function()
    local A, B, C = ("a"):rep(40), ("b"):rep(40), ("c"):rep(40)
    local function wt(path, head, main, bare)
        return { path = path, name = path:match("([^/\\]+)$"), head = head,
            main = main or false, bare = bare or false }
    end

    it("labels a linked worktree HEAD wt:<basename>", function()
        local out = worktree_refs({ wt("/repo", A, true), wt("/repo/wt/scratch", B) }, { [A] = true })
        assert.equals(1, #out)
        assert.same({ name = "wt:scratch", kind = "worktree", hash = B }, out[1])
    end)

    it("skips the main worktree — its HEAD is already the head ref", function()
        -- Main is skipped even when nothing else points at its commit.
        assert.same({}, worktree_refs({ wt("/repo", A, true) }, {}))
    end)

    it("skips a worktree whose HEAD any existing ref already points at", function()
        -- The general form of "do not add it if there is a matching branch":
        -- a worktree checked out on a branch, or a detached HEAD parked on a tip.
        assert.same({}, worktree_refs({ wt("/repo", A, true), wt("/repo/wt/feat", B) },
            { [A] = true, [B] = true }))
    end)

    it("skips a bare worktree and a stanza with no HEAD", function()
        local out = worktree_refs({
            wt("/repo", A, true),
            wt("/repo/wt/bare", nil, false, true),
            wt("/repo/wt/headless", nil),
        }, { [A] = true })
        assert.same({}, out)
    end)

    it("emits one label when two worktrees sit on the same commit", function()
        local out = worktree_refs({
            wt("/repo", A, true), wt("/repo/wt/one", B), wt("/repo/wt/two", B),
        }, { [A] = true })
        assert.equals(1, #out)
        assert.equals("wt:one", out[1].name) -- first wins, in porcelain order
    end)

    it("does not mutate the caller's taken set", function()
        local taken = { [A] = true }
        worktree_refs({ wt("/repo", A, true), wt("/repo/wt/x", B) }, taken)
        assert.is_nil(taken[B])
    end)

    it("is empty for a repository with no linked worktrees", function()
        assert.same({}, worktree_refs(nil, nil))
        assert.same({}, worktree_refs({}, {}))
    end)

    it("a worktree named like a branch still gets its own registry key", function()
        -- The label is `wt:master`, not `master`, so it can never overwrite the
        -- real branch in the name → Ref registry (a `:` is invalid in a refname,
        -- so no real ref can produce this key either).
        local out = worktree_refs({ wt("/repo", A, true), wt("/repo/wt/master", C) }, { [A] = true })
        assert.equals("wt:master", out[1].name)
    end)
end)

describe("worktree ref display + selection (§3.2/§6)", function()
    local function commit(refs) return { refs = refs } end
    local WT = { kind = "worktree", name = "wt:stackA-clean" }

    it("group_refs keeps worktree labels in their own bucket", function()
        local g = group_refs({ { kind = "local", name = "main" }, { kind = "tag", name = "v1" }, WT })
        assert.equals(1, #g.branches)
        assert.same({ "v1" }, g.tags)
        assert.same({ "wt:stackA-clean" }, g.worktrees)
    end)

    it("group_refs.worktrees is empty (not nil) with none present", function()
        assert.same({}, group_refs({ { kind = "local", name = "main" } }).worktrees)
    end)

    it("decoration_texts renders it as {wt:<dir>}, after the tags", function()
        assert.same({ "(main)", "[v1]", "{wt:stackA-clean}" },
            decoration_texts(commit({ { kind = "local", name = "main" },
                { kind = "tag", name = "v1" }, WT })))
    end)

    it("a lone worktree label is the only decoration", function()
        assert.same({ "{wt:stackA-clean}" }, decoration_texts(commit({ WT })))
    end)

    it("ref_decoration_index finds it after the branches and tags", function()
        local c = commit({ { kind = "local", name = "main" }, { kind = "tag", name = "v1" }, WT })
        assert.equals(3, ref_decoration_index(c, "wt:stackA-clean", "worktree"))
        assert.equals(1, ref_decoration_index(c, "main", "local"))
        assert.equals(2, ref_decoration_index(c, "v1", "tag"))
        assert.is_nil(ref_decoration_index(c, "wt:absent", "worktree"))
    end)

    it("selected_owner_ids maps the decoration back to the worktree owner", function()
        local c = commit({ { kind = "local", name = "main" }, { kind = "tag", name = "v1" }, WT })
        assert.same({ "main" }, selected_owner_ids(c, 1))
        assert.same({ "v1" }, selected_owner_ids(c, 2))
        assert.same({ "wt:stackA-clean" }, selected_owner_ids(c, 3))
        assert.is_nil(selected_owner_ids(c, 4))
    end)

    it("owners_from_refs makes a worktree ref an owner like any other", function()
        local tip = { hash = "h1", parents = {}, children = {}, refs = {} }
        local os = owners_from_refs(
            { ["wt:scratch"] = { kind = "worktree", name = "wt:scratch", commit = tip } }, {})
        assert.equals(1, #os)
        assert.equals("wt:scratch", os[1].id)
        assert.equals(tip, os[1].tip)
    end)
end)

describe("pane_labels — worktree labels (§3.2/§6.2)", function()
    local pane_labels = internal.pane_labels
    local function ref(kind, name) return { kind = kind, name = name } end
    it("emits the {wt:<dir>} label with its own kind, after the tags", function()
        local segs = pane_labels({ refs = {
            ref("local", "main"),
            ref("tag", "v1"),
            ref("worktree", "wt:scratch"),
        } }, "other")
        local t, k = {}, {}
        for _, s in ipairs(segs) do t[#t + 1] = s.text; k[#k + 1] = s.kind end
        assert.same({ "(main)", "[v1]", "{wt:scratch}" }, t)
        assert.same({ "branch", "tag", "worktree" }, k)
    end)
end)

describe("pin icon on pinned labels (§6/§10.6)", function()
    local pane_labels = internal.pane_labels
    local marker_units = internal.marker_units
    local function ref(kind, name, extra)
        local r = { kind = kind, name = name }
        for k, v in pairs(extra or {}) do r[k] = v end
        return r
    end
    local PINS = { set = { dev = true, ["origin/rel"] = true, v1 = true, ["wt:rev"] = true, main = true },
        icon = "⚲" }

    it("prefixes a pinned ref's label inside its bracket; unpinned labels are untouched", function()
        local commit = { refs = {
            ref("local", "dev"), ref("remote", "origin/dev"),
            ref("local", "feat"),
            ref("tag", "v1"), ref("tag", "v2"),
            ref("worktree", "wt:rev"),
        } }
        assert.same({ "(⚲dev ↑origin)", "(feat)", "[⚲v1]", "[v2]", "{⚲wt:rev}" },
            decoration_texts(commit, nil, PINS))
        -- No pin set → today's labels.
        assert.same({ "(dev ↑origin)", "(feat)", "[v1]", "[v2]", "{wt:rev}" }, decoration_texts(commit))
    end)

    it("marks a group when only one of its remote refs is pinned (an implicit counterpart)", function()
        local commit = { refs = { ref("local", "rel"), ref("remote", "origin/rel") } }
        assert.same({ "(⚲rel ↑origin)" }, decoration_texts(commit, nil, PINS))
        -- A remote-only group is marked by its remote ref, never by a same-named local elsewhere.
        assert.same({ "(⚲rel ↑origin)" }, decoration_texts({ refs = { ref("remote", "origin/rel") } }, nil, PINS))
        assert.same({ "(dev ↑up)" }, decoration_texts({ refs = { ref("remote", "up/dev") } }, nil, PINS))
    end)

    it("never marks HEAD's label, attached or detached, though HEAD's branch is pinned", function()
        local attached = { refs = { ref("local", "main"), ref("local", "dev"), ref("head", "HEAD", { branch = "main" }) } }
        assert.same({ "(HEAD → main)", "(⚲dev)" }, decoration_texts(attached, nil, PINS))
        local segs = pane_labels({ refs = { ref("local", "dev"), ref("head", "HEAD") } }, nil, PINS)
        assert.same("HEAD", segs[1].text)
        assert.same("(⚲dev)", segs[2].text)
    end)

    it("icon \"\" turns it off", function()
        local commit = { refs = { ref("local", "dev") } }
        assert.same({ "(dev)" }, decoration_texts(commit, nil, { set = PINS.set, icon = "" }))
    end)

    it("pane labels and packed marker units carry the same icon", function()
        local segs = pane_labels({ refs = { ref("local", "dev"), ref("tag", "v2") } }, nil, PINS)
        assert.same({ "(⚲dev)", "[v2]" }, { segs[1].text, segs[2].text })
        local item = { type = "markers", markers = {
            { hash = "x", collapsed = true, count = 2, refs = { ref("local", "dev") } },
            { hash = "y", collapsed = true, count = 3, refs = { ref("local", "feat") } },
        } }
        local units = marker_units(item, PINS)
        assert.same({ "(⚲dev)", "(feat)" }, { units[1].text, units[2].text })
    end)
end)

describe("expanded marker on user-opened labels (§6)", function()
    local pane_labels = internal.pane_labels
    local marker_units = internal.marker_units
    local function ref(kind, name, extra)
        local r = { kind = kind, name = name }
        for k, v in pairs(extra or {}) do r[k] = v end
        return r
    end
    local MARKS = { set = { main = true, dev = true }, icon = "⚲",
        expanded = { feat = true, ["origin/rel"] = true, v1 = true, ["wt:rev"] = true, main = true },
        expanded_icon = "▾" }

    it("prefixes an expanded ref's label inside its bracket, in every bracket kind", function()
        local commit = { refs = {
            ref("local", "feat"), ref("remote", "origin/feat"),
            ref("local", "other"),
            ref("tag", "v1"), ref("tag", "v2"),
            ref("worktree", "wt:rev"),
        } }
        assert.same({ "(▾feat ↑origin)", "(other)", "[▾v1]", "[v2]", "{▾wt:rev}" },
            decoration_texts(commit, nil, MARKS))
    end)

    it("a branch group is marked when any ref in it is expanded", function()
        local commit = { refs = { ref("local", "rel"), ref("remote", "origin/rel") } }
        assert.same({ "(▾rel ↑origin)" }, decoration_texts(commit, nil, MARKS))
    end)

    it("goes after the pin icon when both apply", function()
        local commit = { refs = { ref("local", "dev") } }
        local both = { set = { dev = true }, icon = "⚲", expanded = { dev = true } }
        assert.same({ "(⚲▾dev)" }, decoration_texts(commit, nil, both))
    end)

    it("defaults to ▾ and \"\" turns it off", function()
        local commit = { refs = { ref("local", "feat") } }
        assert.same({ "(▾feat)" }, decoration_texts(commit, nil, { set = {}, expanded = { feat = true } }))
        assert.same({ "(feat)" }, decoration_texts(commit, nil,
            { set = {}, expanded = { feat = true }, expanded_icon = "" }))
    end)

    it("never marks HEAD's label", function()
        local attached = { refs = { ref("local", "main"), ref("local", "feat"), ref("head", "HEAD", { branch = "main" }) } }
        assert.same({ "(HEAD → main)", "(▾feat)" }, decoration_texts(attached, nil, MARKS))
    end)

    it("pane labels and packed marker units carry it too", function()
        local segs = pane_labels({ refs = { ref("local", "feat"), ref("tag", "v2") } }, nil, MARKS)
        assert.same({ "(▾feat)", "[v2]" }, { segs[1].text, segs[2].text })
        local item = { type = "markers", markers = {
            { hash = "x", collapsed = true, count = 2, refs = { ref("local", "feat") } },
            { hash = "y", collapsed = true, count = 3, refs = { ref("local", "other") } },
        } }
        local units = marker_units(item, MARKS)
        assert.same({ "(▾feat)", "(other)" }, { units[1].text, units[2].text })
    end)
end)
