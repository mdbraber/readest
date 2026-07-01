local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local util = require("util")
local sha2 = require("ffi/sha2")
local _ = require("readest_i18n")

local SyncConfig = {}

local function normalizeIdentifier(identifier)
    if identifier:match("urn:") then
        return identifier:match("([^:]+)$")
    elseif identifier:match(":") then
        return identifier:match("^[^:]+:(.+)$")
    end
    return identifier
end

local function normalizeAuthor(author)
    author = author:gsub("^%s*(.-)%s*$", "%1")
    return author
end

function SyncConfig:getMetadataHashInfo(ui)
    local doc_props = ui.doc_settings:readSetting("doc_props") or {}
    local title = doc_props.title or ''
    if title == '' then
        local _doc_path, filename = util.splitFilePathName(ui.doc_settings:readSetting("doc_path") or '')
        local basename, _suffix = util.splitFileNameSuffix(filename)
        title = basename or ''
    end

    local authors_raw = doc_props.authors or ''
    local authors_list = {}
    if authors_raw:find("\n") then
        local list = util.splitToArray(authors_raw, "\n")
        for i, author in ipairs(list) do
            authors_list[i] = normalizeAuthor(author)
        end
    elseif authors_raw ~= '' then
        authors_list = { normalizeAuthor(authors_raw) }
    end

    local identifiers_raw = doc_props.identifiers or ''
    local identifiers_list = {}
    if identifiers_raw:find("\n") then
        local list = util.splitToArray(identifiers_raw, "\n")
        local normalized = {}
        local priorities = { "uuid", "calibre", "isbn" }
        local preferred = nil
        for i, id in ipairs(list) do
            normalized[i] = normalizeIdentifier(id)
            local candidate = id:lower()
            for _, p in ipairs(priorities) do
                if candidate:find(p, 1, true) then
                    preferred = normalized[i]
                    break
                end
            end
        end
        if preferred then
            identifiers_list = { preferred }
        else
            identifiers_list = normalized
        end
    elseif identifiers_raw ~= '' then
        identifiers_list = { normalizeIdentifier(identifiers_raw) }
    end

    local hash_source = title .. "|" .. table.concat(authors_list, ",") .. "|" .. table.concat(identifiers_list, ",")
    return {
        title = title,
        authors = authors_list,
        identifiers = identifiers_list,
        hash_source = hash_source,
        meta_hash = sha2.md5(hash_source),
    }
end

function SyncConfig:generateMetadataHash(ui)
    return self:getMetadataHashInfo(ui).meta_hash
end

function SyncConfig:getMetaHash(ui)
    local doc_readest_sync = ui.doc_settings:readSetting("readest_sync") or {}
    local meta_hash = doc_readest_sync.meta_hash_v1
    if not meta_hash then
        meta_hash = self:generateMetadataHash(ui)
        doc_readest_sync.meta_hash_v1 = meta_hash
        ui.doc_settings:saveSetting("readest_sync", doc_readest_sync)
    end
    return meta_hash
end

function SyncConfig:getDocumentIdentifier(ui)
    return ui.doc_settings:readSetting("partial_md5_checksum")
end

-- Current UTC time as an ISO-8601 string, the representation used end-to-end:
-- the DB column is timestamptz and the server accepts ISO via new Date(...).
-- Keeping every progress timestamp ISO avoids the ms/ISO and number/string
-- mixing that a per-call epoch would introduce.
local function nowIso()
    return os.date("!%Y-%m-%dT%H:%M:%S.000Z")
end

-- Page number out of a progress value, which may be a "[page,total]" string
-- (server row) or a {page, total} table (locally built config).
local function pageFromProgress(progress)
    if type(progress) == "string" then
        return tonumber(progress:match("^%[(%d+),%d+%]$"))
    elseif type(progress) == "table" then
        return tonumber(progress[1])
    end
    return nil
end

-- Stable signature of the device's CURRENT reading position. Used to tell
-- whether the position actually changed between pushes. Paged → page number;
-- reflowable → xpointer.
function SyncConfig:localPositionSig(ui)
    if ui.document.info.has_pages then
        return "p:" .. tostring(ui:getCurrentPage())
    end
    return "x:" .. tostring(ui.rolling:getLastProgress())
end

-- Signature of the position carried by a server config row, in the same shape
-- as localPositionSig so the two can be compared.
function SyncConfig:serverPositionSig(ui, config)
    if ui.document.info.has_pages then
        return "p:" .. tostring(pageFromProgress(config.progress))
    end
    return "x:" .. tostring(config.xpointer)
end

-- The single watermark (progress_sig, progress_updated_at_value) means: the
-- position this device is synced to, and when it was authored. It is advanced
-- on a real local move (push side, author "now") and on adopting a server
-- position (pull side, inherit the server's authored-at) — mirroring the web
-- client's lastSyncedProgressTs. The four helpers below are pure so they can be
-- unit-tested without a live ReaderUI.

-- progressUpdatedAt to report for the current position `sig`: carry the
-- watermark when unchanged (idempotent re-push / inherited server position),
-- else this is a real move we author "now".
function SyncConfig:resolveProgressUpdatedAt(drs, sig, now_value)
    if drs.progress_sig == sig and drs.progress_updated_at_value then
        return drs.progress_updated_at_value
    end
    drs.progress_sig = sig
    drs.progress_updated_at_value = now_value
    return now_value
end

-- Authored-at of the position we currently hold, or nil when the watermark no
-- longer matches it (then we have no claim to its freshness).
function SyncConfig:syncedAuthoredAt(drs, current_sig)
    if drs.progress_sig == current_sig then
        return drs.progress_updated_at_value
    end
    return nil
end

-- Is the server's position (authored at server_prog) newer than ours (authored
-- at my_prog)? No claim of our own → server wins. ISO-8601 UTC strings compare
-- lexicographically == chronologically.
function SyncConfig:isServerNewer(my_prog, server_prog)
    if not my_prog then return true end
    return server_prog ~= nil and server_prog > my_prog
end

-- Advance the watermark to a position we now hold (adopted from the server), so
-- we don't re-adopt it and the next push inherits its authored-at.
function SyncConfig:setSyncedPosition(drs, sig, authored_at)
    drs.progress_sig = sig
    drs.progress_updated_at_value = authored_at
end

function SyncConfig:getCurrentBookConfig(ui)
    local book_hash = self:getDocumentIdentifier(ui)
    local meta_hash = self:getMetaHash(ui)
    if not book_hash or not meta_hash then
        UIManager:show(InfoMessage:new{
            text = _("Cannot identify the current book"),
            timeout = 2,
        })
        return nil
    end

    local config = {
        bookHash = book_hash,
        metaHash = meta_hash,
        progress = "",
        xpointer = "",
        updatedAt = nowIso(),
    }

    local current_page = ui:getCurrentPage()
    local page_count = ui.document:getPageCount()
    config.progress = {current_page, page_count}

    if not ui.document.info.has_pages then
        config.xpointer = ui.rolling:getLastProgress()
    end

    -- Attach an honest progressUpdatedAt so the server's per-field position
    -- merge can protect a newer remote position from an unmoved device.
    local drs = ui.doc_settings:readSetting("readest_sync") or {}
    config.progressUpdatedAt =
        self:resolveProgressUpdatedAt(drs, self:localPositionSig(ui), config.updatedAt)
    ui.doc_settings:saveSetting("readest_sync", drs)

    return config
end

-- Returns true if position was changed, false if skipped or already identical.
-- allow_backwards=true: last-write-wins, applies in any direction.
-- allow_backwards=false (default): forward-only, only advances position.
-- Callers are responsible for the timestamp-newness check before calling.
function SyncConfig:applyBookConfig(ui, config, allow_backwards)
    logger.dbg("ReadestSync: Applying book config:", config)
    local xpointer = config.xpointer
    local progress = config.progress
    local has_pages = ui.document.info.has_pages
    if has_pages and progress then
        local new_page
        if type(progress) == "string" then
            local page = progress:match("^%[(%d+),%d+%]$")
            new_page = tonumber(page)
        elseif type(progress) == "table" then
            new_page = tonumber(progress[1])
        end
        local current_page = ui:getCurrentPage()
        if new_page and new_page ~= current_page
                and (allow_backwards or new_page > current_page) then
            ui.link:addCurrentLocationToStack()
            ui:handleEvent(Event:new("GotoPage", new_page))
            return true
        end
    end
    if not has_pages and xpointer then
        local last_xpointer = ui.rolling:getLastProgress()
        if xpointer ~= last_xpointer then
            if allow_backwards then
                ui.link:addCurrentLocationToStack()
                ui:handleEvent(Event:new("GotoXPointer", xpointer))
                return true
            else
                local cmp_result = ui.document:compareXPointers(last_xpointer, xpointer)
                local working_xpointer = xpointer
                while cmp_result == nil and working_xpointer do
                    local last_slash_pos = working_xpointer:match("^.*()/")
                    if last_slash_pos and last_slash_pos > 1 then
                        working_xpointer = working_xpointer:sub(1, last_slash_pos - 1)
                        cmp_result = ui.document:compareXPointers(last_xpointer, working_xpointer)
                    else
                        break
                    end
                end
                if cmp_result and cmp_result > 0 then
                    ui.link:addCurrentLocationToStack()
                    ui:handleEvent(Event:new("GotoXPointer", xpointer))
                    return true
                end
            end
        end
    end
    return false
end

function SyncConfig:push(ui, settings, client, interactive, last_sync_timestamp)
    local config = self:getCurrentBookConfig(ui)
    if not config then return last_sync_timestamp end

    if interactive then
        UIManager:show(InfoMessage:new{
            text = _("Pushing reading progress..."),
            timeout = 1,
        })
    end

    local payload = {
        books = {},
        notes = {},
        configs = { config },
    }

    client:pushChanges(
        payload,
        function(success, _response)
            if interactive then
                if success then
                    UIManager:show(InfoMessage:new{
                        text = _("Reading progress pushed successfully"),
                        timeout = 2,
                    })
                else
                    UIManager:show(InfoMessage:new{
                        text = _("Failed to push reading progress"),
                        timeout = 2,
                    })
                end
            end
            if success and ui.doc_settings then
                local doc_readest_sync = ui.doc_settings:readSetting("readest_sync") or {}
                doc_readest_sync.last_synced_at_config = os.time()
                ui.doc_settings:saveSetting("readest_sync", doc_readest_sync)
            end
        end
    )

    if not interactive then
        return os.time()
    end
    return last_sync_timestamp
end

function SyncConfig:pull(ui, settings, client, book_hash, meta_hash, interactive, logout_fn)
    if interactive then
        UIManager:show(InfoMessage:new{
            text = _("Pulling reading progress..."),
            timeout = 1,
        })
    end

    client:pullChanges(
        {
            since = 0,
            type = "configs",
            book = book_hash,
            meta_hash = meta_hash,
        },
        function(success, response, status)
            if not success then
                -- Auth failure: server returns HTTP 403 with body
                -- {error="Not authenticated"} per apps/readest-app/src/pages/api/sync.ts:31.
                -- Check the status code primarily so future endpoints with
                -- different body shapes still trigger relogin (codex finding).
                local is_auth_fail = status == 401 or status == 403
                    or (response and response.error == "Not authenticated")
                if is_auth_fail then
                    if interactive then
                        UIManager:show(InfoMessage:new{
                            text = _("Authentication failed, please login again"),
                            timeout = 2,
                        })
                    end
                    if logout_fn then logout_fn() end
                    return
                end
                if interactive then
                    UIManager:show(InfoMessage:new{
                        text = _("Failed to pull reading progress"),
                        timeout = 2,
                    })
                end
                return
            end

            local doc_readest_sync = ui.doc_settings and
                ui.doc_settings:readSetting("readest_sync") or {}
            doc_readest_sync.last_synced_at_config = os.time()
            if ui.doc_settings then
                ui.doc_settings:saveSetting("readest_sync", doc_readest_sync)
            end

            local data = response.configs
            if data and #data > 0 then
                local config = data[1]
                if config then
                    -- Position-author timestamps decide newness (mirrors the web's
                    -- lastSyncedProgressTs): compare the server's progress_updated_at
                    -- against the authored-at of the position we currently hold. Never
                    -- keys on updated_at (row-touch), so an unmoved device's push that
                    -- merely bumped the row can't trigger a needless re-pull.
                    -- sync_progress_backwards only governs DIRECTION in applyBookConfig.
                    local server_sig = self:serverPositionSig(ui, config)
                    local server_prog = config.progress_updated_at or config.updated_at
                    local my_sig = self:localPositionSig(ui)
                    local my_prog = self:syncedAuthoredAt(doc_readest_sync, my_sig)
                    local server_is_newer = self:isServerNewer(my_prog, server_prog)
                    logger.dbg("ReadestSync pull: server_prog=" .. tostring(server_prog)
                        .. " my_prog=" .. tostring(my_prog)
                        .. " sync_progress_backwards=" .. tostring(settings.sync_progress_backwards)
                        .. " server_is_newer=" .. tostring(server_is_newer))
                    if server_is_newer then
                        local navigated = self:applyBookConfig(ui, config, settings.sync_progress_backwards)
                        -- Advance the watermark to the server's position we now hold
                        -- (navigated to it, or were already there) so the next pull
                        -- won't re-adopt it and the next push inherits its authored-at.
                        if navigated or my_sig == server_sig then
                            self:setSyncedPosition(doc_readest_sync, server_sig, server_prog)
                            if ui.doc_settings then
                                ui.doc_settings:saveSetting("readest_sync", doc_readest_sync)
                            end
                        end
                        if interactive then
                            UIManager:show(InfoMessage:new{
                                text = navigated
                                    and _("Reading progress synchronized")
                                    or _("Reading progress is already up to date"),
                                timeout = 2,
                            })
                        end
                    else
                        if interactive then
                            UIManager:show(InfoMessage:new{
                                text = _("Local reading progress is more recent"),
                                timeout = 2,
                            })
                        end
                    end
                    return
                end
            end

            if interactive then
                UIManager:show(InfoMessage:new{
                    text = _("No saved reading progress found for this book"),
                    timeout = 2,
                })
            end
        end
    )
end

return SyncConfig
