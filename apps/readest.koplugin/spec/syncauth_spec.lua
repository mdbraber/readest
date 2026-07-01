-- syncauth_spec.lua
-- Tests for readest_syncauth.lua withFreshToken(): the single-flight token
-- refresh guard and the fresh / refresh / failure paths. These guard against
-- two robustness regressions:
--   1. A storm of concurrent refresh_token calls (config+notes+stats firing
--      together on resume) racing Supabase's refresh-token rotation.
--   2. Sync proceeding with a stale/expired Bearer token because the refresh
--      was fire-and-forget instead of awaited.

local spec_helper = require("spec_helper")

-- KOReader modules pulled at require-time by readest_syncauth.
package.preload["ui/widget/infomessage"] = function()
    return { new = function() return {} end }
end
package.preload["ui/widget/multiinputdialog"] = function()
    return { new = function() return {} end }
end
package.preload["ui/network/manager"] = function()
    return { willRerunWhenOnline = function() return false end }
end
package.preload["ui/uimanager"] = function()
    return { show = function() end, close = function() end }
end
package.preload["util"] = function()
    return { trim = function(s) return s end }
end
package.preload["ffi/util"] = function()
    return { template = function(s) return s end }
end
package.preload["readest_i18n"] = function()
    return function(s) return s end
end

-- Controllable fake of the Supabase auth client. refresh_token records the
-- callback so the test can fire it deterministically and count invocations.
local refresh_calls
local pending_cb
local FakeSupabase = {}
function FakeSupabase:new(_o)
    return self
end
function FakeSupabase:refresh_token(_refresh_token, callback)
    refresh_calls = refresh_calls + 1
    pending_cb = callback
end
package.preload["readest_supabaseauth"] = function()
    return FakeSupabase
end

describe("readest_syncauth needsLogin", function()
    local SyncAuth

    before_each(function()
        package.loaded["readest_syncauth"] = nil
        SyncAuth = require("readest_syncauth")
    end)

    it("returns false when access token is valid", function()
        local s = {
            access_token = "tok",
            expires_at = os.time() + 3600,
            refresh_token = "ref",
        }
        assert.is_false(SyncAuth:needsLogin(s))
    end)

    it("returns false when access token is expiring but refresh token exists", function()
        local s = {
            access_token = "tok",
            expires_at = os.time() - 10,  -- expired
            refresh_token = "ref",
        }
        assert.is_false(SyncAuth:needsLogin(s))
    end)

    it("returns true when no tokens at all", function()
        assert.is_true(SyncAuth:needsLogin({}))
    end)

    it("returns true when refresh token missing even if access token present", function()
        local s = {
            access_token = "tok",
            expires_at = os.time() - 10,
        }
        assert.is_true(SyncAuth:needsLogin(s))
    end)
end)

describe("readest_syncauth withFreshToken", function()
    local SyncAuth
    local settings

    before_each(function()
        spec_helper.reset()
        refresh_calls = 0
        pending_cb = nil
        package.loaded["readest_syncauth"] = nil
        SyncAuth = require("readest_syncauth")
        settings = {
            supabase_url = "https://example.supabase.co",
            supabase_anon_key = "anon",
            access_token = "old-access",
            refresh_token = "old-refresh",
            expires_in = 3600,
            expires_at = os.time() - 10, -- expired by default → needs refresh
        }
    end)

    it("does not refresh when the token still has >50% TTL", function()
        settings.expires_at = os.time() + 3600
        local ok
        SyncAuth:withFreshToken(settings, "/p", function(o) ok = o end)
        assert.are.equal(0, refresh_calls)
        assert.is_true(ok)
    end)

    it("refreshes a fully expired token and persists the new token", function()
        local ok
        SyncAuth:withFreshToken(settings, "/p", function(o) ok = o end)
        assert.are.equal(1, refresh_calls)
        pending_cb(true, {
            access_token = "new-access",
            refresh_token = "new-refresh",
            expires_at = os.time() + 3600,
            expires_in = 3600,
        })
        assert.is_true(ok)
        assert.are.equal("new-access", settings.access_token)
        assert.are.equal("new-refresh", settings.refresh_token)
        -- Persisted to G_reader_settings under the readest_sync key.
        assert.are.equal("new-access",
            G_reader_settings:readSetting("readest_sync").access_token)
    end)

    it("fires a single refresh for concurrent callers and drains all waiters", function()
        local results = {}
        SyncAuth:withFreshToken(settings, "/p", function(o) results[#results + 1] = o end)
        SyncAuth:withFreshToken(settings, "/p", function(o) results[#results + 1] = o end)
        SyncAuth:withFreshToken(settings, "/p", function(o) results[#results + 1] = o end)
        -- Only one network refresh despite three concurrent callers.
        assert.are.equal(1, refresh_calls)
        pending_cb(true, {
            access_token = "new-access",
            refresh_token = "new-refresh",
            expires_at = os.time() + 3600,
            expires_in = 3600,
        })
        -- All three callbacks resolved.
        assert.are.equal(3, #results)
        for _, ok in ipairs(results) do
            assert.is_true(ok)
        end
    end)

    it("reports failure without clearing the session on refresh error", function()
        local ok, err
        SyncAuth:withFreshToken(settings, "/p", function(o, e) ok = o; err = e end)
        pending_cb(false, { msg = "invalid refresh token" })
        assert.is_false(ok)
        assert.is_truthy(err)
        -- Session untouched: tokens remain so a later attempt can retry.
        assert.are.equal("old-access", settings.access_token)
        assert.are.equal("old-refresh", settings.refresh_token)
    end)

    it("allows a new refresh after a previous one completed", function()
        SyncAuth:withFreshToken(settings, "/p", function() end)
        assert.are.equal(1, refresh_calls)
        pending_cb(true, {
            access_token = "a2", refresh_token = "r2",
            expires_at = os.time() - 10, -- still expired → next call refreshes again
            expires_in = 3600,
        })
        SyncAuth:withFreshToken(settings, "/p", function() end)
        assert.are.equal(2, refresh_calls)
    end)
end)
