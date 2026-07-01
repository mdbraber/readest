local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local util = require("util")
local T = require("ffi/util").template
local _ = require("readest_i18n")

local SyncAuth = {}

function SyncAuth:needsLogin(settings)
    if settings.access_token and settings.expires_at
            and settings.expires_at >= os.time() + 60 then
        return false
    end
    return not settings.refresh_token
end

-- Drain the queue of callers awaiting the in-flight refresh, handing each
-- the same (ok, err) result. Cleared before invoking so a callback that
-- itself triggers another refresh starts a fresh queue.
function SyncAuth:_drainRefreshWaiters(ok, err)
    local waiters = self._refresh_waiters or {}
    self._refresh_waiters = {}
    self._refreshing = false
    for _, cb in ipairs(waiters) do
        cb(ok, err)
    end
end

-- Ensure a usable access token, then invoke `callback(ok, err)`:
--   • Token still has > 50% TTL  → callback(true) immediately.
--   • Otherwise                  → refresh, then callback after the new
--                                  token is committed to settings.
--
-- All sync entry points MUST go through this wrapper so requests never
-- carry a stale Bearer header (the old fire-and-forget tryRefreshToken
-- built the client before the refresh landed — codex round 1 finding 14).
--
-- Single-flight: concurrent callers (config + notes + stats all fire on
-- resume) share ONE refresh request and are fanned out together. Without
-- this, N simultaneous refresh_token calls race Supabase's refresh-token
-- rotation — the first rotates the token and the rest present a revoked
-- one, which can revoke the whole token family and force a manual re-login.
function SyncAuth:withFreshToken(settings, path, callback)
    -- Token still has > 50% TTL remaining: nothing to do.
    if not settings.refresh_token or not settings.expires_at
        or settings.expires_at >= os.time() + (settings.expires_in or 0) / 2 then
        if callback then callback(true) end
        return
    end

    -- Join the in-flight refresh (if any) rather than starting another.
    self._refresh_waiters = self._refresh_waiters or {}
    if callback then table.insert(self._refresh_waiters, callback) end
    if self._refreshing then return end

    local client = self:getSupabaseAuthClient(settings, path)
    if not client then
        self:_drainRefreshWaiters(false, "no auth client")
        return
    end

    self._refreshing = true
    client:refresh_token(settings.refresh_token, function(success, response)
        if success then
            settings.access_token  = response.access_token
            settings.refresh_token = response.refresh_token
            settings.expires_at    = response.expires_at
            settings.expires_in    = response.expires_in
            G_reader_settings:saveSetting("readest_sync", settings)
            self:_drainRefreshWaiters(true)
        else
            logger.err("ReadestSync: Token refresh failed:", response or "Unknown error")
            self:_drainRefreshWaiters(false, response and response.msg or "refresh failed")
        end
    end)
end

function SyncAuth:getSupabaseAuthClient(settings, path)
    if not settings.supabase_url or not settings.supabase_anon_key then
        return nil
    end

    local SupabaseAuthClient = require("readest_supabaseauth")
    return SupabaseAuthClient:new{
        service_spec = path .. "/supabase-auth-api.json",
        base_url = settings.supabase_url .. "/auth/v1/",
        api_key = settings.supabase_anon_key,
    }
end

function SyncAuth:getReadestSyncClient(settings, path)
    if not settings.access_token or not settings.expires_at or settings.expires_at < os.time() then
        return nil
    end

    local ReadestSyncClient = require("readest_syncclient")
    return ReadestSyncClient:new{
        service_spec = path .. "/readest-sync-api.json",
        base_url = (settings.api_base_url or ""):gsub("/+$", "") .. "/api",
        access_token = settings.access_token,
    }
end

function SyncAuth:login(settings, path, title, menu)
    if NetworkMgr:willRerunWhenOnline(function() self:login(settings, path, title, menu) end) then
        return
    end

    local dialog
    dialog = MultiInputDialog:new{
        title = title,
        fields = {
            {
                text = settings.user_email,
                hint = "email@example.com",
            },
            {
                hint = "password",
                text_type = "password",
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Login"),
                    callback = function()
                        local email, password = unpack(dialog:getFields())
                        email = util.trim(email)
                        if email == "" or password == "" then
                            UIManager:show(InfoMessage:new{
                                text = _("Please enter both email and password"),
                                timeout = 2,
                            })
                            return
                        end
                        UIManager:close(dialog)
                        self:doLogin(settings, path, email, password, menu)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function SyncAuth:doLogin(settings, path, email, password, menu)
    local client = self:getSupabaseAuthClient(settings, path)
    if not client then
        UIManager:show(InfoMessage:new{
            text = _("Please configure Supabase URL and API key first"),
            timeout = 3,
        })
        return
    end

    UIManager:show(InfoMessage:new{
        text = _("Logging in..."),
        timeout = 1,
    })

    Device:setIgnoreInput(true)
    local success, response = client:sign_in_password(email, password)
    Device:setIgnoreInput(false)

    if success then
        settings.user_email = email
        settings.user_id = response.user.id
        settings.user_name = response.user.user_metadata.user_name or email
        settings.access_token = response.access_token
        settings.refresh_token = response.refresh_token
        settings.expires_at = response.expires_at
        settings.expires_in = response.expires_in
        G_reader_settings:saveSetting("readest_sync", settings)

        if menu then
            menu:updateItems()
        end

        UIManager:show(InfoMessage:new{
            text = _("Successfully logged in to Readest"),
            timeout = 3,
        })
    else
        UIManager:show(InfoMessage:new{
            text = T(_("Login failed: %1"), response.msg or _("unknown error")),
            timeout = 3,
        })
    end
end

function SyncAuth:logout(settings, path, menu)
    if settings.access_token then
        local client = self:getSupabaseAuthClient(settings, path)
        if client then
            client:sign_out(settings.access_token, function(success, _response)
                logger.dbg("ReadestSync: Sign out result:", success)
            end)
        end
    end

    settings.access_token = nil
    settings.refresh_token = nil
    settings.expires_at = nil
    settings.expires_in = nil
    G_reader_settings:saveSetting("readest_sync", settings)

    if menu then
        menu:updateItems()
    end

    UIManager:show(InfoMessage:new{
        text = _("Logged out from Readest"),
        timeout = 2,
    })
end

return SyncAuth
