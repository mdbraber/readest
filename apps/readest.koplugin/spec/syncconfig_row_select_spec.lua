-- A config pull matches the book's file hash OR its metadata hash, so the
-- server can return rows for other copies of the same book. SyncConfig:pull
-- must act on the row for THIS file: its xpointer/page address these bytes.

require("spec_helper")
require("spec.koreader_stubs")

local SyncConfig = require("readest_syncconfig")

-- Paged (PDF-like) document on page `current`: applyBookConfig navigates with
-- GotoPage only when the chosen row's page differs from it.
local function pagedUI(current)
    local values = {}
    local ui = {
        document = { info = { has_pages = true } },
        doc_settings = {
            readSetting = function(_, k) return values[k] end,
            saveSetting = function(_, k, v) values[k] = v end,
        },
        link = { addCurrentLocationToStack = function() end },
        getCurrentPage = function() return current end,
        events = {},
    }
    function ui:handleEvent(ev) table.insert(self.events, ev) end
    return ui
end

local function pullWith(current, rows)
    local ui = pagedUI(current)
    local respond
    local client = { pullChanges = function(_, _, cb) respond = cb end }
    SyncConfig:pull(ui, { sync_progress_backwards = true }, client, "this-file", "meta", false)
    respond(true, { configs = rows }, 200)
    return ui
end

describe("SyncConfig:pull row selection", function()
    it("applies the row for this file even when a sibling copy comes first", function()
        -- Already on this file's synced page 20: choosing the sibling's page 80
        -- would navigate, choosing this file's row does not.
        local ui = pullWith(20, {
            { book_hash = "other-copy", progress = "[80,100]",
              progress_updated_at = "2026-06-30T12:00:00.000Z" },
            { book_hash = "this-file", progress = "[20,100]",
              progress_updated_at = "2026-06-30T11:00:00.000Z" },
        })
        assert.are.equal(0, #ui.events)
    end)

    it("falls back to the first row when none matches this file", function()
        local ui = pullWith(20, {
            { book_hash = "other-copy", progress = "[80,100]",
              progress_updated_at = "2026-06-30T12:00:00.000Z" },
        })
        assert.are.equal(1, #ui.events)
        assert.are.equal("GotoPage", ui.events[1].name)
    end)
end)
