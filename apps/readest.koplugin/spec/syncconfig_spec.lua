-- syncconfig_spec.lua
-- Tests for readest_syncconfig.lua's single progress watermark
-- (progress_sig + progress_updated_at_value = "the position we're synced to and
-- when it was authored"). It is advanced on a real local move (push side) and on
-- adopting a server position (pull side), mirroring the web's lastSyncedProgressTs.
-- progressUpdatedAt must only advance to "now" on a genuine move so an idle
-- device cannot clobber a newer position from another device.

local spec_helper = require("spec_helper")

-- KOReader modules pulled at require-time by readest_syncconfig.
package.preload["ui/event"] = function()
    return { new = function() return {} end }
end
package.preload["ui/widget/infomessage"] = function()
    return { new = function() return {} end }
end
package.preload["ui/uimanager"] = function()
    return { show = function() end }
end
package.preload["util"] = function()
    return {}
end
package.preload["ffi/sha2"] = function()
    return { md5 = function() return "hash" end }
end
package.preload["readest_i18n"] = function()
    return function(s) return s end
end

describe("readest_syncconfig progress watermark", function()
    local SyncConfig
    -- Timestamps are ISO strings end-to-end (matches the DB + the server's
    -- new Date(...) acceptance); the helpers are representation-agnostic.
    local NOW = "2026-06-30T12:00:00.000Z"

    before_each(function()
        spec_helper.reset()
        package.loaded["readest_syncconfig"] = nil
        SyncConfig = require("readest_syncconfig")
    end)

    describe("resolveProgressUpdatedAt", function()
        it("authors 'now' for a brand-new position", function()
            local drs = {}
            local v = SyncConfig:resolveProgressUpdatedAt(drs, "p:3", NOW)
            assert.are.equal(NOW, v)
            assert.are.equal("p:3", drs.progress_sig)
            assert.are.equal(NOW, drs.progress_updated_at_value)
        end)

        it("carries the watermark when the position is unchanged", function()
            local stored = "2026-06-29T08:00:00.000Z"
            local drs = { progress_sig = "p:5", progress_updated_at_value = stored }
            assert.are.equal(stored, SyncConfig:resolveProgressUpdatedAt(drs, "p:5", NOW))
        end)

        it("authors 'now' on a real move to a new position", function()
            local drs = { progress_sig = "p:5", progress_updated_at_value = "2026-06-29T08:00:00.000Z" }
            assert.are.equal(NOW, SyncConfig:resolveProgressUpdatedAt(drs, "p:6", NOW))
            assert.are.equal("p:6", drs.progress_sig)
        end)
    end)

    describe("isServerNewer", function()
        it("lets the server win when we have no claim", function()
            assert.is_true(SyncConfig:isServerNewer(nil, "2026-06-30T10:00:00.000Z"))
        end)
        it("is true when the server position was authored later", function()
            assert.is_true(SyncConfig:isServerNewer(
                "2026-06-30T09:00:00.000Z", "2026-06-30T10:00:00.000Z"))
        end)
        it("is false when ours is the same or newer", function()
            assert.is_false(SyncConfig:isServerNewer(
                "2026-06-30T10:00:00.000Z", "2026-06-30T10:00:00.000Z"))
            assert.is_false(SyncConfig:isServerNewer(
                "2026-06-30T11:00:00.000Z", "2026-06-30T10:00:00.000Z"))
        end)
    end)

    describe("syncedAuthoredAt", function()
        it("returns the watermark value when it matches the current position", function()
            local drs = { progress_sig = "p:7", progress_updated_at_value = "T7" }
            assert.are.equal("T7", SyncConfig:syncedAuthoredAt(drs, "p:7"))
        end)
        it("returns nil when the watermark is for a different position", function()
            local drs = { progress_sig = "p:7", progress_updated_at_value = "T7" }
            assert.is_nil(SyncConfig:syncedAuthoredAt(drs, "p:8"))
        end)
    end)

    -- End-to-end behaviour expressed through the pure helpers + a doc-local drs
    -- table, simulating the pull→push sequence the ReaderUI drives.
    describe("scenarios", function()
        it("an unmoved device inherits the server's authored-at (no clobber)", function()
            -- Open at page 1; pull sees the server also at page 1 @ T0. We have no
            -- prior watermark, so the server wins the decision, we're already at its
            -- position (no navigation), and we adopt its authored-at.
            local drs = {}
            local server_sig, server_prog = "p:1", "2026-06-30T08:00:00.000Z"
            local my_prog = SyncConfig:syncedAuthoredAt(drs, "p:1")
            assert.is_true(SyncConfig:isServerNewer(my_prog, server_prog))
            SyncConfig:setSyncedPosition(drs, server_sig, server_prog) -- adopt (already there)
            -- Another device now advances to page 10; we never move, then push on close.
            -- The push reports the inherited T0, NOT now → server keeps page 10.
            assert.are.equal(server_prog, SyncConfig:resolveProgressUpdatedAt(drs, "p:1", NOW))
        end)

        it("after adopting a newer server position, a later push inherits its time", function()
            -- We sit at page 1 (authored T1). Pull sees server page 10 @ T10.
            local drs = { progress_sig = "p:1", progress_updated_at_value = "2026-06-30T01:00:00.000Z" }
            local server_sig, server_prog = "p:10", "2026-06-30T10:00:00.000Z"
            assert.is_true(SyncConfig:isServerNewer(
                SyncConfig:syncedAuthoredAt(drs, "p:1"), server_prog))
            SyncConfig:setSyncedPosition(drs, server_sig, server_prog) -- navigated to p:10
            -- Push at the adopted position carries the server's authored-at.
            assert.are.equal(server_prog, SyncConfig:resolveProgressUpdatedAt(drs, "p:10", NOW))
            -- A genuine move past it authors 'now'.
            assert.are.equal(NOW, SyncConfig:resolveProgressUpdatedAt(drs, "p:11", NOW))
        end)

        it("does not re-adopt the server position once synced (no churn)", function()
            -- Synced to page 10 @ T10; the server row was merely touched (updated_at
            -- bumped) but progress_updated_at is unchanged. We must not re-adopt.
            local drs = { progress_sig = "p:10", progress_updated_at_value = "2026-06-30T10:00:00.000Z" }
            local my_prog = SyncConfig:syncedAuthoredAt(drs, "p:10")
            assert.is_false(SyncConfig:isServerNewer(my_prog, "2026-06-30T10:00:00.000Z"))
        end)
    end)
end)
