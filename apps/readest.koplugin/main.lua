local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local KeyValuePage = require("ui/widget/keyvaluepage")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local sha2 = require("ffi/sha2")
local T = require("ffi/util").template
local util = require("util")
local _ = require("readest_i18n")

local SyncAuth = require("readest_syncauth")
local SyncConfig = require("readest_syncconfig")
local SyncAnnotations = require("readest_syncannotations")
local SyncStats = require("readest_syncstats")
local SelfUpdate = require("readest_selfupdate")

local ReadestSync = WidgetContainer:new{
    name = "readest",
    title = _("Readest"),
    settings = nil,
}

local API_CALL_DEBOUNCE_DELAY = 30
-- Polling for WiFi after resume: 1s initial delay, 3s between retries, up to 8 retries (~25s total).
-- runWhenOnline/willRerunWhenOnline only fire when KOReader itself initiated the connection;
-- OS-level auto-connect on wake is invisible to those hooks, so we poll instead.
local PULL_ONLINE_POLL_DELAY   = 1
local PULL_ONLINE_POLL_INTERVAL = 3
local PULL_ONLINE_POLL_MAX      = 8
local SUPABAE_ANON_KEY_BASE64 = "ZXlKaGJHY2lPaUpJVXpJMU5pSXNJblI1Y0NJNklrcFhWQ0o5LmV5SnBjM01pT2lKemRYQmhZbUZ6WlNJc0luSmxaaUk2SW5aaWMzbDRablZ6YW1weFpIaHJhbkZzZVhOaklpd2ljbTlzWlNJNkltRnViMjRpTENKcFlYUWlPakUzTXpReE1qTTJOekVzSW1WNGNDSTZNakEwT1RZNU9UWTNNWDAuM1U1VXFhb3VfMVNnclZlMWVvOXJBcGMwdUtqcWhwUWRVWGh2d1VIbVVmZw=="

local DEFAULT_API_BASE_URL = "https://web.readest.com"
local DEFAULT_SUPABASE_URL = "https://readest.supabase.co"
local DEFAULT_SUPABASE_ANON_KEY = sha2.base64_to_bin(SUPABAE_ANON_KEY_BASE64)

ReadestSync.default_settings = {
    server_url = nil,
    api_base_url = DEFAULT_API_BASE_URL,
    supabase_url = DEFAULT_SUPABASE_URL,
    supabase_anon_key = DEFAULT_SUPABASE_ANON_KEY,
    auto_sync = false,
    pull_on_resume = false,
    sync_progress_backwards = false,
    user_email = nil,
    user_name = nil,
    user_id = nil,
    access_token = nil,
    refresh_token = nil,
    expires_at = nil,
    expires_in = nil,
    last_sync_at = nil,
}

-- ── Lifecycle ──────────────────────────────────────────────────────

function ReadestSync:init()
    self.last_sync_timestamp = 0
    self.settings = G_reader_settings:readSetting("readest_sync", self.default_settings)

    -- Migrate: old api_url (with /api suffix) → api_base_url (no /api suffix).
    if self.settings.api_url and not self.settings.api_base_url then
        self.settings.api_base_url = self.settings.api_url:gsub("/api/?$", "")
        self.settings.api_url = nil
    end
    -- Migrate: remote_progress_wins → sync_progress_backwards (clearer name for
    -- the "let an older remote position move us backwards" toggle).
    if self.settings.remote_progress_wins ~= nil and self.settings.sync_progress_backwards == nil then
        self.settings.sync_progress_backwards = self.settings.remote_progress_wins
        self.settings.remote_progress_wins = nil
    end
    -- Back-fill any keys added to default_settings that are absent from the
    -- stored table (e.g. api_base_url for users upgrading from an older version).
    local settings_changed = false
    for k, v in pairs(self.default_settings) do
        if self.settings[k] == nil then
            self.settings[k] = v
            settings_changed = true
        end
    end
    if settings_changed then
        G_reader_settings:saveSetting("readest_sync", self.settings)
    end

    local meta = dofile(self.path .. "/_meta.lua")
    self.installed_version = meta and meta.version and tostring(meta.version)

    self.ui.menu:registerToMainMenu(self)
    -- Dispatcher actions (gestures / quick menu entries). Registering
    -- here in init() rather than onReaderReady so the FileManager-only
    -- actions (Readest Library, Push books, Pull books — flagged with
    -- general=true) show up in FileManager → Settings → Taps and gestures
    -- when no document is open. Reader-only actions (auto sync etc.)
    -- still get registered on first plugin load too — they just don't
    -- fire until a document opens.
    self:onDispatcherRegisterActions()
    -- Long-press file menu in FileManager: add an "Add to Readest"
    -- entry that hashes the file, registers it in the LibraryStore, and
    -- uploads it to the user's Readest cloud. Skipped in reader context
    -- (FileManager.instance is nil there).
    self:registerFileDialogButton()
end

-- Register Library actions (Open / Push / Pull) — available in both
-- reader and FileManager via the `general=true` flag.
function ReadestSync:onDispatcherRegisterActions()
    Dispatcher:registerAction("readest_open_library", { category="none", event="ReadestOpenLibrary", title=_("Open Readest Library"), general=true,})
    Dispatcher:registerAction("readest_push_books", { category="none", event="ReadestPushBooks", title=_("Push Readest book library"), general=true,})
    Dispatcher:registerAction("readest_pull_books", { category="none", event="ReadestPullBooks", title=_("Pull Readest book library"), general=true,})
end

-- Reader-only actions (progress + annotations sync) — registered only
-- after a document opens, so they don't appear in the gesture picker
-- when FileManager is the foreground context. They'd never fire from
-- FileManager anyway (the handlers operate on the active ReaderUI), so
-- showing them there would just be noise.
function ReadestSync:onDispatcherRegisterReaderActions()
    Dispatcher:registerAction("readest_sync_set_autosync",
        { category="string", event="ReadestSyncToggleAutoSync", title=_("Set auto progress sync"), reader=true,
        args={true, false}, toggle={_("on"), _("off")},})
    Dispatcher:registerAction("readest_sync_toggle_autosync", { category="none", event="ReadestSyncToggleAutoSync", title=_("Toggle auto readest sync"), reader=true,})
    Dispatcher:registerAction("readest_sync_push_progress", { category="none", event="ReadestSyncPushProgress", title=_("Push readest progress from this device"), reader=true,})
    Dispatcher:registerAction("readest_sync_pull_progress", { category="none", event="ReadestSyncPullProgress", title=_("Pull readest progress from other devices"), reader=true, separator=true,})
    Dispatcher:registerAction("readest_sync_push_annotations", { category="none", event="ReadestSyncPushAnnotations", title=_("Push readest annotations from this device"), reader=true,})
    Dispatcher:registerAction("readest_sync_pull_annotations", { category="none", event="ReadestSyncPullAnnotations", title=_("Pull readest annotations from other devices"), reader=true, separator=true,})
end

-- Poll for network availability and pull once online. Used by onReaderReady
-- and onResume where OS-level auto-connect makes runWhenOnline unreliable.
function ReadestSync:pullWhenOnline()
    local attempts = 0
    local function tryPull()
        if NetworkMgr:isOnline() then
            self:pullBookConfig(false)
            self:pullBookNotes(false)
            self:pullBookStats(false)
        elseif attempts < PULL_ONLINE_POLL_MAX then
            attempts = attempts + 1
            UIManager:scheduleIn(PULL_ONLINE_POLL_INTERVAL, tryPull)
        end
    end
    UIManager:scheduleIn(PULL_ONLINE_POLL_DELAY, tryPull)
end

function ReadestSync:onReaderReady()
    if self.settings.access_token and (self.settings.auto_sync or self.settings.pull_on_resume) then
        self._refresh_failed_once = nil
        self:pullWhenOnline()
    end
    self:onDispatcherRegisterReaderActions()
end

-- Pull progress + notes + stats. Logged so resume sync issues are diagnosable
-- via KOReader's crash.log (grep "ReadestSync: pulling").
function ReadestSync:pullProgressNow()
    logger.dbg("ReadestSync: pulling progress (resume / network connected)")
    self:pullBookConfig(false)
    self:pullBookNotes(false)
    self:pullBookStats(false)
end

function ReadestSync:onResume()
    if self.settings.access_token and self.settings.pull_on_resume then
        self._refresh_failed_once = nil
        if NetworkMgr:isOnline() then
            self:pullProgressNow()
        elseif NetworkMgr:isConnected() then
            -- isConnected() (ifHasAnAddress) is true: interface is up and has
            -- an IP, but isOnline() (canResolveHostnames) hasn't settled yet.
            -- Poll until DNS is ready; no need for the connect flow below.
            self:pullWhenOnline()
        else
            -- WiFi is off. Set a flag so onNetworkConnected triggers the pull
            -- for any connection event — whether initiated by runWhenOnline or
            -- by KOReader's own WiFi restore on wake. runWhenOnline actively
            -- requests the connection per wifi_enable_action (turns WiFi on,
            -- or prompts the user). The empty callback is intentional: the
            -- actual pull is driven by onNetworkConnected, not this callback,
            -- because reconnectOrShowNetworkMenu (the Kindle lipc path) may
            -- fail its initial scan and drop the callback silently, while
            -- NetworkConnected is still broadcast by connectivityCheck when
            -- the connection eventually succeeds.
            self._pull_on_connect = true
            NetworkMgr:runWhenOnline(function() end)
        end
    end
end

function ReadestSync:onNetworkConnected()
    if self._pull_on_connect then
        self._pull_on_connect = false
        -- Use pullWhenOnline() rather than pullProgressNow() so we wait for
        -- isOnline() (DNS) to settle after NetworkConnected fires. The
        -- original code called pullProgressNow() directly here, which raced
        -- against canResolveHostnames() not yet returning true.
        self:pullWhenOnline()
    end
end

-- Reverse-lookup table: file extension (lowercase) → Readest format
-- token (uppercase). Computed once at module load from EXTS so we don't
-- pay the iteration cost per long-press.
local _readest_format_for_ext = nil
local function readest_format_for_ext(ext)
    if not _readest_format_for_ext then
        _readest_format_for_ext = {}
        local EXTS = require("library.exts")
        for fmt, e in pairs(EXTS) do _readest_format_for_ext[e] = fmt end
    end
    return ext and _readest_format_for_ext[ext:lower()]
end

-- Register an "Add to Readest" button in FileManager's long-press file
-- dialog (the one with Paste / Cut / Delete / Copy / Reading / On hold
-- / etc.). The button only renders for supported book formats and
-- when the user is signed in to Readest.
--
-- Why scheduleIn(0): plugin init() runs while KOReader is still
-- constructing the FileManager — FileManager.instance is not yet
-- assigned. Deferring to the next event-loop tick (same trick simpleui
-- uses at plugins/simpleui.koplugin/main.lua:261) lets the FileManager
-- finish its own init first so .instance is populated when we look it
-- up. Safe in reader context too: .instance stays nil so we no-op.
function ReadestSync:registerFileDialogButton()
    local plugin = self
    UIManager:scheduleIn(0, function()
        local ok_FM, FileManager = pcall(require, "apps/filemanager/filemanager")
        if not ok_FM or not FileManager.instance then return end
        FileManager.instance:addFileDialogButtons("readest_add_to_library",
            function(file, is_file, _book_props)
                if not is_file then return nil end
                local ext = file:match("%.([^./\\]+)$")
                if not readest_format_for_ext(ext) then return nil end
                return {
                    {
                        text = _("Add to Readest"),
                        enabled = plugin.settings.access_token ~= nil,
                        callback = function()
                            local fc = FileManager.instance and FileManager.instance.file_chooser
                            local dlg = fc and fc.file_dialog
                            if dlg then UIManager:close(dlg) end
                            plugin:addToReadest(file)
                        end,
                    },
                }
            end)
    end)
end

-- Hash the file, upsert a Library row, then upload to cloud. Mirrors
-- the upload flow we already use in librarywidget's "Upload to Cloud"
-- action — the only new thing here is computing the partial_md5 from
-- the file directly, since long-pressing in FileManager doesn't go
-- through the Library row path.
function ReadestSync:addToReadest(file)
    local lfs = require("libs/libkoreader-lfs")

    if not self.settings.access_token then
        UIManager:show(InfoMessage:new{
            text = _("Sign in to Readest first."), timeout = 3,
        })
        return
    end
    local attr = lfs.attributes(file)
    if not attr or attr.mode ~= "file" then
        UIManager:show(InfoMessage:new{
            text = _("File not found."), timeout = 3,
        })
        return
    end
    local ext = file:match("%.([^./\\]+)$")
    local format = readest_format_for_ext(ext)
    if not format then
        UIManager:show(InfoMessage:new{
            text = _("Unsupported book format."), timeout = 3,
        })
        return
    end

    -- Hash via util.partialMD5 — same algorithm Readest uses, fast
    -- (reads small chunks at fixed offsets, no full-file scan).
    local progress = InfoMessage:new{
        text = _("Hashing book…"),
    }
    UIManager:show(progress)
    UIManager:nextTick(function()
        local hash = util.partialMD5(file)
        UIManager:close(progress)
        if not hash then
            UIManager:show(InfoMessage:new{
                text = _("Could not read file."), timeout = 3,
            })
            return
        end
        self:_addLocalRow(file, hash, format, attr.size)
    end)
end

function ReadestSync:_addLocalRow(file, hash, format, _size)
    local store = self:getLibraryStore()
    if not store then
        UIManager:show(InfoMessage:new{
            text = _("Sign in to Readest first."), timeout = 3,
        })
        return
    end

    -- Title: filename minus extension. BIM might have richer metadata
    -- if the user has opened the book before, but a filename-derived
    -- title is good enough for the row to round-trip — the user can
    -- later trigger an Upload to Cloud which carries it to Readest.
    local basename = file:match("([^/]+)$") or file
    local title = basename:gsub("%.[^.]+$", "")
    local now = math.floor(os.time() * 1000)
    logger.info("ReadestSync addToReadest: hash=" .. hash:sub(1, 8)
        .. " title=" .. tostring(title)
        .. " format=" .. tostring(format)
        .. " path=" .. tostring(file)
        .. " now=" .. tostring(now))

    -- Dedupe by partial_md5: if a non-tombstoned row with this hash is
    -- already in the user's library, just bump its updated_at and skip.
    -- Tombstoned rows (deleted_at set) are treated as "not in library"
    -- — re-adding writes a fresh local-only row with cloud_present=0.
    local existing = store:_getRowRaw(hash)
    if existing then
        logger.info("ReadestSync addToReadest: existing row found"
            .. " cloud_present=" .. tostring(existing.cloud_present)
            .. " local_present=" .. tostring(existing.local_present)
            .. " deleted_at=" .. tostring(existing.deleted_at)
            .. " updated_at=" .. tostring(existing.updated_at))
    else
        logger.info("ReadestSync addToReadest: no existing row — inserting")
    end
    if existing and existing.deleted_at == nil then
        store:upsertBook({
            hash          = hash,
            title         = existing.title or title,
            file_path     = file,
            local_present = 1,
            updated_at    = now,
        })
        logger.info("ReadestSync addToReadest dedupe: bumped updated_at for "
            .. hash:sub(1, 8) .. " to " .. tostring(now))
        local LibraryWidget = require("library.librarywidget")
        if LibraryWidget._menu then LibraryWidget.refresh() end
        UIManager:show(InfoMessage:new{
            text = _("Already in your Readest library:") .. " "
                .. (existing.title or title),
            timeout = 2,
        })
        return
    end

    -- Add as a local-only row (cloud_present defaults to 0). Stamp
    -- created_at + updated_at explicitly so the row sorts under "Date
    -- Added" / "Last Updated" right away, and so the next pushChangedBooks
    -- pass picks it up (its query is `updated_at > since`).
    -- _clear_fields un-tombstones the row when re-adding a previously-
    -- deleted book — passing deleted_at = nil alone wouldn't clear it
    -- because Lua tables drop nil keys and upsertBook's preserve pass
    -- would copy the existing tombstone forward.
    store:upsertBook({
        hash          = hash,
        title         = title,
        format        = format,
        file_path     = file,
        local_present = 1,
        created_at    = now,
        updated_at    = now,
        _clear_fields = { "deleted_at" },
    })
    local row = store:_getRowRaw(hash)
    logger.info("ReadestSync addToReadest insert: stored row"
        .. " updated_at=" .. tostring(row and row.updated_at)
        .. " created_at=" .. tostring(row and row.created_at)
        .. " cloud_present=" .. tostring(row and row.cloud_present)
        .. " local_present=" .. tostring(row and row.local_present))
    local LibraryWidget = require("library.librarywidget")
    if LibraryWidget._menu then LibraryWidget.refresh() end
    UIManager:show(InfoMessage:new{
        text = _("Added to Readest:") .. " " .. title,
        timeout = 2,
    })
end

function ReadestSync:onAddToReadest(file)
    self:addToReadest(file)
end

-- ── Menu ───────────────────────────────────────────────────────────

function ReadestSync:addToMainMenu(menu_items)
    menu_items.readest_sync = {
        sorting_hint = "tools",
        text = _("Readest"),
        sub_item_table = {
            {
                text = _("Server settings"),
                callback = function()
                    self:showServerSettings()
                end,
                separator = true,
            },
            {
                text_func = function()
                    return SyncAuth:needsLogin(self.settings) and _("Log in Readest Account")
                        or T(_("Log out as %1"), self.settings.user_name or "")
                end,
                callback_func = function()
                    if SyncAuth:needsLogin(self.settings) then
                        return function(menu)
                            SyncAuth:login(self.settings, self.path, self.title, menu)
                        end
                    else
                        return function(menu)
                            SyncAuth:logout(self.settings, self.path, menu)
                        end
                    end
                end,
            },
            {
                text = _("Auto sync"),
                checked_func = function() return self.settings.auto_sync end,
                callback = function()
                    self:onReadestSyncToggleAutoSync()
                end,
            },
            {
                text = _("Pull on resume"),
                checked_func = function() return self.settings.pull_on_resume end,
                callback = function()
                    self.settings.pull_on_resume = not self.settings.pull_on_resume
                    G_reader_settings:saveSetting("readest_sync", self.settings)
                end,
            },
            {
                text = _("Allow reading progress to sync backwards"),
                checked_func = function() return self.settings.sync_progress_backwards end,
                callback = function()
                    self.settings.sync_progress_backwards = not self.settings.sync_progress_backwards
                    G_reader_settings:saveSetting("readest_sync", self.settings)
                end,
                separator = true,
            },
            {
                text = _("Readest library"),
                enabled_func = function()
                    return self.settings.access_token ~= nil and self.settings.user_id ~= nil
                end,
                callback = function()
                    self:openLibrary()
                end,
            },
            {
                text = _("Push stats now"),
                enabled_func = function()
                    return self.settings.access_token ~= nil and self.settings.user_id ~= nil
                end,
                callback = function()
                    self:pushBookStats(true)
                end,
            },
            {
                text = _("Pull stats now"),
                enabled_func = function()
                    return self.settings.access_token ~= nil and self.settings.user_id ~= nil
                end,
                callback = function()
                    self:pullBookStats(true)
                end,
            },
            {
                text = _("Push books now"),
                enabled_func = function()
                    return self.settings.access_token ~= nil and self.settings.user_id ~= nil
                end,
                callback = function()
                    self:syncBooksLibrary("push", true)
                end,
            },
            {
                text = _("Pull books now"),
                enabled_func = function()
                    return self.settings.access_token ~= nil and self.settings.user_id ~= nil
                end,
                callback = function()
                    self:syncBooksLibrary("pull", true)
                end,
                separator = true,
            },
            {
                text = _("Push reading progress now"),
                enabled_func = function()
                    return self.settings.access_token ~= nil and self.ui.document ~= nil
                end,
                callback = function()
                    self:pushBookConfig(true)
                end,
            },
            {
                text = _("Pull reading progress now"),
                enabled_func = function()
                    return self.settings.access_token ~= nil and self.ui.document ~= nil
                end,
                callback = function()
                    self:pullBookConfig(true)
                end,
                separator = true,
            },
            {
                text = _("Push annotations now"),
                enabled_func = function()
                    return self.settings.access_token ~= nil and self.ui.document ~= nil
                end,
                callback = function()
                    self:pushBookNotes(true)
                end,
            },
            {
                text = _("Pull annotations now"),
                enabled_func = function()
                    return self.settings.access_token ~= nil and self.ui.document ~= nil
                end,
                callback = function()
                    self:pullBookNotes(true)
                end,
            },
            {
                text = _("Full sync all annotations"),
                enabled_func = function()
                    return self.settings.access_token ~= nil and self.ui.document ~= nil
                end,
                callback = function()
                    self:fullSyncBookNotes()
                end,
                separator = true,
            },
            {
                text = _("Sync info"),
                enabled_func = function()
                    return self.ui.document ~= nil
                end,
                callback = function()
                    self:showSyncInfo()
                end,
                separator = true,
            },
            {
                text_func = function()
                    if self.installed_version then
                        return T(_("Check for update (v%1)"), self.installed_version)
                    end
                    return _("Check for update")
                end,
                callback = function()
                    SelfUpdate:checkForUpdate(self.path, self.installed_version)
                end,
            },
        }
    }
end

-- ── Sync helpers (thin wrappers around modules) ────────────────────

-- Resolve an authenticated sync client, refreshing the token first if it is
-- near or past expiry, then invoke `callback(client)` (or callback(nil) when
-- unavailable). Async because the refresh is async: building the client
-- synchronously after kicking off a refresh would send a stale/expired Bearer
-- token (sync then silently no-ops after a long sleep — the token is expired,
-- getReadestSyncClient returns nil, and the just-started refresh lands too
-- late for this call). Routing through withFreshToken awaits the new token.
function ReadestSync:ensureClient(interactive, callback)
    if not self.settings.access_token or not self.settings.user_id then
        if interactive then
            UIManager:show(InfoMessage:new{
                text = _("Please login first"),
                timeout = 2,
            })
        end
        callback(nil)
        return
    end

    SyncAuth:withFreshToken(self.settings, self.path, function(ok, err)
        if not ok then
            logger.dbg("ReadestSync: token refresh failed, skipping sync:", err)
            -- On a network-error refresh failure (WiFi not yet stable), retry
            -- once via pullWhenOnline so the next poll gets a fresh attempt.
            -- _refresh_failed_once guards against a second retry (revoked token
            -- or persistent network failure) and is reset on each new pull cycle.
            if not interactive and not self._refresh_failed_once then
                self._refresh_failed_once = true
                self:pullWhenOnline()
            end
            callback(nil)
            return
        end
        self._refresh_failed_once = false

        local client = SyncAuth:getReadestSyncClient(self.settings, self.path)
        if not client then
            if interactive then
                UIManager:show(InfoMessage:new{
                    text = _("Please configure Readest settings first"),
                    timeout = 3,
                })
            end
            callback(nil)
            return
        end
        callback(client)
    end)
end

function ReadestSync:getBookIdentifiers()
    local book_hash = SyncConfig:getDocumentIdentifier(self.ui)
    local meta_hash = SyncConfig:getMetaHash(self.ui)
    return book_hash, meta_hash
end

function ReadestSync:showSyncInfo()
    if not self.ui.document then
        UIManager:show(InfoMessage:new{
            text = _("No book is open"),
            timeout = 2,
        })
        return
    end

    local info = SyncConfig:getMetadataHashInfo(self.ui)
    local doc_readest_sync = self.ui.doc_settings:readSetting("readest_sync") or {}
    local stored_meta_hash = doc_readest_sync.meta_hash_v1
    local placeholder = _("(none)")

    local last_synced_at = math.max(
        doc_readest_sync.last_synced_at_config or 0,
        doc_readest_sync.last_synced_at_notes or 0
    )
    local last_synced_label = last_synced_at > 0
        and os.date("%Y-%m-%d %H:%M", last_synced_at)
        or _("Never synced")

    local kv_pairs = {
        { _("Book Fingerprint"), stored_meta_hash or info.meta_hash },
    }
    table.insert(kv_pairs, { _("Title"), info.title ~= "" and info.title or placeholder })
    table.insert(kv_pairs, {
        _("Author"),
        #info.authors > 0 and table.concat(info.authors, ", ") or placeholder,
    })
    table.insert(kv_pairs, {
        _("Identifiers"),
        #info.identifiers > 0 and table.concat(info.identifiers, ", ") or placeholder,
    })
    table.insert(kv_pairs, { _("Last Synced"), last_synced_label })

    UIManager:show(KeyValuePage:new{
        title = _("Sync Info"),
        kv_pairs = kv_pairs,
    })
end

-- ── Config sync ────────────────────────────────────────────────────

-- force=true bypasses the inter-push debounce. Used on document close so the
-- final reading position always reaches the server, even if a page-turn push
-- fired less than API_CALL_DEBOUNCE_DELAY seconds earlier.
function ReadestSync:pushBookConfig(interactive, force)
    local now = os.time()
    if not interactive and not force and now - self.last_sync_timestamp <= API_CALL_DEBOUNCE_DELAY then
        return
    end

    if interactive and NetworkMgr:willRerunWhenOnline(function() self:pushBookConfig(interactive) end) then
        return
    end

    self:ensureClient(interactive, function(client)
        if not client then return end
        self.last_sync_timestamp = SyncConfig:push(
            self.ui, self.settings, client, interactive, self.last_sync_timestamp
        )
    end)
end

function ReadestSync:pullBookConfig(interactive)
    local book_hash, meta_hash = self:getBookIdentifiers()
    if not book_hash or not meta_hash then return end

    if NetworkMgr:willRerunWhenOnline(function() self:pullBookConfig(interactive) end) then
        return
    end

    self:ensureClient(interactive, function(client)
        if not client then return end
        SyncConfig:pull(
            self.ui, self.settings, client, book_hash, meta_hash, interactive,
            -- Only an explicit user-initiated pull may clear the session on
            -- 401/403; a background auto-sync hitting a transient auth error
            -- must not silently log the user out.
            interactive and function() SyncAuth:logout(self.settings, self.path) end or nil
        )
    end)
end

-- ── Reading statistics sync ────────────────────────────────────────

function ReadestSync:pushBookStats(interactive)
    logger.dbg("ReadestStats pushBookStats: triggered, interactive=" .. tostring(interactive))
    if interactive and NetworkMgr:willRerunWhenOnline(function() self:pushBookStats(interactive) end) then
        return
    end
    self:ensureClient(interactive, function(client)
        if not client then
            logger.dbg("ReadestStats pushBookStats: no client (not signed in / offline); skipping")
            return
        end
        SyncStats:push(self.settings, client, interactive)
    end)
end

function ReadestSync:pullBookStats(interactive)
    logger.dbg("ReadestStats pullBookStats: triggered, interactive=" .. tostring(interactive))
    if NetworkMgr:willRerunWhenOnline(function() self:pullBookStats(interactive) end) then
        return
    end
    self:ensureClient(interactive, function(client)
        if not client then
            logger.dbg("ReadestStats pullBookStats: no client (not signed in / offline); skipping")
            return
        end
        SyncStats:pull(self.settings, client, interactive,
            -- Interactive-only logout: see pullBookConfig.
            interactive and function() SyncAuth:logout(self.settings, self.path) end or nil)
    end)
end

-- ── Annotation sync ────────────────────────────────────────────────

function ReadestSync:pushBookNotes(interactive, full_sync)
    if interactive and NetworkMgr:willRerunWhenOnline(function() self:pushBookNotes(interactive, full_sync) end) then
        return
    end

    self:ensureClient(interactive, function(client)
        if not client then return end
        SyncAnnotations:push(self.ui, self.settings, client, interactive, full_sync)
    end)
end

function ReadestSync:pullBookNotes(interactive, full_sync)
    local book_hash, meta_hash = self:getBookIdentifiers()
    if not book_hash or not meta_hash then return end

    if NetworkMgr:willRerunWhenOnline(function() self:pullBookNotes(interactive, full_sync) end) then
        return
    end

    self:ensureClient(interactive, function(client)
        if not client then return end
        SyncAnnotations:pull(
            self.ui, self.settings, client, book_hash, meta_hash, self.dialog, interactive, full_sync
        )
    end)
end

function ReadestSync:fullSyncBookNotes()
    -- Push all annotations first, then pull all
    self:pushBookNotes(true, true)
    self:pullBookNotes(true, true)
end

-- ── Event handlers ─────────────────────────────────────────────────

function ReadestSync:onReadestSyncToggleAutoSync(toggle)
    if toggle == self.settings.auto_sync then
        return true
    end
    self.settings.auto_sync = not self.settings.auto_sync
    G_reader_settings:saveSetting("readest_sync", self.settings)
    if self.settings.auto_sync and self.ui.document then
        self:pullBookConfig(false)
    end
end

function ReadestSync:onReadestSyncPushProgress()
    self:pushBookConfig(true)
end

function ReadestSync:onReadestSyncPullProgress()
    self:pullBookConfig(true)
end

function ReadestSync:onReadestSyncPushAnnotations()
    self:pushBookNotes(true)
end

function ReadestSync:onReadestSyncPullAnnotations()
    self:pullBookNotes(true)
end

function ReadestSync:openLibrary()
    if not self.settings.access_token or not self.settings.user_id then
        UIManager:show(InfoMessage:new{ text = _("Please login first"), timeout = 2 })
        return
    end
    local LibraryWidget = require("library.librarywidget")
    LibraryWidget.open({
        settings  = self.settings,
        sync_path = self.path,
        sync_auth = SyncAuth,
    })
end

function ReadestSync:onReadestOpenLibrary()
    self:openLibrary()
end

-- Lazy-open a LibraryStore for the current user. The Library widget may
-- already have one open via librarywidget._store; we share it when present
-- to avoid two SQLite handles to the same file. Returns nil if user_id
-- isn't set (shouldn't happen — caller should gate on access_token).
function ReadestSync:getLibraryStore()
    if not self.settings.user_id or self.settings.user_id == "" then return nil end
    local LibraryWidget = require("library.librarywidget")
    if LibraryWidget._store and LibraryWidget._current_user == self.settings.user_id then
        return LibraryWidget._store
    end
    if self.library_store and self.library_store.user_id == self.settings.user_id then
        return self.library_store
    end
    if self.library_store then self.library_store:close() end
    local LibraryStore = require("library.librarystore")
    local DataStorage  = require("datastorage")
    self.library_store = LibraryStore.new({
        user_id = self.settings.user_id,
        db_path = DataStorage:getSettingsDir() .. "/readest_library.sqlite3",
    })
    return self.library_store
end

-- Bump updated_at + last_read_at on the local row for the currently-open
-- book. Called before a sync push so the row's timestamp is fresh. Returns
-- the touched row, or nil if there's nothing to touch (no book open, no
-- partial_md5, or hash not in the LibraryStore index).
function ReadestSync:touchOpenBook()
    if not self.ui or not self.ui.doc_settings then return nil end
    local hash = self.ui.doc_settings:readSetting("partial_md5_checksum")
    if not hash or hash == "" then return nil end

    local store = self:getLibraryStore()
    if not store then return nil end

    local progress_lib
    if self.ui.document and self.ui.document.getPageCount and self.ui.getCurrentPage then
        local cur = self.ui:getCurrentPage()
        local total = self.ui.document:getPageCount()
        if cur and total then
            progress_lib = require("json").encode({ cur, total })
        end
    end

    local touched = store:touchBook(hash, { progress_lib = progress_lib })
    if not touched then
        logger.dbg("ReadestSync touchOpenBook: no row for " .. hash
            .. " (book not in LibraryStore index)")
    end
    return touched
end

-- syncBooksLibrary(mode, interactive) — bidirectional book-row sync,
-- mirroring useBooksSync.handleAutoSync at apps/readest-app/src/app/
-- library/hooks/useBooksSync.ts:66-78. mode: "push"|"pull"|"both".
-- The touched-row bump happens via the before_push callback so it lands
-- AFTER pull has refreshed the local row with the cloud's uploaded_at /
-- metadata / group_id — see syncbooks.syncBooks docstring + issue #4138.
-- Interactive=true shows toast feedback.
function ReadestSync:syncBooksLibrary(mode, interactive)
    if not self.settings.access_token or not self.settings.user_id then
        if interactive then
            UIManager:show(InfoMessage:new{ text = _("Please login first"), timeout = 2 })
        end
        return
    end
    local store = self:getLibraryStore()
    if not store then
        if interactive then
            UIManager:show(InfoMessage:new{ text = _("Library not initialized"), timeout = 2 })
        end
        return
    end

    local syncbooks = require("library.syncbooks")
    syncbooks.syncBooks({
        sync_auth = SyncAuth,
        sync_path = self.path,
        settings  = self.settings,
        store     = store,
    }, mode, function(success, msg, status)
        logger.info("ReadestSync syncBooksLibrary[" .. mode .. "] done: success="
            .. tostring(success) .. " msg=" .. tostring(msg))
        if interactive then
            UIManager:show(InfoMessage:new{
                text = success
                    and _("Books synced")
                    or _("Books sync failed"),
                timeout = 2,
            })
        end
        -- If the Library widget is open, refresh it so newly-pulled rows show
        local LibraryWidget = require("library.librarywidget")
        if LibraryWidget._menu then LibraryWidget.refresh() end
    end, function()
        -- before_push: bump updated_at on the open book so its row is in
        -- the push delta. Runs after pull so the cloud's uploaded_at /
        -- metadata / group_id have already merged into the local row;
        -- touchBook then preserves those fields.
        self:touchOpenBook()
    end)
end

function ReadestSync:onCloseDocument()
    if self.settings.auto_sync and self.settings.access_token then
        NetworkMgr:goOnlineToRun(function()
            self:pushBookConfig(false, true)
            self:pushBookNotes(false)
            self:pushBookStats(false)
            self:syncBooksLibrary("both", false)
        end)
    end
end

function ReadestSync:onReadestPushBooks()
    self:syncBooksLibrary("push", true)
end

function ReadestSync:onReadestPullBooks()
    self:syncBooksLibrary("pull", true)
end

function ReadestSync:onPageUpdate(page)
    if self.settings.auto_sync and self.settings.access_token and page then
        if self.delayed_push_task then
            UIManager:unschedule(self.delayed_push_task)
        end
        self.delayed_push_task = function()
            self:pushBookConfig(false)
        end
        UIManager:scheduleIn(5, self.delayed_push_task)
    end
end

function ReadestSync:onAnnotationsModified(items)
    -- A removal fires AnnotationsModified with a negative index_modified and the
    -- deleted item at items[1]. Capture a tombstone now, before the item is gone
    -- for good — the push walk only sees live annotations, so without this the
    -- deletion never reaches the server (issue #4119, push direction).
    if self.settings.access_token and items and items.index_modified
            and items.index_modified < 0 and items[1] then
        SyncAnnotations:recordDeletion(self.ui.doc_settings, items[1])
    end
    if self.settings.auto_sync and self.settings.access_token then
        UIManager:nextTick(function()
            self:pushBookNotes(false)
        end)
    end
end

function ReadestSync:onCloseWidget()
    if self.delayed_push_task then
        UIManager:unschedule(self.delayed_push_task)
        self.delayed_push_task = nil
    end
end

function ReadestSync:showServerSettings()
    local InputDialog = require("ui/widget/inputdialog")
    local MultiInputDialog = require("ui/widget/multiinputdialog")
    local socketutil = require("socketutil")

    -- ── Manual entry: all fields at once ──────────────────────────
    local function showManualDialog()
        local manual_dialog
        manual_dialog = MultiInputDialog:new{
            title = _("Server settings"),
            fields = {
                {
                    text = self.settings.api_base_url or DEFAULT_API_BASE_URL,
                    hint = _("API Base URL"),
                },
                {
                    text = self.settings.supabase_url or DEFAULT_SUPABASE_URL,
                    hint = _("Auth URL"),
                },
                {
                    text = self.settings.supabase_anon_key or DEFAULT_SUPABASE_ANON_KEY,
                    hint = _("Supabase ANON Key"),
                },
            },
            buttons = {
                {
                    {
                        text = _("Cancel"),
                        id = "close",
                        callback = function()
                            UIManager:close(manual_dialog)
                        end,
                    },
                    {
                        text = _("Reset"),
                        callback = function()
                            UIManager:close(manual_dialog)
                            self.settings.api_base_url = DEFAULT_API_BASE_URL
                            self.settings.supabase_url = DEFAULT_SUPABASE_URL
                            self.settings.supabase_anon_key = DEFAULT_SUPABASE_ANON_KEY
                            G_reader_settings:saveSetting("readest_sync", self.settings)
                            UIManager:show(InfoMessage:new{
                                text = _("Server settings reset to defaults"),
                                timeout = 2,
                            })
                        end,
                    },
                    {
                        text = _("Save"),
                        is_enter_default = true,
                        callback = function()
                            local vals = manual_dialog:getFields()
                            local api = util.trim(vals[1] or "")
                            local auth = util.trim(vals[2] or "")
                            local key = util.trim(vals[3] or "")
                            self.settings.api_base_url = api ~= "" and api or DEFAULT_API_BASE_URL
                            self.settings.supabase_url = auth ~= "" and auth or DEFAULT_SUPABASE_URL
                            self.settings.supabase_anon_key = key ~= "" and key or DEFAULT_SUPABASE_ANON_KEY
                            UIManager:close(manual_dialog)
                            G_reader_settings:saveSetting("readest_sync", self.settings)
                            UIManager:show(InfoMessage:new{
                                text = _("Server settings saved"),
                                timeout = 2,
                            })
                        end,
                    },
                },
            },
        }
        UIManager:show(manual_dialog)
        manual_dialog:onShowKeyboard()
    end

    -- ── Auto-discover from .well-known ─────────────────────────────
    local function discoverConfig(server_url)
        server_url = server_url:gsub("/+$", "")

        local ok_http, http = pcall(require, "socket.http")
        local ok_ltn12, ltn12 = pcall(require, "ltn12")
        local ok_json, json = pcall(require, "json")
        if not (ok_http and ok_ltn12 and ok_json) then
            return nil, _("HTTP library unavailable")
        end

        if server_url:match("^https://") then
            local ok_ssl, ssl_https = pcall(require, "ssl.https")
            if ok_ssl then http = ssl_https end
        end

        local DISCOVER_PATHS = {
            "/.well-known/readest-client-config.json",
            "/api/public/runtime-config",
        }

        socketutil:set_timeout(5, 10)
        local config, last_err
        for _, path in ipairs(DISCOVER_PATHS) do
            local body = {}
            local res, code = http.request{
                url     = server_url .. path,
                sink    = ltn12.sink.table(body),
                headers = { ["Accept"] = "application/json" },
            }
            if res and code == 200 then
                local ok2, parsed = pcall(json.decode, table.concat(body))
                if ok2 and type(parsed) == "table" then
                    config = parsed
                    break
                end
            else
                last_err = code
            end
        end
        socketutil:reset_timeout()

        if config then
            return config
        end
        return nil, T(_("Server unreachable (HTTP %1)"), tostring(last_err or "?"))
    end

    -- ── Entry dialog: server URL with Discover / Manual ────────────
    local ConfirmBox = require("ui/widget/confirmbox")
    local entry_dialog
    entry_dialog = InputDialog:new{
        title = _("Server URL"),
        input = self.settings.server_url or "",
        input_hint = "https://readest.example.com",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(entry_dialog)
                    end,
                },
                {
                    text = _("Manual"),
                    callback = function()
                        UIManager:close(entry_dialog)
                        showManualDialog()
                    end,
                },
                {
                    text = _("Discover"),
                    is_enter_default = true,
                    callback = function()
                        local server_url = util.trim(entry_dialog:getInputText())
                        UIManager:close(entry_dialog)
                        if server_url == "" then
                            showManualDialog()
                            return
                        end
                        self.settings.server_url = server_url
                        UIManager:show(InfoMessage:new{
                            text = _("Discovering server configuration…"),
                            timeout = 1,
                        })
                        local config, err = discoverConfig(server_url)
                        if config then
                            if config.apiBaseUrl then
                                self.settings.api_base_url = config.apiBaseUrl
                            end
                            if config.supabaseUrl then
                                self.settings.supabase_url = config.supabaseUrl
                            end
                            if config.supabaseAnonKey then
                                self.settings.supabase_anon_key = config.supabaseAnonKey
                            end
                            G_reader_settings:saveSetting("readest_sync", self.settings)
                            UIManager:show(InfoMessage:new{
                                text = _("Server configuration discovered and saved"),
                                timeout = 3,
                            })
                        else
                            local ConfirmBox = require("ui/widget/confirmbox")
                            UIManager:show(ConfirmBox:new{
                                text = T(_("Discovery failed: %1\n\nEnter server URLs manually?"), err or ""),
                                ok_text = _("Manual"),
                                cancel_text = _("Cancel"),
                                ok_callback = function()
                                    showManualDialog()
                                end,
                            })
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(entry_dialog)
    entry_dialog:onShowKeyboard()
end

function ReadestSync:deletePluginSettings()
    G_reader_settings:delSetting("readest_sync")
    self.settings = self.default_settings
    return true
end

return ReadestSync
