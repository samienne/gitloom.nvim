-- Unit tests for the pure, ctx-taking window helpers (window._internal) — the
-- resync core, the working-tree splice, the pin resolution and the per-commit
-- linker. These mutate only `ctx.repo` and touch no window, so they run headless
-- without snacks. They are the durable payoff of the B1 extraction (this logic
-- was previously buried in open_graph closures and untested).
--
-- §3.4 (resync), §3.3/§4.2 (working tree), §10.6 (pins), §3.1 (ordering).

-- Fixtures intentionally build partial Commit / Upstream / stream-item shapes
-- (only the fields the helper under test reads); and the assertions read fields
-- right after an assert.is_not_nil that LuaLS doesn't narrow — so suppress both.
---@diagnostic disable: missing-fields, need-check-nil

local window = require("gitloom.window")
local internal = window._internal
local git = require("gitloom.git")

-- A fresh empty repo (the Repo shape: hash->Commit, OrderItem[], name->Ref).
local function new_repo()
    return { root = "/r", commits = {}, order = {}, refs = {} }
end

-- A ctx over `repo`, with every _internal helper attached as a method (so a
-- helper that calls a sibling via `ctx:foo()` resolves — the production code does
-- this with the GRAPH_HELPERS loop).
local function new_ctx(repo, fields)
    local ctx = {
        repo = repo,
        opts = {},
        view_state = { pinned = {}, modes = {}, effective = {} },
        seed_pin_names = {},
        worktree_commits = {},
    }
    for k, v in pairs(fields or {}) do ctx[k] = v end
    for k, f in pairs(internal) do ctx[k] = f end
    return ctx
end

describe("window._internal.effective_pinned (§10.6)", function()
    -- HEAD on `main`; master/dev present; feature tracks origin/feature.
    local function repo_with_branches()
        local repo = new_repo()
        git.add_ref(repo, "main", "local", "h_main")
        git.add_ref(repo, "master", "local", "h_master")
        git.add_ref(repo, "dev", "local", "h_dev")
        git.add_ref(repo, "feature", "local", "h_feat", { short = "origin/feature" })
        git.add_ref(repo, "origin/feature", "remote", "h_feat")
        repo.head = "main"
        return repo
    end

    it("pins HEAD + the conventional trunks by default", function()
        local p = internal.effective_pinned(new_ctx(repo_with_branches()))
        assert.is_true(p.main)   -- HEAD
        assert.is_true(p.master)
        assert.is_true(p.dev)
        assert.is_nil(p.feature) -- not a default anchor
    end)

    it("honours an explicit pin and pins the tracked upstream too (pin-the-pair)", function()
        local ctx = new_ctx(repo_with_branches(), { view_state = { pinned = { feature = true } } })
        local p = internal.effective_pinned(ctx)
        assert.is_true(p.feature)
        assert.is_true(p["origin/feature"]) -- carried by the upstream pairing
    end)

    it("honours an explicit unpin of a default anchor", function()
        local ctx = new_ctx(repo_with_branches(), { view_state = { pinned = { main = false } } })
        assert.is_nil(internal.effective_pinned(ctx).main)
    end)

    it("does not pair the upstream when pin_upstream is off", function()
        local ctx = new_ctx(repo_with_branches(),
            { opts = { pin_upstream = false }, view_state = { pinned = { feature = true } } })
        local p = internal.effective_pinned(ctx)
        assert.is_true(p.feature)
        assert.is_nil(p["origin/feature"])
    end)

    it("pins a seeded pointer mark when its ref exists", function()
        local repo = repo_with_branches()
        local ctx = new_ctx(repo, { seed_pin_names = { feature = true } })
        assert.is_true(internal.effective_pinned(ctx).feature)
    end)
end)

describe("window._internal.reconcile_refs (§3.4)", function()
    -- Refs main@h1, topic@h2, HEAD->main, with the commits present.
    local function base_repo()
        local repo = new_repo()
        git.add_ref(repo, "main", "local", "h1")
        git.add_ref(repo, "topic", "local", "h2")
        git.add_ref(repo, "HEAD", "head", "h1") -- HEAD -> main's commit
        repo.head = "main"
        return repo
    end

    it("adds a new ref and removes a vanished one", function()
        local repo = base_repo()
        -- new set: main unchanged, topic gone, feature added
        internal.reconcile_refs(new_ctx(repo), {
            { name = "main", kind = "local", hash = "h1" },
            { name = "feature", kind = "local", hash = "h3" },
        }, "main", nil)
        assert.is_nil(repo.refs.topic)               -- removed
        assert.is_not_nil(repo.refs.feature)         -- added
        assert.equals("h3", repo.refs.feature.commit.hash)
        assert.is_not_nil(repo.refs.main)            -- kept
    end)

    it("re-points a moved ref and unlinks the old commit's back-list", function()
        local repo = base_repo()
        local old_main_commit = repo.refs.main.commit
        internal.reconcile_refs(new_ctx(repo), {
            { name = "main", kind = "local", hash = "h5" },
            { name = "topic", kind = "local", hash = "h2" },
        }, "main", nil)
        assert.equals("h5", repo.refs.main.commit.hash)
        -- the old commit no longer back-references a `main` ref
        for _, r in ipairs(old_main_commit.refs or {}) do
            assert.is_true(r.name ~= "main")
        end
    end)

    it("rebinds HEAD to the current branch's commit", function()
        local repo = base_repo()
        internal.reconcile_refs(new_ctx(repo), {
            { name = "main", kind = "local", hash = "h5" },
        }, "main", nil)
        assert.is_not_nil(repo.refs.HEAD)
        assert.equals("h5", repo.refs.HEAD.commit.hash) -- follows main to h5
        assert.equals("main", repo.head)
    end)

    it("binds HEAD to the checked-out commit when detached (§3.2)", function()
        local repo = base_repo()
        internal.reconcile_refs(new_ctx(repo), {
            { name = "main", kind = "local", hash = "h1" },
        }, nil, "h9")
        assert.is_nil(repo.head)
        assert.equals("h9", repo.refs.HEAD.commit.hash)
    end)

    it("refreshes upstream divergence even when the tip did not move (§6.3)", function()
        local repo = base_repo()
        internal.reconcile_refs(new_ctx(repo), {
            { name = "main", kind = "local", hash = "h1", upstream = { short = "origin/main" } },
            { name = "topic", kind = "local", hash = "h2" },
        }, "main", nil)
        assert.same({ short = "origin/main" }, repo.refs.main.upstream)
    end)
end)

describe("window._internal.prune_to_reachable (§3.4)", function()
    -- A reachable chain A->B->C off main, plus an orphan D->E reachable from nothing.
    local function repo_with_orphan()
        local repo = new_repo()
        local function C(h) return git.get_or_create_commit(repo, h) end
        local a, b, c, d, e = C("A"), C("B"), C("C"), C("D"), C("E")
        a.parents, b.parents, c.parents = { b }, { c }, {}
        d.parents, e.parents = { e }, {}
        b.children, c.children, e.children = { a }, { b }, { d }
        for _, x in ipairs({ a, b, c, d, e }) do
            repo.order[#repo.order + 1] = { type = "commit", commit = x, columns = {} }
        end
        git.add_ref(repo, "main", "local", "A")
        return repo, { a = a, b = b, c = c, d = d, e = e }
    end

    it("drops commits unreachable from any ref and keeps the reachable cone", function()
        local repo = repo_with_orphan()
        internal.prune_to_reachable(new_ctx(repo))
        assert.is_not_nil(repo.commits.A)
        assert.is_not_nil(repo.commits.B)
        assert.is_not_nil(repo.commits.C)
        assert.is_nil(repo.commits.D) -- orphan pruned
        assert.is_nil(repo.commits.E)
    end)

    it("prunes repo.order and child back-links to match", function()
        local repo = repo_with_orphan()
        internal.prune_to_reachable(new_ctx(repo))
        local hashes = {}
        for _, it in ipairs(repo.order) do hashes[it.commit.hash] = true end
        assert.is_true(hashes.A and hashes.B and hashes.C)
        assert.is_nil(hashes.D)
        assert.is_nil(hashes.E)
        -- no surviving commit still lists a pruned child
        for _, c in pairs(repo.commits) do
            for _, ch in ipairs(c.children or {}) do
                assert.is_not_nil(repo.commits[ch.hash])
            end
        end
    end)

    it("is a no-op when every commit is reachable", function()
        local repo = new_repo()
        local a = git.get_or_create_commit(repo, "A")
        repo.order[1] = { type = "commit", commit = a, columns = {} }
        git.add_ref(repo, "main", "local", "A")
        internal.prune_to_reachable(new_ctx(repo))
        assert.is_not_nil(repo.commits.A)
        assert.equals(1, #repo.order)
    end)

    it("never prunes a virtual (working-tree) commit", function()
        local repo = new_repo()
        local a = git.get_or_create_commit(repo, "A")
        git.add_ref(repo, "main", "local", "A")
        repo.commits.WT = { hash = "WT", virtual = "staged", parents = {}, children = {}, refs = {} }
        internal.prune_to_reachable(new_ctx(repo))
        assert.is_not_nil(repo.commits.WT) -- kept despite being unreachable
    end)
end)

describe("window._internal working-tree splice (§3.3/§4.2)", function()
    -- HEAD commit present in the order.
    local function repo_at_head()
        local repo = new_repo()
        local head = git.get_or_create_commit(repo, "HEADC")
        repo.order[1] = { type = "commit", commit = head, columns = {} }
        return repo, head
    end
    local state = function(staged, unstaged, untracked)
        return { head_hash = "HEADC", status = { staged = staged, unstaged = unstaged, untracked = untracked } }
    end

    it("splices staged + unstaged + untracked virtual commits above HEAD", function()
        local repo = repo_at_head()
        local ctx = new_ctx(repo)
        assert.equals("ok", internal.apply_worktree(ctx, state(2, 1, 3)))
        assert.equals(3, #ctx.worktree_commits)
        assert.equals(4, #repo.order) -- 3 virtual + HEAD
        -- newest-first above HEAD: untracked, unstaged, staged, then HEAD
        local kinds = {}
        for _, it in ipairs(repo.order) do kinds[#kinds + 1] = it.commit.virtual or "real" end
        assert.same({ "untracked", "unstaged", "staged", "real" }, kinds)
    end)

    it("returns 'clean' and splices nothing when the tree is clean", function()
        local repo = repo_at_head()
        local ctx = new_ctx(repo)
        assert.equals("clean", internal.apply_worktree(ctx, state(0, 0, 0)))
        assert.equals(0, #ctx.worktree_commits)
        assert.equals(1, #repo.order)
    end)

    it("returns 'moved' when HEAD advanced past the snapshot", function()
        local repo = repo_at_head()
        local ctx = new_ctx(repo)
        assert.equals("moved", internal.apply_worktree(ctx, { head_hash = "GONE", status = { staged = 1, unstaged = 0, untracked = 0 } }))
    end)

    it("returns 'off' when working_tree is disabled", function()
        local repo = repo_at_head()
        local ctx = new_ctx(repo, { opts = { working_tree = false } })
        assert.equals("off", internal.apply_worktree(ctx, state(1, 1, 1)))
        assert.equals(1, #repo.order)
    end)

    it("clear_worktree_nodes removes a prior splice", function()
        local repo = repo_at_head()
        local ctx = new_ctx(repo)
        internal.apply_worktree(ctx, state(1, 1, 0))
        assert.equals(3, #repo.order)
        internal.clear_worktree_nodes(ctx)
        assert.equals(1, #repo.order)
        assert.equals(0, #ctx.worktree_commits)
        -- HEAD's child back-list no longer references the virtuals
        local head = repo.commits.HEADC
        assert.is_not_nil(head)
        assert.equals(0, #(head.children or {}))
    end)

    it("re-applying replaces the prior splice (clear then splice)", function()
        local repo = repo_at_head()
        local ctx = new_ctx(repo)
        internal.apply_worktree(ctx, state(1, 0, 0))
        internal.apply_worktree(ctx, state(1, 1, 1)) -- clears then re-splices
        assert.equals(3, #ctx.worktree_commits)
        assert.equals(4, #repo.order)
    end)
end)

describe("window._internal.integrate_commit (§3/§3.1)", function()
    it("links a new commit, resolves parents, and appends an OrderItem", function()
        local repo = new_repo()
        local item = { hash = "X", parents = { "P" }, author = "a", date = 1, cepoch = 1, message = "m" }
        local oi = internal.integrate_commit(new_ctx(repo), item)
        assert.is_not_nil(oi)
        assert.equals("X", oi.commit.hash)
        assert.is_not_nil(repo.commits.X)
        assert.is_not_nil(repo.commits.P)          -- parent placeholder created
        assert.equals("X", repo.commits.P.children[1].hash) -- back-linked
        assert.equals(1, #repo.order)
    end)

    it("fills a pre-created placeholder (carrying cepoch) and does not duplicate", function()
        local repo = new_repo()
        local ph = git.get_or_create_commit(repo, "X") -- a bare placeholder (a ref tip)
        assert.is_nil(ph.loaded)
        internal.integrate_commit(new_ctx(repo), { hash = "X", parents = {}, cepoch = 42, message = "m" })
        assert.is_true(repo.commits.X.loaded)
        assert.equals(42, repo.commits.X.cepoch) -- §3.1 squash-merge ordering depends on this
        assert.equals(ph, repo.commits.X)        -- identity preserved
    end)

    it("skips a commit already loaded into a row (the placeholder dup-guard)", function()
        -- The dup-guard keys off `loaded`, which only the placeholder-fill path
        -- sets — so fill a pre-created tip first, then re-integrating is a no-op.
        local repo = new_repo()
        git.get_or_create_commit(repo, "X") -- a bare ref-tip placeholder
        local ctx = new_ctx(repo)
        internal.integrate_commit(ctx, { hash = "X", parents = {}, cepoch = 1 }) -- fills -> loaded
        assert.equals(1, #repo.order)
        local again = internal.integrate_commit(ctx, { hash = "X", parents = {}, cepoch = 1 })
        assert.is_nil(again)         -- no second row
        assert.equals(1, #repo.order)
    end)
end)
