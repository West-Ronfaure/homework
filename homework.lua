--[[
* Addons - Copyright (c) 2024
* Homework - A weekly checklist addon for Ashita 4
--]]

addon.author   = 'Riquelme';
addon.name     = 'Homework';
addon.version   = '3.5';
addon.desc      = 'Weekly homework tracker for FFXI';
addon.link      = '';

require('common');
local imgui = require('imgui');

-- UI State
local ui = {
    is_open = { false },
    selected_char = { 0 },  -- Shared character selection for both tabs
    char_list = {},
    font_scale = 1.2,
    window_flags = ImGuiWindowFlags_NoCollapse,
    -- Set when a tick lands on a full account: { char = name, from = index }
    pending_account_add = nil,
};

-- Defined once the key item constants exist; used by save_settings below.
local build_ki_cache;

-- Custom settings file handling for Ashita v4
-- As of 3.4.0, settings live in Ashita's config tree (Ashita4/config/addons/Homework/)
-- instead of inside the addon folder. This keeps player data out of the addon folder
-- so users can share the addon without accidentally leaking their character data.
local settings_file = nil;
local display_settings_file = nil;

local function get_config_dir()
    return AshitaCore:GetInstallPath() .. 'config/addons/' .. addon.name .. '/';
end

local function get_legacy_dir()
    -- Old location used by versions <= 3.3.x
    return addon.path .. '/settings/';
end

local function get_settings_path()
    if settings_file == nil then
        settings_file = get_config_dir() .. 'homework.json';
    end
    return settings_file;
end

local function get_display_settings_path()
    if display_settings_file == nil then
        display_settings_file = get_config_dir() .. 'display.json';
    end
    return display_settings_file;
end

-- One-shot migration: if the legacy file exists and the new one doesn't, copy it
-- to the new location and delete the original.
local function migrate_settings_file(legacy_path, new_path)
    if not ashita.fs.exists(legacy_path) then return; end
    if ashita.fs.exists(new_path) then return; end
    local src = io.open(legacy_path, 'rb');
    if not src then return; end
    local content = src:read('*all');
    src:close();
    local new_dir = get_config_dir();
    if not ashita.fs.exists(new_dir) then ashita.fs.create_dir(new_dir); end
    local dst = io.open(new_path, 'wb');
    if not dst then return; end
    dst:write(content);
    dst:close();
    os.remove(legacy_path);
end

local function migrate_legacy_settings()
    local legacy_dir = get_legacy_dir();
    migrate_settings_file(legacy_dir .. 'homework.json', get_settings_path());
    migrate_settings_file(legacy_dir .. 'display.json', get_display_settings_path());
end

-- Known array field names (these should always serialize as [] not {})
-- Note: 'tasks' removed from here since display_settings.tracked uses it as an object {task_name: boolean}
local ARRAY_FIELDS = { locked_nations = true, ki_cache = true, counted_glasses = true, chars = true, dynamis_accounts = true };

local function escape_json_string(str)
    return str:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t');
end

local function serialize_value(val, indent, key)
    indent = indent or '';
    local t = type(val);
    if t == 'table' then
        -- Check if this should be an array (has numeric keys OR is a known array field)
        local is_array = #val > 0 or (key ~= nil and ARRAY_FIELDS[key]);
        if is_array then
            local items = {};
            for _, v in ipairs(val) do
                table.insert(items, serialize_value(v, indent));
            end
            return '[' .. table.concat(items, ', ') .. ']';
        else
            local result = '{\n';
            local first = true;
            for k, v in pairs(val) do
                if not first then result = result .. ',\n'; end
                first = false;
                local key_str = '"' .. escape_json_string(tostring(k)) .. '"';
                result = result .. indent .. '  ' .. key_str .. ': ' .. serialize_value(v, indent .. '  ', k);
            end
            if not first then result = result .. '\n' .. indent; end
            return result .. '}';
        end
    elseif t == 'string' then
        return '"' .. escape_json_string(val) .. '"';
    elseif t == 'boolean' then
        return val and 'true' or 'false';
    else
        return tostring(val);
    end
end

local function parse_json_value(str, pos)
    pos = pos or 1;
    -- Skip whitespace
    while pos <= #str and str:sub(pos, pos):match('%s') do pos = pos + 1; end
    if pos > #str then return nil, pos; end
    
    local c = str:sub(pos, pos);
    
    -- String
    if c == '"' then
        local endpos = pos + 1;
        while endpos <= #str do
            local ec = str:sub(endpos, endpos);
            if ec == '\\' then endpos = endpos + 2;
            elseif ec == '"' then break;
            else endpos = endpos + 1; end
        end
        -- Single-pass unescape. Chained gsubs used to mis-handle a literal
        -- backslash followed by 'n', because '\\n' was expanded before '\\\\'.
        local s = str:sub(pos + 1, endpos - 1):gsub('\\(.)', function(c)
            if c == 'n' then return '\n';
            elseif c == 't' then return '\t';
            elseif c == 'r' then return '\r';
            else return c; end
        end);
        return s, endpos + 1;
    end
    
    -- Number
    if c:match('[%d%-]') then
        local endpos = pos;
        while endpos <= #str and str:sub(endpos, endpos):match('[%d%.%-eE%+]') do endpos = endpos + 1; end
        return tonumber(str:sub(pos, endpos - 1)), endpos;
    end
    
    -- Boolean/null
    if str:sub(pos, pos + 3) == 'true' then return true, pos + 4; end
    if str:sub(pos, pos + 4) == 'false' then return false, pos + 5; end
    if str:sub(pos, pos + 3) == 'null' then return nil, pos + 4; end
    
    -- Array
    if c == '[' then
        local arr = {};
        pos = pos + 1;
        while pos <= #str do
            while pos <= #str and str:sub(pos, pos):match('%s') do pos = pos + 1; end
            if str:sub(pos, pos) == ']' then return arr, pos + 1; end
            local val;
            val, pos = parse_json_value(str, pos);
            table.insert(arr, val);
            while pos <= #str and str:sub(pos, pos):match('%s') do pos = pos + 1; end
            if str:sub(pos, pos) == ',' then pos = pos + 1; end
        end
        return arr, pos;
    end
    
    -- Object
    if c == '{' then
        local obj = {};
        pos = pos + 1;
        while pos <= #str do
            while pos <= #str and str:sub(pos, pos):match('%s') do pos = pos + 1; end
            if str:sub(pos, pos) == '}' then return obj, pos + 1; end
            local key;
            key, pos = parse_json_value(str, pos);
            while pos <= #str and str:sub(pos, pos):match('[%s:]') do pos = pos + 1; end
            local val;
            val, pos = parse_json_value(str, pos);
            if key then obj[key] = val; end
            while pos <= #str and str:sub(pos, pos):match('%s') do pos = pos + 1; end
            if str:sub(pos, pos) == ',' then pos = pos + 1; end
        end
        return obj, pos;
    end
    
    return nil, pos + 1;
end

local function load_settings()
    local path = get_settings_path();
    if not ashita.fs.exists(path) then return nil; end
    local f = io.open(path, 'r');
    if not f then return nil; end
    local content = f:read('*all');
    f:close();
    if not content or content == '' then return nil; end
    local result = parse_json_value(content, 1);
    return result;
end

-- Canonical task list. Saved files carry their own copy, so this is merged into
-- the loaded settings on startup - otherwise a task added in a new version would
-- never appear for anyone with an existing homework.json.
local DEFAULT_TASKS = {
    'EcoWarrior',
    'Highwind',
    'UnInvited',
    'CookBook',
    'SpiceGals',
    'X\'sKnife'
};

local function print_msg(message)
    print('\30\081[\30\082Homework\30\081]\30\106 ' .. message);
end

local function print_error(message)
    print('\30\081[\30\082Homework\30\081]\30\068 ' .. message);
end

local function print_success(message)
    print('\30\081[\30\082Homework\30\081]\30\110 ' .. message);
end

-- Tracker data
local tracker = {
    settings = {
        tasks = { 'EcoWarrior', 'Highwind', 'UnInvited', 'CookBook', 'SpiceGals', 'X\'sKnife' },
        -- Dynamis entry pooling. Off means every character counts its own.
        dynamis_account_wide = false,
        dynamis_accounts = {},
        chars_per_account = 3,
        characters = {} -- Per-character data: [charname] = { last_reset = 0, enm_timers = {}, xsknife_data = {}, etc }
    },
    current_char = nil,
    next_check_time = 0,
    -- Login detection state
    login_state = {
        waiting_for_login = false,  -- Set true after logout, cleared on next zone-in
        waiting_for_ki = false,     -- Set true after login/zone, cleared after KI packets received
        ki_packets_received = 0,    -- Count of 0x0055 packets received (need 7 total)
        suppress_ki_events = false  -- Set true during zone-in to prevent false "obtained" messages
    },
    -- KI state tracking (for detecting gain/loss via 0x055)
    -- 3 states: nil = unknown, true = has KI, false = doesn't have KI
    kis = {},  -- [ki_id] = true/false/nil, populated from packets or memory
    kis_initialized = false,  -- Don't trigger gain/loss on initial population
    -- Frame throttle for render
    last_render_time = 0,
    render_interval = 2,          -- Only check every 2 seconds
    -- UnInvited inventory check
    uninvited_done_time = 0,       -- Timestamp when UnInvited marked done
    -- Timestamp of a pending /hw reset, nil when none outstanding
    pending_reset = nil,
    -- Set by the Dynamis claim message, consumed by the hourglass-obtained message
    pending_dynamis_claim = nil
};

-- Save settings function (must be after tracker is defined)
local function save_settings()
    -- Mirror the live key item state into the character record so a reload can
    -- recover it without the game's memory API. See restore_ki_cache().
    if build_ki_cache ~= nil and tracker.kis_initialized
       and tracker.current_char ~= nil and tracker.current_char ~= 'Unknown' then
        local cd = tracker.settings.characters[tracker.current_char];
        if cd ~= nil then cd.ki_cache = build_ki_cache(); end
    end
    local path = get_settings_path();
    local dir = get_config_dir();
    if not ashita.fs.exists(dir) then
        ashita.fs.create_dir(dir);
    end
    local f = io.open(path, 'w');
    if f then
        f:write(serialize_value(tracker.settings));
        f:close();
    end
end

-- ENM/Limbus Key Items (needed for display settings initialization)
local ENM_KEY_ITEMS = {
    { name = 'Limbus', ki_id = 734, ki_name = 'Cosmo-Cleanse', cooldown = 72 * 3600 },
    { name = 'Boneyard Gully', ki_id = 678, ki_name = 'Miasma Filter', cooldown = 120 * 3600 },
    { name = 'Bearclaw Pinnacle', ki_id = 677, ki_name = 'Zephyr Fan', cooldown = 120 * 3600 },
    { name = 'Mine Shaft #2716', ki_id = 676, ki_name = 'Shaft #2716 Operating Lever', cooldown = 120 * 3600 },
    { name = 'Spire of Vahzl', ki_id = 673, ki_name = 'Censer of Acrimony', cooldown = 120 * 3600 },
    { name = 'Monarch Linn', ki_id = 674, ki_name = 'Monarch Beard', cooldown = 120 * 3600 },
    { name = 'The Shrouded Maw', ki_id = 675, ki_name = 'Astral Covenant', cooldown = 120 * 3600 },
    { name = 'Spire of Holla', ki_id = 670, ki_name = 'Censer of Abandonment', cooldown = 120 * 3600 },
    { name = 'Spire of Mea', ki_id = 672, ki_name = 'Censer of Animus', cooldown = 120 * 3600 },
    { name = 'Spire of Dem', ki_id = 671, ki_name = 'Censer of Antipathy', cooldown = 120 * 3600 }
};

-- Limbus Cards (for floating window display only)
local LIMBUS_CARDS = {
    { ki_id = 349, name = 'White Card', location = 'Temenos' },
    { ki_id = 351, name = 'Black Card', location = 'Apollyon (Central, NE, SE, CS)' },
    { ki_id = 350, name = 'Red Card', location = 'Apollyon (NW, SW)' }
};

-- Dynamis zone IDs
local DYNAMIS_ZONES = {
    [185] = 'San d\'Oria',
    [186] = 'Bastok',
    [187] = 'Windurst',
    [188] = 'Jeuno',
    [134] = 'Beaucedine',
    [135] = 'Xarcabard',
    [39] = 'Valkurm',
    [40] = 'Buburimu',
    [41] = 'Qufim',
    [42] = 'Tavnazia'
};

-- Perpetual Hourglass item ID
local PERPETUAL_HOURGLASS_ID = 4237;

-- A charged Perpetual Hourglass carries its booking in the item's Extra bytes.
-- Verified against two live captures (Bastok 186 and Windurst 187):
--   Extra[13..16] (1-based) = unix time the timeless glass was traded
--   Extra[17..20] (1-based) = destination Dynamis zone id
-- An uncharged Timeless Hourglass has Extra all zero, so no serial.
-- Copies of one glass share the same bytes, which is what we want: one break,
-- one entry, however many duplicates get handed round.
local GLASS_EXTRA_TIME_OFFSET = 13;
local GLASS_EXTRA_ZONE_OFFSET = 17;

-- Bags worth scanning for an hourglass.
local GLASS_BAGS = { 0, 1, 2, 4, 5, 6, 7, 8, 9, 10, 11, 12 };

-- Reads the serial from one inventory item. Returns serial, zone_id or nil.
local function glass_serial_from_item(item)
    if item == nil then return nil; end
    local ok, serial, zone = pcall(function()
        if item.Id ~= PERPETUAL_HOURGLASS_ID then return nil, nil; end
        local extra = item.Extra;
        if extra == nil or #extra < GLASS_EXTRA_ZONE_OFFSET + 3 then return nil, nil; end
        local t = struct.unpack('L', extra, GLASS_EXTRA_TIME_OFFSET);
        local z = struct.unpack('L', extra, GLASS_EXTRA_ZONE_OFFSET);
        if t == nil or z == nil or t == 0 then return nil, nil; end
        return string.format('%d-%d', z, t), z;
    end);
    if not ok then return nil; end
    return serial, zone;
end

-- Finds a charged glass. Prefers one booked for prefer_zone when given, so
-- holding a Bastok and a Windurst glass at once still resolves correctly.
local function find_glass_serial(prefer_zone)
    local best_serial, best_zone, any_serial, any_zone = nil, nil, nil, nil;
    pcall(function()
        local inv = AshitaCore:GetMemoryManager():GetInventory();
        if inv == nil then return; end
        for _, bag in ipairs(GLASS_BAGS) do
            local max_slots = inv:GetContainerCountMax(bag);
            if max_slots and max_slots > 0 then
                for slot = 1, max_slots do
                    local serial, zone = glass_serial_from_item(inv:GetContainerItem(bag, slot));
                    if serial ~= nil then
                        if any_serial == nil then any_serial, any_zone = serial, zone; end
                        if prefer_zone ~= nil and zone == prefer_zone and best_serial == nil then
                            best_serial, best_zone = serial, zone;
                        end
                    end
                end
            end
        end
    end);
    if best_serial ~= nil then return best_serial, best_zone; end
    return any_serial, any_zone;
end

-- How long a /hw reset confirmation stays valid.
local RESET_CONFIRM_WINDOW = 30;

-- How long before the weekly reset a Dynamis claim still counts against the
-- upcoming week's allowance.
local DYNAMIS_CLAIM_CARRY_WINDOW = 24 * 3600;

-- Display settings structure
-- font_scale is not stored here; it lives on `ui` and is written out at save time.
local display_settings = {
    tracked = {}  -- Per-character tracking: [char_name] = {tasks = {task1=true, ...}, timers = {timer1=true, ...}}
};

local function save_display_settings()
    local path = get_display_settings_path();
    local dir = get_config_dir();
    if not ashita.fs.exists(dir) then
        ashita.fs.create_dir(dir);
    end
    local f = io.open(path, 'w');
    if f then
        f:write(serialize_value({ font_scale = ui.font_scale, tracked = display_settings.tracked }));
        f:close();
    end
end

local function load_display_settings()
    local path = get_display_settings_path();
    if not ashita.fs.exists(path) then return; end
    local f = io.open(path, 'r');
    if not f then return; end
    local content = f:read('*all');
    f:close();
    if not content or content == '' then return; end
    local result = parse_json_value(content, 1);
    if result then
        if result.font_scale then ui.font_scale = result.font_scale; end
        if result.tracked then display_settings.tracked = result.tracked; end
    end
end

-- Get or initialize tracked items for a character
local function get_char_tracking(char_name)
    if not display_settings.tracked[char_name] then
        -- Initialize NEW character with all tasks/timers enabled by default
        display_settings.tracked[char_name] = {
            tasks = {},
            timers = {}
        };

        -- Enable all tasks by default for new characters
        for _, task in ipairs(tracker.settings.tasks) do
            display_settings.tracked[char_name].tasks[task] = true;
        end

        -- Enable all timers by default for new characters
        for _, enm in ipairs(ENM_KEY_ITEMS) do
            display_settings.tracked[char_name].timers[enm.name] = true;
        end
    else
        -- For existing characters, only add NEW tasks/timers that don't exist yet
        local tracking = display_settings.tracked[char_name];

        for _, task in ipairs(tracker.settings.tasks) do
            if tracking.tasks[task] == nil then
                tracking.tasks[task] = true;
            end
        end

        for _, enm in ipairs(ENM_KEY_ITEMS) do
            if tracking.timers[enm.name] == nil then
                tracking.timers[enm.name] = true;
            end
        end
    end

    return display_settings.tracked[char_name];
end

-- Zone IDs for Highwind spawns (airships)
local HIGHWIND_ZONES = {223, 224, 225, 226};

-- X'sKnife (Requiem of Sin) Key Items
local XSKNIFE_KI_ID_FIRST = 721;
local XSKNIFE_KI_ID_REPEAT = 722;

-- Weekly Quest Key Items
local COOKBOOK_KI_ID = 622;
local SPICEGALS_KI_ID = 621;
local UNINVITED_KI_ID = 720;

-- EcoWarrior Key Items
local ECOWARRIOR_KI_IDS = {
    sandoria = 472,
    windurst = 474,
    bastok = 473
};

-- How many characters one account may hold. A setting rather than a constant in
-- case the server changes the limit.
local DEFAULT_CHARS_PER_ACCOUNT = 3;

-- Fresh Dynamis bookkeeping.
local function new_dynamis_data()
    return { entries_remaining = 2, counted_glasses = {} };
end

-- Which account (if any) a character belongs to. Returns the account table.
local function find_dynamis_account(char_name)
    if char_name == nil then return nil; end
    for _, acct in ipairs(tracker.settings.dynamis_accounts or {}) do
        for _, c in ipairs(acct.chars or {}) do
            if c == char_name then return acct; end
        end
    end
    return nil;
end

-- Returns the table holding entries_remaining/counted_glasses for a character,
-- plus true when that table is shared across an account. Every Dynamis read and
-- write goes through here so per-character and account-wide behave identically.
local function get_dynamis_store(char_name)
    if tracker.settings.dynamis_account_wide then
        local acct = find_dynamis_account(char_name);
        if acct ~= nil then
            if acct.entries_remaining == nil then acct.entries_remaining = 2; end
            if type(acct.counted_glasses) ~= 'table' then acct.counted_glasses = {}; end
            return acct, true;
        end
    end
    local cd = char_name and tracker.settings.characters[char_name] or nil;
    if cd == nil then return nil, false; end
    if cd.dynamis_data == nil then cd.dynamis_data = new_dynamis_data(); end
    if type(cd.dynamis_data.counted_glasses) ~= 'table' then cd.dynamis_data.counted_glasses = {}; end
    return cd.dynamis_data, false;
end

local function chars_per_account()
    local n = tonumber(tracker.settings.chars_per_account or DEFAULT_CHARS_PER_ACCOUNT);
    if n == nil or n < 1 then n = DEFAULT_CHARS_PER_ACCOUNT; end
    return n;
end

local function dynamis_accounts()
    if type(tracker.settings.dynamis_accounts) ~= 'table' then
        tracker.settings.dynamis_accounts = {};
    end
    return tracker.settings.dynamis_accounts;
end

local function add_dynamis_account()
    local accts = dynamis_accounts();
    table.insert(accts, {
        name = 'Account ' .. tostring(#accts + 1),
        chars = {},
        entries_remaining = 2,
        counted_glasses = {}
    });
    return #accts;
end

-- Drops a character from every account. A character belongs to at most one, so
-- ticking a name somewhere else silently moves it rather than warning.
local recalc_account_from_members;

local function unassign_char(char_name)
    for _, acct in ipairs(dynamis_accounts()) do
        if type(acct.chars) == 'table' then
            local removed = false;
            for i = #acct.chars, 1, -1 do
                if acct.chars[i] == char_name then table.remove(acct.chars, i); removed = true; end
            end
            if removed then recalc_account_from_members(acct); end
        end
    end
end

-- An account inherits the LOWEST remaining count among its members, so grouping
-- characters never hands back an entry somebody already spent. Clamped against
-- the account's own value as well, so adding a fresh character to an account that
-- has already been used cannot top it back up. Membership changes can therefore
-- only lower the count - delete the account to start it over.
-- Member glass serials are merged in too, otherwise a glass one character already
-- counted would count a second time once the pool took over.
function recalc_account_from_members(acct)
    if acct == nil or type(acct.chars) ~= 'table' or #acct.chars == 0 then return; end
    local lowest = acct.entries_remaining or 2;
    local merged, seen = {}, {};
    for _, sn in ipairs(acct.counted_glasses or {}) do
        if not seen[sn] then seen[sn] = true; table.insert(merged, sn); end
    end
    for _, cname in ipairs(acct.chars) do
        local cd = tracker.settings.characters[cname];
        local dd = cd and cd.dynamis_data or nil;
        if dd ~= nil then
            local e = tonumber(dd.entries_remaining);
            if e ~= nil and e < lowest then lowest = e; end
            for _, sn in ipairs(dd.counted_glasses or {}) do
                if not seen[sn] then seen[sn] = true; table.insert(merged, sn); end
            end
        end
    end
    acct.entries_remaining = lowest;
    acct.counted_glasses = merged;
end

-- Returns false when the target account is already full.
local function assign_char_to_account(char_name, acct_index)
    local accts = dynamis_accounts();
    local acct = accts[acct_index];
    if acct == nil then return false; end
    if type(acct.chars) ~= 'table' then acct.chars = {}; end
    local already = false;
    for _, c in ipairs(acct.chars) do if c == char_name then already = true; break; end end
    if not already and #acct.chars >= chars_per_account() then return false; end
    unassign_char(char_name);
    if not already then table.insert(acct.chars, char_name); end
    recalc_account_from_members(acct);
    return true;
end

local function remove_dynamis_account(acct_index)
    local accts = dynamis_accounts();
    if accts[acct_index] == nil then return; end
    table.remove(accts, acct_index);
    -- Renumber the default names so they stay 1..n
    for i, acct in ipairs(accts) do
        if acct.name == nil or acct.name:match('^Account %d+$') then
            acct.name = 'Account ' .. tostring(i);
        end
    end
end

local function glass_already_counted(store, serial)
    if store == nil or serial == nil then return false; end
    for _, sn in ipairs(store.counted_glasses or {}) do
        if sn == serial then return true; end
    end
    return false;
end

-- Counts one entry against a store. Returns true if it actually counted.
local function count_dynamis_entry(store, serial, label)
    if store == nil then return false; end
    if serial ~= nil then
        if glass_already_counted(store, serial) then return false; end
        table.insert(store.counted_glasses, serial);
    end
    if (store.entries_remaining or 0) > 0 then
        store.entries_remaining = store.entries_remaining - 1;
        save_settings();
        print_success(string.format('Dynamis %s! %d entr%s remaining this week.',
            label or 'entry counted', store.entries_remaining,
            store.entries_remaining == 1 and 'y' or 'ies'));
    else
        save_settings();
        print_msg('Dynamis entry detected but the counter is already at 0.');
    end
    return true;
end

-- Every key item id this addon tracks, in one place.
local TRACKED_KI_IDS = {};
do
    local seen = {};
    local function add(id)
        if id ~= nil and not seen[id] then seen[id] = true; table.insert(TRACKED_KI_IDS, id); end
    end
    for _, enm in ipairs(ENM_KEY_ITEMS) do add(enm.ki_id); end
    for _, card in ipairs(LIMBUS_CARDS) do add(card.ki_id); end
    add(XSKNIFE_KI_ID_FIRST); add(XSKNIFE_KI_ID_REPEAT);
    add(COOKBOOK_KI_ID); add(SPICEGALS_KI_ID); add(UNINVITED_KI_ID);
    for _, id in pairs(ECOWARRIOR_KI_IDS) do add(id); end
end

-- Ids currently held, as a plain list, for persisting to homework.json.
function build_ki_cache()
    local held = {};
    for _, id in ipairs(TRACKED_KI_IDS) do
        if tracker.kis[id] == true then table.insert(held, id); end
    end
    return held;
end

local ECOWARRIOR_ZONES = {
    sandoria = {
        quest_npc = 'Norejaie',
        field_agent = 'Rojaireaut',
        ki_name = 'Indigested stalagmite',
        zone_name = "Ordelle's Caves",
        city_name = "Southern San d'Oria",
        short_zone = "Ordelle's",
        short_city = "San d'Oria",
        short_agent = 'Rojaireaut',
    },
    windurst = {
        quest_npc = 'Lumomo',
        field_agent = 'Ahko Mhalijikhari',
        ki_name = 'Indigested meat',
        zone_name = 'Maze of Shakhrami',
        city_name = 'Windurst Waters',
        short_zone = 'Shakhrami',
        short_city = 'Windurst',
        short_agent = 'Ahko',
    },
    bastok = {
        quest_npc = 'Raifa',
        field_agent = 'Degga',
        ki_name = 'Indigested ore',
        zone_name = 'Gusgen Mines',
        city_name = 'Port Bastok',
        short_zone = 'Gusgen',
        short_city = 'Bastok',
        short_agent = 'Degga',
    }
};

local function get_char_name()
    local success, result = pcall(function()
        local party = AshitaCore:GetMemoryManager():GetParty();
        local name = party:GetMemberName(0);
        return name;
    end);
    if success and result ~= nil and result ~= '' then
        return result;
    end
    return 'Unknown';
end

local function get_zone_id()
    local party = AshitaCore:GetMemoryManager():GetParty();
    return party:GetMemberZone(0);
end


local function is_in_highwind_zone()
    local zone_id = get_zone_id();
    for _, v in ipairs(HIGHWIND_ZONES) do
        if zone_id == v then return true; end
    end
    return false;
end

local function get_char_data()
    if tracker.current_char == nil then
        tracker.current_char = get_char_name();
    end
    if tracker.current_char == 'Unknown' then
        return nil;
    end
    if tracker.settings.characters[tracker.current_char] == nil then
        tracker.settings.characters[tracker.current_char] = {
            last_reset = os.time(),
            enm_timers = {},
            xsknife_data = { step = 'unknown', has_ki = false },
            quest_steps = { highwind = 'scanned', uninvited = 'unknown', spicegals = 'unknown', cookbook = 'unknown' },
            ecowarrior_data = { step = 'unknown', current_nation = nil, locked_nations = {}, knows_status = false },
            dynamis_data = new_dynamis_data()
        };
        save_settings();
        print_success('Created new tracker for character: ' .. tracker.current_char);
    end
    -- Ensure enm_timers exists
    if tracker.settings.characters[tracker.current_char].enm_timers == nil then
        tracker.settings.characters[tracker.current_char].enm_timers = {};
    end
    -- Ensure xsknife_data exists
    if tracker.settings.characters[tracker.current_char].xsknife_data == nil then
        tracker.settings.characters[tracker.current_char].xsknife_data = { step = 'unknown', has_ki = false };
    end
    -- Migrate old xsknife_data format
    if tracker.settings.characters[tracker.current_char].xsknife_data.step == nil then
        local old_data = tracker.settings.characters[tracker.current_char].xsknife_data;
        tracker.settings.characters[tracker.current_char].xsknife_data = { step = 'unknown', has_ki = old_data.has_ki or false };
    end
    -- Ensure quest_steps exists
    if tracker.settings.characters[tracker.current_char].quest_steps == nil then
        tracker.settings.characters[tracker.current_char].quest_steps = { highwind = 'scanned', uninvited = 'unknown', spicegals = 'unknown', cookbook = 'unknown' };
    end
    -- Ensure ecowarrior_data exists
    if tracker.settings.characters[tracker.current_char].ecowarrior_data == nil then
        tracker.settings.characters[tracker.current_char].ecowarrior_data = { step = 'unknown', current_nation = nil, locked_nations = {}, knows_status = false };
    end
    -- Migrate ecowarrior_data to include knows_status
    if tracker.settings.characters[tracker.current_char].ecowarrior_data.knows_status == nil then
        local eco = tracker.settings.characters[tracker.current_char].ecowarrior_data;
        -- If step is 'scanned', 'ready', or 'done', we know status
        eco.knows_status = (eco.step == 'scanned' or eco.step == 'ready' or eco.step == 'done');
    end
    -- Ensure dynamis_data exists
    if tracker.settings.characters[tracker.current_char].dynamis_data == nil then
        tracker.settings.characters[tracker.current_char].dynamis_data = new_dynamis_data();
    end
    return tracker.settings.characters[tracker.current_char];
end

-- Checks if player has a key item (reads from tracker.kis table, NOT game memory)
local function has_key_item(ki_id)
    return tracker.kis[ki_id] == true;
end

-- Populates tracker.kis from game memory - ONLY called once on addon load if already logged in
local function populate_kis_from_memory()
    local player = AshitaCore:GetMemoryManager():GetPlayer();
    if player == nil then return false; end
    local found_any = false;
    for _, enm in ipairs(ENM_KEY_ITEMS) do
        local has = player:HasKeyItem(enm.ki_id);
        tracker.kis[enm.ki_id] = has;
        if has then found_any = true; end
    end
    -- Limbus cards (for floating window display)
    for _, card in ipairs(LIMBUS_CARDS) do
        local has = player:HasKeyItem(card.ki_id);
        tracker.kis[card.ki_id] = has;
        if has then found_any = true; end
    end
    local extras = { XSKNIFE_KI_ID_FIRST, XSKNIFE_KI_ID_REPEAT, COOKBOOK_KI_ID, SPICEGALS_KI_ID, UNINVITED_KI_ID };
    for _, ki_id in ipairs(extras) do
        local has = player:HasKeyItem(ki_id);
        tracker.kis[ki_id] = has;
        if has then found_any = true; end
    end
    for _, ki_id in pairs(ECOWARRIOR_KI_IDS) do
        local has = player:HasKeyItem(ki_id);
        tracker.kis[ki_id] = has;
        if has then found_any = true; end
    end
    -- If we didn't find ANY KI, the game hasn't sent the KI list yet.
    -- Don't mark as initialized so we wait for the 0x055 packet path.
    if not found_any then
        -- Reset what we just wrote so a stale scan won't corrupt data
        tracker.kis = {};
        return false;
    end
    tracker.kis_initialized = true;
    return true;
end

-- Rebuilds tracker.kis from the list persisted by the previous session.
-- On clients where HasKeyItem is unavailable this is the only way a reload can
-- come back with a correct picture without waiting for a zone change.
local function restore_ki_cache()
    if tracker.current_char == nil or tracker.current_char == 'Unknown' then return false; end
    local cd = tracker.settings.characters[tracker.current_char];
    if cd == nil or type(cd.ki_cache) ~= 'table' then return false; end
    local held = {};
    for _, id in ipairs(cd.ki_cache) do held[id] = true; end
    tracker.kis = {};
    for _, id in ipairs(TRACKED_KI_IDS) do
        tracker.kis[id] = (held[id] == true);
    end
    tracker.kis_initialized = true;
    return true;
end

local function scan_key_items(silent)
    -- HARD GUARD. Without a real key item read, has_key_item() answers false for
    -- everything and this function will happily write "you own nothing" across
    -- every ENM, quest and timer, then save it. That is exactly how data was
    -- lost before 3.4.5. Never scan on an empty table.
    if not tracker.kis_initialized then
        if not silent then
            print_error('Key items are not loaded yet - nothing was scanned and nothing was changed.');
            print_msg('Zone once (or warp) so the game re-sends the key item list, then try again.');
        end
        return false;
    end
    local char_data = get_char_data();
    local current_time = os.time();
    local found_count = 0;
    local new_entries = 0;
    local updated_count = 0;
    if not silent then print_msg('Scanning key items...'); end
    -- Scan ENM/Limbus KIs
    for _, enm in ipairs(ENM_KEY_ITEMS) do
        local has_ki = has_key_item(enm.ki_id);
        if char_data.enm_timers[enm.name] == nil then
            char_data.enm_timers[enm.name] = { has_ki = has_ki, next_ki_time = current_time + enm.cooldown, timer_source = 'scan' };
            new_entries = new_entries + 1;
            if has_ki then found_count = found_count + 1; end
        else
            local old_has_ki = char_data.enm_timers[enm.name].has_ki;
            if old_has_ki ~= has_ki then updated_count = updated_count + 1; end
            char_data.enm_timers[enm.name].has_ki = has_ki;
            if char_data.enm_timers[enm.name].next_ki_time == 0 then
                char_data.enm_timers[enm.name].next_ki_time = current_time + enm.cooldown;
                char_data.enm_timers[enm.name].timer_source = 'scan';
                updated_count = updated_count + 1;
            end
            if has_ki then found_count = found_count + 1; end
        end
    end
    -- Scan X'sKnife KIs
    local xsknife_has = has_key_item(XSKNIFE_KI_ID_FIRST) or has_key_item(XSKNIFE_KI_ID_REPEAT);
    local old_xsknife_has = char_data.xsknife_data.has_ki;
    if old_xsknife_has ~= xsknife_has then updated_count = updated_count + 1; end
    char_data.xsknife_data.has_ki = xsknife_has;
    local current_step = char_data.xsknife_data.step;
    if current_step == 'unknown' then
        if xsknife_has then
            char_data.xsknife_data.step = 'scanned_has_ki';
            if not silent then print_msg("X'sKnife: Found KI - Go to Boneyard Gully!"); end
        else
            char_data.xsknife_data.step = 'scanned_no_ki';
            if not silent then print_msg("X'sKnife: No KI found."); end
        end
    elseif (current_step == 'scanned_no_ki' or current_step == 'scanned_has_ki_used') and xsknife_has then
        char_data.xsknife_data.step = 'scanned_has_ki';
        if not silent then print_msg("X'sKnife: Found KI - Go to Boneyard Gully!"); end
    elseif current_step == 'scanned_has_ki' and not xsknife_has then
        char_data.xsknife_data.step = 'scanned_has_ki_used';
        if not silent then print_msg("X'sKnife: KI used - Check Despachiaire for another."); end
    end
    -- Scan Highwind
    if char_data.quest_steps.highwind == 'unknown' then char_data.quest_steps.highwind = 'scanned'; end
    -- Scan SpiceGals KI
    if has_key_item(SPICEGALS_KI_ID) then
        if char_data.quest_steps.spicegals == 'unknown' or char_data.quest_steps.spicegals == 'scanned' or char_data.quest_steps.spicegals == 'rouva' or char_data.quest_steps.spicegals == 'riverne' then
            char_data.quest_steps.spicegals = 'rouva_return';
            if not silent then print_msg('Found Rivernewort - Return to Rouva!'); end
        end
    elseif char_data.quest_steps.spicegals == 'unknown' then
        char_data.quest_steps.spicegals = 'scanned';
    end
    -- Scan CookBook KI
    if has_key_item(COOKBOOK_KI_ID) then
        if char_data.quest_steps.cookbook == 'unknown' or char_data.quest_steps.cookbook == 'scanned' or char_data.quest_steps.cookbook == 'jonette' or char_data.quest_steps.cookbook == 'sacrarium' then
            char_data.quest_steps.cookbook = 'jonette_return';
            if not silent then print_msg('Found Tavnazian Cookbook - Return to Jonette!'); end
        end
    elseif char_data.quest_steps.cookbook == 'unknown' then
        char_data.quest_steps.cookbook = 'scanned';
    end
    -- Scan UnInvited KI
    if has_key_item(UNINVITED_KI_ID) then
        if char_data.quest_steps.uninvited == 'unknown' or char_data.quest_steps.uninvited == 'scanned' or char_data.quest_steps.uninvited == 'justinius' then
            char_data.quest_steps.uninvited = 'bcnm';
            if not silent then print_msg('Found Monarch Linn Patrol Permit - Head to BCNM!'); end
        end
    elseif char_data.quest_steps.uninvited == 'unknown' then
        char_data.quest_steps.uninvited = 'scanned';
    end
    -- Scan EcoWarrior KIs
    local eco_data = char_data.ecowarrior_data;
    for nation, ki_id in pairs(ECOWARRIOR_KI_IDS) do
        if has_key_item(ki_id) then
            -- Has an EcoWarrior KI - update state
            local zone_info = ECOWARRIOR_ZONES[nation];
            if eco_data.step == 'unknown' then
                -- Found KI but don't know locked nations yet
                eco_data.step = 'scanned_has_ki';
                eco_data.current_nation = nation;
                if not silent then print_msg('Found ' .. zone_info.ki_name .. ' - Return to ' .. zone_info.field_agent .. '! (Locked nations unknown)'); end
            elseif eco_data.step == 'scanned' or eco_data.step == 'ready' or eco_data.step == 'field_agent' or eco_data.step == 'nm' then
                -- We know locked nations from Eeko-Weeko or quest interaction
                eco_data.step = 'field_agent_return';
                eco_data.current_nation = nation;
                if not silent then print_msg('Found ' .. zone_info.ki_name .. ' - Return to ' .. zone_info.field_agent .. '!'); end
            end
            break;  -- Only one EcoWarrior KI at a time
        end
    end
    -- NOTE: We do NOT change EcoWarrior from 'unknown' to 'scanned' here because
    -- having no KI doesn't tell us if the quest was already completed this week.
    -- EcoWarrior status can only be determined by talking to Eeko-Weeko or quest NPCs.
    save_settings();
    if not silent and new_entries > 0 then print_msg(string.format('Scanned %d new ENM/Limbus activities', new_entries)); end
    if not silent and updated_count > 0 then print_msg(string.format('Updated %d key item statuses', updated_count)); end
    if not silent then print_success(string.format('Scan complete! You have %d/%d key items', found_count, #ENM_KEY_ITEMS)); end
    return true;
end

local function on_ki_gained(ki_id)
    local char_data = get_char_data();
    if char_data == nil then return; end
    -- Check ENM/Limbus KIs
    for _, enm in ipairs(ENM_KEY_ITEMS) do
        if ki_id == enm.ki_id then
            local current_time = os.time();
            char_data.enm_timers[enm.name] = { has_ki = true, next_ki_time = current_time + enm.cooldown, timer_source = 'obtained' };
            save_settings();
            local days = math.floor(enm.cooldown / 86400);
            local hours = math.floor((enm.cooldown % 86400) / 3600);
            print_success(string.format('Obtained %s! Next KI available in %d day(s), %d hour(s)', enm.ki_name, days, hours));
            return;
        end
    end
    -- Check X'sKnife KIs
    if ki_id == XSKNIFE_KI_ID_FIRST or ki_id == XSKNIFE_KI_ID_REPEAT then
        char_data.xsknife_data.has_ki = true;
        local current_step = char_data.xsknife_data.step;
        if current_step == 'unknown' or current_step == 'scanned_no_ki' or current_step == 'scanned_has_ki_used' then
            char_data.xsknife_data.step = 'boneyard';
        elseif current_step == 'despachiaire' then
            char_data.xsknife_data.step = 'boneyard';
        end
        save_settings();
        print_success('Obtained X\'sKnife Letter - Head to Boneyard Gully!');
        return;
    end
    -- Check CookBook KI
    if ki_id == COOKBOOK_KI_ID then
        char_data.quest_steps.cookbook = 'jonette_return';
        save_settings();
        print_success('Obtained Tavnazian Cookbook - Return to Jonette!');
        return;
    end
    -- Check SpiceGals KI
    if ki_id == SPICEGALS_KI_ID then
        char_data.quest_steps.spicegals = 'rouva_return';
        save_settings();
        print_success('Obtained Rivernewort - Return to Rouva!');
        return;
    end
    -- Check UnInvited KI
    if ki_id == UNINVITED_KI_ID then
        char_data.quest_steps.uninvited = 'bcnm';
        save_settings();
        print_success('Obtained Monarch Linn Patrol Permit - Head to BCNM!');
        return;
    end
    -- Check EcoWarrior KIs
    for nation, id in pairs(ECOWARRIOR_KI_IDS) do
        if ki_id == id then
            local eco_data = char_data.ecowarrior_data;
            if eco_data ~= nil then
                local zone_info = ECOWARRIOR_ZONES[nation];
                if eco_data.step == 'unknown' or eco_data.step == 'scanned_has_ki' then
                    -- Don't know locked nations yet
                    eco_data.step = 'scanned_has_ki';
                    eco_data.current_nation = nation;
                    save_settings();
                    print_success('Obtained ' .. zone_info.ki_name .. ' - Return to ' .. zone_info.field_agent .. '! (Locked nations unknown)');
                else
                    -- We know locked nations from Eeko-Weeko or quest interaction
                    eco_data.step = 'field_agent_return';
                    eco_data.current_nation = nation;
                    save_settings();
                    print_success('Obtained ' .. zone_info.ki_name .. ' - Return to ' .. zone_info.field_agent .. '!');
                end
            end
            return;
        end
    end
end

local function on_ki_lost(ki_id)
    local char_data = get_char_data();
    if char_data == nil then return; end
    -- Check ENM/Limbus KIs
    for _, enm in ipairs(ENM_KEY_ITEMS) do
        if ki_id == enm.ki_id then
            local timer_data = char_data.enm_timers[enm.name];
            if timer_data == nil then
                -- Never scanned, so we have no idea when the KI was obtained.
                -- Record the loss with an unknown timer rather than dropping it.
                char_data.enm_timers[enm.name] = { has_ki = false, next_ki_time = 0, timer_source = 'scan' };
            else
                timer_data.has_ki = false;
            end
            save_settings();
            print_msg(string.format('Used %s - Timer continues', enm.ki_name));
            return;
        end
    end
    -- Check X'sKnife KIs
    if ki_id == XSKNIFE_KI_ID_FIRST or ki_id == XSKNIFE_KI_ID_REPEAT then
        char_data.xsknife_data.has_ki = false;
        local current_step = char_data.xsknife_data.step;
        if current_step == 'unknown' or current_step == 'scanned_has_ki' then
            char_data.xsknife_data.step = 'scanned_has_ki_used';
        elseif current_step == 'boneyard' then
            char_data.xsknife_data.step = 'done';
            print_success("X'sKnife complete for this week!");
        elseif current_step == 'boneyard_2x' then
            char_data.xsknife_data.step = 'despachiaire';
            print_success("X'sKnife fight done! Go to Despachiaire for another KI!");
        end
        save_settings();
        return;
    end
    -- Check CookBook KI
    if ki_id == COOKBOOK_KI_ID then
        if char_data.quest_steps.cookbook == 'jonette_return' then
            char_data.quest_steps.cookbook = 'done';
            save_settings();
            print_success('CookBook complete!');
        end
        return;
    end
    -- Check SpiceGals KI
    if ki_id == SPICEGALS_KI_ID then
        if char_data.quest_steps.spicegals == 'rouva_return' then
            char_data.quest_steps.spicegals = 'done';
            save_settings();
            print_success('SpiceGals complete!');
        end
        return;
    end
    -- Check UnInvited KI
    if ki_id == UNINVITED_KI_ID then
        if char_data.quest_steps.uninvited == 'bcnm' then
            char_data.quest_steps.uninvited = 'justinius_return';
            save_settings();
            print_success('Entered BCNM - Fight the NM then return to Justinius!');
        end
        return;
    end
    -- Check EcoWarrior KIs
    for nation, id in pairs(ECOWARRIOR_KI_IDS) do
        if ki_id == id then
            local eco_data = char_data.ecowarrior_data;
            if eco_data ~= nil then
                if eco_data.knows_status then
                    -- We know locked nations, track completion
                    eco_data.step = 'done';
                    if eco_data.locked_nations == nil then eco_data.locked_nations = {}; end
                    -- Check if already locked before adding (prevent duplicates)
                    local already_locked = false;
                    for _, n in ipairs(eco_data.locked_nations) do
                        if n == nation then already_locked = true; break; end
                    end
                    if not already_locked then
                        table.insert(eco_data.locked_nations, nation);
                    elseif #eco_data.locked_nations >= 3 then
                        -- Cycle-restart detection: re-completing a nation that's
                        -- already locked while all 3 are locked means the in-game
                        -- cycle silently reset. Start a fresh cycle with just this
                        -- nation locked.
                        eco_data.locked_nations = { nation };
                    end
                    eco_data.current_nation = nil;
                    save_settings();
                    print_success('EcoWarrior complete for ' .. nation .. '!');
                else
                    -- We didn't know locked nations, go back to unknown
                    eco_data.step = 'unknown';
                    eco_data.current_nation = nil;
                    save_settings();
                    print_success('EcoWarrior KI used! Use /hw eco or talk to Eeko-Weeko to update status.');
                end
            end
            return;
        end
    end
end

-- Defined further down (UI section) but needed by on_character_change above it.
local update_char_list;

local function normalize_task(task)
    return task:lower():gsub('%s+', ''):gsub("'", '');
end

-- Short forms advertised in the UI tooltips. Previously these were suggested to
-- the user but rejected by the exact-match lookup below.
local TASK_ALIASES = {
    knife     = "X'sKnife",
    xknife    = "X'sKnife",
    high      = 'Highwind',
    hw        = 'Highwind',
    spice     = 'SpiceGals',
    gals      = 'SpiceGals',
    cook      = 'CookBook',
    book      = 'CookBook',
    uninv     = 'UnInvited',
    invited   = 'UnInvited',
    eco       = 'EcoWarrior',
    warrior   = 'EcoWarrior'
};

local function find_task_name(task)
    local normalized = normalize_task(task);
    -- Exact match on the configured task list wins.
    for _, v in ipairs(tracker.settings.tasks) do
        if normalize_task(v) == normalized then return v; end
    end
    -- Then a known alias, but only if that task is actually configured.
    local aliased = TASK_ALIASES[normalized];
    if aliased ~= nil then
        for _, v in ipairs(tracker.settings.tasks) do
            if v == aliased then return v; end
        end
    end
    -- Finally an unambiguous prefix (e.g. 'ecow' -> 'EcoWarrior').
    local match = nil;
    for _, v in ipairs(tracker.settings.tasks) do
        if normalize_task(v):sub(1, #normalized) == normalized then
            if match ~= nil then return nil; end
            match = v;
        end
    end
    return match;
end

local reset_dynamis_store;

local function calculate_next_reset(from_time)
    local SECONDS_PER_DAY = 86400;
    local JST_OFFSET = 9 * 3600;
    from_time = from_time or os.time();
    local jpUTC = from_time + JST_OFFSET;
    local jpDay = math.floor(jpUTC / SECONDS_PER_DAY);
    local weekday = (jpDay + 3) % 7;
    local daysRemaining = (weekday == 0) and 7 or (7 - weekday);
    local jstReset = (jpDay + daysRemaining) * SECONDS_PER_DAY;
    return jstReset - JST_OFFSET;
end

-- Shared by per-character stores and account stores.
function reset_dynamis_store(store, current_time)
    if store == nil then return; end
    -- Legacy fields from before serial tracking.
    store.glass_used = nil;
    store.dynamis_zone = nil;
    store.claimed_before_reset = nil;
    -- A glass broken in the final day before reset belongs to the new week, so the
    -- entry stays spent and its serial stays on the list.
    if store.claimed_at ~= nil and (current_time - store.claimed_at) <= DYNAMIS_CLAIM_CARRY_WINDOW then
        store.entries_remaining = 1;
        store.counted_glasses = { 'carried-' .. tostring(store.claimed_at) };
    else
        store.entries_remaining = 2;
        store.counted_glasses = {};
    end
    store.claimed_at = nil;
end

local function reset_character_data(char_data)
    local current_time = os.time();
    char_data.last_reset = current_time;
    -- UnInvited: only reset if done, otherwise keep current step
    local uninvited_step = char_data.quest_steps and char_data.quest_steps.uninvited or 'unknown';
    if uninvited_step == 'done' or uninvited_step == 'unknown' or uninvited_step == 'scanned' then
        uninvited_step = 'justinius';
    end
    -- SpiceGals: only reset if done, otherwise keep current step
    local spicegals_step = char_data.quest_steps and char_data.quest_steps.spicegals or 'unknown';
    if spicegals_step == 'done' or spicegals_step == 'unknown' or spicegals_step == 'scanned' then
        spicegals_step = 'rouva';
    end
    -- CookBook: only reset if done, otherwise keep current step
    local cookbook_step = char_data.quest_steps and char_data.quest_steps.cookbook or 'unknown';
    if cookbook_step == 'done' or cookbook_step == 'unknown' or cookbook_step == 'scanned' then
        cookbook_step = 'jonette';
    end
    char_data.quest_steps = { highwind = 'start', uninvited = uninvited_step, spicegals = spicegals_step, cookbook = cookbook_step };
    if char_data.ecowarrior_data then
        local current_step = char_data.ecowarrior_data.step;
        if current_step == 'unknown' then
            char_data.ecowarrior_data.step = 'unknown';
            char_data.ecowarrior_data.knows_status = false;
        elseif current_step == 'scanned' then
            char_data.ecowarrior_data.step = 'ready';
            char_data.ecowarrior_data.knows_status = true;
        elseif current_step == 'scanned_has_ki' then
            char_data.ecowarrior_data.step = 'scanned_has_ki';  -- Still don't know locked nations
            char_data.ecowarrior_data.knows_status = false;
        elseif current_step == 'done' then
            char_data.ecowarrior_data.step = 'ready';
            char_data.ecowarrior_data.knows_status = true;
        elseif current_step == 'ready' then
            char_data.ecowarrior_data.knows_status = true;
        end
        -- All other steps (field_agent, nm, field_agent_return, reward) stay as-is including knows_status
        if current_step == 'done' then
            char_data.ecowarrior_data.current_nation = nil;
        end
    end
    if char_data.xsknife_data then
        local current_step = char_data.xsknife_data.step;
        if current_step == 'unknown' then
            char_data.xsknife_data.step = 'unknown';
        elseif current_step == 'scanned_no_ki' or current_step == 'scanned_has_ki_used' then
            char_data.xsknife_data.step = 'despachiaire';
        elseif current_step == 'scanned_has_ki' then
            char_data.xsknife_data.step = 'boneyard_2x';
        elseif current_step == 'despachiaire' then
            char_data.xsknife_data.step = 'despachiaire';
        elseif current_step == 'boneyard' then
            char_data.xsknife_data.step = 'boneyard_2x';
        elseif current_step == 'boneyard_2x' then
            char_data.xsknife_data.step = 'boneyard_2x';
        elseif current_step == 'done' then
            char_data.xsknife_data.step = 'despachiaire';
        end
    end
    -- Dynamis: fresh allowance and a fresh list of counted glass serials.
    if char_data.dynamis_data then
        reset_dynamis_store(char_data.dynamis_data, current_time);
    else
        char_data.dynamis_data = new_dynamis_data();
    end
end

local function reset_tracker()
    -- Reset ALL characters, not just current one
    local reset_count = 0;
    for char_name, char_data in pairs(tracker.settings.characters) do
        if char_name ~= nil and char_name ~= '' and char_name ~= 'Unknown' then
            reset_character_data(char_data);
            reset_count = reset_count + 1;
        end
    end
    -- Account stores are shared, so they reset once rather than once per character.
    local now = os.time();
    for _, acct in ipairs(tracker.settings.dynamis_accounts or {}) do
        reset_dynamis_store(acct, now);
    end
    save_settings();
    print_success('Weekly tracker has been reset for all ' .. reset_count .. ' characters!');
    local next_reset = calculate_next_reset(os.time());
    tracker.next_check_time = next_reset;
end

local function initialize_timer()
    local char_data = get_char_data();
    local current_time = os.time();
    -- calculate_next_reset always returns a strictly future timestamp, so the old
    -- `current_time >= calculate_next_reset(current_time)` guard could never fire
    -- and `last_reset < last_reset_point` was likewise always true. Both dropped.
    if current_time >= calculate_next_reset(char_data.last_reset) then
        reset_tracker(); return;
    end
    tracker.next_check_time = calculate_next_reset(current_time);
end

local function on_character_change(new_char_name)
    if tracker.current_char ~= new_char_name then
        local is_first_detection = (tracker.current_char == 'Unknown');
        if is_first_detection then print_success('Character detected: ' .. new_char_name);
        else print_success('Character changed: ' .. new_char_name); end
        tracker.next_check_time = 0;
        tracker.current_char = new_char_name;
        tracker.kis = {};
        tracker.kis_initialized = false;
        local char_data = get_char_data();
        if not tracker.kis_initialized then restore_ki_cache(); end
        local needs_scan = char_data.quest_steps.uninvited == 'unknown' or
                          char_data.quest_steps.spicegals == 'unknown' or
                          char_data.quest_steps.cookbook == 'unknown';
        if needs_scan then print_msg('Use /hw scan to check key items for this character'); end
        initialize_timer();
        update_char_list();  -- keep the window dropdown in sync if it is already open
    end
end

local HDR = '\30\081[\30\082Homework\30\081]\30\106 ';

-- EcoWarrior nations still open this cycle, as display text.
local function eco_available_text(locked)
    local available = {};
    for _, n in ipairs({'sandoria', 'windurst', 'bastok'}) do
        local is_locked = false;
        for _, l in ipairs(locked or {}) do if l == n then is_locked = true; break; end end
        if not is_locked then
            if n == 'sandoria' then table.insert(available, "San d'Oria");
            elseif n == 'windurst' then table.insert(available, 'Windurst');
            elseif n == 'bastok' then table.insert(available, 'Bastok'); end
        end
    end
    if #available == 0 then return 'All Nations', 0; end      -- cycle complete, all reopen
    if #available == 3 then return 'All Nations', 3; end
    if #available == 2 then return available[1] .. ' & ' .. available[2], 2; end
    return available[1], 1;
end

-- One chat line for one task. Shared by /hw weeklys and /hw chars <name>,
-- which previously carried two drifting copies of this logic.
local function format_task_line(task, char_data)
    local normalized = normalize_task(task);
    if normalized == 'xsknife' then
        local step = (char_data.xsknife_data or {}).step or 'unknown';
        if step == 'unknown' then return HDR .. '\30\104[ ? ]\30\106 ' .. task;
        elseif step == 'scanned_no_ki' then return HDR .. '\30\104[   ]\30\106 ' .. task;
        elseif step == 'scanned_has_ki' then return HDR .. '\30\104[Boneyard Gully - Requiem of Sin]\30\106 ' .. task;
        elseif step == 'scanned_has_ki_used' then return HDR .. '\30\104[Despachiaire]\30\106 ' .. task;
        elseif step == 'despachiaire' then return HDR .. '\30\110[Despachiaire]\30\106 ' .. task;
        elseif step == 'boneyard' then return HDR .. '\30\110[Boneyard Gully - Requiem of Sin]\30\106 ' .. task;
        elseif step == 'boneyard_2x' then return HDR .. '\30\110[2x Boneyard Gully - Requiem of Sin]\30\106 ' .. task;
        elseif step == 'done' then return HDR .. '\30\076[X]\30\106 ' .. task;
        else return HDR .. '\30\104[   ]\30\106 ' .. task; end
    elseif normalized == 'highwind' then
        local step = char_data.quest_steps.highwind or 'scanned';
        if step == 'start' then return HDR .. '\30\110[NM]\30\106 ' .. task;
        elseif step == 'done' then return HDR .. '\30\076[X]\30\106 ' .. task;
        else return HDR .. '\30\104[   ]\30\106 ' .. task; end
    elseif normalized == 'uninvited' then
        local step = char_data.quest_steps.uninvited or 'unknown';
        if step == 'scanned' then return HDR .. '\30\104[   ]\30\106 ' .. task;
        elseif step == 'justinius' then return HDR .. '\30\110[Justinius - Start]\30\106 ' .. task;
        elseif step == 'bcnm' then return HDR .. '\30\110[BCNM Monarch]\30\106 ' .. task;
        elseif step == 'justinius_return' then return HDR .. '\30\110[Justinius - Reward]\30\106 ' .. task;
        elseif step == 'done' then return HDR .. '\30\076[X]\30\106 ' .. task;
        else return HDR .. '\30\104[ ? ]\30\106 ' .. task; end
    elseif normalized == 'spicegals' then
        local step = char_data.quest_steps.spicegals or 'unknown';
        if step == 'scanned' then return HDR .. '\30\104[   ]\30\106 ' .. task;
        elseif step == 'rouva' then return HDR .. '\30\110[Rouva - Start]\30\106 ' .. task;
        elseif step == 'riverne' then return HDR .. '\30\110[Riverne B]\30\106 ' .. task;
        elseif step == 'rouva_return' then return HDR .. '\30\110[Rouva - Reward]\30\106 ' .. task;
        elseif step == 'done' then return HDR .. '\30\076[X]\30\106 ' .. task;
        else return HDR .. '\30\104[ ? ]\30\106 ' .. task; end
    elseif normalized == 'cookbook' then
        local step = char_data.quest_steps.cookbook or 'unknown';
        if step == 'scanned' then return HDR .. '\30\104[   ]\30\106 ' .. task;
        elseif step == 'jonette' then return HDR .. '\30\110[Jonette - Start]\30\106 ' .. task;
        elseif step == 'sacrarium' then return HDR .. '\30\110[??? Sacrarium]\30\106 ' .. task;
        elseif step == 'jonette_return' then return HDR .. '\30\110[Jonette - Reward]\30\106 ' .. task;
        elseif step == 'done' then return HDR .. '\30\076[X]\30\106 ' .. task;
        else return HDR .. '\30\104[ ? ]\30\106 ' .. task; end
    elseif normalized == 'ecowarrior' then
        local eco_data = char_data.ecowarrior_data or {};
        local step = eco_data.step or 'unknown';
        local nation = eco_data.current_nation;
        local available_text = eco_available_text(eco_data.locked_nations);
        local zone_info = nation and ECOWARRIOR_ZONES[nation] or nil;
        -- \30\110 = green (status known), \30\104 = yellow (status uncertain)
        local color = eco_data.knows_status and '\30\110' or '\30\104';
        if step == 'scanned' then return HDR .. '\30\104[' .. available_text .. ']\30\106 ' .. task;
        elseif step == 'ready' then return HDR .. '\30\110[' .. available_text .. ']\30\106 ' .. task;
        elseif step == 'done' then return HDR .. '\30\076[' .. available_text .. ']\30\106 ' .. task;
        elseif step == 'scanned_has_ki' and zone_info then
            return HDR .. '\30\104[' .. zone_info.zone_name .. ' - ' .. zone_info.field_agent .. ']\30\106 ' .. task;
        elseif step == 'field_agent' and zone_info then
            return HDR .. color .. '[' .. zone_info.zone_name .. ' - ' .. zone_info.field_agent .. ']\30\106 ' .. task;
        elseif step == 'nm' and nation then
            return HDR .. color .. '[Kill the NM]\30\106 ' .. task;
        elseif step == 'field_agent_return' and zone_info then
            return HDR .. color .. '[' .. zone_info.zone_name .. ' - ' .. zone_info.field_agent .. ']\30\106 ' .. task;
        elseif step == 'reward' and zone_info then
            return HDR .. color .. '[' .. zone_info.city_name .. ' - ' .. zone_info.quest_npc .. ']\30\106 ' .. task;
        elseif step == 'unknown' then return HDR .. '\30\104[ ? ]\30\106 ' .. task;
        else return HDR .. '\30\104[   ]\30\106 ' .. task; end
    end
    return nil;
end

-- One chat line for the Dynamis entry counter. Mirrors the row the floating
-- window draws above the tasks.
local function format_dynamis_line(char_name, char_data)
    local store, shared = get_dynamis_store(char_name);
    if store == nil then store = char_data.dynamis_data; end
    if store == nil then return HDR .. '\30\104[ ? ]\30\106 Dynamis'; end
    local entries = store.entries_remaining or 2;
    local suffix = shared and ' \30\067[account]\30\106' or '';
    if entries <= 0 then return HDR .. '\30\076[X]\30\106 Dynamis \30\071(no runs left)\30\106' .. suffix;
    elseif entries == 1 then return HDR .. '\30\104[1 Run]\30\106 Dynamis \30\071(1 run left)\30\106' .. suffix;
    else return HDR .. '\30\110[' .. entries .. ' Runs]\30\106 Dynamis \30\071(' .. entries .. ' runs left)\30\106' .. suffix; end
end

-- One chat line for one ENM/Limbus timer.
local function format_timer_line(enm, timer_data, current_time)
    local status_icon = '\30\104[ ? ]\30\106';
    local status_text = '\30\071(Unknown)\30\106';
    if timer_data ~= nil then
        if timer_data.next_ki_time == nil or timer_data.next_ki_time == 0 then
            if timer_data.has_ki then status_icon = '\30\104[KI]\30\106'; else status_icon = '\30\104[   ]\30\106'; end
        elseif current_time >= timer_data.next_ki_time then
            if timer_data.has_ki then status_icon = '\30\110[KI]\30\106'; else status_icon = '\30\110[   ]\30\106'; end
            status_text = '\30\071(Ready)\30\106';
        elseif timer_data.timer_source == 'scan' then
            if timer_data.has_ki then status_icon = '\30\104[KI]\30\106'; else status_icon = '\30\104[   ]\30\106'; end
        else
            local time_left = timer_data.next_ki_time - current_time;
            local days = math.floor(time_left / 86400);
            local hours = math.floor((time_left % 86400) / 3600);
            if timer_data.has_ki then status_icon = '\30\076[KI]\30\106'; else status_icon = '\30\068[   ]\30\106'; end
            if days > 0 then status_text = string.format('\30\071(%dd %dh)\30\106', days, hours);
            else status_text = string.format('\30\071(%dh)\30\106', hours); end
        end
    end
    return string.format('%s%s %s - %s', HDR, status_icon, enm.name, status_text);
end

-- "2 day(s)" / "5 hour(s), 3 minute(s)" / "12 minute(s)"
local function format_countdown(seconds)
    local days = math.floor(seconds / 86400);
    local hours = math.floor((seconds % 86400) / 3600);
    local minutes = math.floor((seconds % 3600) / 60);
    if days > 0 then return string.format('%d day(s)', days); end
    if hours >= 3 then return string.format('%d hour(s)', hours); end
    if hours > 0 then return string.format('%d hour(s), %d minute(s)', hours, minutes); end
    return string.format('%d minute(s)', minutes);
end

local function print_task_legend(char_data)
    local flags = {};
    for _, task in ipairs(tracker.settings.tasks) do
        local normalized = normalize_task(task);
        if normalized == 'xsknife' then
            local step = (char_data.xsknife_data or {}).step or 'unknown';
            if step == 'unknown' then flags.knife_unknown = true;
            elseif step == 'scanned_no_ki' then flags.knife_empty = true;
            elseif step == 'scanned_has_ki' then flags.knife_boneyard = true;
            elseif step == 'scanned_has_ki_used' then flags.knife_des = true; end
        elseif normalized == 'highwind' then
            if (char_data.quest_steps.highwind or 'scanned') == 'scanned' then flags.yellow_empty = true; end
        elseif normalized == 'uninvited' or normalized == 'spicegals' or normalized == 'cookbook' then
            local step = char_data.quest_steps[normalized] or 'unknown';
            if step == 'unknown' then flags.question = true;
            elseif step == 'scanned' then flags.yellow_empty = true; end
        elseif normalized == 'ecowarrior' then
            local step = (char_data.ecowarrior_data or {}).step or 'unknown';
            if step == 'unknown' then flags.eco_unknown = true;
            elseif step == 'scanned' then flags.eco_nation = true;
            elseif step == 'scanned_has_ki' then flags.eco_scanned_ki = true; end
        end
    end
    if flags.question then print('\30\104[ ? ]\30\067 = Use /hw scan to detect progress.'); end
    if flags.yellow_empty then print('\30\104[   ]\30\067 = Unknown progress. Resolves at next tally or use /hw <task>.'); end
    if flags.eco_unknown then print('\30\104[ ? ]\30\067 (EcoWarrior) = Use /hw eco <nation> or talk to Eeko-Weeko.'); end
    if flags.eco_nation then print('\30\104[Nation]\30\067 (EcoWarrior) = Unknown if completed. Resolves at next tally or quest interaction.'); end
    if flags.eco_scanned_ki then print('\30\104[Zone - Agent]\30\067 (EcoWarrior) = Has KI but locked nations unknown. Use /hw eco or talk to Eeko-Weeko.'); end
    if flags.knife_unknown then print('\30\104[ ? ]\30\067 (X\'sKnife) = Use /hw scan or talk to Despachiaire.'); end
    if flags.knife_empty then print('\30\104[   ]\30\067 (X\'sKnife) = Unknown if Despachiaire has KI. Resolves at next tally or when KI obtained.'); end
    if flags.knife_des then print('\30\104[Despachiaire]\30\067 (X\'sKnife) = Unknown if Despachiaire has KI. Resolves at next tally or when KI obtained.'); end
    if flags.knife_boneyard then print('\30\104[Boneyard Gully]\30\067 (X\'sKnife) = Unknown if Despachiaire has another KI. Resolves at next tally or when KI obtained.'); end
end

local function print_weekly_block(char_name, char_data, current_time)
    print_msg('Weekly Homework for \30\110' .. char_name .. '\30\106:');
    print_task_legend(char_data);
    print_msg('=================');
    print(format_dynamis_line(char_name, char_data));
    for _, task in ipairs(tracker.settings.tasks) do
        local line = format_task_line(task, char_data);
        if line then print(line); end
    end
    print('');
    print_msg(string.format('Next reset in %s', format_countdown(calculate_next_reset(current_time) - current_time)));
end

local function print_timer_block(char_name, char_data, current_time)
    print_msg('ENM & Limbus Timers for \30\110' .. char_name .. '\30\106:');
    print_msg('====================');
    for _, enm in ipairs(ENM_KEY_ITEMS) do
        print(format_timer_line(enm, char_data.enm_timers[enm.name], current_time));
    end
end

local function show_list()
    local char_data = get_char_data();
    print_weekly_block(tracker.current_char, char_data, os.time());
end
local function show_timers()
    local char_data = get_char_data();
    local current_time = os.time();
    local has_unknown_question = false;
    local has_unknown_ki = false;
    local has_unknown_no_ki = false;
    local has_any_timers = false;
    local longest_no_ki_timer = 0;
    for _, enm in ipairs(ENM_KEY_ITEMS) do
        local timer_data = char_data.enm_timers[enm.name];
        if timer_data ~= nil then has_any_timers = true; end
        if timer_data == nil or timer_data.next_ki_time == 0 then
            if timer_data ~= nil and timer_data.has_ki then has_unknown_ki = true;
            elseif timer_data ~= nil and not timer_data.has_ki then has_unknown_no_ki = true;
            else has_unknown_question = true; end
        elseif timer_data.timer_source == 'scan' and current_time < timer_data.next_ki_time then
            if timer_data.has_ki then has_unknown_ki = true;
            else
                has_unknown_no_ki = true;
                if timer_data.next_ki_time > longest_no_ki_timer then longest_no_ki_timer = timer_data.next_ki_time; end
            end
        end
    end
    print_msg('ENM & Limbus Timers for \30\110' .. tracker.current_char .. '\30\106:');
    if not has_any_timers then print('\30\081[\30\082Homework\30\081]\30\106 Please use \30\110/hw scan\30\106 to scan for your current KIs'); end
    if has_unknown_question then print('\30\104[ ? ]\30\067 = Unknown status. Use /hw scan to update.'); end
    if has_unknown_no_ki then
        local time_left = longest_no_ki_timer - current_time;
        local days = math.floor(time_left / 86400);
        local hours = math.floor((time_left % 86400) / 3600);
        local time_str = '';
        if days > 0 then time_str = tostring(days) .. ' days, ' .. tostring(hours) .. ' hours';
        else time_str = tostring(hours) .. ' hours'; end
        print('\30\104[   ]\30\067 = No KI. Unknown if ready. Resolves after ' .. time_str .. ' or when KI obtained.');
    end
    if has_unknown_ki then
        local longest_ki_timer = 0;
        for _, enm in ipairs(ENM_KEY_ITEMS) do
            local timer_data = char_data.enm_timers[enm.name];
            if timer_data ~= nil and timer_data.has_ki then
                if timer_data.timer_source == 'scan' and timer_data.next_ki_time > longest_ki_timer then
                    longest_ki_timer = timer_data.next_ki_time;
                elseif timer_data.next_ki_time == 0 then
                    longest_ki_timer = math.max(longest_ki_timer, current_time + 432000);
                end
            end
        end
        if longest_ki_timer > current_time then
            local time_left = longest_ki_timer - current_time;
            local days = math.floor(time_left / 86400);
            local hours = math.floor((time_left % 86400) / 3600);
            local time_str = '';
            if days > 0 then time_str = tostring(days) .. ' days, ' .. tostring(hours) .. ' hours';
            else time_str = tostring(hours) .. ' hours'; end
            print('\30\104[KI]\30\067 = Have KI. Timer unknown. Resolves after ' .. time_str .. ' or when KI obtained.');
        else
            print('\30\104[KI]\30\067 = Have KI. Timer unknown. Updates when KI obtained.');
        end
    end
    print_msg('====================');
    for _, enm in ipairs(ENM_KEY_ITEMS) do
        print(format_timer_line(enm, char_data.enm_timers[enm.name], current_time));
    end
end

-- ============================================================================
-- UI Rendering (imgui)
-- ============================================================================

local function format_time_short(seconds)
    if seconds <= 0 then return 'Ready'; end
    local days = math.floor(seconds / 86400);
    local hours = math.floor((seconds % 86400) / 3600);
    local minutes = math.floor((seconds % 3600) / 60);
    if days > 0 then return string.format('%dd %dh', days, hours);
    elseif hours > 0 then return string.format('%dh %dm', hours, minutes);
    else return string.format('%dm', minutes); end
end

function update_char_list()
    ui.char_list = {};
    for char_name, _ in pairs(tracker.settings.characters) do
        if char_name ~= nil and char_name ~= '' and char_name ~= 'Unknown' then
            table.insert(ui.char_list, char_name);
        end
    end
    table.sort(ui.char_list);
    -- Find current char index
    for i, name in ipairs(ui.char_list) do
        if name == tracker.current_char then
            ui.selected_char[1] = i - 1;
            break;
        end
    end
end

local function factory_reset()
    -- Delete homework.json
    local settings_path = get_settings_path();
    if ashita.fs.exists(settings_path) then
        os.remove(settings_path);
    end
    -- Delete display.json
    local display_path = get_display_settings_path();
    if ashita.fs.exists(display_path) then
        os.remove(display_path);
    end
    -- Reset in-memory state
    tracker.settings.characters = {};
    tracker.kis = {};
    tracker.kis_initialized = false;
    tracker.login_state.waiting_for_login = false;
    tracker.login_state.waiting_for_ki = false;
    tracker.login_state.ki_packets_received = 0;
    tracker.login_state.suppress_ki_events = false;
    tracker.pending_dynamis_claim = nil;
    display_settings.tracked = {};
    ui.font_scale = 1.2;
    ui.char_list = {};
    ui.selected_char = { 0 };
    -- Re-initialize current character
    local char_name = get_char_name();
    if char_name ~= 'Unknown' then
        tracker.current_char = char_name;
        get_char_data();  -- Creates fresh character data
        update_char_list();
    end
    print_success('Factory reset complete! All data deleted.');
end

-- Help marker with tooltip (like SkillchainCalc)
local function help_marker(text)
    imgui.SameLine();
    imgui.TextDisabled('(?)');
    if imgui.IsItemHovered() then
        imgui.BeginTooltip();
        imgui.PushTextWrapPos(imgui.GetFontSize() * 35.0);
        imgui.TextUnformatted(text);
        imgui.PopTextWrapPos();
        imgui.EndTooltip();
    end
end

-- Gradient header helper: color > transparent with small text padding
local function draw_gradient_header(text, width, help_text)
    local drawlist = imgui.GetWindowDrawList();
    local x, y = imgui.GetCursorScreenPos();
    local lineH = imgui.GetTextLineHeightWithSpacing();

    -- Extract width if it's a table from GetContentRegionAvail()
    local actualWidth = type(width) == 'table' and width[1] or width;

    local fadeFraction = 0.75;
    local gradWidth = actualWidth * fadeFraction;

    local colLeft = {0.4, 0.7, 0.9, 1.0};  -- Light blue color (RGBA)
    local colLeftU32 = imgui.GetColorU32(colLeft);
    local colRight = {colLeft[1], colLeft[2], colLeft[3], 0.0};  -- Transparent
    local colRightU32 = imgui.GetColorU32(colRight);

    drawlist:AddRectFilledMultiColor(
        {x, y},
        {x + gradWidth, y + lineH},
        colLeftU32,
        colRightU32,
        colRightU32,
        colLeftU32
    );

    local padX = 4;
    local padY = 2;
    imgui.SetCursorScreenPos({x + padX, y + padY});
    imgui.Text(text);

    -- Add help marker on same line if provided (only if it's a string)
    if help_text and type(help_text) == 'string' then
        help_marker(help_text);
    end

    local _, newY = imgui.GetCursorScreenPos();
    imgui.SetCursorScreenPos({x, newY});
    imgui.Spacing();
end

local function render_ui()
    if not ui.is_open[1] then return; end
    
    -- Get selected character data
    local char_name = ui.char_list[ui.selected_char[1] + 1] or tracker.current_char;
    local char_data = tracker.settings.characters[char_name];
    if char_data == nil then return; end
    
    local current_time = os.time();
    
    -- Window styling - minimal
    imgui.SetNextWindowSize({ 280, 400 }, ImGuiCond_FirstUseEver);
    imgui.PushStyleColor(ImGuiCol_WindowBg, { 0.0, 0.0, 0.0, 0.85 });
    imgui.PushStyleColor(ImGuiCol_TitleBg, { 0.0, 0.0, 0.0, 0.9 });
    imgui.PushStyleColor(ImGuiCol_TitleBgActive, { 0.0, 0.0, 0.0, 0.9 });
    imgui.PushStyleColor(ImGuiCol_FrameBg, { 0.1, 0.1, 0.1, 0.9 });
    imgui.PushStyleColor(ImGuiCol_Border, { 0.0, 0.0, 0.0, 0.0 });
    imgui.PushStyleVar(ImGuiStyleVar_WindowBorderSize, 0);
    imgui.PushStyleVar(ImGuiStyleVar_FrameBorderSize, 0);
    
    if imgui.Begin('Homework v' .. addon.version, ui.is_open, ui.window_flags) then
        imgui.PopStyleColor(5);
        imgui.PopStyleVar(2);
        
        -- Apply font scale (compatible with both old and new Ashita)
        local _useNewFont = (imgui.SetWindowFontScale == nil);
        if _useNewFont then
            local defaultFont = imgui.GetFont();
            local defaultSize = imgui.GetFontSize();
            imgui.PushFont(defaultFont, defaultSize * ui.font_scale);
        else
            imgui.SetWindowFontScale(ui.font_scale);
        end

        -- Tab bar
        if imgui.BeginTabBar('##homework_tabs', ImGuiTabBarFlags_None) then
            -- Tasks tab
            if imgui.BeginTabItem('Tasks') then
            -- Character dropdown + Reset timer on same line
            local char_names = table.concat(ui.char_list, '\0') .. '\0';
            imgui.SetNextItemWidth(100 * ui.font_scale);
            if imgui.Combo('##char_select', ui.selected_char, char_names) then
                char_name = ui.char_list[ui.selected_char[1] + 1];
                char_data = tracker.settings.characters[char_name];
            end

            local next_reset = calculate_next_reset(current_time);
            local reset_seconds = next_reset - current_time;
            imgui.SameLine();
            imgui.Text('Reset: ' .. format_time_short(reset_seconds));

            imgui.Spacing();

        -- Weeklies header
        draw_gradient_header('Weeklies', imgui.GetContentRegionAvail(), '[?] = Use /hw scan to detect progress\n[  ] = Unknown progress. Resolves at next tally or use /hw <task>');

        -- Column positions scaled with font
        local col_task = 35 * ui.font_scale;
        local col_location = 120 * ui.font_scale;

        -- Get tracking settings for current character
        local tracking = get_char_tracking(char_name);

        -- Dynamis entry counter (displayed above EcoWarrior)
        local dyn_store, dyn_shared = get_dynamis_store(char_name);
        if dyn_store then
            local entries = dyn_store.entries_remaining or 2;
            local dyn_icon, dyn_color;
            if entries == 0 then
                dyn_icon = '[X]';
                dyn_color = { 1.0, 0.3, 0.3, 1.0 };  -- Red
            elseif entries == 1 then
                dyn_icon = '[1]';
                dyn_color = { 1.0, 1.0, 0.0, 1.0 };  -- Yellow
            else
                dyn_icon = '[2]';
                dyn_color = { 0.0, 1.0, 0.0, 1.0 };  -- Green
            end
            imgui.TextColored(dyn_color, dyn_icon);
            imgui.SameLine();
            imgui.SetCursorPosX(col_task);
            imgui.Text('Dynamis');
            imgui.SameLine();
            imgui.SetCursorPosX(col_location);
            imgui.TextColored({ 0.6, 0.8, 1.0, 1.0 }, entries .. ' entries left' .. (dyn_shared and ' (account)' or ''));
        end

        for _, task in ipairs(tracker.settings.tasks) do
            -- Skip if not tracked for this character
            if not tracking.tasks[task] then
                goto continue_task;
            end

            local normalized = normalize_task(task);
            local icon, color, location = '[?]', { 1.0, 1.0, 0.0, 1.0 }, '';
            local help_text = nil;  -- Help marker text for this specific task

            if normalized == 'xsknife' then
                local step = char_data.xsknife_data and char_data.xsknife_data.step or 'unknown';
                if step == 'done' then icon = '[X]'; color = { 1.0, 0.3, 0.3, 1.0 };
                elseif step == 'boneyard' then icon = '[O]'; color = { 0.0, 1.0, 0.0, 1.0 }; location = 'Boneyard Gully';
                elseif step == 'boneyard_2x' then icon = '[O]'; color = { 0.0, 1.0, 0.0, 1.0 }; location = '2x Boneyard';
                elseif step == 'despachiaire' then icon = '[O]'; color = { 0.0, 1.0, 0.0, 1.0 }; location = 'Despachiaire';
                elseif step == 'scanned_no_ki' then
                    icon = '[  ]'; color = { 1.0, 1.0, 0.0, 1.0 };
                    help_text = "Unknown if Despachiaire has KI. Resolves at next tally or when KI obtained.\n/hw knife to toggle.";
                elseif step == 'scanned_has_ki' then
                    icon = '[  ]'; color = { 1.0, 1.0, 0.0, 1.0 }; location = 'Boneyard Gully';
                    help_text = "Unknown if Despachiaire has another KI. Resolves at next tally or when KI obtained.\n/hw knife to toggle.";
                elseif step == 'scanned_has_ki_used' then
                    icon = '[  ]'; color = { 1.0, 1.0, 0.0, 1.0 }; location = 'Despachiaire';
                    help_text = "Unknown if Despachiaire has KI. Resolves at next tally or when KI obtained.\n/hw knife to toggle.";
                else
                    help_text = "Use /hw scan or talk to Despachiaire.\n/hw knife to toggle.";
                end
            elseif normalized == 'highwind' then
                local step = char_data.quest_steps and char_data.quest_steps.highwind or 'scanned';
                if step == 'done' then icon = '[X]'; color = { 1.0, 0.3, 0.3, 1.0 };
                elseif step == 'start' then icon = '[O]'; color = { 0.0, 1.0, 0.0, 1.0 }; location = 'Airship NM';
                else
                    icon = '[  ]'; color = { 1.0, 1.0, 0.0, 1.0 };
                    help_text = "Unknown progress. Resolves at next tally.\n/hw high to toggle.";
                end
            elseif normalized == 'uninvited' then
                local step = char_data.quest_steps and char_data.quest_steps.uninvited or 'unknown';
                if step == 'done' then icon = '[X]'; color = { 1.0, 0.3, 0.3, 1.0 };
                elseif step == 'justinius' then icon = '[O]'; color = { 0.0, 1.0, 0.0, 1.0 }; location = 'Justinius - Start';
                elseif step == 'bcnm' then icon = '[O]'; color = { 0.0, 1.0, 0.0, 1.0 }; location = 'BCNM Monarch';
                elseif step == 'justinius_return' then icon = '[O]'; color = { 0.0, 1.0, 0.0, 1.0 }; location = 'Justinius - Reward';
                elseif step == 'scanned' then
                    icon = '[  ]'; color = { 1.0, 1.0, 0.0, 1.0 };
                    help_text = "Unknown progress. Resolves at next tally.\n/hw uninvited to toggle.";
                else
                    icon = '[?]'; color = { 1.0, 1.0, 0.0, 1.0 };
                    help_text = "Use /hw scan to detect progress.\n/hw uninvited to toggle.";
                end
            elseif normalized == 'spicegals' then
                local step = char_data.quest_steps and char_data.quest_steps.spicegals or 'unknown';
                if step == 'done' then icon = '[X]'; color = { 1.0, 0.3, 0.3, 1.0 };
                elseif step == 'rouva' then icon = '[O]'; color = { 0.0, 1.0, 0.0, 1.0 }; location = 'Rouva - Start';
                elseif step == 'riverne' then icon = '[O]'; color = { 0.0, 1.0, 0.0, 1.0 }; location = 'Riverne B';
                elseif step == 'rouva_return' then icon = '[O]'; color = { 0.0, 1.0, 0.0, 1.0 }; location = 'Rouva - Reward';
                elseif step == 'scanned' then
                    icon = '[  ]'; color = { 1.0, 1.0, 0.0, 1.0 };
                    help_text = "Unknown progress. Resolves at next tally.\n/hw spice to toggle.";
                else
                    icon = '[?]'; color = { 1.0, 1.0, 0.0, 1.0 };
                    help_text = "Use /hw scan to detect progress.\n/hw spice to toggle.";
                end
            elseif normalized == 'cookbook' then
                local step = char_data.quest_steps and char_data.quest_steps.cookbook or 'unknown';
                if step == 'done' then icon = '[X]'; color = { 1.0, 0.3, 0.3, 1.0 };
                elseif step == 'jonette' then icon = '[O]'; color = { 0.0, 1.0, 0.0, 1.0 }; location = 'Jonette - Start';
                elseif step == 'sacrarium' then icon = '[O]'; color = { 0.0, 1.0, 0.0, 1.0 }; location = 'Sacrarium';
                elseif step == 'jonette_return' then icon = '[O]'; color = { 0.0, 1.0, 0.0, 1.0 }; location = 'Jonette - Reward';
                elseif step == 'scanned' then
                    icon = '[  ]'; color = { 1.0, 1.0, 0.0, 1.0 };
                    help_text = "Unknown progress. Resolves at next tally or use /hw cookbook.";
                else
                    icon = '[?]'; color = { 1.0, 1.0, 0.0, 1.0 };
                    help_text = "Use /hw scan to detect progress.";
                end
            elseif normalized == 'ecowarrior' then
                local eco_data = char_data.ecowarrior_data or {step = 'unknown', locked_nations = {}};
                local step = eco_data.step or 'unknown';
                local knows = eco_data.knows_status;
                local available_text = eco_available_text(eco_data.locked_nations);

                if step == 'done' then
                    icon = '[X]'; color = { 1.0, 0.3, 0.3, 1.0 };
                    location = available_text;
                elseif step == 'ready' then
                    -- Known ready state
                    icon = '[O]'; color = { 0.0, 1.0, 0.0, 1.0 };
                    location = available_text;
                elseif step == 'scanned' then
                    -- Scanned but uncertain if done - YELLOW
                    icon = '[  ]'; color = { 1.0, 1.0, 0.0, 1.0 };
                    location = available_text;
                    help_text = "Unknown if completed. Resolves at next tally or quest interaction.";
                elseif step == 'scanned_has_ki' then
                    -- Has KI but locked nations unknown - YELLOW
                    icon = '[  ]'; color = { 1.0, 1.0, 0.0, 1.0 };
                    local nation = eco_data.current_nation;
                    if nation then
                        local zone_info = ECOWARRIOR_ZONES[nation];
                        if zone_info then location = zone_info.short_zone .. ' - ' .. zone_info.short_agent; end
                    end
                    help_text = "Has KI but locked nations unknown. Use /hw eco or talk to Eeko-Weeko.";
                elseif step == 'field_agent' or step == 'nm' or step == 'field_agent_return' or step == 'reward' then
                    -- In progress - color depends on knows_status
                    if knows then
                        icon = '[O]'; color = { 0.0, 1.0, 0.0, 1.0 };
                    else
                        icon = '[  ]'; color = { 1.0, 1.0, 0.0, 1.0 };
                        help_text = "Status uncertain. Resolves at quest interaction.";
                    end
                    local nation = eco_data.current_nation;
                    if nation then
                        local zone_info = ECOWARRIOR_ZONES[nation];
                        if zone_info then
                            if step == 'field_agent' then location = zone_info.short_zone .. ' - ' .. zone_info.short_agent;
                            elseif step == 'nm' then location = 'Kill NM';
                            elseif step == 'field_agent_return' then location = zone_info.short_zone .. ' - ' .. zone_info.short_agent;
                            elseif step == 'reward' then location = zone_info.short_city .. ' - ' .. zone_info.quest_npc; end
                        end
                    end
                else
                    -- Unknown
                    icon = '[?]'; color = { 1.0, 1.0, 0.0, 1.0 };
                    help_text = "Use /hw eco <nation> or talk to Eeko-Weeko.";
                end
            end
            
            -- Render with column alignment (grouped for hover detection)
            imgui.BeginGroup();
            imgui.TextColored(color, icon);
            imgui.SameLine();
            imgui.SetCursorPosX(col_task);
            imgui.Text(task);
            if location ~= '' then
                imgui.SameLine();
                imgui.SetCursorPosX(col_location);
                imgui.TextColored({ 0.0, 1.0, 0.0, 1.0 }, '(' .. location .. ')');
            end
            imgui.EndGroup();
            
            -- Add help marker if this task has help text
            if help_text then
                help_marker(help_text);
            end

            ::continue_task::
        end

        imgui.Spacing();

        -- Timers header
        draw_gradient_header('Timers', imgui.GetContentRegionAvail(), '[?] = Use /hw scan to detect timers\n[KI]/[  ] = Timer unknown. Updates when KI obtained.');

        -- Timer column positions scaled with font
        local timer_col_name = 40 * ui.font_scale;
        local timer_col_status = 170 * ui.font_scale;

        for _, enm in ipairs(ENM_KEY_ITEMS) do
            -- Skip if not tracked for this character
            if not tracking.timers[enm.name] then
                goto continue_timer;
            end

            local timer_data = char_data.enm_timers and char_data.enm_timers[enm.name];
            local icon, icon_color, status_text;
            local timer_help_text = nil;
            
            if timer_data == nil then
                -- No data at all
                icon = '[?]'; icon_color = { 1.0, 1.0, 0.0, 1.0 };
                status_text = 'Unknown';
                timer_help_text = "Use /hw scan to detect timers.";
            elseif timer_data.next_ki_time == nil or timer_data.next_ki_time == 0 then
                -- Have timer_data but no time set
                if timer_data.has_ki then
                    icon = '[KI]'; icon_color = { 1.0, 1.0, 0.0, 1.0 };
                    timer_help_text = "Have KI. Timer unknown. Updates when KI obtained.";
                else
                    icon = '[  ]'; icon_color = { 1.0, 1.0, 0.0, 1.0 };
                    timer_help_text = "No KI. Timer unknown. Updates when KI obtained.";
                end
                status_text = 'Unknown';
            else
                local remaining = timer_data.next_ki_time - current_time;
                
                if remaining <= 0 then
                    -- Timer expired = Ready
                    if timer_data.has_ki then
                        icon = '[KI]'; icon_color = { 0.0, 1.0, 0.0, 1.0 };
                    else
                        icon = '[  ]'; icon_color = { 0.0, 1.0, 0.0, 1.0 };
                    end
                    status_text = 'Ready';
                elseif timer_data.timer_source == 'scan' then
                    -- Scan-based timer = Unknown status
                    if timer_data.has_ki then
                        icon = '[KI]'; icon_color = { 1.0, 1.0, 0.0, 1.0 };
                        timer_help_text = "Have KI. Timer unknown. Updates when KI obtained.";
                    else
                        icon = '[  ]'; icon_color = { 1.0, 1.0, 0.0, 1.0 };
                        timer_help_text = "No KI. Timer unknown. Updates when KI obtained.";
                    end
                    status_text = 'Unknown';
                else
                    -- Real timer counting down
                    if timer_data.has_ki then
                        icon = '[KI]'; icon_color = { 0.0, 1.0, 0.0, 1.0 };
                    else
                        icon = '[  ]'; icon_color = { 1.0, 0.0, 0.0, 1.0 };
                    end
                    status_text = format_time_short(remaining);
                end
            end
            
            -- Render with column alignment
            imgui.TextColored(icon_color, icon);
            imgui.SameLine();
            imgui.SetCursorPosX(timer_col_name);
            imgui.Text(enm.name);
            imgui.SameLine();
            imgui.SetCursorPosX(timer_col_status);
            imgui.TextColored({ 0.4, 0.7, 0.9, 1.0 }, '(' .. status_text .. ')');
            -- Add help marker if this timer has help text
            if timer_help_text then
                help_marker(timer_help_text);
            end
            
            -- Show Limbus cards as sub-items (only in floating window)
            if enm.name == 'Limbus' then
                local card_indent = 20 * ui.font_scale;
                local card_col_name = timer_col_name + card_indent;
                
                for _, card in ipairs(LIMBUS_CARDS) do
                    local has_card = tracker.kis[card.ki_id] == true;
                    local card_icon, card_color;
                    if has_card then
                        card_icon = '[KI]';
                        card_color = { 0.0, 1.0, 0.0, 1.0 };
                    else
                        card_icon = '[  ]';
                        card_color = { 0.5, 0.5, 0.5, 1.0 };
                    end
                    
                    imgui.SetCursorPosX(card_indent);
                    imgui.TextColored(card_color, card_icon);
                    imgui.SameLine();
                    imgui.SetCursorPosX(card_col_name);
                    imgui.TextColored({ 1.0, 1.0, 1.0, 1.0 }, card.name);
                    help_marker(card.location);
                end
            end

            ::continue_timer::
        end

                imgui.EndTabItem();
            end

            -- Settings tab
            if imgui.BeginTabItem('Settings') then
                draw_gradient_header('Display Settings', imgui.GetContentRegionAvail());

                imgui.Text('Font Scale:');
                imgui.SameLine();
                if imgui.SmallButton('-##font') and ui.font_scale > 0.8 then
                    ui.font_scale = ui.font_scale - 0.1;
                    save_display_settings();
                end
                imgui.SameLine();
                imgui.Text(string.format('%.1f', ui.font_scale));
                imgui.SameLine();
                if imgui.SmallButton('+##font') and ui.font_scale < 2.0 then
                    ui.font_scale = ui.font_scale + 0.1;
                    save_display_settings();
                end

                imgui.Spacing();
                imgui.Spacing();

                draw_gradient_header('Dynamis Sharing', imgui.GetContentRegionAvail(),
                    'Turn on when the server counts Dynamis entries per account instead of per character.\nGroup the characters that share one account. Characters left out of every account keep their own count.');

                local aw = { tracker.settings.dynamis_account_wide == true };
                if imgui.Checkbox('Dynamis entries are account-wide', aw) then
                    tracker.settings.dynamis_account_wide = aw[1];
                    ui.pending_account_add = nil;
                    save_settings();
                end

                if tracker.settings.dynamis_account_wide then
                    local accts = dynamis_accounts();
                    local limit = chars_per_account();

                    for ai, acct in ipairs(accts) do
                        imgui.Spacing();
                        local label = (acct.name or ('Account ' .. ai));
                        imgui.TextColored({ 0.6, 0.8, 1.0, 1.0 },
                            string.format('%s  (%d/%d)', label, #(acct.chars or {}), limit));
                        imgui.SameLine();
                        if imgui.SmallButton('Delete##acct' .. ai) then
                            remove_dynamis_account(ai);
                            ui.pending_account_add = nil;
                            save_settings();
                            break;
                        end

                        imgui.Indent(8);
                        for _, cname in ipairs(ui.char_list) do
                            local in_this = false;
                            for _, c in ipairs(acct.chars or {}) do
                                if c == cname then in_this = true; break; end
                            end
                            local box = { in_this };
                            if imgui.Checkbox(cname .. '##acct' .. ai, box) then
                                if box[1] then
                                    if assign_char_to_account(cname, ai) then
                                        ui.pending_account_add = nil;
                                        save_settings();
                                    else
                                        -- Account full: offer to spill into a new one.
                                        ui.pending_account_add = { char = cname, from = ai };
                                    end
                                else
                                    unassign_char(cname);
                                    ui.pending_account_add = nil;
                                    save_settings();
                                end
                            end
                        end
                        imgui.Unindent(8);
                    end

                    imgui.Spacing();
                    if imgui.SmallButton('+ Add account') then
                        add_dynamis_account();
                        save_settings();
                    end

                    if ui.pending_account_add ~= nil then
                        imgui.Spacing();
                        imgui.TextColored({ 1.0, 1.0, 0.0, 1.0 }, string.format(
                            'That account is full (%d). Create a new account for %s?',
                            limit, tostring(ui.pending_account_add.char)));
                        if imgui.SmallButton('Yes##spill') then
                            local idx = add_dynamis_account();
                            assign_char_to_account(ui.pending_account_add.char, idx);
                            ui.pending_account_add = nil;
                            save_settings();
                        end
                        imgui.SameLine();
                        if imgui.SmallButton('No##spill') then
                            ui.pending_account_add = nil;
                        end
                    end

                    if #accts == 0 then
                        imgui.TextColored({ 0.7, 0.7, 0.7, 1.0 }, 'No accounts yet.');
                    end
                end

                imgui.Spacing();
                imgui.Spacing();

                draw_gradient_header('Display Task', imgui.GetContentRegionAvail(), 'Check to affect which tasks are displayed. All are actively tracked.');

                -- Character selector for tracking settings (synchronized with Tasks tab)
                local char_names = table.concat(ui.char_list, '\0') .. '\0';
                imgui.SetNextItemWidth(150 * ui.font_scale);
                if imgui.Combo('##settings_char_select', ui.selected_char, char_names) then
                    -- Character selection changed - will affect both tabs
                end

                local settings_char = ui.char_list[ui.selected_char[1] + 1];
                if settings_char then
                    local tracking = get_char_tracking(settings_char);

                    imgui.Spacing();
                    imgui.TextColored({ 0.7, 0.7, 0.7, 1.0 }, 'Weekly Tasks:');
                    imgui.Spacing();

                    -- Weekly task checkboxes (show/hide only)
                    for _, task in ipairs(tracker.settings.tasks) do
                        imgui.Indent(2);
                        local checked = { tracking.tasks[task] or false };
                        if imgui.Checkbox(task, checked) then
                            tracking.tasks[task] = checked[1];
                            save_display_settings();
                        end
                        imgui.Unindent(2);
                    end

                    imgui.Spacing();
                    imgui.Spacing();
                    
                    -- Dynamis Run Count manual override
                    local set_store, set_shared = get_dynamis_store(settings_char);
                    if set_store then
                        imgui.TextColored({ 0.7, 0.7, 0.7, 1.0 }, 'Dynamis Run Count:' .. (set_shared and '  (shared by account)' or ''));
                        local entries = set_store.entries_remaining or 2;
                        
                        -- Radio buttons for 0, 1, 2 runs
                        imgui.Indent(2);
                        local sel_0 = { entries == 0 };
                        local sel_1 = { entries == 1 };
                        local sel_2 = { entries == 2 };
                        
                        if imgui.RadioButton('0 Runs', sel_0[1]) then
                            set_store.entries_remaining = 0;
                            save_settings();
                        end
                        imgui.SameLine();
                        if imgui.RadioButton('1 Run', sel_1[1]) then
                            set_store.entries_remaining = 1;
                            save_settings();
                        end
                        imgui.SameLine();
                        if imgui.RadioButton('2 Runs', sel_2[1]) then
                            set_store.entries_remaining = 2;
                            save_settings();
                        end
                        imgui.Unindent(2);
                    end

                    imgui.Spacing();
                    imgui.Spacing();
                    imgui.TextColored({ 0.7, 0.7, 0.7, 1.0 }, 'Timers (ENM/Limbus):');
                    imgui.Spacing();

                    -- Timer checkboxes (indented)
                    for _, enm in ipairs(ENM_KEY_ITEMS) do
                        imgui.Indent(2);
                        local checked = { tracking.timers[enm.name] or false };
                        if imgui.Checkbox(enm.name, checked) then
                            tracking.timers[enm.name] = checked[1];
                            save_display_settings();
                        end
                        imgui.Unindent(2);
                    end
                end

                imgui.EndTabItem();
            end

            imgui.EndTabBar();
        end

        -- Pop font if we used PushFont
        if _useNewFont then
            imgui.PopFont();
        end

    else
        imgui.PopStyleColor(5);
        imgui.PopStyleVar(2);
    end
    imgui.End();
end

local function show_all_chars()
    print_msg('All Characters:');
    print_msg('=================');
    for char_name, char_data in pairs(tracker.settings.characters) do
        if char_name ~= nil and char_name ~= '' and char_name ~= 'Unknown' and string.len(char_name) > 0 then
            local completed_count = 0;
            if char_data.quest_steps then
                if char_data.quest_steps.highwind == 'done' then completed_count = completed_count + 1; end
                if char_data.quest_steps.uninvited == 'done' then completed_count = completed_count + 1; end
                if char_data.quest_steps.spicegals == 'done' then completed_count = completed_count + 1; end
                if char_data.quest_steps.cookbook == 'done' then completed_count = completed_count + 1; end
            end
            if char_data.ecowarrior_data and char_data.ecowarrior_data.step == 'done' then completed_count = completed_count + 1; end
            if char_data.xsknife_data and char_data.xsknife_data.step == 'done' then completed_count = completed_count + 1; end
            local is_current = char_name == tracker.current_char and ' \30\110(current)\30\106' or '';
            print(string.format('\30\081[\30\082Homework\30\081]\30\106 %s: %d/%d completed%s', char_name, completed_count, #tracker.settings.tasks, is_current));
        end
    end
end

local function show_char_details(char_name)
    if tracker.settings.characters[char_name] == nil then print_error('Character not found: ' .. char_name); return; end
    local char_data = tracker.settings.characters[char_name];
    local current_time = os.time();
    if char_data.enm_timers == nil then char_data.enm_timers = {}; end
    if char_data.quest_steps == nil then char_data.quest_steps = {}; end
    if char_data.xsknife_data == nil then char_data.xsknife_data = {step = 'unknown'}; end
    if char_data.ecowarrior_data == nil then char_data.ecowarrior_data = {step = 'unknown', knows_status = false}; end
    if char_data.dynamis_data == nil then char_data.dynamis_data = new_dynamis_data(); end
    print_weekly_block(char_name, char_data, current_time);
    print('');
    print_timer_block(char_name, char_data, current_time);
end
local function toggle_task(task)
    local proper_name = find_task_name(task);
    if not proper_name then print_error('Invalid task: ' .. task); return; end
    local normalized = normalize_task(proper_name);
    local char_data = get_char_data();
    if normalized == 'highwind' then
        if char_data.quest_steps.highwind == 'done' then char_data.quest_steps.highwind = 'start'; print_success('Unmarked ' .. proper_name .. ' for ' .. tracker.current_char);
        else char_data.quest_steps.highwind = 'done'; print_success('Marked ' .. proper_name .. ' as completed for ' .. tracker.current_char .. '!'); end
        save_settings(); return;
    elseif normalized == 'uninvited' then
        if char_data.quest_steps.uninvited == 'done' then char_data.quest_steps.uninvited = 'justinius'; print_success('Unmarked ' .. proper_name .. ' for ' .. tracker.current_char);
        else char_data.quest_steps.uninvited = 'done'; print_success('Marked ' .. proper_name .. ' as completed for ' .. tracker.current_char .. '!'); end
        save_settings(); return;
    elseif normalized == 'spicegals' then
        if char_data.quest_steps.spicegals == 'done' then char_data.quest_steps.spicegals = 'rouva'; print_success('Unmarked ' .. proper_name .. ' for ' .. tracker.current_char);
        else char_data.quest_steps.spicegals = 'done'; print_success('Marked ' .. proper_name .. ' as completed for ' .. tracker.current_char .. '!'); end
        save_settings(); return;
    elseif normalized == 'cookbook' then
        if char_data.quest_steps.cookbook == 'done' then char_data.quest_steps.cookbook = 'jonette'; print_success('Unmarked ' .. proper_name .. ' for ' .. tracker.current_char);
        else char_data.quest_steps.cookbook = 'done'; print_success('Marked ' .. proper_name .. ' as completed for ' .. tracker.current_char .. '!'); end
        save_settings(); return;
    elseif normalized == 'ecowarrior' then
        local eco_data = char_data.ecowarrior_data;
        if eco_data.step == 'done' then 
            eco_data.step = 'ready'; 
            eco_data.knows_status = true;
            print_success('Unmarked ' .. proper_name .. ' for ' .. tracker.current_char);
        else 
            eco_data.step = 'done'; 
            eco_data.knows_status = true;
            print_success('Marked ' .. proper_name .. ' as completed for ' .. tracker.current_char .. '!'); 
        end
        save_settings(); return;
    elseif normalized == 'xsknife' then
        local xsknife_data = char_data.xsknife_data;
        if xsknife_data.step == 'done' then xsknife_data.step = 'despachiaire'; print_success('Unmarked ' .. proper_name .. ' for ' .. tracker.current_char);
        else xsknife_data.step = 'done'; print_success('Marked ' .. proper_name .. ' as completed for ' .. tracker.current_char .. '!'); end
        save_settings(); return;
    end
    print_error('Unknown task: ' .. proper_name);
end

ashita.events.register('load', 'load_cb', function()
    -- One-shot migration from legacy path (addon/settings) to config/addons/Homework
    migrate_legacy_settings();
    -- Try to remove the now-empty legacy dir (best-effort; only succeeds if empty)
    local legacy_dir = get_legacy_dir();
    if ashita.fs.exists(legacy_dir) then
        os.remove(legacy_dir);
    end
    local dir = get_config_dir();
    if not ashita.fs.exists(dir) then
        ashita.fs.create_dir(dir);
    end
    local loaded_settings = load_settings();
    if loaded_settings ~= nil then
        tracker.settings = loaded_settings;
        if tracker.settings.characters == nil then tracker.settings.characters = {}; end
        if type(tracker.settings.dynamis_accounts) ~= 'table' then tracker.settings.dynamis_accounts = {}; end
        if tracker.settings.dynamis_account_wide ~= true then tracker.settings.dynamis_account_wide = false; end
        if tonumber(tracker.settings.chars_per_account or 0) == nil
           or tonumber(tracker.settings.chars_per_account or 0) < 1 then
            tracker.settings.chars_per_account = DEFAULT_CHARS_PER_ACCOUNT;
        end
        local needs_save = false;
        -- A truncated or partly written homework.json used to leave `tasks` nil,
        -- which then blew up in the first ipairs() during render.
        if type(tracker.settings.tasks) ~= 'table' or #tracker.settings.tasks == 0 then
            tracker.settings.tasks = {};
            for _, t in ipairs(DEFAULT_TASKS) do table.insert(tracker.settings.tasks, t); end
            needs_save = true;
        else
            -- Append any task added by a newer version that this save predates.
            for _, t in ipairs(DEFAULT_TASKS) do
                local found = false;
                for _, existing in ipairs(tracker.settings.tasks) do
                    if existing == t then found = true; break; end
                end
                if not found then table.insert(tracker.settings.tasks, t); needs_save = true; end
            end
        end
        if tracker.settings.characters['Unknown'] ~= nil then
            tracker.settings.characters['Unknown'] = nil;
            needs_save = true;
        end
        if tracker.settings.reset_time ~= nil then
            tracker.settings.reset_time = nil;
            needs_save = true;
        end
        for char_name, char_data in pairs(tracker.settings.characters) do
            if char_data.completed ~= nil then char_data.completed = nil; needs_save = true; end
            if char_data.weekly_ki_data ~= nil then char_data.weekly_ki_data = nil; needs_save = true; end
            if char_data.xsknife_data ~= nil and char_data.xsknife_data.tally_tracked ~= nil then
                char_data.xsknife_data.tally_tracked = nil; needs_save = true;
            end
        end
        if needs_save then save_settings(); end
    end
    load_display_settings();
    tracker.current_char = get_char_name();
    if tracker.current_char ~= 'Unknown' then
        get_char_data();
        initialize_timer();
        update_char_list();
        -- Reading key items out of game memory is best-effort: on some clients
        -- HasKeyItem is simply unavailable and answers false for every id. It is
        -- never treated as authoritative on its own any more.
        if populate_kis_from_memory() then
            scan_key_items(true);
        elseif restore_ki_cache() then
            -- Recovered last session's state from homework.json. Accurate unless
            -- key items changed elsewhere; the next zone-in corrects it silently.
            print_msg('Key items restored from your last session. Zone once to refresh.');
        else
            -- Nothing to go on. Wait for the 0x055 packets, which arrive on zone-in.
            tracker.login_state.waiting_for_ki = true;
            tracker.login_state.suppress_ki_events = true;
            tracker.login_state.ki_packets_received = 0;
            print_msg('Key items unavailable - zone once and they will sync automatically.');
        end
    else
        tracker.login_state.waiting_for_login = true;
        print_msg('Waiting for character data...');
    end
    print_success('Loaded successfully! Use /hw to open or /hw help for commands.');
end);

ashita.events.register('unload', 'unload_cb', function()
    save_settings();
    save_display_settings();
end);

ashita.events.register('text_in', 'text_in_cb', function(e)
    local base_mode = bit.band(e.mode, 0xFF);
    -- Early exit for modes we don't care about (cheapest check first)
    if base_mode ~= 150 and base_mode ~= 9 and base_mode ~= 142 then return; end
    
    if tracker.current_char == nil or tracker.current_char == 'Unknown' then return; end
    
    local message = e.message;
    local zone_id = get_zone_id();
    local char_data = get_char_data();
    
    -- Base mode 142: Highwind completion & Dynamis claim
    if base_mode == 142 then
        if is_in_highwind_zone() and message:contains('Obtained 3000 gil') then
            char_data.quest_steps.highwind = 'done';
            save_settings();
            print_success('Highwind complete!');
        end
        -- Dynamis zone-claim detection (two-step: claim message then obtain confirmation)
        if message:find('The time and destination for your foray into Dynamis has been recorded') then
            tracker.pending_dynamis_claim = os.time();
        elseif message:find('Obtained: Perpetual hourglass') then
            if tracker.pending_dynamis_claim ~= nil
                and (os.time() - tracker.pending_dynamis_claim) <= 5 then
                local store = get_dynamis_store(tracker.current_char);
                if store ~= nil then
                    -- The charged glass is already in the bag by the time this
                    -- message lands, so its serial can be read immediately.
                    local serial = find_glass_serial(nil);
                    store.claimed_at = os.time();
                    count_dynamis_entry(store, serial, 'glass broken - counted');
                end
            end
            tracker.pending_dynamis_claim = nil;
        end
        return;
    end
    
    -- Base mode 9: Eeko-Weeko (Ru'Lude Gardens zone 243)
    if base_mode == 9 then
        if zone_id ~= 243 then return; end
        if message:find('direction of') and message:find('Consulate') then
            local eco_data = char_data.ecowarrior_data;
            local locked = {};
            if message:find('Windurst Consulate') then table.insert(locked, 'windurst'); end
            if message:find("San d'Oria Consulate") or message:find("San d\'Oria Consulate") then table.insert(locked, 'sandoria'); end
            if message:find('Bastok Consulate') then table.insert(locked, 'bastok'); end
            if #locked > 0 then
                eco_data.locked_nations = locked;
                eco_data.knows_status = true;
                if eco_data.step == 'unknown' then
                    eco_data.step = 'scanned';
                end
                eco_data.current_nation = nil;
                save_settings();
                print_success('EcoWarrior updated from Eeko-Weeko!');
            end
        end
        if message:find('all three nation') then
            local eco_data = char_data.ecowarrior_data;
            eco_data.locked_nations = {};
            eco_data.knows_status = true;
            if eco_data.step == 'unknown' then
                eco_data.step = 'scanned';
            end
            eco_data.current_nation = nil;
            save_settings();
            print_msg('EcoWarrior: All nations available!');
        end
        return;
    end
    
    -- Base mode 150: NPC dialogue
    -- CookBook quest start (Jonette in Tavnazian Safehold)
    if zone_id == 26 and message:find('The information you have brought me on Tavnazian cuisine') then
        if char_data.quest_steps.cookbook == 'jonette' or char_data.quest_steps.cookbook == 'unknown' then
            char_data.quest_steps.cookbook = 'sacrarium';
            save_settings();
            print_success('CookBook started - Head to ??? in Sacrarium!');
        end
    end
    -- SpiceGals quest acceptance (Rouva in Southern San d'Oria)
    if zone_id == 230 and message:find("Forget the words I have spoken") then
        if char_data.quest_steps.spicegals == 'rouva' or char_data.quest_steps.spicegals == 'unknown' or char_data.quest_steps.spicegals == 'scanned' then
            char_data.quest_steps.spicegals = 'riverne';
            save_settings();
            print_success('SpiceGals started - Head to Riverne B for Rivernewort!');
        end
    end
    -- EcoWarrior quest acceptance San d'Oria (Norejaie in Southern San d'Oria)
    if zone_id == 230 and (message:find("Rojaireaut, our V.E.R.M.I.N. agent") or message:find("I knew you'd come through for us")) then
        local eco_data = char_data.ecowarrior_data;
        if eco_data.step == 'ready' or eco_data.step == 'scanned' or eco_data.step == 'unknown' then
            eco_data.step = 'field_agent'; eco_data.current_nation = 'sandoria';
            eco_data.knows_status = true;
            save_settings();
            print_success("EcoWarrior: San d'Oria quest accepted! Head to Ordelle's Caves.");
        end
    end
    -- EcoWarrior quest acceptance Windurst (Lumomo in Windurst Waters)
    if zone_id == 238 and (message:find("Ahko Mhalijikhari, will be waiting") or message:find("Ta%-taru and good luck")) then
        local eco_data = char_data.ecowarrior_data;
        if eco_data.step == 'ready' or eco_data.step == 'scanned' or eco_data.step == 'unknown' then
            eco_data.step = 'field_agent'; eco_data.current_nation = 'windurst';
            eco_data.knows_status = true;
            save_settings();
            print_success('EcoWarrior: Windurst quest accepted! Head to Maze of Shakhrami.');
        end
    end
    -- EcoWarrior quest acceptance Bastok (Raifa in Port Bastok)
    if zone_id == 236 and message:find("Degga, one of our V.E.R.M.I.N.") then
        local eco_data = char_data.ecowarrior_data;
        if eco_data.step == 'ready' or eco_data.step == 'scanned' or eco_data.step == 'unknown' then
            eco_data.step = 'field_agent'; eco_data.current_nation = 'bastok';
            eco_data.knows_status = true;
            save_settings();
            print_success('EcoWarrior: Bastok quest accepted! Head to Gusgen Mines.');
        end
    end
    -- EcoWarrior NM spawn San d'Oria (Rojaireaut in Ordelle's Caves)
    if zone_id == 193 and message:find("Now, close your eyes for a moment") then
        local eco_data = char_data.ecowarrior_data;
        if eco_data.step == 'field_agent' and eco_data.current_nation == 'sandoria' then
            eco_data.step = 'nm';
            save_settings();
            print_success('EcoWarrior: Kill the NM!');
        end
    end
    -- EcoWarrior NM spawn Windurst (Ahko Mhalijikhari in Maze of Shakhrami)
    if zone_id == 198 and message:find("Rrright, here we go") then
        local eco_data = char_data.ecowarrior_data;
        if eco_data.step == 'field_agent' and eco_data.current_nation == 'windurst' then
            eco_data.step = 'nm';
            save_settings();
            print_success('EcoWarrior: Kill the NM!');
        end
    end
    -- EcoWarrior NM spawn Bastok (Degga in Gusgen Mines)
    if zone_id == 196 and message:find("just close your eyes") then
        local eco_data = char_data.ecowarrior_data;
        if eco_data.step == 'field_agent' and eco_data.current_nation == 'bastok' then
            eco_data.step = 'nm';
            save_settings();
            print_success('EcoWarrior: Kill the NM!');
        end
    end
    -- EcoWarrior return to city NPC San d'Oria (Rojaireaut in Ordelle's Caves)
    if zone_id == 193 and (message:find("Take it back to her in San d'Oria") or message:find("proof enough for Norejaie")) then
        local eco_data = char_data.ecowarrior_data;
        if eco_data.step == 'field_agent_return' and eco_data.current_nation == 'sandoria' then
            eco_data.step = 'reward';
            save_settings();
            print_success("EcoWarrior: Go to Norejaie in Southern San d'Oria for reward!");
        end
    end
    -- EcoWarrior return to city NPC Windurst (Ahko Mhalijikhari in Maze of Shakhrami)
    if zone_id == 198 and message:find("take it back to Lumomo") then
        local eco_data = char_data.ecowarrior_data;
        if eco_data.step == 'field_agent_return' and eco_data.current_nation == 'windurst' then
            eco_data.step = 'reward';
            save_settings();
            print_success('EcoWarrior: Go to Lumomo in Windurst Waters for reward!');
        end
    end
    -- EcoWarrior return to city NPC Bastok (Degga in Gusgen Mines)
    if zone_id == 196 and message:find("waiting for you in Bastok") then
        local eco_data = char_data.ecowarrior_data;
        if eco_data.step == 'field_agent_return' and eco_data.current_nation == 'bastok' then
            eco_data.step = 'reward';
            save_settings();
            print_success('EcoWarrior: Go to Raifa in Port Bastok for reward!');
        end
    end
    -- UnInvited win (Justinius in Tavnazian Safehold)
    if zone_id == 26 and message:find("intruders are gone for good") then
        if char_data.quest_steps.uninvited == 'justinius_return' then
            char_data.quest_steps.uninvited = 'done';
            tracker.uninvited_done_time = os.time();
            save_settings();
            print_success('UnInvited complete!');
        end
    end
    -- UnInvited lose (Justinius in Tavnazian Safehold)
    if zone_id == 26 and message:find("another permit approved") then
        if char_data.quest_steps.uninvited == 'justinius_return' then
            char_data.quest_steps.uninvited = 'done';
            save_settings();
            print_msg('UnInvited complete (lost). Wait for next permit.');
        end
    end
    -- UnInvited inventory full (undo done if within 4 seconds)
    if zone_id == 26 and message:find("sorting your inventory") then
        if char_data.quest_steps.uninvited == 'done' then
            local time_since_done = os.time() - (tracker.uninvited_done_time or 0);
            if time_since_done <= 4 then
                char_data.quest_steps.uninvited = 'justinius_return';
                save_settings();
                print_msg('UnInvited: Inventory full - Return after using reward.');
            end
        end
    end
end);

ashita.events.register('packet_in', 'packet_in_cb', function(e)
    local id = e.id;
    local data = e.data;
    -- Logout packet
    if id == 0x000B then
        local logout_state = struct.unpack('I', data, 0x04 + 1);
        if logout_state == 1 then
            tracker.current_char = 'Unknown';
            tracker.next_check_time = 0;
            tracker.login_state.waiting_for_login = true;
            tracker.kis = {};
            tracker.kis_initialized = false;
            print_msg('Logout detected.');
        end
        return;
    end
    -- Login packet (also received on zone-in)
    if id == 0x000A then
        -- Get zone ID from packet
        local zone_id = struct.unpack('H', data, 0x30 + 1) or 0;
        
        -- Check if this is a Dynamis zone
        if DYNAMIS_ZONES[zone_id] then
            get_char_data();
            local store = get_dynamis_store(tracker.current_char);
            if store ~= nil then
                -- Count once per glass, identified by its serial. A glass we broke
                -- ourselves was already counted, so walking in changes nothing. A
                -- glass someone else broke - same zone or not - is a new serial and
                -- counts here.
                local serial = find_glass_serial(zone_id);
                if serial == nil then
                    -- Could not read a serial (no glass in the bag, or unreadable
                    -- Extra bytes). Fall back to counting each Dynamis zone once per
                    -- week so an entry is never silently missed.
                    serial = 'zone-' .. tostring(zone_id);
                end
                if not glass_already_counted(store, serial) then
                    count_dynamis_entry(store, serial, 'entry counted');
                end
            end
        end
        
        if tracker.login_state.waiting_for_login then
            -- Full login - character change
            tracker.login_state.waiting_for_login = false;
            tracker.kis = {};
            tracker.kis_initialized = false;
            local name_offset = 0x84 + 1;
            local raw_name = data:sub(name_offset, name_offset + 15);
            local current_char = raw_name:match("^[%w]+") or 'Unknown';
            if current_char ~= 'Unknown' and current_char ~= '' then
                on_character_change(current_char);
                print_success('Character loaded: ' .. current_char);
                tracker.login_state.waiting_for_ki = true;
                tracker.login_state.ki_packets_received = 0;
                tracker.login_state.suppress_ki_events = true;
            end
        else
            -- Zone-in (not a fresh login) - suppress KI events until packets stabilize
            tracker.login_state.suppress_ki_events = true;
            tracker.login_state.ki_packets_received = 0;
        end
        return;
    end
    -- Key Item packet
    if id == 0x0055 then
        local ki_table_type = struct.unpack('B', data, 0x84 + 1);
        local offset = ki_table_type * 512;
        for i = 0, 511 do
            local ki_position = i + offset;
            local byte_index = math.floor(i / 8);
            local bit_index = i % 8;
            local ki_byte = struct.unpack('B', data, 0x04 + byte_index + 1);
            local has_ki = bit.band(bit.rshift(ki_byte, bit_index), 1) == 1;
            -- Only trigger events if not suppressed (zone-in/login in progress)
            if not tracker.login_state.suppress_ki_events then
                if (tracker.kis[ki_position] ~= nil) and (has_ki ~= tracker.kis[ki_position]) then
                    if has_ki then on_ki_gained(ki_position); else on_ki_lost(ki_position); end
                end
            end
            tracker.kis[ki_position] = has_ki;
        end
        -- Track packets received during login/zone
        tracker.login_state.ki_packets_received = tracker.login_state.ki_packets_received + 1;
        if tracker.login_state.ki_packets_received >= 7 then
            -- All KI packets received - clear suppression and update state
            tracker.login_state.suppress_ki_events = false;
            tracker.login_state.ki_packets_received = 0;
            tracker.kis_initialized = true;
            if tracker.login_state.waiting_for_ki then
                tracker.login_state.waiting_for_ki = false;
                local char_data = get_char_data();
                if char_data ~= nil then
                    scan_key_items(true);
                end
            end
        end
        return;
    end
    return;
end);

-- Note: the old outgoing 0x028 drop handler is gone. Dropping a glass no longer
-- affects anything, because entries are keyed on glass serials rather than on a
-- "do I still hold a glass" flag.

ashita.events.register('d3d_present', 'd3d_present_cb', function()
    -- Render UI (always, imgui handles visibility)
    render_ui();
    
    -- Throttled checks
    local current_time = os.time();
    if current_time - tracker.last_render_time < tracker.render_interval then return; end
    tracker.last_render_time = current_time;
    if tracker.next_check_time > 0 and current_time >= tracker.next_check_time then
        reset_tracker();
    end
end);

ashita.events.register('command', 'command_cb', function(e)
    local command = e.command;
    local args = command:args();
    if (#args == 0 or (args[1] ~= '/hw' and args[1] ~= '/homework' and args[1] ~= '/homeworks')) then return; end
    e.blocked = true;
    local char_data = get_char_data();
    if char_data == nil then print_error('Character not loaded yet. Please wait...'); return; end
    local current_time = os.time();
    if char_data.last_reset > 0 and current_time >= calculate_next_reset(char_data.last_reset) then
        reset_tracker();
    end
    if (#args == 1) then
        -- /hw alone toggles the window
        if ui.is_open[1] then
            ui.is_open[1] = false;
        else
            update_char_list();
            ui.is_open[1] = true;
        end
        return;
    end
    if (args[2] == 'help') then
        print_msg('Available commands:');
        print('  \30\106/hw - Toggle tracking window');
        print('  \30\106/hw weeklys - Show weekly homeworks checklist (chat)');
        print('  \30\106/hw timers - Show ENM/Limbus timers (chat)');
        print('  \30\106/hw chars - Show all characters and their progress');
        print('  \30\106/hw chars <n> - Show week & timers for specific character');
        print('  \30\106/hw <task> - Toggle task completion');
        print('  \30\106/hw task - List every task and its short forms');
        print('  \30\106/hw eco - Toggle EcoWarrior done/undone');
        print('  \30\106/hw eco <nation> - Start EcoWarrior for nation (sandy/basty/windy)');
        print('  \30\106/hw scan - Scan key items for current character');
        print('  \30\106/hw reset - Factory reset (delete all data)');
        print('  \30\106/hw help - Show this help');
        print('');
        print_msg('Aliases: /hw, /homework, /homeworks');
        return;
    end
    if (args[2] == 'show') then
        update_char_list();
        ui.is_open[1] = true;
        return;
    end
    if (args[2] == 'hide') then
        ui.is_open[1] = false;
        return;
    end
    if (args[2] == 'weeklys' or args[2] == 'week' or args[2] == 'weekly' or args[2] == 'list') then show_list(); return; end
    if (args[2] == 'timers' or args[2] == 'timer') then show_timers(); return; end
    if (args[2] == 'chars' or args[2] == 'char') then
        if (#args >= 3) then show_char_details(args[3]); else show_all_chars(); end
        return;
    end
    if (args[2] == 'reset') then
        local char_count = 0;
        for _ in pairs(tracker.settings.characters) do char_count = char_count + 1; end
        print_msg('WARNING: This will DELETE all saved data (' .. char_count .. ' characters, progress, timers).');
        print_msg('Type /hw yes within 30 seconds to confirm, or /hw no to cancel.');
        tracker.pending_reset = os.time();
        return;
    end
    if (args[2] == 'yes') then
        if tracker.pending_reset == nil then
            print_error('Nothing to confirm.');
        elseif (current_time - tracker.pending_reset) > RESET_CONFIRM_WINDOW then
            tracker.pending_reset = nil;
            print_error('That confirmation expired. Run /hw reset again if you meant it.');
        else
            tracker.pending_reset = nil;
            factory_reset();
        end
        return;
    end
    if (args[2] == 'no') then
        if tracker.pending_reset == nil then
            print_error('Nothing to cancel.');
        else
            tracker.pending_reset = nil;
            print_msg('Reset cancelled.');
        end
        return;
    end
    if (args[2] == 'task' or args[2] == 'tasks') then
        print_msg('Toggle a task with \30\110/hw <task>\30\106:');
        for _, task in ipairs(tracker.settings.tasks) do
            local short = {};
            for alias, target in pairs(TASK_ALIASES) do
                if target == task then table.insert(short, alias); end
            end
            table.sort(short);
            local canonical = normalize_task(task);
            local shown = { canonical };
            for _, a in ipairs(short) do
                if a ~= canonical then table.insert(shown, a); end
            end
            print(string.format('%s\30\110%-12s\30\106 %s', HDR, task, table.concat(shown, ', ')));
        end
        print_msg('Also: \30\110/hw eco <nation>\30\106 to set an EcoWarrior nation.');
        return;
    end
    if (args[2] == 'scan') then
        if not tracker.kis_initialized then
            if not populate_kis_from_memory() then restore_ki_cache(); end
        end
        scan_key_items();
        return;
    end
    if (args[2] == 'eco' or args[2] == 'ecowarrior') then
        local eco_data = char_data.ecowarrior_data;
        
        -- No nation argument = toggle done/undone
        if #args < 3 then
            local step = eco_data.step;
            if step == 'unknown' then
                print_error('EcoWarrior status unknown. Use /hw scan or /hw eco <nation> first.');
                return;
            elseif step == 'done' then
                eco_data.step = 'ready';
                eco_data.knows_status = true;
                print_success('EcoWarrior marked as NOT done.');
            else
                -- scanned, ready, field_agent, nm, field_agent_return, reward -> done
                eco_data.step = 'done';
                eco_data.knows_status = true;
                eco_data.current_nation = nil;
                print_success('EcoWarrior marked as done.');
            end
            save_settings();
            return;
        end
        
        -- Nation argument = start for that nation
        local nation_input = args[3]:lower();
        local nation = nil;
        if nation_input == 'sandoria' or nation_input == 'sandy' or nation_input == 'sand' or nation_input == "san d'oria" or nation_input == 'san doria' then nation = 'sandoria';
        elseif nation_input == 'bastok' or nation_input == 'basty' or nation_input == 'bast' then nation = 'bastok';
        elseif nation_input == 'windurst' or nation_input == 'windy' or nation_input == 'windhurst' then nation = 'windurst'; end
        if nation == nil then print_error('Invalid nation. Use: sandy, basty, or windy'); return; end
        local is_locked = false;
        local lock_index = nil;
        for i, n in ipairs(eco_data.locked_nations) do if n == nation then is_locked = true; lock_index = i; break; end end
        if is_locked then table.remove(eco_data.locked_nations, lock_index); print_success('Unlocked ' .. nation .. ' for EcoWarrior');
        else table.insert(eco_data.locked_nations, nation); print_success('Marked ' .. nation .. ' as completed for EcoWarrior'); end
        if #eco_data.locked_nations >= 3 then eco_data.locked_nations = {}; print_msg('All nations complete! Reset for next cycle.'); end
        if eco_data.step == 'unknown' then eco_data.step = 'scanned'; end
        eco_data.knows_status = true;
        eco_data.current_nation = nil;
        save_settings();
        return;
    end
    if (#args >= 2) then
        local task = args[2];
        local proper_name = find_task_name(task);
        if proper_name then toggle_task(task); return; end
    end
    print_error('Invalid command. Use /hw help for usage.');
    return;
end);
