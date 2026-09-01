--[[
* Addons - Copyright (c) 2024
* Homework - A weekly checklist addon for Ashita 4
--]]

addon.author   = 'Riquelme';
addon.name     = 'Homework';
addon.version   = '3.8';
addon.desc      = 'Weekly homework tracker for FFXI';
addon.link      = '';

require('common');
local imgui = require('imgui');

-- UI State
local ui = {
    is_open = { false },
    selected_char = { 0 },  -- Shared character selection for both tabs
    selected_name = nil,    -- Name behind that index, so a rebuild keeps the choice
    char_list = {},
    font_scale = 1.2,
    -- Resolved lazily in render_ui: read at file-load time this could capture
    -- nil if the ImGui globals are not populated yet, leaving the window
    -- permanently collapsible with no way back short of a reload.
    window_flags = nil,
    -- Set when render_ui throws, so a broken frame does not repeat 60x a second.
    -- Cleared by /hw show and by a factory reset, both of which change the state
    -- that caused it.
    render_failed = false,
    char_list_combo = nil,   -- cached '\0'-joined dropdown string
    -- Push depths, so a throw inside render_ui can be unwound cleanly
    style_colors = 0,
    style_vars = 0,
    fonts_pushed = 0,
    began = false,
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

-- Defined below with the rest of the file I/O, but migrate_settings_file runs
-- above it. Without this the name compiled to a global read - nil - and the
-- migration threw inside load_cb for every user upgrading from a legacy path.
local write_file_atomic;

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
    -- Use the shared writer: a crash between write and verify used to leave a
    -- corrupt file at the new path, which then blocked migration forever via the
    -- exists-check while the good legacy file sat untouched.
    if not write_file_atomic(new_path, content) then return; end
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
    -- Parenthesised: a tail-returned gsub also yields its replacement count, so
    -- any caller that forwards the result onward silently gets two values.
    -- Control bytes below 0x20 have to be encoded too, or the save-verify parse
    -- can reject the file and persistence stops silently. The parser below
    -- decodes \uXXXX to match; escaping on the writer alone would corrupt
    -- round-trips, because the unescape would return the literal 'u'.
    return (str:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t')
               :gsub('[%z\1-\8\11\12\14-\31]', function(c)
                   return string.format('\\u%04X', string.byte(c));
               end));
end

local function serialize_value(val, indent, key, depth)
    indent = indent or '';
    depth = (depth or 0) + 1;
    local t = type(val);
    -- A cycle would recurse until the stack blew, and the throw would land in
    -- whatever event handler called save rather than in write_file_atomic's
    -- polite failure path. Nothing legitimate here nests anywhere near this deep.
    if depth > 32 then return 'null'; end
    if t == 'table' then
        -- Check if this should be an array (has numeric keys OR is a known array field)
        local is_array = #val > 0 or (key ~= nil and ARRAY_FIELDS[key]);
        if is_array then
            local items = {};
            for _, v in ipairs(val) do
                table.insert(items, serialize_value(v, indent, nil, depth));
            end
            return '[' .. table.concat(items, ', ') .. ']';
        else
            local result = '{\n';
            local first = true;
            for k, v in pairs(val) do
                if not first then result = result .. ',\n'; end
                first = false;
                local key_str = '"' .. escape_json_string(tostring(k)) .. '"';
                result = result .. indent .. '  ' .. key_str .. ': ' .. serialize_value(v, indent .. '  ', k, depth);
            end
            if not first then result = result .. '\n' .. indent; end
            return result .. '}';
        end
    elseif t == 'string' then
        return '"' .. escape_json_string(val) .. '"';
    elseif t == 'boolean' then
        return val and 'true' or 'false';
    elseif t == 'number' then
        -- tostring(0/0) emits 'nan', which the save verification then fails to
        -- parse - so one bad number silently stopped the addon persisting at all
        -- for the rest of the session. Anything non-finite becomes 0.
        if val ~= val or val == math.huge or val == -math.huge then return '0'; end
        return tostring(val);
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
        -- An explicit scanner, not a gsub. Lua patterns cannot express the
        -- lookahead this needs: `\\(u?)(%x?%x?%x?%x?)` can never capture n, t or
        -- r (not 'u', not hex), so the match consumed only the backslash and
        -- left the letter behind - \\n decoded to the letter n, and an escaped
        -- backslash vanished entirely. Three attempts at a clever one-liner
        -- produced three different corruptions; this is boring and correct.
        local raw = str:sub(pos + 1, endpos - 1);
        local out, i = {}, 1;
        while i <= #raw do
            local j = raw:find('\\', i, true);
            if j == nil then table.insert(out, raw:sub(i)); break; end
            table.insert(out, raw:sub(i, j - 1));
            local c = raw:sub(j + 1, j + 1);
            if c == 'u' and raw:sub(j + 2, j + 5):match('^%x%x%x%x$') then
                local n = tonumber(raw:sub(j + 2, j + 5), 16);
                -- Out of byte range: hand back the original text rather than
                -- silently dropping the character.
                table.insert(out, n < 256 and string.char(n) or raw:sub(j, j + 5));
                i = j + 6;
            else
                if c == 'n' then c = '\n';
                elseif c == 't' then c = '\t';
                elseif c == 'r' then c = '\r'; end
                table.insert(out, c);
                i = j + 2;
            end
        end
        local s = table.concat(out);
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
            -- table.insert with nil leaves a hole that breaks # and ipairs, and
            -- this parser exists precisely because files get hand-edited.
            if val ~= nil then table.insert(arr, val); end
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

-- Set once when a save is dropped, so the warning is not repeated every second.
local save_warned = false;
local display_save_warned = false;

local function print_msg(message)
    print('\30\081[\30\082Homework\30\081]\30\106 ' .. message);
end

local function print_error(message)
    print('\30\081[\30\082Homework\30\081]\30\068 ' .. message);
end

local function print_success(message)
    print('\30\081[\30\082Homework\30\081]\30\110 ' .. message);
end

-- ===== FILE I/O =====
-- Every write in this addon goes through here. Three hand-rolled copies of this
-- logic had drifted apart, each hardened at a different time; the one that was
-- never hardened silently destroyed display.json on a failed write.
--
-- Writes to a temp file, checks the return of write (which yields nil on
-- failure rather than raising), reads the bytes back and compares them, then
-- rotates the previous file to .bak and renames the temp into place. Any
-- failure leaves the existing file exactly as it was.
function write_file_atomic(path, body, verify)
    local tmp = path .. '.tmp';
    local f = io.open(tmp, 'wb');
    if f == nil then return false, 'cannot open temp file'; end
    local wrote = f:write(body);
    f:close();
    if wrote == nil then os.remove(tmp); return false, 'write failed'; end

    local vf = io.open(tmp, 'rb');
    if vf == nil then return false, 'temp file vanished'; end
    local back = vf:read('*all');
    vf:close();
    if back ~= body then os.remove(tmp); return false, 'short write'; end
    if verify ~= nil then
        local ok, err = verify(back);
        if not ok then os.remove(tmp); return false, err or 'verification failed'; end
    end

    if ashita.fs.exists(path) then
        os.remove(path .. '.bak');
        if not os.rename(path, path .. '.bak') then
            os.remove(tmp); return false, 'cannot rotate backup';
        end
    end
    if not os.rename(tmp, path) then
        os.rename(path .. '.bak', path);   -- put the old one back
        os.remove(tmp);
        return false, 'cannot replace file';
    end
    return true;
end

-- Reads and parses, tolerating anything. Returns nil rather than throwing, so a
-- corrupt file can never take a load path down with it.
local function read_json_file(path)
    if not ashita.fs.exists(path) then return nil; end
    local f = io.open(path, 'rb');
    if f == nil then return nil; end
    local content = f:read('*all');
    f:close();
    if content == nil or content == '' then return nil; end
    local ok, result = pcall(parse_json_value, content, 1);
    if not ok or type(result) ~= 'table' then return nil; end
    return result;
end

-- Defined further down, once the limit constants it clamps against exist.
local sanitize_loaded_settings;

local function load_settings()
    local path = get_settings_path();
    -- Judge the RAW read: sanitize backfills characters = {}, so asking the
    -- sanitized copy whether it has characters always says yes and the backup
    -- would never be consulted.
    local raw = read_json_file(path);
    if raw == nil or type(raw.characters) ~= 'table' then
        local backup = read_json_file(path .. '.bak');
        if backup ~= nil and type(backup.characters) == 'table' then
            print_msg('homework.json was unreadable - restored from the backup copy.');
            return sanitize_loaded_settings(backup);
        end
    end
    return sanitize_loaded_settings(raw);
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

-- Tracker data
local tracker = {
    settings = {
        -- Filled from DEFAULT_TASKS in the load handler, so a new task cannot be
        -- added to one list and forgotten in the other.
        tasks = {},
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
        suppress_ki_events = false, -- Set true during zone-in to prevent false "obtained" messages
        suppress_started = 0,       -- When suppression began, so it cannot stick forever
        blocks_this_zone = 0        -- Blocks seen since the last zone-in
    },
    -- KI state tracking (for detecting gain/loss via 0x055)
    -- 3 states: nil = unknown, true = has KI, false = doesn't have KI
    kis = {},  -- [ki_id] = true/false/nil, populated from packets or memory
    kis_initialized = false,  -- Don't trigger gain/loss on initial population
    isnm_observed_since = nil, -- When continuous KI observation of this login began
    -- Frame throttle for render
    -- These throttle the periodic reset/suppression checks, NOT rendering -
    -- render_ui runs every frame regardless.
    last_check_time = 0,
    check_interval = 2,
    -- UnInvited inventory check
    uninvited_done_time = 0,       -- Timestamp when UnInvited marked done
    -- Timestamp of a pending /hw reset, nil when none outstanding
    pending_reset = nil,
    -- Set by the Dynamis claim message, consumed by the hourglass-obtained message
    pending_dynamis_claim = nil,
    -- Session only: stops the "already used both runs" notice repeating
    last_denied_serial = nil
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
    local body = serialize_value(tracker.settings);
    local ok, why = write_file_atomic(path, body, function(bytes)
        local parsed = parse_json_value(bytes, 1);
        if type(parsed) ~= 'table' or parsed.characters == nil then
            return false, 'saved data did not parse back';
        end
        return true;
    end);
    if not ok then
        -- Silent failure here is invisible data loss, so say it once.
        if not save_warned then
            save_warned = true;
            print_error('Could not save homework.json (' .. tostring(why)
                .. '). Your previous save is intact.');
        end
        return false;
    end
    save_warned = false;
    return true;
end

-- ENM/Limbus Key Items (needed for display settings initialization)
local ENM_KEY_ITEMS = {
    { name = 'Boneyard Gully', ki_id = 678, ki_name = 'Miasma Filter', cooldown = 120 * 3600 },
    { name = 'Bearclaw Pinnacle', ki_id = 677, ki_name = 'Zephyr Fan', cooldown = 120 * 3600 },
    { name = 'Mine Shaft #2716', ki_id = 676, ki_name = 'Shaft #2716 Operating Lever', cooldown = 120 * 3600 },
    -- Same zone, SEPARATE key item and separate cooldown (LSB: charVar
    -- [ENM]GateDial vs [ENM]OperatingLever, both from Twinkbrix). The Lever
    -- opens Bionic Bug; the Dial opens BOTH Pulling the Strings and
    -- Automaton Assault - one timer, two possible fights.
    { name = 'Mine Shaft (Dial)', ki_id = 707, ki_name = 'Shaft Gate Operating Dial', cooldown = 120 * 3600 },
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

-- Incoming 0x020 "item obtained" packet, 1-based offsets for struct.unpack:
--   13 = item id (u16)
--   18 = start of the item's Extra block, same layout as the inventory copy
-- Verified byte for byte against a live capture of a Windurst glass being broken.
local ITEM_PACKET_ID_OFFSET    = 13;
local ITEM_PACKET_EXTRA_OFFSET = 18;

-- ===== ASSAULT =====
-- Key item ids, matching LandSandBoat's key_item enum. Confirmed against a live
-- /debug ki capture of three assault runs.
local IMPERIAL_ARMY_ID_TAG = 787;
local ASSAULT_ARMBAND      = 797;

-- Rytaal's tag counter menu. The server fills it via
--   startEvent(268, 2, tagStock, currentAssault, haveIDtag, allTagsTimeCS, tagsAvail)
-- so those six event params land in the 0x034 packet in order starting at 0x08.
local RYTAAL_MENU_ID       = 268;
local MENU_OFFSET_MENU_ID  = 0x2C;   -- u16
local MENU_PARAM_TAG_STOCK = 0x0C;   -- u32, tags Rytaal is holding
local MENU_PARAM_ASSAULT   = 0x10;   -- u32, current assault mission id
local MENU_PARAM_HAVE_TAG  = 0x14;   -- u32, 1 when carrying a tag
local MENU_PARAM_TAG_TIME  = 0x18;   -- u32, restock anchor

-- One tag per 24h. It is 600s instead for anyone holding Rhapsody in Azure,
-- which we cannot see, so the countdown will read long for those players.
local ASSAULT_TAG_PERIOD = 24 * 3600;

-- allTagsTimeCS + this = unix time of the next tag.
-- Calibrated against live behaviour on THIS server (2026-08-24): a tag drawn
-- Aug 20 22:03:42 regenerated on the same clock time days later, and the
-- countdown built from this constant matched to the minute. This is
-- LandSandBoat's VANADIEL_EPOCH plus exactly 2 days; this server's custom
-- account pool evidently reports its anchor differently than stock LSB, so
-- the live calibration wins over the source reading. Do not "correct" this
-- from LSB again without a live capture proving it wrong.
local ASSAULT_TAG_EPOCH = 1009983600;

-- Rytaal stocks 3, or 4 for a Second Lieutenant who has cleared every assault
-- (LandSandBoat getMaxTagStock: rank plus every mission complete, with a
-- one-time bonus tag on first qualifying).
-- The packet never states the cap, so start at 3 and raise it if we see more.
local ASSAULT_DEFAULT_MAX_STOCK = 3;

-- ===== ISNM =====
-- Imperial Standing NM battlefields. Two key items sold by Shajaf in Whitegate
-- (LandSandBoat scripts/zones/Aht_Urhgan_Whitegate/npcs/Shajaf.lua):
--   807 CONFIDENTIAL_IMPERIAL_ORDER - 2000 credits, the level 60 fights
--   808 SECRET_IMPERIAL_ORDER      - 3000 credits, the uncapped fights
-- Buying either sets charVar [ISNM]Accepted until JST midnight, so the daily
-- lock is shared between the two tiers and sits on BUYING, never on using.
-- The key item itself never expires (the script's own TODO admits expiry is
-- unimplemented), so holding an order across the reset and fighting twice back
-- to back is legal. Only the player who opens the battlefield loses the order
-- (requiredKeyItems onlyInitiator = true in the battlefield scripts).
local ISNM_CONFIDENTIAL_KI = 807;
local ISNM_SECRET_KI       = 808;

-- Shajaf's menus, verified against a live capture (menu 160 carrying the
-- player's standing as its first param). Which menu OPENS is the state:
--   160 can buy   161 already holding   162 no Wildcat Badge   163 locked today
-- Small menu ids repeat across zones, so these are gated on the zone id that
-- rides in the same packet.
local ISNM_SHAJAF_ZONE   = 50;    -- Aht Urhgan Whitegate
local ISNM_MENU_CAN_BUY  = 160;
local ISNM_MENU_HOLDING  = 161;
local ISNM_MENU_NO_BADGE = 162;
local ISNM_MENU_LOCKED   = 163;
local MENU_OFFSET_ZONE   = 0x2A;  -- u16 zone id inside the 0x034 packet

-- Shajaf's lock expires at Japanese midnight: JST is UTC+9 with no daylight
-- saving, so the reset is a fixed 15:00 UTC every day.
local function next_jst_midnight(now)
    local into_day = (now + 9 * 3600) % 86400;
    return now + (86400 - into_day);
end

local function isnm_data_for(cd)
    if cd == nil then return nil; end
    if type(cd.isnm_data) ~= 'table' then cd.isnm_data = {}; end
    return cd.isnm_data;
end

-- ===== Ashu Talif weekly chain =====
-- Three quests from Halshaob in Nashmau, fought aboard The Ashu Talif
-- (zone 60): 101 Scouting, 102 Royal Painter Escort, 103 Targeting the
-- Captain. Everything here reads the client quest log (packet 0x056):
-- chunk 0x0080 carries the ToAU ACTIVE bits, chunk 0x00C0 the COMPLETED
-- bits, and the bit index IS the quest id - verified live 2026-08-24/25,
-- three wins captured to the second. Server rules, all observed:
--   pay -> active bit on. Board -> Cutter menu, zone 60.
--   Win -> completed bit on (while still aboard). Fail -> week is burned.
--   The Ephramadian gold coin (KI 786) is a ONE-TIME first-clear grant:
--   repeat weeks hand out no key item at all, so nothing here may ever
--   depend on it.
--   Weekly tally clears COMPLETED bits but a paid, unfought stage stays
--   active across the reset (a party member banked one and used it).
-- One table, not seven locals: render_ui lives at the 60-upvalue limit.
local ASHU = {
    SHIP_ZONE = 60,
    FIRST = 101,
    LAST  = 103,
    NAMES = { [101] = 'Scouting', [102] = 'Painter', [103] = 'Captain' },
    ROW_LABEL = 'Ashu Talif',
};

function ASHU.data_for(cd)
    if cd == nil then return nil; end
    if type(cd.ashu_data) ~= 'table' then cd.ashu_data = {}; end
    local a = cd.ashu_data;
    if type(a.active) ~= 'table' then a.active = {}; end
    if type(a.completed) ~= 'table' then a.completed = {}; end
    return a;
end

-- ===== The chain as a state machine =====
-- Built from a full REPEAT-week capture (2026-08-31): on repeat weeks the
-- quest book never moves, so every signal here is a menu number or a system
-- line, all observed three times each:
--   pay   : Halshaob menu 302 (zone 53) carrying the quest id in its params
--   board : zone 60 (after the Cutter's menu 222 in Arrapago)
--   win   : "Objective complete. You may return on the lifeboat."
--   loss  : "The mission has failed." - or leaving the ship with no win
-- The quest-book bits are kept only as a first-ever-week bonus that funnels
-- into the same functions.
--
-- ashu_data: stage (1..3, chain position), paid, aboard, done, failed,
-- anchored (a weekly reset was witnessed), known (quest book seen once).
ASHU.NAMES_BY_STAGE = { [1] = 'Scouting', [2] = 'Painter', [3] = 'Captain' };

local function ashu_synced(a)
    return a.anchored == true or a.paid == true or a.aboard == true
        or a.done == true or a.failed == true or (a.stage or 1) > 1;
end

function ASHU.mark_paid(cd, quest_id)
    local a = ASHU.data_for(cd);
    if a == nil then return; end
    local st = quest_id - ASHU.FIRST + 1;
    if st < 1 or st > 3 then return; end
    a.stage = st;
    a.paid = true;
    a.aboard = nil;
    a.failed = nil;
    a.done = nil;
    save_settings();
    print_success(string.format('Ashu Talif: paid for %s - board the ship at the Cutter!',
        ASHU.NAMES_BY_STAGE[st]));
end

function ASHU.mark_aboard(cd)
    local a = ASHU.data_for(cd);
    if a == nil or a.aboard == true then return; end
    -- Only a PAID chain stage is ours to judge: the same ship hosts the Black
    -- Coffin story mission and the COR job fight, and a stage number alone
    -- (e.g. 1 after a reset) must not turn those into a "failed" chain.
    if a.paid ~= true then return; end
    a.aboard = true;
    save_settings();
end

function ASHU.mark_won(cd)
    local a = ASHU.data_for(cd);
    if a == nil or a.aboard ~= true then return; end
    local st = a.stage or 1;
    a.aboard = nil;
    a.paid = nil;
    if st >= 3 then
        a.done = true;
        print_success('Ashu Talif: Captain down - chain complete for the week!');
    else
        a.stage = st + 1;
        print_success(string.format('Ashu Talif: %s cleared! Pay Halshaob for %s.',
            ASHU.NAMES_BY_STAGE[st], ASHU.NAMES_BY_STAGE[st + 1]));
    end
    save_settings();
end

function ASHU.mark_failed(cd)
    local a = ASHU.data_for(cd);
    if a == nil or a.aboard ~= true then return; end
    a.aboard = nil;
    a.paid = nil;
    a.failed = true;
    save_settings();
    print_error('Ashu Talif: the run was lost. The chain waits for the weekly reset.');
end

-- Display state. Returns nil when never synced (fresh install, nothing
-- observed), else the data table.
function ASHU.state(cd)
    local a = cd and cd.ashu_data or nil;
    if a == nil then return nil; end
    if not ashu_synced(a) then return nil, a; end
    return a;
end

-- Icon / color-key / status for both the window and the chat line, so the
-- two can never drift. Icon is the stage number in a box: a chain is a
-- position, not a stock, so it must not look like Dynamis' 2/3.
-- color_key: 'green' | 'grey' | 'yellow'.
function ASHU.describe(cd)
    local a, raw = ASHU.state(cd);
    if a == nil then
        return '[?]', 'yellow', (raw ~= nil) and 'pay to sync' or 'zone once to sync';
    end
    if a.failed then return '[x]', 'grey', 'failed - wait for reset'; end
    if a.done   then return '[x]', 'grey', 'done!'; end
    local st = a.stage or 1;
    local name = ASHU.NAMES_BY_STAGE[st] or '?';
    local status;
    if a.aboard then status = name .. ' - aboard';
    elseif a.paid then status = name .. ' - fight!';
    else status = 'pay for ' .. name; end
    return string.format('[%d]', st), 'green', status;
end

-- An unknown buy lock resolves itself at the reset IF the addon provably
-- watched the reset pass: a purchase cannot happen without the key item event
-- firing, so continuous observation from before JST midnight to after it is
-- proof the character is unlocked. A character who logs in after the reset
-- stays unknown - they may have bought earlier today with the addon off.
local function resolve_isnm_unknown(cd, char_name)
    if cd == nil or char_name ~= tracker.current_char then return; end
    local isnm = cd.isnm_data;
    if isnm == nil then return; end
    local now = os.time();
    if isnm.next_buy_time == nil then
        local last_midnight = next_jst_midnight(now) - 86400;
        -- A character who was last seen BEFORE the most recent reset is open:
        -- offline characters cannot buy, so any lock they had has expired.
        -- Only the install day itself stays unknown (no last_observed yet) -
        -- they may have bought earlier that day before the addon existed.
        if isnm.last_observed ~= nil and isnm.last_observed < last_midnight then
            isnm.next_buy_time = last_midnight;
            save_settings();
        -- Or we watched the reset pass live this session: provably open.
        elseif tracker.isnm_observed_since ~= nil
            and tracker.isnm_observed_since <= last_midnight then
            isnm.next_buy_time = last_midnight;
            save_settings();
        end
    end
    -- Updated in memory every call; it rides along with the next normal save.
    isnm.last_observed = now;
end

-- Which order this character holds, if any. The live key item table is the
-- truth for the logged-in character; alts fall back to their persisted cache.
local function isnm_held_ki(char_name)
    if char_name == tracker.current_char and tracker.kis_initialized then
        if tracker.kis[ISNM_SECRET_KI] then return ISNM_SECRET_KI; end
        if tracker.kis[ISNM_CONFIDENTIAL_KI] then return ISNM_CONFIDENTIAL_KI; end
        return nil;
    end
    local cd = char_name and tracker.settings.characters[char_name] or nil;
    if cd == nil or type(cd.ki_cache) ~= 'table' then return nil; end
    for _, id in ipairs(cd.ki_cache) do
        if id == ISNM_SECRET_KI then return ISNM_SECRET_KI; end
        if id == ISNM_CONFIDENTIAL_KI then return ISNM_CONFIDENTIAL_KI; end
    end
    return nil;
end

-- Picking a mission makes key item 787 flicker off/on/off inside a single
-- second, so a withdrawal is only believed if the previous one was longer ago
-- than this. A real trip to Rytaal takes minutes, so a few seconds is plenty.
local ASSAULT_TAG_DEBOUNCE = 5;

-- Cancelling an assault turns your orders back into a tag in your own inventory.
-- Rytaal's stock never moves, so that arrival must not decrement it.
--
-- Orders (762-766) and the tag (787) both live in key item table 1, so a cancel
-- decodes BOTH from a single 0x055 packet. A turn-in followed by taking a tag is
-- always two separate packets, seconds apart. Packet identity therefore separates
-- them exactly.
--
-- This used to be a five second timer, which threw away a genuine withdrawal from
-- anyone who took their reward and grabbed a tag quickly. Measured gaps for a
-- deliberate player were 9-10 seconds; a fast one lands inside 5 and lost the
-- count until their next Rytaal visit.
local ASSAULT_KI_PACKET_SEQ = 0;

-- Assault Orders key items, one per area. Whichever of these the player is
-- holding tells us which assault they are currently on. All five confirmed
-- against a live capture.
-- Longest of these is 16 characters, which clears the indented row's ~19
-- character budget at the widened status column.
local ASSAULT_ORDERS = {
    [762] = 'Leujaoam Sanctum',
    [763] = 'Mamool Ja T.G.',
    [764] = 'Lebros Cavern',
    [765] = 'Periqia',
    [766] = 'Ilrusi Atoll',
};

local ASSAULT_AREA_FULL = {
    ['Mamool Ja T.G.'] = 'Mamool Ja Training Grounds',
};

-- The five mission-giver menus. Each fills its 0x034 with
--   startEvent(offset, rank, hasIDtag, assaultPoints, currentAssault, cipher)
-- so rank sits at 0x08 and that area's points at 0x10.
local MISSION_GIVER_MENUS = {
    [273] = 'Leujaoam Sanctum',
    [274] = 'Mamool Ja T.G.',
    [275] = 'Lebros Cavern',
    [276] = 'Periqia',
    [277] = 'Ilrusi Atoll',
};
local MENU_PARAM_RANK   = 0x08;   -- u32, 1..11
local MENU_PARAM_POINTS = 0x10;   -- u32, assault points for that area

-- Mercenary ranks, from LandSandBoat's xi.assault.mercenaryRank.
local MERCENARY_RANKS = {
    [1]  = 'Private Second Class',
    [2]  = 'Private First Class',
    [3]  = 'Superior Private',
    [4]  = 'Lance Corporal',
    [5]  = 'Corporal',
    [6]  = 'Sergeant',
    [7]  = 'Sergeant Major',
    [8]  = 'Chief Sergeant',
    [9]  = 'Second Lieutenant',
    [10] = 'First Lieutenant',
    [11] = 'Captain',
};

-- Short forms so the row stays inside the status column.
local MERCENARY_RANKS_SHORT = {
    [1] = 'PSC', [2] = 'PFC', [3] = 'SP',  [4] = 'LC',  [5] = 'Cpl',
    [6] = 'Sgt', [7] = 'SgtM', [8] = 'CSgt', [9] = '2Lt', [10] = '1Lt', [11] = 'Capt',
};

-- Row labels, also the keys used by the show/hide checkboxes.
local ASSAULT_ROW_LABEL = 'Assault Tags';   -- settings key and checkbox text
local ISNM_ROW_LABEL    = 'ISNM';           -- settings key and checkbox text
local ASSAULT_ROW_SHORT = 'Assault';        -- what the row itself shows
local DYNAMIS_ROW_LABEL = 'Dynamis';
local LIMBUS_ROW_LABEL  = 'Limbus';
local LIMBUS_KI_ID      = 734;   -- Cosmo-Cleanse
local LIMBUS_NPC        = 'Mister Glean';

-- Limbus lost its 71h cooldown and became a weekly allowance: 4 Cosmo-Cleanses
-- per account per week, no more than 2 to any one character.
local LIMBUS_ACCOUNT_LIMIT   = 4;
local LIMBUS_CHARACTER_LIMIT = 2;

-- Runs are counted when Mister Glean hands the Cosmo-Cleanse over, not when you
-- enter. A cleanse held across the weekly reset was counted in the week it was
-- issued, so spending it later costs nothing - which is the behaviour we want.
-- Taking a key item makes the 0x055 table flicker, so repeats inside this window
-- are ignored.
local LIMBUS_DEBOUNCE = 5;

-- Bags worth scanning for an hourglass.
local GLASS_BAGS = { 0, 1, 2, 4, 5, 6, 7, 8, 9, 10, 11, 12 };

-- Extra layout, 1-based for Lua's struct.unpack:
--   13 = unix time the timeless glass was traded
--   17 = destination Dynamis zone id
-- Confirmed identical whether the bytes come from the inventory or straight out
-- of an incoming 0x020 item packet.
local function glass_serial_from_extra(extra)
    if extra == nil or #extra < GLASS_EXTRA_ZONE_OFFSET + 3 then return nil; end
    local ok, serial, zone = pcall(function()
        local t = struct.unpack('L', extra, GLASS_EXTRA_TIME_OFFSET);
        local z = struct.unpack('L', extra, GLASS_EXTRA_ZONE_OFFSET);
        if t == nil or z == nil or t == 0 then return nil, nil; end
        if DYNAMIS_ZONES[z] == nil then return nil, nil; end
        return string.format('%d-%d', z, t), z;
    end);
    if not ok then return nil; end
    return serial, zone;
end

-- Reads the serial from one inventory item. Returns serial, zone_id or nil.
local function glass_serial_from_item(item)
    if item == nil then return nil; end
    local ok, extra = pcall(function()
        if item.Id ~= PERPETUAL_HOURGLASS_ID then return nil; end
        return item.Extra;
    end);
    if not ok or extra == nil then return nil; end
    return glass_serial_from_extra(extra);
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

-- Key item event suppression is lifted by the 7th 0x055 block of a zone-in. If a
-- zone ever sends fewer, this stops the addon going deaf for the whole session.
local KI_SUPPRESS_TIMEOUT = 15;

-- How long before the weekly reset a Dynamis claim still counts against the
-- upcoming week's allowance.
-- Only a run genuinely straddling the reset can spill into the new week. This
-- was 24h, which docked the new week an entry for any glass broken across the
-- whole of Sunday - an arbitrary overreach, not a server rule. The glass
-- lifetime (210 minutes with every extension) plus slack.
local DYNAMIS_CLAIM_CARRY_WINDOW = 4 * 3600;

-- A charged hourglass starts with one hour, but kills inside the zone extend
-- the run to a maximum of 210 minutes. The old value of one hour treated the
-- back half of any extended run as a brand new one, so a job change or DC late
-- in a run counted a second entry. A glass older than 210 minutes cannot
-- belong to a live run no matter how many extensions it earned.
local DYNAMIS_GLASS_LIFETIME = 210 * 60;

-- The bag API is unreliable on this client (the same failure as HasKeyItem),
-- so the 0x020 packet is the record of what we hold: every charged glass that
-- lands in the bag - broken or traded - is remembered here, one per zone,
-- newest wins. Stored on the character, not the account: the glass is a
-- physical item in one character's bag.
-- Defined after DYNAMIS_GLASS_LIFETIME on purpose - these close over the
-- local, and this file has shipped a use-before-declaration twice already.
local function remember_held_glass(cd, serial, zone_id)
    if cd == nil or serial == nil or zone_id == nil then return; end
    if cd.dynamis_data == nil then return; end
    if type(cd.dynamis_data.held_glasses) ~= 'table' then
        cd.dynamis_data.held_glasses = {};
    end
    -- The serial embeds the time the run was registered. Use that for the
    -- lifetime test, not the packet arrival time: a traded copy can land in
    -- the bag well into the run.
    local born = tonumber(tostring(serial):match('%-(%d+)$')) or os.time();
    -- Newest-born wins regardless of arrival order, so someone handing over a
    -- dead spare later cannot shadow the live glass.
    local prev = cd.dynamis_data.held_glasses[tostring(zone_id)];
    if prev ~= nil and (prev.born or 0) > born then return; end
    cd.dynamis_data.held_glasses[tostring(zone_id)] = { serial = serial, born = born };
end

-- The glass we hold for this zone, if it can still belong to a live run.
-- Returns nil for a zone we hold nothing for, or only a dead glass for.
local function held_glass_serial(cd, zone_id)
    if cd == nil or cd.dynamis_data == nil or zone_id == nil then return nil; end
    local hg = cd.dynamis_data.held_glasses;
    local rec = hg ~= nil and hg[tostring(zone_id)] or nil;
    if rec == nil or type(rec.serial) ~= 'string' then return nil; end
    if (os.time() - (rec.born or 0)) > DYNAMIS_GLASS_LIFETIME then return nil; end
    return rec.serial;
end

-- How long after the "time and destination recorded" message the glass may take
-- to reach the bag and still be treated as your own break. Live captures show a
-- gap of anywhere from a millisecond to about a second; five is generous without
-- being long enough to swallow a trade.
local DYNAMIS_BREAK_WINDOW = 5;

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
    -- Same writer as homework.json. This was the third copy of "write a file"
    -- in the addon and the only one never hardened, so a failed write silently
    -- destroyed every show/hide preference and the font scale.
    local body = serialize_value({ font_scale = ui.font_scale, tracked = display_settings.tracked });
    local ok, why = write_file_atomic(path, body, function(bytes)
        local parsed = parse_json_value(bytes, 1);
        if type(parsed) ~= 'table' then return false, 'did not parse back'; end
        return true;
    end);
    if not ok and not display_save_warned then
        display_save_warned = true;
        print_error('Could not save display.json (' .. tostring(why) .. ').');
    elseif ok then
        display_save_warned = false;
    end
end

local function load_display_settings()
    -- Shares read_json_file with homework.json, which pcalls the parse and
    -- rejects non-tables. Previously this called the parser bare.
    local result = read_json_file(get_display_settings_path());
    if result == nil then return; end

    -- A hand-edited or corrupt value here multiplies every column position and
    -- would throw on the very first frame.
    local fs = tonumber(result.font_scale);
    -- NaN fails BOTH comparisons below, so it sailed through the clamp and made
    -- every column position NaN.
    if fs ~= nil and fs == fs and fs ~= math.huge and fs ~= -math.huge then
        if fs < 0.8 then fs = 0.8; elseif fs > 2.0 then fs = 2.0; end
        ui.font_scale = fs;
    end

    -- Validate all the way down. `tracked` arriving as a string or number used
    -- to make get_char_tracking index a non-table, killing render_ui on every
    -- frame with no way back short of hand-editing the file.
    if type(result.tracked) ~= 'table' then return; end
    local clean = {};
    for char_name, entry in pairs(result.tracked) do
        if type(char_name) == 'string' and type(entry) == 'table' then
            -- Coerce the leaves too: a string here reaches imgui as a string,
            -- because `tracking.tasks[task] or false` passes it straight through.
            local tasks, timers = {}, {};
            for k, v in pairs(type(entry.tasks) == 'table' and entry.tasks or {}) do
                if type(k) == 'string' then tasks[k] = (v == true); end
            end
            for k, v in pairs(type(entry.timers) == 'table' and entry.timers or {}) do
                if type(k) == 'string' then timers[k] = (v == true); end
            end
            clean[char_name] = { tasks = tasks, timers = timers };
        end
    end
    display_settings.tracked = clean;
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

        -- Dynamis and Assault are not entries in tracker.settings.tasks /
        -- ENM_KEY_ITEMS, but they get show/hide toggles of their own.
        display_settings.tracked[char_name].tasks[DYNAMIS_ROW_LABEL] = true;
        display_settings.tracked[char_name].tasks[ASHU.ROW_LABEL] = true;
        display_settings.tracked[char_name].timers[ASSAULT_ROW_LABEL] = true;
        display_settings.tracked[char_name].timers[ISNM_ROW_LABEL] = true;
        display_settings.tracked[char_name].tasks[LIMBUS_ROW_LABEL] = true;
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

        if tracking.tasks[DYNAMIS_ROW_LABEL] == nil then tracking.tasks[DYNAMIS_ROW_LABEL] = true; end

        -- Limbus moved from `timers` to `tasks` when its cooldown was dropped.
        if tracking.tasks[LIMBUS_ROW_LABEL] == nil then
            if tracking.timers[LIMBUS_ROW_LABEL] ~= nil then
                tracking.tasks[LIMBUS_ROW_LABEL] = tracking.timers[LIMBUS_ROW_LABEL];
            else
                tracking.tasks[LIMBUS_ROW_LABEL] = true;
            end
        end
        tracking.timers[LIMBUS_ROW_LABEL] = nil;

        -- Assault went the other way: it refills on a rolling clock, so it belongs
        -- with the timers. 3.6.1 briefly filed it under tasks.
        if tracking.timers[ASSAULT_ROW_LABEL] == nil then
            if tracking.tasks[ASSAULT_ROW_LABEL] ~= nil then
                tracking.timers[ASSAULT_ROW_LABEL] = tracking.tasks[ASSAULT_ROW_LABEL];
            else
                tracking.timers[ASSAULT_ROW_LABEL] = true;
            end
        end
        tracking.tasks[ASSAULT_ROW_LABEL] = nil;

        if tracking.timers[ISNM_ROW_LABEL] == nil then
            tracking.timers[ISNM_ROW_LABEL] = true;
        end
        if tracking.tasks[ASHU.ROW_LABEL] == nil then
            tracking.tasks[ASHU.ROW_LABEL] = true;
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

-- Horizon's Dynamis rules: an account gets 3 entries a week, but no single
-- character may use more than 2 of them.
local ACCOUNT_ENTRY_LIMIT   = 3;
local CHARACTER_ENTRY_LIMIT = 2;

-- Fresh Dynamis bookkeeping.
-- Every sub-table in a character record was only ever nil-checked, never
-- type-checked, so a hand-edited "enm_timers": "x" survived every ensure-block
-- and then threw on the first assignment into it. display.json got this
-- treatment in 3.13; homework.json is the bigger file with more to lose.
--
-- One pass, at load, so nothing downstream has to defend itself.
function sanitize_loaded_settings(st)
    if type(st) ~= 'table' then return nil; end

    local function tbl(v)  return type(v) == 'table' and v or {}; end
    local function num(v, default, lo, hi)
        local n = tonumber(v);
        if n == nil or n ~= n then return default; end        -- nil or NaN
        if n == math.huge or n == -math.huge then return default; end
        if lo ~= nil and n < lo then return lo; end
        if hi ~= nil and n > hi then return hi; end
        return n;
    end
    -- Strings only. Allowing numbers through let a numeric task name reach
    -- normalize_task, which indexes it.
    local function strlist(v)
        local out = {};
        for _, item in ipairs(tbl(v)) do
            if type(item) == 'string' then table.insert(out, item); end
        end
        return out;
    end

    -- ki_cache is the one list whose payload is legitimately numeric, so it
    -- needs its own helper. Making strlist strict without checking every
    -- consumer emptied the cache on load: an empty cache still passes
    -- restore_ki_cache's type check, so the addon reported "restored from your
    -- last session" over an all-false picture, mirrored that back to disk, and
    -- left /hw scan free to write "no KI" across every record.
    local function numlist(v)
        local out = {};
        for _, item in ipairs(tbl(v)) do
            local n = tonumber(item);
            if n ~= nil and n == n then table.insert(out, n); end
        end
        return out;
    end

    st.characters = tbl(st.characters);
    st.dynamis_accounts = tbl(st.dynamis_accounts);
    st.dynamis_account_wide = st.dynamis_account_wide == true;
    st.chars_per_account = num(st.chars_per_account, DEFAULT_CHARS_PER_ACCOUNT, 1, 16);
    st.tasks = strlist(st.tasks);

    for name, cd in pairs(st.characters) do
        if type(name) ~= 'string' or type(cd) ~= 'table' then
            st.characters[name] = nil;
        else
            cd.last_reset    = num(cd.last_reset, 0, 0);
            cd.enm_timers    = tbl(cd.enm_timers);
            cd.quest_steps   = tbl(cd.quest_steps);
            for k, v in pairs(cd.quest_steps) do
                if type(k) ~= 'string' or type(v) ~= 'string' then cd.quest_steps[k] = nil; end
            end
            cd.xsknife_data  = tbl(cd.xsknife_data);
            cd.ecowarrior_data = tbl(cd.ecowarrior_data);
            cd.ecowarrior_data.locked_nations = strlist(cd.ecowarrior_data.locked_nations);
            cd.ki_cache      = numlist(cd.ki_cache);

            cd.dynamis_data = tbl(cd.dynamis_data);
            cd.dynamis_data.entries_remaining =
                num(cd.dynamis_data.entries_remaining, CHARACTER_ENTRY_LIMIT, 0, CHARACTER_ENTRY_LIMIT);
            cd.dynamis_data.counted_glasses = strlist(cd.dynamis_data.counted_glasses);
            -- Saves from before the flag existed were tracking all along:
            -- missing = known. Only a freshly created record starts unknown.
            if cd.dynamis_data.known == nil then cd.dynamis_data.known = true; end
            -- These reach arithmetic and comparisons directly. A string
            -- claimed_at throws inside reset_dynamis_store, which aborts
            -- reset_tracker partway and leaves some characters reset and some
            -- not - the exact partial state the stale-reset guard exists for.
            if cd.dynamis_data.claimed_at ~= nil then
                cd.dynamis_data.claimed_at = num(cd.dynamis_data.claimed_at, nil, 0);
            end
            if cd.dynamis_data.last_break_time ~= nil then
                cd.dynamis_data.last_break_time = num(cd.dynamis_data.last_break_time, nil, 0);
            end
            if cd.dynamis_data.last_break_zone ~= nil then
                cd.dynamis_data.last_break_zone = num(cd.dynamis_data.last_break_zone, nil, 0);
            end
            if type(cd.dynamis_data.last_break_serial) ~= 'string' then
                cd.dynamis_data.last_break_serial = nil;
            end
            -- Glasses remembered from 0x020 packets, keyed by zone id as a
            -- string. Drop anything malformed, and anything too old to belong
            -- to a live run - 12 hours is generous without growing the file.
            local hg = cd.dynamis_data.held_glasses;
            local cleaned = {};
            if type(hg) == 'table' then
                for k, v in pairs(hg) do
                    if type(k) == 'string' and type(v) == 'table'
                       and type(v.serial) == 'string' then
                        local born = num(v.born, 0, 0);
                        if born > 0 and (os.time() - born) <= 12 * 3600 then
                            cleaned[k] = { serial = v.serial, born = born };
                        end
                    end
                end
            end
            cd.dynamis_data.held_glasses = cleaned;

            cd.isnm_data = tbl(cd.isnm_data);
            if cd.isnm_data.next_buy_time ~= nil then
                cd.isnm_data.next_buy_time = num(cd.isnm_data.next_buy_time, nil, 0);
            end
            if cd.isnm_data.no_badge ~= true then cd.isnm_data.no_badge = nil; end
            if cd.isnm_data.last_observed ~= nil then
                cd.isnm_data.last_observed = num(cd.isnm_data.last_observed, nil, 0);
            end
            -- Ashu Talif chain: booleans keyed by quest id as a string.
            cd.ashu_data = tbl(cd.ashu_data);
            local ash = cd.ashu_data;
            ash.known = ash.known == true;
            ash.failed = ash.failed == true or nil;
            ash.aboard = ash.aboard == true or nil;
            ash.paid = ash.paid == true or nil;
            ash.done = ash.done == true or nil;
            if ash.stage ~= nil then ash.stage = num(ash.stage, nil, 1, 3); end
            ash.aboard_stage = nil; ash.wins = nil; ash.hist = nil;   -- retired
            local function boolmap(t)
                local out = {};
                if type(t) == 'table' then
                    for q = ASHU.FIRST, ASHU.LAST do
                        if t[tostring(q)] == true then out[tostring(q)] = true; end
                    end
                end
                return out;
            end
            ash.active = boolmap(ash.active);
            ash.completed = boolmap(ash.completed);
            ash.anchored = ash.anchored == true or nil;
            ash.hist = nil;   -- retired field; also cleans polluted saves
            if ash.wins ~= nil then ash.wins = num(ash.wins, nil, 0, 3); end

            cd.limbus_data = tbl(cd.limbus_data);
            cd.limbus_data.runs_remaining =
                num(cd.limbus_data.runs_remaining, LIMBUS_CHARACTER_LIMIT, 0, LIMBUS_CHARACTER_LIMIT);
            cd.limbus_data.seen = num(cd.limbus_data.seen, 0, 0);
            cd.limbus_data.known = cd.limbus_data.known == true;
            cd.limbus_data.last_gain = num(cd.limbus_data.last_gain, 0, 0);

            cd.assault_data = tbl(cd.assault_data);
            cd.assault_data.points = tbl(cd.assault_data.points);
            if cd.assault_data.tags_stored ~= nil then
                cd.assault_data.tags_stored = num(cd.assault_data.tags_stored, nil, 0, 4);
            end
            if cd.assault_data.rank ~= nil then
                cd.assault_data.rank = num(cd.assault_data.rank, nil, 1, 11);
            end
            -- next_tag_time is compared with > in assault_state, so a string
            -- here throws inside render_ui on every frame.
            cd.assault_data.next_tag_time  = num(cd.assault_data.next_tag_time, 0, 0);
            cd.assault_data.checked_at     = num(cd.assault_data.checked_at, 0, 0);
            cd.assault_data.last_withdraw  = num(cd.assault_data.last_withdraw, 0, 0);
            -- Packet sequence is session-only; a value carried in from disk is
            -- meaningless and could suppress a real withdrawal after a reload.
            cd.assault_data.orders_lost_seq = nil;
            cd.assault_data.orders_lost_at = nil;
            cd.assault_data.rank_seen_at   = num(cd.assault_data.rank_seen_at, 0, 0);
            cd.assault_data.max_stock      = num(cd.assault_data.max_stock, ASSAULT_DEFAULT_MAX_STOCK, 1, 4);
            for k, v in pairs(cd.assault_data.points) do
                if type(k) ~= 'string' then cd.assault_data.points[k] = nil;
                else cd.assault_data.points[k] = num(v, 0, 0); end
            end

            -- enm_timers entries must be tables with sane fields
            for tname, td in pairs(cd.enm_timers) do
                if type(td) ~= 'table' then
                    cd.enm_timers[tname] = nil;
                else
                    td.has_ki = td.has_ki == true;
                    td.next_ki_time = num(td.next_ki_time, 0, 0);
                    -- Compared against 'scan' downstream; a non-string silently
                    -- misclassifies the timer rather than crashing, which is
                    -- exactly the sort of accidental defence the sanitizer is
                    -- meant to make unnecessary.
                    if type(td.timer_source) ~= 'string' then td.timer_source = 'scan'; end
                end
            end
        end
    end

    for i = #st.dynamis_accounts, 1, -1 do
        local acct = st.dynamis_accounts[i];
        if type(acct) ~= 'table' then
            table.remove(st.dynamis_accounts, i);
        else
            acct.chars = strlist(acct.chars);
            acct.counted_glasses = strlist(acct.counted_glasses);
            acct.entries_remaining = num(acct.entries_remaining, ACCOUNT_ENTRY_LIMIT, 0, ACCOUNT_ENTRY_LIMIT);
            acct.limbus_remaining = num(acct.limbus_remaining, LIMBUS_ACCOUNT_LIMIT, 0, LIMBUS_ACCOUNT_LIMIT);
            -- limbus_seen sat directly beside limbus_remaining and was missed.
            acct.limbus_seen = num(acct.limbus_seen, 0, 0);
            -- Shared assault stock. No weekly component, so it is never reset;
            -- only Rytaal's menu is authoritative for it.
            if acct.assault_pool ~= nil then
                local ap = tbl(acct.assault_pool);
                if ap.tags_stored ~= nil then ap.tags_stored = num(ap.tags_stored, nil, 0, 4); end
                ap.next_tag_time = num(ap.next_tag_time, 0, 0);
                ap.checked_at    = num(ap.checked_at, 0, 0);
                ap.last_withdraw = num(ap.last_withdraw, 0, 0);
                ap.max_stock     = num(ap.max_stock, ASSAULT_DEFAULT_MAX_STOCK, 1, 4);
                acct.assault_pool = ap;
            end
            acct.limbus_known = acct.limbus_known == true;
            acct.is_account = true;
            acct.manual_override = acct.manual_override == true;
            -- remove_dynamis_account calls :match on this.
            if type(acct.name) ~= 'string' then acct.name = 'Account ' .. tostring(i); end
            if acct.claimed_at ~= nil then acct.claimed_at = num(acct.claimed_at, nil, 0); end
            if acct.last_break_time ~= nil then acct.last_break_time = num(acct.last_break_time, nil, 0); end
            if acct.last_break_zone ~= nil then acct.last_break_zone = num(acct.last_break_zone, nil, 0); end
            if type(acct.last_break_serial) ~= 'string' then acct.last_break_serial = nil; end
        end
    end

    return st;
end

-- runs_remaining starts at the cap, but `known` stays false until a weekly reset
-- has passed with the addon running. Until then the addon cannot know what was
-- taken before it was installed, so the row shows the yellow "unknown" marker
-- instead of a confident number it cannot back up.
local function new_limbus_data()
    return { runs_remaining = LIMBUS_CHARACTER_LIMIT, seen = 0, known = false, last_gain = 0 };
end

-- Account-side Limbus pool. Stored on the same account record as Dynamis, since
-- the character grouping is shared, but counted independently.
local function ensure_limbus_account(acct)
    if acct.limbus_remaining == nil then acct.limbus_remaining = LIMBUS_ACCOUNT_LIMIT; end
    if acct.limbus_seen == nil then acct.limbus_seen = 0; end
    if acct.limbus_known == nil then acct.limbus_known = false; end
    return acct;
end

-- known=false until a weekly reset is witnessed or an entry is counted. A
-- fresh install used to assume 2/2, which lied to anyone installing mid-week
-- after a run. There is no NPC to sync Dynamis from, so [?] is the truth.
local function new_dynamis_data()
    return { entries_remaining = CHARACTER_ENTRY_LIMIT, counted_glasses = {}, known = false };
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
            acct.is_account = true;
            if acct.entries_remaining == nil then acct.entries_remaining = ACCOUNT_ENTRY_LIMIT; end
            if acct.known == nil then acct.known = true; end   -- pre-flag saves were tracking
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

-- Mirrors get_dynamis_store: the table holding this character's Limbus counters,
-- plus true when it is an account-wide pool.
-- Rytaal's stock and its restock clock belong to the ACCOUNT, not the
-- character: a tag drawn on any member drops the count everyone sees. The tag
-- in hand, the current mission and the mercenary rank stay personal, so those
-- keep living on the character record.
-- Defined further down; get_assault_store and unassign_char both reach it from
-- above. Without this it compiled to a nil global read.
local new_assault_data;
-- unassign_char reaches this from above its definition.
local inherit_assault_from_pool;

local function ensure_assault_account(acct)
    if acct.assault_pool == nil then
        acct.assault_pool = {
            tags_stored = nil,          -- nil until a Rytaal menu is seen
            next_tag_time = 0,
            checked_at = 0,
            last_withdraw = 0,
            max_stock = ASSAULT_DEFAULT_MAX_STOCK,
        };
    end
    return acct.assault_pool;
end

-- Returns the table holding the shared stock, plus true when it is an account
-- pool. Unlike Dynamis and Limbus this has no weekly component - the restock
-- clock is a rolling 24h and must survive the weekly reset untouched.
local function get_assault_store(char_name)
    if tracker.settings.dynamis_account_wide then
        local acct = find_dynamis_account(char_name);
        if acct ~= nil then return ensure_assault_account(acct), true; end
    end
    local cd = char_name and tracker.settings.characters[char_name] or nil;
    if cd == nil then return nil, false; end
    if cd.assault_data == nil then cd.assault_data = new_assault_data(); end
    return cd.assault_data, false;
end

local function get_limbus_store(char_name)
    if tracker.settings.dynamis_account_wide then
        local acct = find_dynamis_account(char_name);
        if acct ~= nil then return ensure_limbus_account(acct), true; end
    end
    local cd = char_name and tracker.settings.characters[char_name] or nil;
    if cd == nil then return nil, false; end
    if cd.limbus_data == nil then cd.limbus_data = new_limbus_data(); end
    return cd.limbus_data, false;
end

-- Returns effective_remaining, char_remaining, acct_remaining, known, shared.
local function limbus_state(char_name)
    local cd = char_name and tracker.settings.characters[char_name] or nil;
    if cd == nil then return nil; end
    if cd.limbus_data == nil then cd.limbus_data = new_limbus_data(); end
    local own = cd.limbus_data;
    local store, shared = get_limbus_store(char_name);

    local char_left = own.runs_remaining or LIMBUS_CHARACTER_LIMIT;
    local acct_left = shared and (store.limbus_remaining or LIMBUS_ACCOUNT_LIMIT) or nil;
    local known = (own.known == true) and (not shared or store.limbus_known == true);

    -- Watched handouts are proof whatever happened before the addon existed: if
    -- it saw two, this character is out regardless of the unknown starting point.
    if (own.seen or 0) >= LIMBUS_CHARACTER_LIMIT then char_left = 0; known = true; end
    if shared and (store.limbus_seen or 0) >= LIMBUS_ACCOUNT_LIMIT then acct_left = 0; known = true; end

    local eff = char_left;
    if acct_left ~= nil and acct_left < eff then eff = acct_left; end
    return eff, char_left, acct_left, known, shared;
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
        is_account = true,
        known = false,   -- unknown until a member knows, a reset, or a counted entry
        entries_remaining = ACCOUNT_ENTRY_LIMIT,
        counted_glasses = {}
    });
    return #accts;
end

-- Drops a character from every account. A character belongs to at most one, so
-- ticking a name somewhere else silently moves it rather than warning.
local recalc_account_from_members;

-- skip_inherit is set when the character is moving to ANOTHER account rather
-- than leaving grouping entirely. Inheriting on a move re-armed the personal
-- reading with account 1's figure, which the destination account then seeded
-- from - so moving a character out of a depleted account dragged a full account
-- down to it. A character joining another account needs no personal count at
-- all; they read the destination pool.
local function unassign_char(char_name, skip_inherit)
    for _, acct in ipairs(dynamis_accounts()) do
        if type(acct.chars) == 'table' then
            local removed = false;
            for i = #acct.chars, 1, -1 do
                if acct.chars[i] == char_name then table.remove(acct.chars, i); removed = true; end
            end
            if removed then
                -- Leave with whatever the pool last said, rather than a stale
                -- personal number from before the character was grouped.
                if not skip_inherit then
                    inherit_assault_from_pool(acct, char_name);
                end
                recalc_account_from_members(acct, true);
            end
        end
    end
end

-- Copies the pool's figures onto a character leaving an account. Grouped members'
-- personal counts are guaranteed stale (all writes went to the pool), so every
-- exit path has to do this - not just the per-character untick.
--
-- NOT called when a character is moving to another account: see unassign_char's
-- skip_inherit.
function inherit_assault_from_pool(acct, char_name)
    local pool = acct and acct.assault_pool or nil;
    local cd = char_name and tracker.settings.characters[char_name] or nil;
    if pool == nil or cd == nil or pool.tags_stored == nil then return; end
    if cd.assault_data == nil then cd.assault_data = new_assault_data(); end
    cd.assault_data.tags_stored   = pool.tags_stored;
    cd.assault_data.next_tag_time = pool.next_tag_time or 0;
    cd.assault_data.checked_at    = pool.checked_at or 0;
    cd.assault_data.max_stock     = pool.max_stock or ASSAULT_DEFAULT_MAX_STOCK;
end

-- Absorbs each member's personal reading into the pool ONCE, then clears it.
--
-- Nothing refreshes a grouped member's personal tags_stored - while grouped, all
-- writes go to the pool - so those copies freeze at whatever they said when the
-- character joined. This runs on every membership change AND at load, taking the
-- lowest of pool-vs-members. Without consuming the readings, every load
-- re-applied the stalest, lowest number on file: Rytaal raises the pool to 3,
-- you reload, and a member's frozen 1 drags it back down, forever.
local function seed_assault_pool(acct)
    local pool = ensure_assault_account(acct);
    local lowest, newest = pool.tags_stored, pool.checked_at or 0;
    local absorbed = {};
    for _, cname in ipairs(acct.chars or {}) do
        local cd = tracker.settings.characters[cname];
        local ad = cd and cd.assault_data or nil;
        if ad ~= nil and ad.tags_stored ~= nil then
            if lowest == nil or ad.tags_stored < lowest then lowest = ad.tags_stored; end
            -- Latest reading wins for the clock, per the same reasoning.
            if (ad.checked_at or 0) > newest then
                newest = ad.checked_at or 0;
                pool.next_tag_time = ad.next_tag_time or 0;
            end
            table.insert(absorbed, ad);
        end
    end
    if lowest ~= nil then
        pool.tags_stored = lowest;
        pool.checked_at = newest;
        -- Consumed: a later seed must not see these again.
        for _, ad in ipairs(absorbed) do ad.tags_stored = nil; end
    end
    -- Report the consumption rather than leaving callers to infer it from field
    -- comparisons: when a member's frozen reading already equalled the pool,
    -- tags_stored looked unchanged before and after even though records were
    -- cleared, so the save gate missed it and the write floated.
    return #absorbed > 0;
end

-- An account inherits the LOWEST remaining Dynamis count among its members, so
-- grouping characters never hands back an entry somebody already spent. Clamped
-- against the account's own value as well, so adding a fresh character to an
-- account that has already been used cannot top it back up. Membership changes
-- can therefore only lower the count - delete the account to start it over.
-- Member glass serials are merged in too, otherwise a glass one character
-- already counted would count a second time once the pool took over.
--
-- `from_membership` marks the call as triggered by ticking a character in or out
-- of an account, as opposed to deriving the pool from scratch (load, or turning
-- sharing on). Only membership changes are clamped: unticking a member who spent
-- two runs would otherwise hand those entries back. A genuine re-derivation has
-- to be free to raise, or a stale 0 from a previous session could never recover.
--
-- Returns true when anything was written, so callers can decide to save without
-- diffing individual fields.
function recalc_account_from_members(acct, from_membership)
    if acct == nil or type(acct.chars) ~= 'table' or #acct.chars == 0 then return false; end
    -- Assault first: manual_override is a Dynamis concept, and letting it return
    -- early here silently disabled assault seeding for the whole account.
    local consumed = seed_assault_pool(acct);
    -- The pool is known as soon as any member is: their usage is real data.
    for _, cname in ipairs(acct.chars) do
        local mcd = tracker.settings.characters[cname];
        if mcd and mcd.dynamis_data and mcd.dynamis_data.known == true then
            acct.known = true; break;
        end
    end
    -- A number the player typed in beats anything derived. Cleared at the weekly
    -- reset, when the addon's own count becomes trustworthy again.
    if acct.manual_override then return consumed; end

    -- Work from what the members have actually USED, not from whoever has the
    -- fewest left. Taking the lowest threw away an alt's unused entries: a
    -- character sitting at 0 would drag the whole pool to 0 even when nobody
    -- else had run. Each character's own allowance is CHARACTER_ENTRY_LIMIT, so
    -- (limit - remaining) is how many runs they spent.
    local used = 0;
    local merged, seen = {}, {};
    for _, sn in ipairs(acct.counted_glasses or {}) do
        if not seen[sn] then seen[sn] = true; table.insert(merged, sn); end
    end
    for _, cname in ipairs(acct.chars) do
        local cd = tracker.settings.characters[cname];
        local dd = cd and cd.dynamis_data or nil;
        if dd ~= nil then
            local left = tonumber(dd.entries_remaining);
            if left == nil then left = CHARACTER_ENTRY_LIMIT; end
            if left < 0 then left = 0; end
            if left > CHARACTER_ENTRY_LIMIT then left = CHARACTER_ENTRY_LIMIT; end
            used = used + (CHARACTER_ENTRY_LIMIT - left);
            for _, sn in ipairs(dd.counted_glasses or {}) do
                if not seen[sn] then seen[sn] = true; table.insert(merged, sn); end
            end
        end
    end

    local remaining = ACCOUNT_ENTRY_LIMIT - used;
    local previous = acct.entries_remaining;
    if from_membership and type(previous) == 'number' and remaining > previous then
        remaining = previous;
    end
    if remaining < 0 then remaining = 0; end
    local before = acct.entries_remaining;
    acct.entries_remaining = remaining;
    acct.counted_glasses = merged;
    return consumed or (remaining ~= before);
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
    unassign_char(char_name, true);   -- moving, not leaving: do not inherit
    if not already then table.insert(acct.chars, char_name); end
    recalc_account_from_members(acct, true);
    return true;
end

local function remove_dynamis_account(acct_index)
    local accts = dynamis_accounts();
    if accts[acct_index] == nil then return; end
    -- Everyone leaving at once still has to inherit, or they all revert to
    -- frozen pre-grouping counts.
    for _, cname in ipairs(accts[acct_index].chars or {}) do
        inherit_assault_from_pool(accts[acct_index], cname);
    end
    table.remove(accts, acct_index);
    -- Renumber the default names so they stay 1..n
    for i, acct in ipairs(accts) do
        if acct.name == nil or acct.name:match('^Account %d+$') then
            acct.name = 'Account ' .. tostring(i);
        end
    end
end

function new_assault_data()
    return { tags_stored = nil, checked_at = 0, next_tag_time = 0,
             max_stock = ASSAULT_DEFAULT_MAX_STOCK, current_assault = 0,
             rank = nil, rank_seen_at = 0, points = {}, last_withdraw = 0,
             orders_lost_seq = nil };
end

-- Whether the player is carrying a tag right now. Read live from the key item
-- table rather than the Rytaal packet, so it stays correct between visits.
-- Key items for a NAMED character. tracker.kis only ever describes whoever is
-- logged in, so reading it while the window shows an alt reported your own
-- Cosmo-Cleanse, cards and assault orders under their name. Every character
-- persists ki_cache, so use that for anyone else.
local function ki_held(char_name, ki_id)
    if char_name == nil or char_name == tracker.current_char then
        -- Before the first zone-in tracker.kis is empty, which showed the
        -- current character holding nothing while alts correctly showed their
        -- cached state. Fall through to the cache during that window.
        if tracker.kis_initialized or char_name == nil then
            return tracker.kis[ki_id] == true;
        end
    end
    local cd = tracker.settings.characters[char_name];
    if cd == nil or type(cd.ki_cache) ~= 'table' then return false; end
    for _, id in ipairs(cd.ki_cache) do
        if id == ki_id then return true; end
    end
    return false;
end

local function assault_holding_tag(char_name)
    return ki_held(char_name, IMPERIAL_ARMY_ID_TAG);
end

-- The Assault Orders key item names the area. Read live rather than stored, so
-- it clears itself the moment the orders are handed back to Rytaal.
local function assault_active_area(char_name)
    for id, area in pairs(ASSAULT_ORDERS) do
        if ki_held(char_name, id) then return area; end
    end
    return nil;
end

-- Projects the stored count forward from the last Rytaal reading. Returns
-- stored, next_tag_unix, max_stock - or nil when Rytaal has never been seen.
-- This function writes nothing back; the next Rytaal visit is the source of
-- truth and this only keeps the display honest in between. Note that the tag
-- withdrawal handler in on_ki_gained DOES materialise the result into
-- assault_data before spending, because it has to decrement the projected stock
-- rather than the stale stored one.
-- char_data is accepted for call-site compatibility, but the stock is read from
-- whichever store owns it - the account pool when grouped.
local function assault_state(char_data, char_name)
    -- No `or tracker.current_char` default: a legacy-shaped call with an alt's
    -- char_data and no name would have resolved the LOGGED-IN character's store
    -- while reading the alt's record. Fall through to char_data instead.
    local ad = char_name ~= nil and get_assault_store(char_name) or nil;
    if ad == nil then ad = char_data and char_data.assault_data or nil; end
    if ad == nil or ad.tags_stored == nil then return nil; end
    local maxs   = ad.max_stock or ASSAULT_DEFAULT_MAX_STOCK;
    local stored = ad.tags_stored;
    local nxt    = ad.next_tag_time or 0;
    local now    = os.time();
    if nxt > 0 then
        while stored < maxs and now >= nxt do
            stored = stored + 1;
            nxt = nxt + ASSAULT_TAG_PERIOD;
        end
    end
    if stored >= maxs then nxt = 0; end
    return stored, nxt, maxs;
end

local function glass_already_counted(store, serial)
    if store == nil or serial == nil then return false; end
    for _, sn in ipairs(store.counted_glasses or {}) do
        if sn == serial then return true; end
    end
    return false;
end

-- What actually limits this character right now: the lower of their own
-- remaining entries and (when grouped) their account's.
local function dynamis_effective_remaining(char_name)
    local store, shared = get_dynamis_store(char_name);
    if store == nil then return 0, 0, nil; end
    -- Default to the caps, matching recalc_account_from_members. Defaulting to
    -- zero rendered a missing value as a red "none left" rather than a full one.
    local acct_left = store.entries_remaining or ACCOUNT_ENTRY_LIMIT;
    if not shared then return acct_left, acct_left, nil; end
    local cd = char_name and tracker.settings.characters[char_name] or nil;
    local char_left = (cd and cd.dynamis_data and cd.dynamis_data.entries_remaining)
        or CHARACTER_ENTRY_LIMIT;
    local eff = acct_left;
    if char_left < eff then eff = char_left; end
    -- (eff, char_left, acct_left) to match limbus_state. These two returned
    -- their extras in opposite orders, which is a trap in a codebase whose
    -- documented failure mode is copying between siblings.
    return eff, char_left, acct_left;
end

-- Counts one entry. When the character is in an account this spends from both
-- the account's 3 and the character's own 2, because Horizon caps each.
local function count_dynamis_entry(store, serial, label, char_name)
    if store == nil then return false; end
    if serial ~= nil and glass_already_counted(store, serial) then return false; end
    store.known = true;

    char_name = char_name or tracker.current_char;
    local _, shared = get_dynamis_store(char_name);
    local char_data = char_name and tracker.settings.characters[char_name] or nil;
    local char_store = (shared and char_data) and char_data.dynamis_data or nil;

    -- A character who has already used their personal 2 cannot spend from the
    -- account pool, so the remaining entry stays available to their alts. The
    -- serial is NOT recorded here: nothing was spent, and marking it counted
    -- would stop an alt's entry on that same glass from counting either.
    if char_store ~= nil and (char_store.entries_remaining or 0) <= 0 then
        -- Nothing is recorded here on purpose, so without a session-only guard
        -- this message repeated on every zone-in, relog and re-entry.
        if tracker.last_denied_serial ~= serial then
            tracker.last_denied_serial = serial;
            print_msg('This character has already used both of their Dynamis runs this week.');
        end
        return true;
    end

    -- Same reasoning as the character guard above, which an earlier fix stopped
    -- one step short of: if the pool is empty too, nothing is spent, so the
    -- glass must not be marked counted. Recording it would stop the entry being
    -- counted later if the numbers are corrected by hand.
    if (store.entries_remaining or 0) <= 0
       and (char_store == nil or (char_store.entries_remaining or 0) <= 0) then
        print_msg('Dynamis entry detected but the counter is already at 0.');
        return true;
    end

    if serial ~= nil then table.insert(store.counted_glasses, serial); end

    local counted = false;
    if (store.entries_remaining or 0) > 0 then
        store.entries_remaining = store.entries_remaining - 1;
        counted = true;
    end
    -- Mirror the spend onto the character's own allowance so their personal cap
    -- keeps counting down while the account pool does too.
    if char_store ~= nil then
        if serial ~= nil and not glass_already_counted(char_store, serial) then
            table.insert(char_store.counted_glasses, serial);
        end
        if (char_store.entries_remaining or 0) > 0 then
            char_store.entries_remaining = char_store.entries_remaining - 1;
            counted = true;
        end
    end

    save_settings();
    if not counted then
        print_msg('Dynamis entry detected but the counter is already at 0.');
        return true;
    end

    local eff, char_left, acct_left = dynamis_effective_remaining(char_name);
    -- Guard on acct_left, which is the value that is nil when the character is
    -- not in an account. The reorder in 3.17 moved that nil from the third
    -- return to the second: the destructure here was updated, but this test
    -- still asked "is the third value nil", which is now never true - so every
    -- ungrouped character hit %d with a nil and threw inside the packet handler.
    if acct_left ~= nil and acct_left ~= char_left then
        print_success(string.format('Dynamis %s! %d left (account: %d).',
            label or 'entry counted', char_left, acct_left));
    else
        print_success(string.format('Dynamis %s! %d entr%s remaining this week.',
            label or 'entry counted', eff, eff == 1 and 'y' or 'ies'));
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
    add(LIMBUS_KI_ID);
    for _, card in ipairs(LIMBUS_CARDS) do add(card.ki_id); end
    add(XSKNIFE_KI_ID_FIRST); add(XSKNIFE_KI_ID_REPEAT);
    add(IMPERIAL_ARMY_ID_TAG); add(ASSAULT_ARMBAND);
    add(ISNM_CONFIDENTIAL_KI); add(ISNM_SECRET_KI);
    for id in pairs(ASSAULT_ORDERS) do add(id); end
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
    -- text_in reaches this before get_char_data(), guarded only by a cached name
    -- string, which is not proof the party object exists right now.
    local ok, zone = pcall(function()
        local party = AshitaCore:GetMemoryManager():GetParty();
        return party:GetMemberZone(0);
    end);
    if ok and type(zone) == 'number' then return zone; end
    return 0;
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
            dynamis_data = new_dynamis_data(),
            assault_data = new_assault_data(),
            limbus_data = new_limbus_data(),
            isnm_data = {},
            ashu_data = {}
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
    -- Ensure assault_data exists
    if tracker.settings.characters[tracker.current_char].assault_data == nil then
        tracker.settings.characters[tracker.current_char].assault_data = new_assault_data();
    end
    -- Ensure limbus_data exists
    if tracker.settings.characters[tracker.current_char].limbus_data == nil then
        tracker.settings.characters[tracker.current_char].limbus_data = new_limbus_data();
    end
    return tracker.settings.characters[tracker.current_char];
end

-- Checks if player has a key item (reads from tracker.kis table, NOT game memory)
local function has_key_item(ki_id)
    return tracker.kis[ki_id] == true;
end

-- Populates tracker.kis from game memory - ONLY called once on addon load if already logged in
local function populate_kis_from_memory()
    -- On this server HasKeyItem resolves and returns false for everything, which
    -- is handled below. On a client where the scanned pointer is genuinely
    -- absent the member is nil and the call throws - and this runs bare inside
    -- load_cb and /hw scan, while every other AshitaCore call in the file is
    -- wrapped.
    local ok, player = pcall(function()
        return AshitaCore:GetMemoryManager():GetPlayer();
    end);
    if not ok or player == nil then return false; end
    local has_ki = function(id)
        local got, v = pcall(function() return player:HasKeyItem(id); end);
        return got and v == true;
    end
    local found_any = false;
    for _, enm in ipairs(ENM_KEY_ITEMS) do
        local has = has_ki(enm.ki_id);
        tracker.kis[enm.ki_id] = has;
        if has then found_any = true; end
    end
    -- Limbus cards (for floating window display)
    for _, card in ipairs(LIMBUS_CARDS) do
        local has = has_ki(card.ki_id);
        tracker.kis[card.ki_id] = has;
        if has then found_any = true; end
    end
    local extras = { XSKNIFE_KI_ID_FIRST, XSKNIFE_KI_ID_REPEAT, COOKBOOK_KI_ID, SPICEGALS_KI_ID, UNINVITED_KI_ID,
                     IMPERIAL_ARMY_ID_TAG, ASSAULT_ARMBAND };
    for id in pairs(ASSAULT_ORDERS) do table.insert(extras, id); end
    for _, ki_id in ipairs(extras) do
        local has = has_ki(ki_id);
        tracker.kis[ki_id] = has;
        if has then found_any = true; end
    end
    for _, ki_id in pairs(ECOWARRIOR_KI_IDS) do
        local has = has_ki(ki_id);
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
    if tracker.isnm_observed_since == nil then tracker.isnm_observed_since = os.time(); end
    return true;
end

-- Rebuilds tracker.kis from the list persisted by the previous session.
-- On clients where HasKeyItem is unavailable this is the only way a reload can
-- come back with a correct picture without waiting for a zone change.
local function restore_ki_cache()
    if tracker.current_char == nil or tracker.current_char == 'Unknown' then return false; end
    local cd = tracker.settings.characters[tracker.current_char];
    if cd == nil or type(cd.ki_cache) ~= 'table' then return false; end
    -- An empty list is indistinguishable from a wiped one, and claiming a
    -- restore on it produces a confident all-false picture. Waiting for the
    -- 0x055 blocks is the safe reading of nothing.
    if #cd.ki_cache == 0 then return false; end
    local held = {};
    for _, id in ipairs(cd.ki_cache) do held[id] = true; end
    tracker.kis = {};
    for _, id in ipairs(TRACKED_KI_IDS) do
        tracker.kis[id] = (held[id] == true);
    end
    tracker.kis_initialized = true;
    if tracker.isnm_observed_since == nil then tracker.isnm_observed_since = os.time(); end
    return true;
end

local function scan_key_items(silent)
    -- Callers have always guarded this, but the safety lived in them rather than
    -- here; one new call site away from an error every frame or command.
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
    if char_data == nil then return false; end
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

-- The 0x055 table flickers when a key item is taken, so one handout can arrive
-- as several events inside a second.
local function cd_limbus_debounce_ok(char_data, now)
    if char_data.limbus_data == nil then char_data.limbus_data = new_limbus_data(); end
    return (now - (char_data.limbus_data.last_gain or 0)) > LIMBUS_DEBOUNCE;
end

-- ===== Quest starts =====
-- One implementation per quest, reached from TWO triggers: the NPC's menu
-- number (exact, wording-proof - the primary path) and the old dialogue
-- sentence (kept as a fallback for menu numbers we have not captured yet,
-- e.g. a first-time accept). Both funnel here, so there are no sibling
-- copies to drift apart.
local function accept_spicegals(char_data)
    local s = char_data.quest_steps.spicegals;
    if s == 'rouva' or s == 'unknown' or s == 'scanned' then
        char_data.quest_steps.spicegals = 'riverne';
        save_settings();
        print_success('SpiceGals started - Head to Riverne B for Rivernewort!');
    end
end

local function accept_cookbook(char_data)
    local s = char_data.quest_steps.cookbook;
    if s == 'jonette' or s == 'unknown' or s == 'scanned' then
        char_data.quest_steps.cookbook = 'sacrarium';
        save_settings();
        print_success('CookBook started - Head to ??? in Sacrarium!');
    end
end

-- NPC menus that mean "quest accepted", captured live 2026-08-30/31 with the
-- 0x032 short menu packet (idx 0x08, zone 0x0A, menu 0x0C):
--   Rouva     zone 230  menu 728 (accept)   727 (reward)
--   Jonette   zone  26  menu 507 (repeat accept) 508 (reward) 365 (idle)
--             LSB numbers the first-ever accept 506, so both are listened to.
--   Justinius zone  26  menu 573 (accept)   572 (reward)
-- Rewards are deliberately NOT menu-triggered: Jonette opened 508 on a
-- turn-in that FAILED (bag full), so "she tried" is all a menu proves. The
-- key item leaving the bag remains the completion signal. UnInvited's start
-- is already covered by the permit key item arriving, so it needs no menu.
local QUEST_START_MENUS = {
    [230] = { [728] = 'spicegals' },
    [26]  = { [507] = 'cookbook', [506] = 'cookbook' },
};

-- ===== EcoWarrior transitions (one implementation, menu + text triggers) =====
local ECO_FIELD_HINT = {
    sandoria = "Head to Ordelle's Caves.",
    windurst = 'Head to Maze of Shakhrami.',
    bastok   = 'Head to Gusgen Mines.',
};
local ECO_REWARD_HINT = {
    sandoria = "Go to Norejaie in Southern San d'Oria for reward!",
    windurst = 'Go to Lumomo in Windurst Waters for reward!',
    bastok   = 'Go to Raifa in Port Bastok for reward!',
};
local ECO_NATION_LABEL = { sandoria = "San d'Oria", windurst = 'Windurst', bastok = 'Bastok' };

local function eco_accept(char_data, nation)
    local eco = char_data.ecowarrior_data;
    if eco.step == 'ready' or eco.step == 'scanned' or eco.step == 'unknown' then
        eco.step = 'field_agent'; eco.current_nation = nation;
        eco.knows_status = true;
        save_settings();
        print_success('EcoWarrior: ' .. ECO_NATION_LABEL[nation] .. ' quest accepted! ' .. ECO_FIELD_HINT[nation]);
    end
end

local function eco_nm(char_data, nation)
    local eco = char_data.ecowarrior_data;
    if eco.step == 'field_agent' and eco.current_nation == nation then
        eco.step = 'nm';
        save_settings();
        print_success('EcoWarrior: Kill the NM!');
    end
end

local function eco_return(char_data, nation)
    local eco = char_data.ecowarrior_data;
    if eco.step == 'field_agent_return' and eco.current_nation == nation then
        eco.step = 'reward';
        save_settings();
        print_success('EcoWarrior: ' .. ECO_REWARD_HINT[nation]);
    end
end

-- EcoWarrior menu numbers. Source: LandSandBoat scripts/quests/<nation>/
-- Eco_Warrior.lua, and the Bastok set was verified live 2026-08-31 (Degga
-- 13 and 16, Raifa 282 all matched the packets exactly), so the server kept
-- LSB's numbering. Layout: [zone] = { [menu] = { kind, nation } }.
--   kind 'return' = the field agent sends you back to the city (no choice)
-- Yes/no menus are NOT here: the city offer AND the field agent's ointment
-- both open whether you accept or decline (LSB applies the ointment only on
-- option 1), so those are read from your reply packet (ECO_REPLY_MENUS).
local ECO_MENUS = {
    [193] = { [54] = { 'return', 'sandoria' } },  -- Rojaireaut, Ordelle's
    [198] = { [65] = { 'return', 'windurst' } },  -- Ahko Mhalijikhari, Shakhrami
    [196] = { [16] = { 'return', 'bastok' } },    -- Degga, Gusgen
};
-- Menus that mean something only when the reply carries option 1.
local ECO_REPLY_MENUS = {
    [230] = { [677] = { 'accept', 'sandoria' } },   -- Norejaie
    [238] = { [818] = { 'accept', 'windurst' } },   -- Lumomo
    [236] = { [278] = { 'accept', 'bastok' } },     -- Raifa
    [193] = { [51]  = { 'nm', 'sandoria' } },       -- Rojaireaut's ointment
    [198] = { [62]  = { 'nm', 'windurst' } },       -- Ahko's ointment
    [196] = { [13]  = { 'nm', 'bastok' } },         -- Degga's ointment
};

local function on_quest_menu(zone_id, menu_id)
    local char_data = nil;
    local zone_map = QUEST_START_MENUS[zone_id];
    local which = zone_map and zone_map[menu_id] or nil;
    if which ~= nil then
        char_data = get_char_data();
        if char_data == nil then return; end
        if which == 'spicegals' then accept_spicegals(char_data);
        elseif which == 'cookbook' then accept_cookbook(char_data); end
        return;
    end
    local eco_map = ECO_MENUS[zone_id];
    local eco = eco_map and eco_map[menu_id] or nil;
    if eco ~= nil then
        char_data = get_char_data();
        if char_data == nil then return; end
        if eco[1] == 'return' then eco_return(char_data, eco[2]); end
    end
end

-- Your reply to a menu (outgoing 0x05B): option at 0x08, zone at 0x10,
-- menu at 0x12 - verified against captured replies (Halshaob, Rytaal).
local function on_menu_reply(zone_id, menu_id, option)
    local zmap = ECO_REPLY_MENUS[zone_id];
    local entry = zmap and zmap[menu_id] or nil;
    if entry == nil or option ~= 1 then return; end   -- declined = nothing
    local char_data = get_char_data();
    if char_data == nil then return; end
    if entry[1] == 'accept' then eco_accept(char_data, entry[2]);
    elseif entry[1] == 'nm' then eco_nm(char_data, entry[2]); end
end

local function on_ki_gained(ki_id)
    local char_data = get_char_data();
    if char_data == nil then return; end
    -- An Imperial order landing in the bag is the ISNM purchase; Shajaf's lock
    -- runs from now until JST midnight. If the addon was off at purchase time,
    -- this instead fires on the next baseline and stamps the lock late - the
    -- next Shajaf visit or the midnight itself corrects it.
    if ki_id == ISNM_CONFIDENTIAL_KI or ki_id == ISNM_SECRET_KI then
        local isnm = isnm_data_for(char_data);
        isnm.next_buy_time = next_jst_midnight(os.time());
        isnm.no_badge = nil;
        save_settings();
        print_success(string.format('%s Imperial order taken! Next purchase after %s.',
            ki_id == ISNM_SECRET_KI and 'Secret (3000)' or 'Confidential (2000)',
            os.date('%H:%M', isnm.next_buy_time)));
        return;
    end
    -- Taking a tag moves it from Rytaal's stock into your hands. The menu packet
    -- is sent when the menu OPENS, before the option is picked, so it always
    -- reports the count from before the withdrawal - there is no second packet
    -- to correct it. Without this the same tag is counted in both places.
    -- Mister Glean handing over a Cosmo-Cleanse is one Limbus run, against both
    -- this character's 2 and the account's 4.
    if ki_id == LIMBUS_KI_ID then
        local now = os.time();
        if cd_limbus_debounce_ok(char_data, now) then
            local own = char_data.limbus_data;
            own.last_gain = now;
            -- A character who has already used their 2 cannot spend from the
            -- account's 4, so the rest stays available to their alts.
            if (own.runs_remaining or LIMBUS_CHARACTER_LIMIT) <= 0 then
                own.seen = (own.seen or 0) + 1;
                save_settings();
                print_msg('This character has already used both Limbus runs this week.');
                return;
            end
            own.seen = (own.seen or 0) + 1;
            own.runs_remaining = math.max(0, (own.runs_remaining or LIMBUS_CHARACTER_LIMIT) - 1);
            local store, shared = get_limbus_store(tracker.current_char);
            if shared and store ~= nil then
                store.limbus_seen = (store.limbus_seen or 0) + 1;
                store.limbus_remaining = math.max(0, (store.limbus_remaining or LIMBUS_ACCOUNT_LIMIT) - 1);
            end
            save_settings();
            local eff, char_left, acct_left = limbus_state(tracker.current_char);
            if acct_left ~= nil then
                print_success(string.format('Cosmo-Cleanse taken! %d left for this character, %d on the account.',
                    char_left, acct_left));
            else
                print_success(string.format('Cosmo-Cleanse taken! %d Limbus run%s left this week.',
                    char_left, char_left == 1 and '' or 's'));
            end
        end
        return;
    end

    if ki_id == IMPERIAL_ARMY_ID_TAG then
        -- Decrement the shared pool when grouped, so an alt's withdrawal is
        -- visible on every character.
        local ad = get_assault_store(tracker.current_char) or char_data.assault_data;
        if ad ~= nil and ad.tags_stored ~= nil then
            local now = os.time();
            -- Materialise the projection first. assault_state ticks the stock
            -- forward every 24h since the anchor, but this handler read the raw
            -- stored value: with Rytaal last seen at 0 and three days elapsed,
            -- the display correctly showed 3 while `tags_stored > 0` was false,
            -- so the withdrawal was skipped and the restock clock never
            -- restarted.
            local projected, proj_next = assault_state(char_data, tracker.current_char);
            if projected ~= nil then
                ad.tags_stored = projected;
                ad.next_tag_time = proj_next or 0;
            end
            -- Same packet as the orders vanishing means this is a cancellation
            -- refund, not a withdrawal from Rytaal.
            -- Orders are personal, so this flag stays on the character record
            -- even when the stock it protects is shared.
            local own = char_data.assault_data;
            if own ~= nil and own.orders_lost_seq ~= nil
               and own.orders_lost_seq == ASSAULT_KI_PACKET_SEQ then
                own.orders_lost_seq = nil;
                -- The projection above was already written into the store, so
                -- persist it rather than leaving it floating until some other
                -- save happens to fire.
                save_settings();
                return;
            end
            if (now - (ad.last_withdraw or 0)) > ASSAULT_TAG_DEBOUNCE then
                ad.last_withdraw = now;
                if ad.tags_stored > 0 then
                    local was_full = ad.tags_stored >= (ad.max_stock or ASSAULT_DEFAULT_MAX_STOCK);
                    ad.tags_stored = ad.tags_stored - 1;
                    -- Dropping below a full stock is what starts the restock clock.
                    -- Without this the row keeps showing whatever countdown Rytaal
                    -- last reported, which can be an hour or more out of date until
                    -- the next visit corrects it.
                    if was_full then
                        ad.next_tag_time = now + ASSAULT_TAG_PERIOD;
                    end
                    save_settings();
                end
            end
        end
        return;
    end
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
    -- The order breaks when its holder opens the battlefield. Nothing to store:
    -- the key item table is the record of what is held, and the buy lock keeps
    -- running regardless.
    if ki_id == ISNM_CONFIDENTIAL_KI or ki_id == ISNM_SECRET_KI then
        print_success('Imperial order used - ISNM underway!');
        return;
    end
    -- Losing Assault Orders means the run ended one way or another. Note the
    -- moment: if a tag turns up immediately afterwards it was a cancellation.
    if ASSAULT_ORDERS[ki_id] ~= nil then
        if char_data.assault_data == nil then char_data.assault_data = new_assault_data(); end
        -- Which packet, not which second.
        char_data.assault_data.orders_lost_seq = ASSAULT_KI_PACKET_SEQ;
    end
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
            -- The permit leaving the bag means entered OR abandoned; we cannot
            -- tell which, so do not congratulate.
            print_msg('Monarch Linn permit used. Return to Justinius when done.');
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
    -- Parenthesised: a tail-returned gsub also yields its replacement count,
    -- which silently corrupts any caller that uses this in a list or arg slot.
    return (task:lower():gsub('%s+', ''):gsub("'", ''));
end

-- Short forms advertised in the UI tooltips. Previously these were suggested to
-- the user but rejected by the exact-match lookup below.
local TASK_ALIASES = {
    knife     = "X'sKnife",
    xknife    = "X'sKnife",
    high      = 'Highwind',
    -- 'hw' deliberately omitted: /hw hw reads like "open the window" and would
    -- instead silently toggle a quest.
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
    store.known = true;   -- a witnessed reset: the count is authoritative from here
    -- Legacy fields from before serial tracking.
    store.glass_used = nil;
    store.dynamis_zone = nil;
    store.claimed_before_reset = nil;

    local full = store.is_account and ACCOUNT_ENTRY_LIMIT or CHARACTER_ENTRY_LIMIT;
    local carried = store.claimed_at ~= nil
        and (current_time - store.claimed_at) <= DYNAMIS_CLAIM_CARRY_WINDOW;

    if carried then
        -- A glass broken just before the reset stays spent in the new week. Keep
        -- its REAL serial and its break zone: an earlier version substituted a
        -- 'carried-<time>' placeholder and wiped the zone guard, so walking into
        -- that zone after the reset found an unrecognised serial and charged a
        -- second entry for one run.
        store.entries_remaining = full - 1;
        local keep = {};
        if store.last_break_serial ~= nil then
            table.insert(keep, store.last_break_serial);
        else
            table.insert(keep, 'carried-' .. tostring(store.claimed_at));
        end
        store.counted_glasses = keep;
        -- last_break_zone / last_break_time deliberately survive so the zone-in
        -- guard still recognises the arrival.
    else
        store.entries_remaining = full;
        store.counted_glasses = {};
        store.last_break_zone = nil;
        store.last_break_time = nil;
        store.last_break_serial = nil;
    end
    store.claimed_at = nil;
end

local function reset_character_data(char_data)
    local current_time = os.time();
    char_data.last_reset = current_time;
    -- Ashu Talif: the tally zeroes OUR win count and any fail, but a paid,
    -- unfought stage SURVIVES the reset - observed live: a member banked the
    -- first quest across a tally and fought it after. Witnessing this reset
    -- anchors the character: from here on, "nothing observed" provably means
    -- a fresh 3/3 rather than an unknown.
    if type(char_data.ashu_data) == 'table' then
        local ash = char_data.ashu_data;
        ash.anchored = true;
        ash.done = nil;
        ash.failed = nil;
        ash.aboard = nil;
        -- A paid, unfought stage survives the tally (observed); otherwise the
        -- chain restarts at stage 1.
        if ash.paid ~= true then ash.stage = 1; end
        ash.hist = nil; ash.wins = nil; ash.aboard_stage = nil;   -- retired fields
    end
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
    -- Limbus: fresh allowance. From this point the addon has watched a whole
    -- week, so the count is trustworthy and the unknown marker can go.
    if char_data.limbus_data == nil then char_data.limbus_data = new_limbus_data(); end
    char_data.limbus_data.runs_remaining = LIMBUS_CHARACTER_LIMIT;
    char_data.limbus_data.seen = 0;
    char_data.limbus_data.known = true;
    char_data.limbus_data.last_gain = 0;

    -- Dynamis: fresh allowance and a fresh list of counted glass serials.
    if char_data.dynamis_data then
        reset_dynamis_store(char_data.dynamis_data, current_time);
    else
        char_data.dynamis_data = new_dynamis_data();
    end
end

local function reset_tracker()
    -- Reset ALL characters, not just the current one.
    --
    -- Guard first: a single character with a stale last_reset - from a restored
    -- backup, a hand-edit, or a merged save - used to drag every character
    -- through a reset and wipe usage that was legitimately tracked this week.
    -- If the NEWEST last_reset on file is still inside the current week, this is
    -- one desynced record rather than a real weekly rollover, so just bring the
    -- laggards forward and leave everyone's counts alone.
    local newest = 0;
    for char_name, cd in pairs(tracker.settings.characters) do
        if char_name ~= 'Unknown' and type(cd.last_reset) == 'number' and cd.last_reset > newest then
            newest = cd.last_reset;
        end
    end
    if newest > 0 and os.time() < calculate_next_reset(newest) then
        for _, cd in pairs(tracker.settings.characters) do
            if type(cd.last_reset) == 'number' and cd.last_reset < newest then
                cd.last_reset = newest;
            end
        end
        save_settings();
        tracker.next_check_time = calculate_next_reset(os.time());
        return;
    end

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
        ensure_limbus_account(acct);
        acct.manual_override = nil;
        acct.limbus_remaining = LIMBUS_ACCOUNT_LIMIT;
        acct.limbus_seen = 0;
        acct.limbus_known = true;
    end
    save_settings();
    print_success('Weekly tracker has been reset for all ' .. reset_count .. ' characters!');
    local next_reset = calculate_next_reset(os.time());
    tracker.next_check_time = next_reset;
end

-- The newest last_reset across all characters. A single stale value - from a
-- restored backup or a hand-edited save - used to trigger reset_tracker(), which
-- wipes every character's week, not just the stale one.
local function newest_last_reset()
    local newest = 0;
    for _, cd in pairs(tracker.settings.characters or {}) do
        local lr = tonumber(cd.last_reset) or 0;
        if lr > newest then newest = lr; end
    end
    return newest;
end

local function initialize_timer()
    local char_data = get_char_data();
    if char_data == nil then return; end
    local current_time = os.time();
    -- calculate_next_reset always returns a strictly future timestamp, so the old
    -- `current_time >= calculate_next_reset(current_time)` guard could never fire
    -- and `last_reset < last_reset_point` was likewise always true. Both dropped.
    local anchor = math.max(tonumber(char_data.last_reset) or 0, newest_last_reset());
    if current_time >= calculate_next_reset(anchor) then
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
    tracker.isnm_observed_since = nil;
        local char_data = get_char_data();
        if not tracker.kis_initialized then restore_ki_cache(); end
        local needs_scan = char_data.quest_steps.uninvited == 'unknown' or
                          char_data.quest_steps.spicegals == 'unknown' or
                          char_data.quest_steps.cookbook == 'unknown';
        if needs_scan then print_msg('Use /hw scan to check key items for this character'); end
        initialize_timer();
        -- A relog is the player saying "I'm someone else now": clear the
        -- sticky selection so the dropdown follows them. Window rebuilds
        -- (list changes, settings toggles) still keep whatever was viewed -
        -- that rule lives in update_char_list and is untouched.
        ui.selected_name = nil;
        update_char_list();
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
    if #available == 0 then return 'All Nations'; end         -- cycle complete, all reopen
    if #available == 3 then return 'All Nations'; end
    if #available == 2 then return available[1] .. ' & ' .. available[2]; end
    return available[1];
end

-- One chat line for one task. Shared by /hw weeklys and /hw chars <name>,
-- which previously carried two drifting copies of this logic.
local function format_task_line(task, char_data)
    local normalized = normalize_task(task);
    if normalized == 'xsknife' then
        local step = (char_data.xsknife_data or {}).step or 'unknown';
        -- The count answers "how many fights are left this week" (2 per week);
        -- the bracket answers "where do I go". '2x' used to read like part of
        -- the place name.
        if step == 'unknown' then return HDR .. '\30\104[?]\30\106 ' .. task;
        elseif step == 'scanned_no_ki' then return HDR .. '\30\104?/2\30\106 ' .. task;
        elseif step == 'scanned_has_ki' then return HDR .. '\30\104?/2 [Boneyard Gully - Requiem of Sin]\30\106 ' .. task;
        elseif step == 'scanned_has_ki_used' then return HDR .. '\30\104?/2 [Despachiaire]\30\106 ' .. task;
        elseif step == 'despachiaire' then return HDR .. '\30\1101/2 [Despachiaire]\30\106 ' .. task;
        elseif step == 'boneyard' then return HDR .. '\30\1101/2 [Boneyard Gully - Requiem of Sin]\30\106 ' .. task;
        elseif step == 'boneyard_2x' then return HDR .. '\30\1102/2 [Boneyard Gully - Requiem of Sin]\30\106 ' .. task;
        elseif step == 'done' then return HDR .. '\30\068[x]\30\106 ' .. task;
        else return HDR .. '\30\104?/2\30\106 ' .. task; end
    elseif normalized == 'highwind' then
        local step = char_data.quest_steps.highwind or 'scanned';
        if step == 'start' then return HDR .. '\30\110[NM]\30\106 ' .. task;
        elseif step == 'done' then return HDR .. '\30\068[x]\30\106 ' .. task;
        else return HDR .. '\30\104[ ]\30\106 ' .. task; end
    elseif normalized == 'uninvited' then
        local step = char_data.quest_steps.uninvited or 'unknown';
        if step == 'scanned' then return HDR .. '\30\104[ ]\30\106 ' .. task;
        elseif step == 'justinius' then return HDR .. '\30\110[Justinius - Start]\30\106 ' .. task;
        elseif step == 'bcnm' then return HDR .. '\30\110[BCNM Monarch]\30\106 ' .. task;
        elseif step == 'justinius_return' then return HDR .. '\30\110[Justinius - Reward]\30\106 ' .. task;
        elseif step == 'done' then return HDR .. '\30\068[x]\30\106 ' .. task;
        else return HDR .. '\30\104[?]\30\106 ' .. task; end
    elseif normalized == 'spicegals' then
        local step = char_data.quest_steps.spicegals or 'unknown';
        if step == 'scanned' then return HDR .. '\30\104[ ]\30\106 ' .. task;
        elseif step == 'rouva' then return HDR .. '\30\110[Rouva - Start]\30\106 ' .. task;
        elseif step == 'riverne' then return HDR .. '\30\110[Riverne B]\30\106 ' .. task;
        elseif step == 'rouva_return' then return HDR .. '\30\110[Rouva - Reward]\30\106 ' .. task;
        elseif step == 'done' then return HDR .. '\30\068[x]\30\106 ' .. task;
        else return HDR .. '\30\104[?]\30\106 ' .. task; end
    elseif normalized == 'cookbook' then
        local step = char_data.quest_steps.cookbook or 'unknown';
        if step == 'scanned' then return HDR .. '\30\104[ ]\30\106 ' .. task;
        elseif step == 'jonette' then return HDR .. '\30\110[Jonette - Start]\30\106 ' .. task;
        elseif step == 'sacrarium' then return HDR .. '\30\110[??? Sacrarium]\30\106 ' .. task;
        elseif step == 'jonette_return' then return HDR .. '\30\110[Jonette - Reward]\30\106 ' .. task;
        elseif step == 'done' then return HDR .. '\30\068[x]\30\106 ' .. task;
        else return HDR .. '\30\104[?]\30\106 ' .. task; end
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
        elseif step == 'done' then return HDR .. '\30\068[x]\30\106 ' .. task;
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
        elseif step == 'unknown' then return HDR .. '\30\104[?]\30\106 ' .. task;
        else return HDR .. '\30\104[ ]\30\106 ' .. task; end
    end
    return nil;
end

-- One chat line for the Dynamis entry counter. Mirrors the row the floating
-- window draws above the tasks.
local function format_dynamis_line(char_name, char_data)
    local store, shared = get_dynamis_store(char_name);
    if store == nil then store = char_data.dynamis_data; end
    if store == nil then return HDR .. '\30\104[?]\30\106 Dynamis'; end
    -- Show what actually limits this character: the lower of their own cap and
    -- the account pool. Saying "1 left" when the character is capped would lie.
    if store.known == false then
        return HDR .. '\30\104[ ? ]\30\106 Dynamis \30\071(unknown until reset)\30\106';
    end
    local entries, char_left, acct_left = dynamis_effective_remaining(char_name);
    if not shared then entries = store.entries_remaining or CHARACTER_ENTRY_LIMIT; end
    local suffix = '';
    if shared then
        if char_left ~= nil and acct_left ~= char_left then
            suffix = string.format(', account: %d', acct_left);
        else
            suffix = ', account';
        end
    end
    -- Counts render as n/max here too, matching the window: brackets mean
    -- status, a bare fraction means a count.
    local dmax = CHARACTER_ENTRY_LIMIT;   -- see the window row: always the character's cap
    local colour = (entries <= 0) and '\30\076'
                or (entries == 1) and '\30\104'
                or '\30\110';
    local count = string.format('%s%d/%d\30\106', colour, entries, dmax);
    if suffix ~= '' then
        return HDR .. count .. ' Dynamis \30\071(' .. entries .. ' left' .. suffix .. ')\30\106';
    end
    if entries <= 0 then return HDR .. count .. ' Dynamis \30\071(no runs left)\30\106'; end
    return HDR .. count .. string.format(' Dynamis \30\071(%d run%s left)\30\106',
        entries, entries == 1 and '' or 's');
end

local function format_time_short(seconds)
    if seconds <= 0 then return 'Ready'; end
    local days = math.floor(seconds / 86400);
    local hours = math.floor((seconds % 86400) / 3600);
    local minutes = math.floor((seconds % 3600) / 60);
    if days > 0 then return string.format('%dd %dh', days, hours);
    elseif hours > 0 then return string.format('%dh %dm', hours, minutes);
    else return string.format('%dm', minutes); end
end

-- Limbus in chat. Cooldown is gone, so this reports the Cosmo-Cleanse and the
-- three cards rather than a timer.
local function format_limbus_line(char_name)
    local has_cosmo = ki_held(char_name, LIMBUS_KI_ID);
    local eff, char_left, acct_left, known = limbus_state(char_name);
    local cards = {};
    for _, card in ipairs(LIMBUS_CARDS) do
        if ki_held(char_name, card.ki_id) then table.insert(cards, card.name); end
    end
    local suffix = '';
    if #cards > 0 then suffix = ' \30\071(' .. table.concat(cards, ', ') .. ')\30\106'; end

    local icon;
    if eff == nil then icon = '\30\104[?]\30\106';
    elseif not known then icon = string.format('\30\104?/%d\30\106', LIMBUS_CHARACTER_LIMIT);
    elseif eff <= 0 then icon = string.format('\30\076%d/%d\30\106', eff, LIMBUS_CHARACTER_LIMIT);
    else icon = string.format('\30\110%d/%d\30\106', eff, LIMBUS_CHARACTER_LIMIT); end

    local where = has_cosmo and 'Apollyon/Temenos' or LIMBUS_NPC;
    local counts = '';
    if eff ~= nil then
        counts = string.format(', %d left', char_left);
        if acct_left ~= nil then counts = counts .. string.format(', account %d', acct_left); end
    end
    return HDR .. icon .. ' Limbus \30\071(' .. where .. counts .. ')\30\106' .. suffix;
end

-- Assault tags in chat: Rytaal's stock, plus what is in hand.
local function format_assault_line(char_data, char_name)
    local stored, next_tag, max_stock = assault_state(char_data, char_name);
    local carried = assault_holding_tag(char_name);
    local area = assault_active_area(char_name);
    if stored == nil then
        return HDR .. '\30\104[?]\30\106 Assault \30\071(talk to Rytaal)\30\106';
    end
    local colour = (stored == 0) and '\30\076'
                or (stored == 1) and '\30\104'
                or '\30\110';
    local icon = string.format('%s%d/%d\30\106', colour, stored, max_stock);
    local bits = { stored .. ' at Rytaal' };
    if carried then table.insert(bits, 'carrying 1'); end
    if next_tag > 0 then table.insert(bits, 'next in ' .. format_time_short(next_tag - os.time())); end
    if area ~= nil then table.insert(bits, 'on ' .. area); end
    return HDR .. icon .. ' Assault \30\071(' .. table.concat(bits, ', ') .. ')\30\106';
end

-- The Ashu Talif chain in chat: fights left and the next action.
local function format_ashu_line(char_data)
    local icon, key, status = ASHU.describe(char_data);
    local col = (key == 'green') and '\30\110' or (key == 'grey') and '\30\068' or '\30\104';
    if icon == '[x]' then icon = '[ x ]'; elseif icon == '[?]' then icon = '[ ? ]'; end
    return HDR .. col .. icon .. '\30\106 Ashu Talif \30\071(' .. status .. ')\30\106';
end

-- ISNM in chat: what is held, and when Shajaf sells again.
local function format_isnm_line(char_name)
    local cd = char_name and tracker.settings.characters[char_name] or nil;
    resolve_isnm_unknown(cd, char_name);
    local isnm = cd and cd.isnm_data or nil;
    if isnm ~= nil and isnm.no_badge then
        return HDR .. '\30\068[ ]\30\106 ISNM \30\071(need the Wildcat Badge)\30\106';
    end
    local held = isnm_held_ki(char_name);
    local nbt = isnm and isnm.next_buy_time or nil;
    local buy;
    if nbt == nil then buy = 'see Shajaf';
    elseif os.time() >= nbt then buy = 'Ready';
    else buy = format_time_short(nbt - os.time()); end
    if held ~= nil then
        local tier = held == ISNM_SECRET_KI and '3000' or '2000';
        return HDR .. '\30\110[KI]\30\106 ISNM \30\071(' .. tier .. ' held, ' .. buy .. ')\30\106';
    end
    if nbt == nil then
        return HDR .. '\30\104[ ? ]\30\106 ISNM \30\071(see Shajaf)\30\106';
    end
    local icon = (os.time() >= nbt) and '\30\110[  ]' or '\30\068[ x ]';
    return HDR .. icon .. '\30\106 ISNM \30\071(' .. buy .. ')\30\106';
end

-- One chat line for one ENM/Limbus timer.
local function format_timer_line(enm, timer_data, current_time)
    local status_icon = '\30\104[ ? ]\30\106';
    local status_text = '\30\071(Unknown)\30\106';
    -- [KI] green = in the bag (fight open), [    ] = ready but KI not taken,
    -- [ x ] = waiting, [ ? ] = unknown. Same vocabulary as the window.
    if timer_data ~= nil then
        if timer_data.next_ki_time == nil or timer_data.next_ki_time == 0 then
            if timer_data.has_ki then
                status_icon = '\30\110[KI]\30\106';
                status_text = '\30\071(Ready)\30\106';
            end
        elseif current_time >= timer_data.next_ki_time then
            if timer_data.has_ki then
                status_icon = '\30\110[KI]\30\106';
            else
                status_icon = '\30\110[    ]\30\106';
            end
            status_text = '\30\071(Ready)\30\106';
        elseif timer_data.timer_source == 'scan' then
            if timer_data.has_ki then
                status_icon = '\30\110[KI]\30\106';
                status_text = '\30\071(Ready)\30\106';
            end
        else
            local time_left = timer_data.next_ki_time - current_time;
            local days = math.floor(time_left / 86400);
            local hours = math.floor((time_left % 86400) / 3600);
            if timer_data.has_ki then status_icon = '\30\110[KI]\30\106'; else status_icon = '\30\068[ x ]\30\106'; end
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
    if flags.question then print('\30\104[?]\30\067 = Use /hw scan to detect progress.'); end
    if flags.yellow_empty then print('\30\104[ ]\30\067 = Unknown progress. Resolves at next tally or use /hw <task>.'); end
    if flags.eco_unknown then print('\30\104[?]\30\067 (EcoWarrior) = Use /hw eco <nation> or talk to Eeko-Weeko.'); end
    if flags.eco_nation then print('\30\104[Nation]\30\067 (EcoWarrior) = Unknown if completed. Resolves at next tally or quest interaction.'); end
    if flags.eco_scanned_ki then print('\30\104[Zone - Agent]\30\067 (EcoWarrior) = Has KI but locked nations unknown. Use /hw eco or talk to Eeko-Weeko.'); end
    if flags.knife_unknown then print('\30\104[?]\30\067 (X\'sKnife) = Use /hw scan or talk to Despachiaire.'); end
    if flags.knife_empty then print('\30\104?/2\30\067 (X\'sKnife) = Fights left unknown. Resolves at next tally or when KI obtained.'); end
    if flags.knife_des then print('\30\104?/2 [Despachiaire]\30\067 (X\'sKnife) = Unknown if Despachiaire has KI. Resolves at next tally or when KI obtained.'); end
    if flags.knife_boneyard then print('\30\104?/2 [Boneyard Gully]\30\067 (X\'sKnife) = KI in hand; unknown if another follows. Resolves at next tally or when KI obtained.'); end
end

local function print_weekly_block(char_name, char_data, current_time)
    print_msg('Weekly Homework for \30\110' .. char_name .. '\30\106:');
    print_task_legend(char_data);
    print_msg('=================');
    print(format_dynamis_line(char_name, char_data));
    print(format_limbus_line(char_name));
    print(format_task_line("X'sKnife", char_data));
    print(format_ashu_line(char_data));
    print(format_assault_line(char_data, char_name));
    print(format_isnm_line(char_name));
    for _, task in ipairs(tracker.settings.tasks) do
        local line = nil;
        if normalize_task(task) ~= 'xsknife' then
            line = format_task_line(task, char_data);
        end
        if line then print(line); end
    end
    print('');
    print_msg(string.format('Next reset in %s', format_countdown(calculate_next_reset(current_time) - current_time)));
end

local function print_timer_block(char_name, char_data, current_time)
    print_msg('ENM Timers for \30\110' .. char_name .. '\30\106:');
    print_msg('====================');
    -- Assault and ISNM head the Timers panel, so they head this print too.
    print(format_assault_line(char_data, char_name));
    print(format_isnm_line(char_name));
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
    print_msg('ENM Timers for \30\110' .. tracker.current_char .. '\30\106:');
    if not has_any_timers then print('\30\081[\30\082Homework\30\081]\30\106 Please use \30\110/hw scan\30\106 to scan for your current KIs'); end
    if has_unknown_question then print('\30\104[?]\30\067 = Unknown status. Use /hw scan to update.'); end
    if has_unknown_no_ki then
        local time_left = longest_no_ki_timer - current_time;
        local days = math.floor(time_left / 86400);
        local hours = math.floor((time_left % 86400) / 3600);
        local time_str = '';
        if days > 0 then time_str = tostring(days) .. ' days, ' .. tostring(hours) .. ' hours';
        else time_str = tostring(hours) .. ' hours'; end
        print('\30\104[?]\30\067 = No KI. Unknown if ready. Resolves after ' .. time_str .. ' or when KI obtained.');
    end
    if has_unknown_ki then
        local longest_ki_timer = 0;
        for _, enm in ipairs(ENM_KEY_ITEMS) do
            local timer_data = char_data.enm_timers[enm.name];
            if timer_data ~= nil and timer_data.has_ki then
                if timer_data.timer_source == 'scan' and timer_data.next_ki_time > longest_ki_timer then
                    longest_ki_timer = timer_data.next_ki_time;
                elseif timer_data.next_ki_time == 0 then
                    longest_ki_timer = math.max(longest_ki_timer, current_time + enm.cooldown);
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
            print('\30\110[o]\30\067 = KI in hand, fight open. Timer resolves after ' .. time_str .. ' or when KI obtained.');
        else
            print('\30\110[o]\30\067 = KI in hand, fight open. Timer updates when KI obtained.');
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

-- format_time_short answers 'Ready' at zero, which reads badly as "N ago".
local function format_elapsed_short(seconds)
    if seconds < 60 then return 'moments'; end
    local days = math.floor(seconds / 86400);
    local hours = math.floor((seconds % 86400) / 3600);
    local minutes = math.floor((seconds % 3600) / 60);
    if days > 0 then return string.format('%dd %dh', days, hours); end
    if hours > 0 then return string.format('%dh %dm', hours, minutes); end
    return string.format('%dm', minutes);
end

function update_char_list()
    ui.char_list = {};
    ui.char_list_combo = nil;   -- rebuilt lazily below
    for char_name, _ in pairs(tracker.settings.characters) do
        if char_name ~= nil and char_name ~= '' and char_name ~= 'Unknown' then
            table.insert(ui.char_list, char_name);
        end
    end
    table.sort(ui.char_list);
    -- Keep whatever the player was looking at. Re-pointing at the logged-in
    -- character every time snapped the dropdown back off an alt whenever
    -- anything rebuilt the list.
    local keep = ui.selected_name;
    local target = nil;
    if keep ~= nil then
        for i, name in ipairs(ui.char_list) do
            if name == keep then target = i - 1; break; end
        end
    end
    if target == nil then
        for i, name in ipairs(ui.char_list) do
            if name == tracker.current_char then target = i - 1; break; end
        end
    end
    ui.selected_char[1] = target or 0;
    -- Clamp BEFORE deriving the name, or the two disagree whenever the list has
    -- shrunk. This function has produced two rounds of selection bugs already.
    if ui.selected_char[1] >= #ui.char_list then
        ui.selected_char[1] = math.max(0, #ui.char_list - 1);
    end
    ui.selected_name = ui.char_list[ui.selected_char[1] + 1];
end

local function factory_reset()
    -- Delete homework.json, plus the backup and any stray temp file. Without
    -- the .bak the reset is undone on the next load: if no fresh save follows
    -- (resetting while logged out writes none), load_settings finds no main
    -- file and restores everything from the backup.
    local settings_path = get_settings_path();
    if ashita.fs.exists(settings_path) then
        os.remove(settings_path);
    end
    os.remove(settings_path .. '.bak');
    os.remove(settings_path .. '.tmp');
    -- Delete display.json
    local display_path = get_display_settings_path();
    if ashita.fs.exists(display_path) then
        os.remove(display_path);
    end
    -- Reset in-memory state
    tracker.settings.characters = {};
    -- Accounts reference character names. Left behind, they get written straight
    -- back into the fresh save pointing at characters that no longer exist.
    tracker.settings.dynamis_accounts = {};
    tracker.settings.dynamis_account_wide = false;
    tracker.settings.chars_per_account = DEFAULT_CHARS_PER_ACCOUNT;
    ui.pending_account_add = nil;
    tracker.kis = {};
    tracker.kis_initialized = false;
    tracker.isnm_observed_since = nil;
    tracker.login_state.waiting_for_login = false;
    tracker.login_state.waiting_for_ki = false;
    tracker.login_state.ki_packets_received = 0;
    tracker.login_state.suppress_ki_events = false;
    tracker.pending_dynamis_claim = nil;
    tracker.last_denied_serial = nil;
    tracker.pending_reset = nil;
    tracker.uninvited_done_time = 0;
    tracker.login_state.suppress_started = 0;
    tracker.login_state.blocks_this_zone = 0;
    display_settings.tracked = {};
    ui.font_scale = 1.2;
    ui.render_failed = false;
    ui.char_list = {};
    ui.selected_char = { 0 };
    ui.selected_name = nil;
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

-- The tree connector in front of sub-rows (Carrying Tag, Cards): marks them
-- as belonging to the row above. If this renders as a broken box on some
-- client font, change it to '\\-' here and nowhere else.
local SUB_MARK = '\226\148\148\226\148\128';   -- corner + horizontal run, ends at the bracket

-- Fixed-bracket icons: '[' and ']' land on the same pixel columns in every
-- row and the symbol is centered between them, so alignment never depends on
-- how wide the font draws a space. Chat keeps plain strings - pixel
-- positioning only exists in imgui.
-- Text width on THIS client's font. CalcTextSize is documented by Ashita as
-- optionally not implemented, and users can override the ImGui font family
-- and size entirely - so when the function is missing, the width is taken by
-- MEASURING WITH THE RENDERER ITSELF: an invisible calibration pass draws the
-- string in fully transparent ink and reads how far the cursor moved. That is
-- the same engine that draws the visible text, so it cannot disagree with it.
-- Re-measured every frame - fonts can load a few frames after startup, and a
-- cached width from the wrong font was exactly the bug this replaces.
local MEASURE = { want = {}, w = {} };

local function icon_text_w(s)
    s = tostring(s);
    if imgui.CalcTextSize ~= nil then
        local a = imgui.CalcTextSize(s);
        if type(a) == 'table' and a.x ~= nil then return a.x; end
        if type(a) == 'number' then return a; end
    end
    MEASURE.want[s] = true;
    return MEASURE.w[s] or (#s * 9);   -- one-frame stand-in until measured
end

-- Runs at the top of the window each frame, only when CalcTextSize is absent.
local function run_measurements()
    if imgui.CalcTextSize ~= nil then return; end
    if imgui.GetCursorPosY == nil or imgui.SetCursorPosY == nil then return; end
    local sx, sy = imgui.GetCursorPosX(), imgui.GetCursorPosY();
    for s, _ in pairs(MEASURE.want) do
        imgui.SetCursorPosX(sx);
        imgui.SetCursorPosY(sy);
        local x0 = imgui.GetCursorPosX();
        imgui.TextColored({ 0.0, 0.0, 0.0, 0.0 }, s);
        imgui.SameLine(0, 0);
        MEASURE.w[s] = imgui.GetCursorPosX() - x0;
    end
    imgui.SetCursorPosX(sx);
    imgui.SetCursorPosY(sy);
end

local function draw_icon_box(sym, color)
    local icon_box_inner = icon_text_w('KI') + 4;
    local x0 = imgui.GetCursorPosX();
    imgui.TextColored(color, '[');
    imgui.SameLine(0, 0);
    if sym ~= nil and sym ~= '' then
        imgui.SetCursorPosX(x0 + icon_text_w('[') + (icon_box_inner - icon_text_w(sym)) / 2);
        imgui.TextColored(color, sym);
        imgui.SameLine(0, 0);
    end
    imgui.SetCursorPosX(x0 + icon_text_w('[') + icon_box_inner);
    imgui.TextColored(color, ']');
end

-- Route any row icon: bracketed strings become fixed boxes ('[ x ]' -> box
-- with centered x). Counts and other bare strings are centered under the same
-- footprint, so 2/3 sits under the box symbols instead of hugging the left.
local function draw_row_icon(icon, color)
    local inner = tostring(icon):match('^%[(.-)%]$');
    if inner ~= nil then
        draw_icon_box((inner:gsub('%s+', '')), color);
        return;
    end
    local icon_box_inner = icon_text_w('KI') + 4;
    local total = icon_text_w('[') * 2 + icon_box_inner;
    local x0 = imgui.GetCursorPosX();
    local w = icon_text_w(icon);
    if w < total then imgui.SetCursorPosX(x0 + (total - w) / 2); end
    imgui.TextColored(color, icon);
end

local function render_ui()
    if not ui.is_open[1] then return; end
    
    -- Get selected character data
    local char_name = ui.char_list[ui.selected_char[1] + 1] or tracker.current_char;
    local char_data = tracker.settings.characters[char_name];
    if char_data == nil then
        -- Fall back rather than drawing nothing: silently vanishing looks like a
        -- crash to anyone whose selected character was just removed.
        char_name = tracker.current_char;
        char_data = char_name and tracker.settings.characters[char_name] or nil;
        if char_data ~= nil then
            ui.selected_name = char_name;
            update_char_list();
        end
    end
    if char_data == nil then return; end
    
    local current_time = os.time();
    
    -- Window styling - minimal
    imgui.SetNextWindowSize({ 340, 400 }, ImGuiCond_FirstUseEver);
    ui.style_colors = 5; ui.style_vars = 2;
    imgui.PushStyleColor(ImGuiCol_WindowBg, { 0.0, 0.0, 0.0, 0.85 });
    imgui.PushStyleColor(ImGuiCol_TitleBg, { 0.0, 0.0, 0.0, 0.9 });
    imgui.PushStyleColor(ImGuiCol_TitleBgActive, { 0.0, 0.0, 0.0, 0.9 });
    imgui.PushStyleColor(ImGuiCol_FrameBg, { 0.1, 0.1, 0.1, 0.9 });
    imgui.PushStyleColor(ImGuiCol_Border, { 0.0, 0.0, 0.0, 0.0 });
    imgui.PushStyleVar(ImGuiStyleVar_WindowBorderSize, 0);
    imgui.PushStyleVar(ImGuiStyleVar_FrameBorderSize, 0);
    
    ui.began = true;
    if ui.window_flags == nil then
        ui.window_flags = ImGuiWindowFlags_NoCollapse or 0;
    end
    -- The resize grip (bottom-right triangle) is near-invisible on the dark
    -- theme; tint it the header orange so new users can find it. Guarded, in
    -- case this Ashita build lacks the style constants.
    local grip_pushed = 0;
    if imgui.PushStyleColor ~= nil and ImGuiCol_ResizeGrip ~= nil then
        imgui.PushStyleColor(ImGuiCol_ResizeGrip,        { 0.90, 0.45, 0.20, 0.80 });
        imgui.PushStyleColor(ImGuiCol_ResizeGripHovered, { 1.00, 0.60, 0.30, 1.00 });
        imgui.PushStyleColor(ImGuiCol_ResizeGripActive,  { 1.00, 0.72, 0.40, 1.00 });
        grip_pushed = 3;
    end
    if imgui.Begin('Homework v' .. addon.version, ui.is_open, ui.window_flags) then
        run_measurements();
        -- Only WindowBg/TitleBg/TitleBgActive are consumed by Begin itself, so
        -- FrameBg and Border must stay pushed to reach the combos and checkboxes
        -- inside. Popping all five here made two of them no-ops.
        imgui.PopStyleColor(3);
        imgui.PopStyleVar(2);
        ui.style_colors = 2; ui.style_vars = 0;
        
        -- Apply font scale (compatible with both old and new Ashita)
        local _useNewFont = (imgui.SetWindowFontScale == nil);
        if _useNewFont then
            local defaultFont = imgui.GetFont();
            local defaultSize = imgui.GetFontSize();
            imgui.PushFont(defaultFont, defaultSize * ui.font_scale);
            ui.fonts_pushed = 1;
        else
            imgui.SetWindowFontScale(ui.font_scale);
        end

        -- Tab bar
        if imgui.BeginTabBar('##homework_tabs', ImGuiTabBarFlags_None) then
            -- Tasks tab
            if imgui.BeginTabItem('Tasks') then
            -- Character dropdown + Reset timer on same line
            -- Cached: this ran twice a frame, once per tab, allocating a new
            -- string each time for a list that changes only on character switch.
            if ui.char_list_combo == nil then
                ui.char_list_combo = table.concat(ui.char_list, '\0') .. '\0';
            end
            local char_names = ui.char_list_combo;
            imgui.SetNextItemWidth(100 * ui.font_scale);
            if imgui.Combo('##char_select', ui.selected_char, char_names) then
                char_name = ui.char_list[ui.selected_char[1] + 1];
                ui.selected_name = char_name;
                char_data = tracker.settings.characters[char_name];
            end

            local next_reset = calculate_next_reset(current_time);
            local reset_seconds = next_reset - current_time;
            imgui.SameLine();
            imgui.Text('Reset: ' .. format_time_short(reset_seconds));

            imgui.Spacing();

        -- Weeklies header
        draw_gradient_header('Weeklies', imgui.GetContentRegionAvail(), '[o] ready / go here    [x] done this week\n[ ] still to do        [?] unknown - /hw scan\nCounts are remaining/max. Status shows a place or what to do next.');

        -- Column positions scaled with font
        -- Columns derive from the font's own measurements, so every
        -- resolution and font size lands the same layout: the name column
        -- always clears the icon box by one letter-width, whatever the box
        -- measures on this machine. Hardcoded pixels broke on other screens.
        local em = icon_text_w('M');
        local box_total = icon_text_w('[') * 2 + icon_text_w('KI') + 4;
        -- The icons start at the window's left padding, not at zero. Columns
        -- must include it, or the one-letter gap silently shrinks by the
        -- padding - which at small font scales meant NO gap at all.
        local base = imgui.GetCursorPosX();
        local col_task = base + box_total + em;
        local col_location = col_task + 13 * em;

        -- Get tracking settings for current character
        local tracking = get_char_tracking(char_name);

        -- Dynamis entry counter (displayed above EcoWarrior)
        local dyn_store, dyn_shared = get_dynamis_store(char_name);
        if dyn_store and tracking.tasks[DYNAMIS_ROW_LABEL] ~= false then
            local entries, dyn_char_left, dyn_acct_left = dynamis_effective_remaining(char_name);
            if not dyn_shared then entries = dyn_store.entries_remaining or CHARACTER_ENTRY_LIMIT; end
            -- Counts render as n/max WITHOUT brackets. Bracketed digits were
            -- indistinguishable from the [o] used for a ready task in the game's
            -- font, so square brackets now always mean status and a bare
            -- fraction always means a count. The cap comes along for free.
            -- Always the character's own cap. `entries` is the LOWER of the
            -- character and account figures, so pairing it with the account cap
            -- read as "1/3" for someone who can only ever do 2. The account
            -- total is already shown in the column beside this.
            local dyn_max = CHARACTER_ENTRY_LIMIT;
            local dyn_known = (dyn_store.known ~= false);
            local dyn_icon, dyn_color;
            if not dyn_known then
                dyn_icon = '[?]'; dyn_color = { 1.0, 1.0, 0.0, 1.0 };
            else
                dyn_icon = string.format('%d/%d', entries, dyn_max);
                if entries == 0 then
                    dyn_color = { 1.0, 0.3, 0.3, 1.0 };  -- Red
                elseif entries == 1 then
                    dyn_color = { 1.0, 1.0, 0.0, 1.0 };  -- Yellow
                else
                    dyn_color = { 0.0, 1.0, 0.0, 1.0 };  -- Green
                end
            end
            draw_row_icon(dyn_icon, dyn_color);
            imgui.SameLine();
            imgui.SetCursorPosX(col_task);
            imgui.Text('Dynamis');
            -- Always print the number when grouped. Hiding it whenever the
            -- personal and account figures happened to match meant it appeared
            -- on one character and vanished on another for no visible reason,
            -- which reads as the addon failing to track the account.
            local dyn_note = '';
            if not dyn_known then
                dyn_note = '(unknown until reset)';
            elseif dyn_shared and dyn_acct_left ~= nil then
                dyn_note = string.format('(account: %d/%d)', dyn_acct_left, ACCOUNT_ENTRY_LIMIT);
            end
            -- SameLine only when something actually follows. Calling it and then
            -- printing nothing left the cursor parked mid-row, so the NEXT row
            -- drew on top of this one - which is why an ungrouped character (no
            -- account text) saw Dynamis and Limbus overlapping.
            if dyn_note ~= '' then
                imgui.SameLine();
                imgui.SetCursorPosX(col_location);
                imgui.TextColored({ 0.6, 0.8, 1.0, 1.0 }, dyn_note);
            end
        end

        -- Limbus lost its 71h Cosmo-Cleanse cooldown, so it is a weekly now
        -- rather than a timer. The cards move up with it.
        if tracking.tasks[LIMBUS_ROW_LABEL] ~= false then
            local has_cosmo = ki_held(char_name, LIMBUS_KI_ID);
            local eff, char_left, acct_left, known = limbus_state(char_name);
            local l_icon, l_color, l_where, l_where_color;

            local l_max = LIMBUS_CHARACTER_LIMIT;
            if eff == nil then
                l_icon = '[?]'; l_color = { 1.0, 1.0, 0.0, 1.0 };
            elseif not known then
                -- Counting, but the addon never saw the start of this week.
                l_icon = string.format('?/%d', l_max); l_color = { 1.0, 1.0, 0.0, 1.0 };
            elseif eff <= 0 then
                l_icon = string.format('%d/%d', eff, l_max); l_color = { 1.0, 0.3, 0.3, 1.0 };
            else
                l_icon = string.format('%d/%d', eff, l_max); l_color = { 0.0, 1.0, 0.0, 1.0 };
            end

            -- Holding a cleanse means the next step is the zone, not the NPC.
            -- Zone name abbreviated so the account figure below still fits the
            -- column at the default window width.
            local l_dest;
            if has_cosmo then
                l_dest = 'Apollyon/Tem';
                l_where_color = { 0.0, 1.0, 0.0, 1.0 };
            elseif eff ~= nil and known and eff <= 0 then
                l_dest = LIMBUS_NPC;
                l_where_color = { 1.0, 0.3, 0.3, 1.0 };
            else
                l_dest = LIMBUS_NPC;
                l_where_color = (eff ~= nil and known)
                    and { 0.0, 1.0, 0.0, 1.0 } or { 1.0, 1.0, 0.0, 1.0 };
            end
            -- The account total lived only in the hover tooltip, so there was no
            -- way to see the 4-per-account cap at a glance the way Dynamis shows
            -- its 3. When the week is still unknown the account figure is just as
            -- untrustworthy as the personal one, so it shows ? too.
            local l_shared = select(5, limbus_state(char_name));
            if l_shared and acct_left ~= nil then
                l_where = string.format('(%s - %s/%d)', l_dest,
                    known and tostring(acct_left) or '?', LIMBUS_ACCOUNT_LIMIT);
            else
                l_where = '(' .. l_dest .. ')';
            end

            draw_row_icon(l_icon, l_color);
            imgui.SameLine();
            imgui.SetCursorPosX(col_task);
            imgui.Text(LIMBUS_ROW_LABEL);
            imgui.SameLine();
            imgui.SetCursorPosX(col_location);
            imgui.TextColored(l_where_color, l_where);

            local l_help;
            if eff == nil then
                l_help = 'No data for this character yet.';
            else
                l_help = string.format('%d run%s left for this character (max %d)',
                    char_left, char_left == 1 and '' or 's', LIMBUS_CHARACTER_LIMIT);
                if acct_left ~= nil then
                    l_help = l_help .. string.format('\n%d left on the account (max %d)',
                        acct_left, LIMBUS_ACCOUNT_LIMIT);
                end
                if not known then
                    l_help = l_help .. '\n\n[?] = the addon was installed mid-week and cannot know'
                          .. '\nwhat you already took. Correct it in Settings, or it will'
                          .. '\nsort itself out at the next weekly reset.';
                end
                l_help = l_help .. (has_cosmo
                    and '\n\nYou hold a Cosmo-Cleanse - head to Apollyon or Temenos.'
                    or  ('\n\nTake a Cosmo-Cleanse from ' .. LIMBUS_NPC .. ' in Lower Jeuno.'));
                l_help = l_help .. '\nA cleanse kept across the reset does not cost a run.';
            end
            help_marker(l_help);

            local card_indent = 20 * ui.font_scale;
            local card_col_name = col_task + card_indent;
            local held_short, held_full, missing = {}, {}, {};
            for _, card in ipairs(LIMBUS_CARDS) do
                if ki_held(char_name, card.ki_id) then
                    -- 'White Card' -> 'White', so all three still fit the column
                    table.insert(held_short, (card.name:gsub(' Card$', '')));
                    table.insert(held_full, card.name .. ' - ' .. card.location);
                else
                    table.insert(missing, card.name);
                end
            end

            -- Column system, same as the mains (see the assault sub-row).
            local card_icon_x = card_indent + icon_text_w(SUB_MARK) + em;
            imgui.SetCursorPosX(card_icon_x - icon_text_w(SUB_MARK));
            imgui.TextColored({ 0.55, 0.55, 0.55, 1.0 }, SUB_MARK);
            imgui.SameLine();
            imgui.SetCursorPosX(card_icon_x);
            if #held_short > 0 then
                draw_icon_box('KI', { 0.0, 1.0, 0.0, 1.0 });
            else
                draw_icon_box('', { 0.55, 0.55, 0.55, 1.0 });
            end
            imgui.SameLine();
            imgui.SetCursorPosX(card_icon_x + box_total + em);
            imgui.TextColored({ 1.0, 1.0, 1.0, 1.0 },
                string.format('Cards %d/%d', #held_short, #LIMBUS_CARDS));
            if #held_short > 0 then
                imgui.SameLine();
                imgui.SetCursorPosX(col_location);
                imgui.TextColored({ 0.0, 1.0, 0.0, 1.0 }, table.concat(held_short, ', '));
            end

            -- Held cards with where they came from, then the ones still to find
            -- with where to look. Listing a missing card twice, once by name and
            -- again with its location, just made the tooltip longer.
            local need_full = {};
            for _, card in ipairs(LIMBUS_CARDS) do
                if not ki_held(char_name, card.ki_id) then
                    table.insert(need_full, card.name .. ' - ' .. card.location);
                end
            end
            local card_help = '';
            if #held_full > 0 then
                card_help = 'Holding:\n  ' .. table.concat(held_full, '\n  ');
            end
            if #need_full > 0 then
                if card_help ~= '' then card_help = card_help .. '\n\n'; end
                card_help = card_help .. 'Still needed:\n  ' .. table.concat(need_full, '\n  ');
            end
            help_marker(card_help);
        end

        -- X'sKnife lives under Limbus (both are the week's battlefields), out
        -- of the generic task loop so its position is fixed.
        if tracking.tasks["X'sKnife"] ~= false and tracker.settings.tasks ~= nil then
            local k_in_list = false;
            for _, t in ipairs(tracker.settings.tasks) do
                if normalize_task(t) == 'xsknife' then k_in_list = true; break; end
            end
            if k_in_list then
                local step = char_data.xsknife_data and char_data.xsknife_data.step or 'unknown';
                local icon, color, location = '[?]', { 1.0, 1.0, 0.0, 1.0 }, '';
                local help_text = nil;
                if step == 'done' then icon = '[x]'; color = { 0.55, 0.55, 0.55, 1.0 };
                elseif step == 'boneyard' then icon = '1/2'; color = { 0.0, 1.0, 0.0, 1.0 }; location = 'Boneyard Gully';
                elseif step == 'boneyard_2x' then icon = '2/2'; color = { 0.0, 1.0, 0.0, 1.0 }; location = 'Boneyard Gully';
                elseif step == 'despachiaire' then icon = '1/2'; color = { 0.0, 1.0, 0.0, 1.0 }; location = 'Despachiaire';
                elseif step == 'scanned_no_ki' then
                    icon = '?/2'; color = { 1.0, 1.0, 0.0, 1.0 };
                    help_text = "Fights left this week unknown. Resolves at next tally or when KI obtained.\n/hw knife to toggle.";
                elseif step == 'scanned_has_ki' then
                    icon = '?/2'; color = { 1.0, 1.0, 0.0, 1.0 }; location = 'Boneyard Gully';
                    help_text = "KI in hand; unknown if Despachiaire has another. Resolves at next tally or when KI obtained.\n/hw knife to toggle.";
                elseif step == 'scanned_has_ki_used' then
                    icon = '?/2'; color = { 1.0, 1.0, 0.0, 1.0 }; location = 'Despachiaire';
                    help_text = "Unknown if Despachiaire has KI. Resolves at next tally or when KI obtained.\n/hw knife to toggle.";
                else
                    help_text = "Use /hw scan or talk to Despachiaire.\n/hw knife to toggle.";
                end
                imgui.BeginGroup();
                draw_row_icon(icon, color);
                imgui.SameLine();
                imgui.SetCursorPosX(col_task);
                imgui.Text("X'sKnife");
                if location ~= '' then
                    imgui.SameLine();
                    imgui.SetCursorPosX(col_location);
                    imgui.TextColored({ 0.0, 1.0, 0.0, 1.0 }, '(' .. location .. ')');
                end
                imgui.EndGroup();
                if help_text then help_marker(help_text); end
            end
        end

        -- The Ashu Talif chain: count = fights left this week, the status is
        -- always the one thing to do next. A stage paid before the tally
        -- survives it, so a fresh week can open already at "fight!".
        if tracking.tasks[ASHU.ROW_LABEL] ~= false then
            local aa_icon, aa_key, aa_status = ASHU.describe(char_data);
            local aa_color = (aa_key == 'green') and { 0.0, 1.0, 0.0, 1.0 }
                          or (aa_key == 'grey') and { 0.55, 0.55, 0.55, 1.0 }
                          or { 1.0, 1.0, 0.0, 1.0 };
            imgui.BeginGroup();
            draw_row_icon(aa_icon, aa_color);
            imgui.SameLine();
            imgui.SetCursorPosX(col_task);
            imgui.Text('Ashu Talif');
            imgui.SameLine();
            imgui.SetCursorPosX(col_location);
            imgui.TextColored({ 0.0, 1.0, 0.0, 1.0 }, '(' .. aa_status .. ')');
            imgui.EndGroup();
            help_marker('Three weekly fights from Halshaob in Nashmau, in order:\n'
                .. 'Scouting (3 bronze) > Painter (1 silver) > Captain (1 mythril).\n'
                .. 'Win to unlock the next. Losing or crashing burns the chain\n'
                .. 'until the weekly reset. A stage paid before the reset is not\n'
                .. 'lost - it can be fought after.\n\n'
                .. 'Fresh install shows [?] until the addon sees a real event:\n'
                .. 'paying Halshaob syncs it instantly, and after one weekly\n'
                .. 'reset it is always known.');
        end

        for _, task in ipairs(tracker.settings.tasks) do
            -- Skip if not tracked for this character
            if not tracking.tasks[task] then
                goto continue_task;
            end

            local normalized = normalize_task(task);
            -- X'sKnife renders in its own block under Limbus, not here.
            if normalized == 'xsknife' then goto continue_task; end
            local icon, color, location = '[?]', { 1.0, 1.0, 0.0, 1.0 }, '';
            local help_text = nil;  -- Help marker text for this specific task

            if false then -- (X'sKnife moved to its own block under Limbus)
            elseif normalized == 'highwind' then
                local step = char_data.quest_steps and char_data.quest_steps.highwind or 'scanned';
                if step == 'done' then icon = '[x]'; color = { 0.55, 0.55, 0.55, 1.0 };
                elseif step == 'start' then icon = '[o]'; color = { 0.0, 1.0, 0.0, 1.0 }; location = 'Airship NM';
                else
                    icon = '[ ]'; color = { 1.0, 1.0, 0.0, 1.0 };
                    help_text = "Unknown progress. Resolves at next tally.\n/hw high to toggle.";
                end
            elseif normalized == 'uninvited' then
                local step = char_data.quest_steps and char_data.quest_steps.uninvited or 'unknown';
                if step == 'done' then icon = '[x]'; color = { 0.55, 0.55, 0.55, 1.0 };
                elseif step == 'justinius' then icon = '[o]'; color = { 0.0, 1.0, 0.0, 1.0 }; location = 'Justinius - Start';
                elseif step == 'bcnm' then icon = '[o]'; color = { 0.0, 1.0, 0.0, 1.0 }; location = 'BCNM Monarch';
                elseif step == 'justinius_return' then icon = '[o]'; color = { 0.0, 1.0, 0.0, 1.0 }; location = 'Justinius - Reward';
                elseif step == 'scanned' then
                    icon = '[ ]'; color = { 1.0, 1.0, 0.0, 1.0 };
                    help_text = "Unknown progress. Resolves at next tally.\n/hw uninvited to toggle.";
                else
                    icon = '[?]'; color = { 1.0, 1.0, 0.0, 1.0 };
                    help_text = "Use /hw scan to detect progress.\n/hw uninvited to toggle.";
                end
            elseif normalized == 'spicegals' then
                local step = char_data.quest_steps and char_data.quest_steps.spicegals or 'unknown';
                if step == 'done' then icon = '[x]'; color = { 0.55, 0.55, 0.55, 1.0 };
                elseif step == 'rouva' then icon = '[o]'; color = { 0.0, 1.0, 0.0, 1.0 }; location = 'Rouva - Start';
                elseif step == 'riverne' then icon = '[o]'; color = { 0.0, 1.0, 0.0, 1.0 }; location = 'Riverne B';
                elseif step == 'rouva_return' then icon = '[o]'; color = { 0.0, 1.0, 0.0, 1.0 }; location = 'Rouva - Reward';
                elseif step == 'scanned' then
                    icon = '[ ]'; color = { 1.0, 1.0, 0.0, 1.0 };
                    help_text = "Unknown progress. Resolves at next tally.\n/hw spice to toggle.";
                else
                    icon = '[?]'; color = { 1.0, 1.0, 0.0, 1.0 };
                    help_text = "Use /hw scan to detect progress.\n/hw spice to toggle.";
                end
            elseif normalized == 'cookbook' then
                local step = char_data.quest_steps and char_data.quest_steps.cookbook or 'unknown';
                if step == 'done' then icon = '[x]'; color = { 0.55, 0.55, 0.55, 1.0 };
                elseif step == 'jonette' then icon = '[o]'; color = { 0.0, 1.0, 0.0, 1.0 }; location = 'Jonette - Start';
                elseif step == 'sacrarium' then icon = '[o]'; color = { 0.0, 1.0, 0.0, 1.0 }; location = 'Sacrarium';
                elseif step == 'jonette_return' then icon = '[o]'; color = { 0.0, 1.0, 0.0, 1.0 }; location = 'Jonette - Reward';
                elseif step == 'scanned' then
                    icon = '[ ]'; color = { 1.0, 1.0, 0.0, 1.0 };
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
                    icon = '[x]'; color = { 0.55, 0.55, 0.55, 1.0 };
                    location = available_text;
                elseif step == 'ready' then
                    -- Known ready state
                    icon = '[o]'; color = { 0.0, 1.0, 0.0, 1.0 };
                    location = available_text;
                elseif step == 'scanned' then
                    -- Scanned but uncertain if done - YELLOW
                    icon = '[ ]'; color = { 1.0, 1.0, 0.0, 1.0 };
                    location = available_text;
                    help_text = "Unknown if completed. Resolves at next tally or quest interaction.";
                elseif step == 'scanned_has_ki' then
                    -- Has KI but locked nations unknown - YELLOW
                    icon = '[ ]'; color = { 1.0, 1.0, 0.0, 1.0 };
                    local nation = eco_data.current_nation;
                    if nation then
                        local zone_info = ECOWARRIOR_ZONES[nation];
                        if zone_info then location = zone_info.short_zone .. ' - ' .. zone_info.short_agent; end
                    end
                    help_text = "Has KI but locked nations unknown. Use /hw eco or talk to Eeko-Weeko.";
                elseif step == 'field_agent' or step == 'nm' or step == 'field_agent_return' or step == 'reward' then
                    -- In progress - color depends on knows_status
                    if knows then
                        icon = '[o]'; color = { 0.0, 1.0, 0.0, 1.0 };
                    else
                        icon = '[ ]'; color = { 1.0, 1.0, 0.0, 1.0 };
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
            draw_row_icon(icon, color);
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
        draw_gradient_header('Timers', imgui.GetContentRegionAvail(), '[KI] in your bag - fight open    [    ] ready, KI not taken\n[ x ] on cooldown    [ ? ] unknown - /hw scan\nCounts are remaining/max. Status shows a time or what to do next.');

        -- Timer column positions scaled with font
        local em = icon_text_w('M');
        local box_total = icon_text_w('[') * 2 + icon_text_w('KI') + 4;
        local base = imgui.GetCursorPosX();   -- window padding: see Weeklies
        local timer_col_name = base + box_total + em;
        local timer_col_status = timer_col_name + 23 * em;

        -- Assault tags belong here, not in Weeklies: they refill on a rolling
        -- 24 hour clock rather than resetting with the week.
        if tracking.timers[ASSAULT_ROW_LABEL] ~= false then
            local carried = assault_holding_tag(char_name);
            local stored, next_tag, max_stock = assault_state(char_data, char_name);
            -- Rank, points and the current mission stay personal; only the stock
            -- and its clock come from the pool.
            local ad_r = char_data.assault_data or {};
            local a_pool = get_assault_store(char_name) or ad_r;
            local a_icon, a_color, a_status, a_help;

            if stored == nil then
                a_icon = '[?]'; a_color = { 1.0, 1.0, 0.0, 1.0 };
                a_status = 'see Rytaal';
                a_help = 'Talk to Rytaal once and the tag count will appear.\n'
                      .. 'Carrying a tag: ' .. (carried and 'yes' or 'no');
            else
                a_icon = string.format('%d/%d', stored, max_stock);
                if stored == 0 then a_color = { 1.0, 0.3, 0.3, 1.0 };
                elseif stored == 1 then a_color = { 1.0, 1.0, 0.0, 1.0 };
                else a_color = { 0.0, 1.0, 0.0, 1.0 }; end
                -- Key off the stock. Reading "full" from next_tag == 0 showed a
                -- partly-filled pool as full whenever the clock was missing.
                if stored >= max_stock then
                    a_status = nil;   -- 3/3 already says full
                elseif next_tag > 0 then
                    a_status = format_time_short(next_tag - current_time);
                else
                    a_status = 'see Rytaal';   -- partial stock, no clock on record
                end
                local ago = current_time - (a_pool.checked_at or 0);
                a_help = string.format(
                    'Waiting at Rytaal: %d / %d\nCarrying: %d      Total usable: %d\n%s\n'
                 .. 'Last checked with Rytaal %s ago.\n'
                 .. 'Counts refresh whenever you open Rytaal\'s menu.',
                    stored, max_stock, carried and 1 or 0, stored + (carried and 1 or 0),
                    (stored >= max_stock)
                        and 'Stock is full - no clock running.'
                        or (next_tag > 0
                            and ('Next tag in ' .. format_time_short(next_tag - current_time))
                            or  'No restock clock recorded - open Rytaal\'s menu to set it.'),
                    format_elapsed_short(ago));
            end
            if ad_r.rank then
                a_help = a_help .. '\nRank: ' .. (MERCENARY_RANKS[ad_r.rank] or '?');
            end
            if type(ad_r.points) == 'table' then
                local plist = {};
                for aname, pv in pairs(ad_r.points) do
                    table.insert(plist, string.format('%s %d', aname, pv));
                end
                table.sort(plist);
                if #plist > 0 then a_help = a_help .. '\nPoints: ' .. table.concat(plist, ', '); end
            end

            draw_row_icon(a_icon, a_color);
            imgui.SameLine();
            imgui.SetCursorPosX(timer_col_name);
            imgui.Text(ASSAULT_ROW_SHORT);
            if a_status ~= nil then
                imgui.SameLine();
                imgui.SetCursorPosX(timer_col_status);
                imgui.TextColored({ 0.4, 0.7, 0.9, 1.0 }, '(' .. a_status .. ')');
            end
            if a_help then help_marker(a_help); end

            -- One sub-row, not two. A tag becomes orders the moment you pick a
            -- mission, so you can never hold both - two lines meant one was
            -- always empty.
            local area = assault_active_area(char_name);
            local sub_indent = 20 * ui.font_scale;
            local sub_col_name = timer_col_name + sub_indent;
            local rank_name = ad_r.rank and MERCENARY_RANKS[ad_r.rank] or nil;

            -- Sub-rows flow inline: plain [KI] and one normal space, no fixed
            -- columns - they are annotations, not table rows.
            -- Column system, same as the mains: the icon sits at a fixed
            -- position, the name sits at a fixed position one letter-width
            -- after the icon box. Scales with the font like everything else.
            -- The corner glyph hugs the bracket: drawn so its right edge
            -- lands exactly where the '[' begins. The bracket itself stays put.
            local sub_icon_x = sub_indent + icon_text_w(SUB_MARK) + em;
            imgui.SetCursorPosX(sub_icon_x - icon_text_w(SUB_MARK));
            imgui.TextColored({ 0.55, 0.55, 0.55, 1.0 }, SUB_MARK);
            imgui.SameLine();
            imgui.SetCursorPosX(sub_icon_x);
            if area ~= nil or carried then
                draw_icon_box('KI', { 0.0, 1.0, 0.0, 1.0 });
            else
                draw_icon_box('', { 0.55, 0.55, 0.55, 1.0 });
            end
            imgui.SameLine();
            imgui.SetCursorPosX(sub_icon_x + box_total + em);
            imgui.TextColored({ 1.0, 1.0, 1.0, 1.0 },
                area or (carried and 'Carrying Tag' or 'No Tag'));
            if area ~= nil and rank_name ~= nil then
                imgui.SameLine();
                imgui.SetCursorPosX(timer_col_status);
                imgui.TextColored({ 0.4, 0.7, 0.9, 1.0 },
                    '(' .. (MERCENARY_RANKS_SHORT[ad_r.rank] or '?') .. ')');
            end
            local pts = (area and type(ad_r.points) == 'table') and ad_r.points[area] or nil;
            help_marker((area
                    and ('On assault: ' .. (ASSAULT_AREA_FULL[area] or area)
                         .. '\nOrders go back to Rytaal when you finish.')
                    or  (carried
                        and 'You are carrying an Imperial Army I.D. Tag.\nTrade it to a mission giver to start an assault.'
                        or  'No tag and no assault. Pick a tag up from Rytaal.'))
                .. (rank_name and ('\nRank: ' .. rank_name) or
                    '\nRank shows after you talk to a mission giver.')
                .. (pts and ('\nAssault points here: ' .. pts) or ''));
        end

        -- ISNM: one line. Icon answers "am I holding an order" (ready to
        -- fight); the status is Shajaf's buy clock. Personal and daily - the
        -- weekly reset never touches it.
        if tracking.timers[ISNM_ROW_LABEL] ~= false then
            local cd_i = tracker.settings.characters[char_name];
            resolve_isnm_unknown(cd_i, char_name);
            local isnm = cd_i and cd_i.isnm_data or nil;
            local held = isnm_held_ki(char_name);
            local now = os.time();
            local nbt = isnm and isnm.next_buy_time or nil;
            local name = (held == ISNM_SECRET_KI and 'ISNM: 3000 held')
                      or (held == ISNM_CONFIDENTIAL_KI and 'ISNM: 2000 held')
                      or 'ISNM';
            local icon, icolor, status;
            if isnm ~= nil and isnm.no_badge then
                icon, icolor, status = '[ ]', { 0.55, 0.55, 0.55, 1.0 }, 'need badge';
            else
                if nbt == nil then status = 'see Shajaf';
                elseif now >= nbt then status = 'Ready';
                else status = format_time_short(nbt - now); end
                if held ~= nil then
                    icon, icolor = '[KI]', { 0.0, 1.0, 0.0, 1.0 };     -- order in the bag
                elseif nbt == nil then
                    icon, icolor = '[?]', { 1.0, 1.0, 0.0, 1.0 };      -- first launch: unknown
                elseif now >= nbt then
                    icon, icolor = '[ ]', { 0.0, 1.0, 0.0, 1.0 };      -- shop open: go get it
                else
                    icon, icolor = '[x]', { 0.55, 0.55, 0.55, 1.0 };
                end
            end
            draw_row_icon(icon, icolor);
            imgui.SameLine();
            imgui.SetCursorPosX(timer_col_name);
            imgui.Text(name);
            imgui.SameLine();
            imgui.SetCursorPosX(timer_col_status);
            imgui.TextColored({ 0.4, 0.7, 0.9, 1.0 }, '(' .. status .. ')');
            help_marker('Imperial Standing NM. Buy an order from Shajaf in Whitegate:'
                .. '\nConfidential (2000) for the level 60 fights, Secret (3000)'
                .. '\nfor the uncapped ones. One purchase per day, resetting at'
                .. '\nJapanese midnight. The order never expires: hold it across'
                .. '\nthe reset and you can fight twice back to back. Only the'
                .. '\nplayer who opens the fight spends their order.');
        end

        for _, enm in ipairs(ENM_KEY_ITEMS) do
            -- Skip if not tracked for this character
            if not tracking.timers[enm.name] then
                goto continue_timer;
            end

            local timer_data = char_data.enm_timers and char_data.enm_timers[enm.name];
            local icon, icon_color, status_text;
            local timer_help_text = nil;
            
            -- Icons: [KI] green = the key item is in the bag (fight open),
            -- [    ] green = fight open but the KI not taken yet,
            -- [ x ] grey = waiting on the clock, [ ? ] yellow = unknown.
            -- [KI] is always green and only ever means "in the bag" - color
            -- never changes its meaning.
            if timer_data == nil then
                icon = '[ ? ]'; icon_color = { 1.0, 1.0, 0.0, 1.0 };
                status_text = '/hw scan';
                timer_help_text = "Use /hw scan to detect timers.";
            elseif timer_data.next_ki_time == nil or timer_data.next_ki_time == 0 then
                -- Have timer_data but no time set
                if timer_data.has_ki then
                    icon = '[KI]'; icon_color = { 0.0, 1.0, 0.0, 1.0 };
                    status_text = 'Ready';
                    timer_help_text = "KI in hand - fight open. Next-KI timer unknown; updates when KI obtained.";
                else
                    icon = '[ ? ]'; icon_color = { 1.0, 1.0, 0.0, 1.0 };
                    status_text = 'Unknown';
                    timer_help_text = "No KI. Timer unknown. Updates when KI obtained.";
                end
            else
                local remaining = timer_data.next_ki_time - current_time;

                if remaining <= 0 then
                    -- Timer expired = Ready
                    if timer_data.has_ki then
                        icon = '[KI]'; icon_color = { 0.0, 1.0, 0.0, 1.0 };
                        timer_help_text = "KI in hand - fight open.";
                    else
                        icon = '[    ]'; icon_color = { 0.0, 1.0, 0.0, 1.0 };
                    end
                    status_text = 'Ready';
                elseif timer_data.timer_source == 'scan' then
                    -- Scan-based timer: the clock is an estimate
                    if timer_data.has_ki then
                        icon = '[KI]'; icon_color = { 0.0, 1.0, 0.0, 1.0 };
                        status_text = 'Ready';
                        timer_help_text = "KI in hand - fight open. Next-KI timer unknown; updates when KI obtained.";
                    else
                        icon = '[ ? ]'; icon_color = { 1.0, 1.0, 0.0, 1.0 };
                        status_text = 'Unknown';
                        timer_help_text = "No KI. Timer unknown. Updates when KI obtained.";
                    end
                else
                    -- Real timer counting down
                    if timer_data.has_ki then
                        icon = '[KI]'; icon_color = { 0.0, 1.0, 0.0, 1.0 };
                        timer_help_text = "KI in hand - fight open. The countdown is for the NEXT KI.";
                    else
                        icon = '[ x ]'; icon_color = { 0.55, 0.55, 0.55, 1.0 };
                    end
                    status_text = format_time_short(remaining);
                end
            end
            
            -- Render with column alignment
            draw_row_icon(icon, icon_color);
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
                    ui.font_scale = math.floor((ui.font_scale - 0.1) * 10 + 0.5) / 10;
                    save_display_settings();
                end
                imgui.SameLine();
                imgui.Text(string.format('%.1f', ui.font_scale));
                imgui.SameLine();
                if imgui.SmallButton('+##font') and ui.font_scale < 2.0 then
                    ui.font_scale = math.floor((ui.font_scale + 0.1) * 10 + 0.5) / 10;
                    save_display_settings();
                end

                imgui.Spacing();
                imgui.Spacing();

                draw_gradient_header('Account Sharing', imgui.GetContentRegionAvail(),
                    'Horizon counts some things per account, not per character:\nDynamis entries, Limbus runs, and Rytaal\'s assault tag stock.\nGroup the characters that share one account. Characters left\nout of every account just keep their own private counts.');

                local aw = { tracker.settings.dynamis_account_wide == true };
                if imgui.Checkbox('Horizon: account-wide counters (Dynamis / Limbus / Assault)', aw) then
                    tracker.settings.dynamis_account_wide = aw[1];
                    ui.pending_account_add = nil;
                    -- Turning sharing off is an exit path too.
                    if not aw[1] then
                        for _, acct in ipairs(dynamis_accounts()) do
                            for _, cname in ipairs(acct.chars or {}) do
                                inherit_assault_from_pool(acct, cname);
                            end
                        end
                    end
                    -- Pools can be stale from a previous session; turning sharing
                    -- back on has to re-derive them rather than trust old numbers.
                    if aw[1] then
                        for _, acct in ipairs(dynamis_accounts()) do
                            recalc_account_from_members(acct);
                        end
                    end
                    save_settings();
                end

                if tracker.settings.dynamis_account_wide then
                    local accts = dynamis_accounts();
                    local limit = chars_per_account();
                    imgui.TextColored({ 0.7, 0.7, 0.7, 1.0 },
                        string.format('%d entries per account, %d per character.',
                            ACCOUNT_ENTRY_LIMIT, CHARACTER_ENTRY_LIMIT));

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
                if ui.char_list_combo == nil then
                    ui.char_list_combo = table.concat(ui.char_list, '\0') .. '\0';
                end
                local char_names = ui.char_list_combo;
                imgui.SetNextItemWidth(150 * ui.font_scale);
                if imgui.Combo('##settings_char_select', ui.selected_char, char_names) then
                    ui.selected_name = ui.char_list[ui.selected_char[1] + 1];
                end

                local settings_char = ui.char_list[ui.selected_char[1] + 1];
                if settings_char then
                    local tracking = get_char_tracking(settings_char);

                    imgui.Spacing();
                    imgui.TextColored({ 0.7, 0.7, 0.7, 1.0 }, 'Weekly Tasks:');
                    imgui.Spacing();

                    -- Dynamis is not one of tracker.settings.tasks, but it has a
                    -- row in the Weeklies list so it gets its own toggle.
                    imgui.Indent(2);
                    for _, label in ipairs({ DYNAMIS_ROW_LABEL, LIMBUS_ROW_LABEL, ASHU.ROW_LABEL }) do
                        local box = { tracking.tasks[label] ~= false };
                        if imgui.Checkbox(label, box) then
                            tracking.tasks[label] = box[1];
                            save_display_settings();
                        end
                    end
                    imgui.Unindent(2);

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
                    
                    -- Dynamis Run Count manual override. An account can hold 3,
                    -- a character only ever 2, so the button row adapts.
                    local set_store, set_shared = get_dynamis_store(settings_char);
                    if set_store then
                        local max_runs = set_shared and ACCOUNT_ENTRY_LIMIT or CHARACTER_ENTRY_LIMIT;
                        imgui.TextColored({ 0.7, 0.7, 0.7, 1.0 },
                            'Dynamis Run Count:' .. (set_shared and '  (account pool)' or ''));
                        local entries = set_store.entries_remaining or max_runs;
                        imgui.Indent(2);
                        for n = 0, max_runs do
                            if n > 0 then imgui.SameLine(); end
                            local lbl = (n == 1) and '1 Run' or (tostring(n) .. ' Runs');
                            if imgui.RadioButton(lbl, entries == n) then
                                set_store.entries_remaining = n;
                                set_store.known = true;   -- hand-set beats "unknown"
                                -- keep the character's own record known too when
                                -- editing a pool, so the row never falls back to [?]
                                local cd_k = tracker.settings.characters[settings_char];
                                if cd_k and cd_k.dynamis_data then cd_k.dynamis_data.known = true; end
                                -- Mark it hand-set. The load handler re-derives
                                -- pools from member usage, which silently undid
                                -- this on the next reload.
                                if set_shared then set_store.manual_override = true; end
                                save_settings();
                            end
                        end
                        imgui.Unindent(2);

                        if set_shared then
                            local cd_sel = tracker.settings.characters[settings_char];
                            if cd_sel and cd_sel.dynamis_data then
                                imgui.TextColored({ 0.7, 0.7, 0.7, 1.0 }, 'This character\'s own limit:');
                                local own = cd_sel.dynamis_data.entries_remaining or CHARACTER_ENTRY_LIMIT;
                                imgui.Indent(2);
                                for n = 0, CHARACTER_ENTRY_LIMIT do
                                    if n > 0 then imgui.SameLine(); end
                                    local lbl = (n == 1) and '1 Run##own' or (tostring(n) .. ' Runs##own');
                                    if imgui.RadioButton(lbl, own == n) then
                                        cd_sel.dynamis_data.entries_remaining = n;
                                        -- Refresh the pool now, rather than
                                        -- leaving the account total stale until
                                        -- the next load.
                                        local acct = find_dynamis_account(settings_char);
                                        if acct ~= nil then recalc_account_from_members(acct); end
                                        save_settings();
                                    end
                                end
                                imgui.Unindent(2);
                            end
                        end
                    end

                    imgui.Spacing();
                    imgui.Spacing();

                    -- Limbus override. The addon cannot see what was taken before
                    -- it was installed, so this is how the real number gets in.
                    local lim_store, lim_shared = get_limbus_store(settings_char);
                    if lim_store ~= nil then
                        local lim_cd = tracker.settings.characters[settings_char];
                        if lim_cd.limbus_data == nil then lim_cd.limbus_data = new_limbus_data(); end
                        if lim_shared then
                            imgui.TextColored({ 0.7, 0.7, 0.7, 1.0 }, 'Limbus Run Count:  (account pool)');
                            local av = lim_store.limbus_remaining or LIMBUS_ACCOUNT_LIMIT;
                            imgui.Indent(2);
                            for n = 0, LIMBUS_ACCOUNT_LIMIT do
                                if n > 0 then imgui.SameLine(); end
                                if imgui.RadioButton((n == 1 and '1 Run##lima' or (tostring(n) .. ' Runs##lima')), av == n) then
                                    lim_store.limbus_remaining = n;
                                    lim_store.limbus_seen = LIMBUS_ACCOUNT_LIMIT - n;
                                    lim_store.limbus_known = true;
                                    save_settings();
                                end
                            end
                            imgui.Unindent(2);
                            imgui.TextColored({ 0.7, 0.7, 0.7, 1.0 }, 'This character\'s own limit:');
                        else
                            imgui.TextColored({ 0.7, 0.7, 0.7, 1.0 }, 'Limbus Run Count:');
                        end
                        local ov = lim_cd.limbus_data.runs_remaining or LIMBUS_CHARACTER_LIMIT;
                        imgui.Indent(2);
                        for n = 0, LIMBUS_CHARACTER_LIMIT do
                            if n > 0 then imgui.SameLine(); end
                            if imgui.RadioButton((n == 1 and '1 Run##limc' or (tostring(n) .. ' Runs##limc')), ov == n) then
                                lim_cd.limbus_data.runs_remaining = n;
                                lim_cd.limbus_data.seen = LIMBUS_CHARACTER_LIMIT - n;
                                lim_cd.limbus_data.known = true;
                                save_settings();
                            end
                        end
                        imgui.Unindent(2);
                    end

                    imgui.Spacing();
                    imgui.Spacing();
                    imgui.TextColored({ 0.7, 0.7, 0.7, 1.0 }, 'Timers (ENM):');
                    imgui.Spacing();

                    -- Assault heads the Timers list, so its toggle heads this one.
                    imgui.Indent(2);
                    local asl_box = { tracking.timers[ASSAULT_ROW_LABEL] ~= false };
                    if imgui.Checkbox(ASSAULT_ROW_LABEL, asl_box) then
                        tracking.timers[ASSAULT_ROW_LABEL] = asl_box[1];
                        save_display_settings();
                    end
                    local isnm_box = { tracking.timers[ISNM_ROW_LABEL] ~= false };
                    if imgui.Checkbox(ISNM_ROW_LABEL, isnm_box) then
                        tracking.timers[ISNM_ROW_LABEL] = isnm_box[1];
                        save_display_settings();
                    end
                    imgui.Unindent(2);

                    -- Timer checkboxes (indented). Limbus is a weekly now, so it
                    -- is listed with the tasks above instead.
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
            ui.fonts_pushed = 0;
        end
        imgui.PopStyleColor(2);   -- FrameBg, Border - held through the widgets
        ui.style_colors = 0;

    else
        imgui.PopStyleColor(5);
        imgui.PopStyleVar(2);
        ui.style_colors = 0; ui.style_vars = 0;
    end
    imgui.End();
    if grip_pushed > 0 then imgui.PopStyleColor(grip_pushed); end
    ui.began = false;
end

local function show_all_chars()
    print_msg('All Characters:');
    print_msg('=================');
    for char_name, char_data in pairs(tracker.settings.characters) do
        if char_name ~= nil and char_name ~= '' and char_name ~= 'Unknown' and string.len(char_name) > 0 then
            -- Derive both halves from the same list. The numerator used to be
            -- six hardcoded checks against a denominator of #tasks, so any save
            -- with an extra or renamed task reported nonsense like "4/7".
            local completed_count = 0;
            for _, task in ipairs(tracker.settings.tasks) do
                local n = normalize_task(task);
                local done = false;
                if n == 'ecowarrior' then
                    done = (char_data.ecowarrior_data or {}).step == 'done';
                elseif n == 'xsknife' then
                    done = (char_data.xsknife_data or {}).step == 'done';
                else
                    done = (char_data.quest_steps or {})[n] == 'done';
                end
                if done then completed_count = completed_count + 1; end
            end
            local is_current = char_name == tracker.current_char and ' \30\110(current)\30\106' or '';
            print(string.format('\30\081[\30\082Homework\30\081]\30\106 %s: %d/%d completed%s', char_name, completed_count, #tracker.settings.tasks, is_current));
        end
    end
end

local function show_char_details(char_name)
    -- FFXI names are capitalised, but nobody types them that way.
    if tracker.settings.characters[char_name] == nil then
        local want = tostring(char_name):lower();
        for name in pairs(tracker.settings.characters) do
            if tostring(name):lower() == want then char_name = name; break; end
        end
    end
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
    -- The old settings/ folder is left in place: os.remove cannot delete a
    -- directory on the Windows CRT, so the call was doing nothing anyway.
    local dir = get_config_dir();
    if not ashita.fs.exists(dir) then
        ashita.fs.create_dir(dir);
    end
    local loaded_settings = load_settings();
    -- Seed the defaults before the merge below, so a first run with no file on
    -- disk gets the full list rather than the empty table the tracker starts with.
    if #tracker.settings.tasks == 0 then
        for _, t in ipairs(DEFAULT_TASKS) do table.insert(tracker.settings.tasks, t); end
    end
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
    -- Re-derive every account pool from its members' usage. Without this an
    -- account keeps whatever number was stored when it was last edited, so a
    -- value written by an older version (or by a member's count changing
    -- outside the settings tab) would stick until the user happened to toggle
    -- a checkbox.
    if tracker.settings.dynamis_account_wide then
        local changed = false;
        for _, acct in ipairs(tracker.settings.dynamis_accounts or {}) do
            -- Ask the function what it did. Comparing fields missed the case
            -- where a member's frozen reading already matched the pool: records
            -- were cleared but nothing looked different.
            if recalc_account_from_members(acct) then changed = true; end
        end
        if changed then save_settings(); end
    end

    print_success('Loaded successfully! Use /hw to open or /hw help for commands.');
end);

ashita.events.register('unload', 'unload_cb', function()
    save_settings();
    save_display_settings();
end);

ashita.events.register('text_in', 'text_in_cb', function(e)
    -- Same reasoning as packet_in: an injected chat line is not evidence.
    if e.injected then return; end
    local base_mode = bit.band(e.mode, 0xFF);
    -- Early exit for modes we don't care about (cheapest check first)
    -- 146 = the battlefield objective/failure lines (mode 658).
    if base_mode ~= 150 and base_mode ~= 9 and base_mode ~= 142 and base_mode ~= 146 then return; end
    
    if tracker.current_char == nil or tracker.current_char == 'Unknown' then return; end
    
    local message = e.message;
    local zone_id = get_zone_id();
    local char_data = get_char_data();
    if char_data == nil then return; end
    
    -- Ashu Talif outcome lines (system messages, identical every fight):
    if message:find('Objective complete', 1, true) then
        ASHU.mark_won(char_data);
    elseif message:find('The mission has failed', 1, true) then
        ASHU.mark_failed(char_data);
    end

    -- Base mode 142: Highwind completion & Dynamis claim
    if base_mode == 142 then
        -- Any gil reward on the airship is the Highwind kill (nothing else
        -- aboard pays gil); not pinned to 3000 so a reward change can't
        -- silently break it. Captured 2026-08-31: "Obtained 3000 gil".
        if is_in_highwind_zone() and message:find('Obtained ', 1, true) and message:find(' gil', 1, true) then
            char_data.quest_steps.highwind = 'done';
            save_settings();
            print_success('Highwind complete!');
        end
        -- Only this line means "you charged a glass". It arrives a beat before the
        -- item does, so the flag is left standing for the 0x020 handler to consume.
        -- Clearing it on the "Obtained:" line, as an earlier version did, killed it
        -- before the packet could ever see it.
        if message:find('The time and destination for your foray into Dynamis has been recorded') then
            tracker.pending_dynamis_claim = os.time();
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
            -- \' and ' are the same string in Lua, so the old second test was a
            -- no-op copy of the first.
            if message:find("San d'Oria Consulate", 1, true) then table.insert(locked, 'sandoria'); end
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
    -- Text fallbacks only: the primary trigger is the NPC menu number (see
    -- on_quest_menu). Rouva's sentence below does not even occur on this
    -- server's accept flow (captured 2026-08-30), which is why the menu path
    -- exists.
    if zone_id == 26 and message:find('The information you have brought me on Tavnazian cuisine') then
        accept_cookbook(char_data);
    end
    -- SpiceGals quest acceptance (Rouva in Southern San d'Oria)
    if zone_id == 230 and message:find("Forget the words I have spoken") then
        accept_spicegals(char_data);
    end
    -- EcoWarrior quest acceptance San d'Oria (Norejaie in Southern San d'Oria)
    -- EcoWarrior: no text triggers. Every step runs on menu numbers and your
    -- menu replies (ECO_MENUS / ECO_REPLY_MENUS) plus the key items.
    -- EcoWarrior quest acceptance Windurst (Lumomo in Windurst Waters)

    -- EcoWarrior quest acceptance Bastok (Raifa in Port Bastok)

    -- EcoWarrior NM spawn San d'Oria (Rojaireaut in Ordelle's Caves)

    -- EcoWarrior NM spawn Windurst (Ahko Mhalijikhari in Maze of Shakhrami)

    -- EcoWarrior NM spawn Bastok (Degga in Gusgen Mines)

    -- EcoWarrior return to city NPC San d'Oria (Rojaireaut in Ordelle's Caves)

    -- EcoWarrior return to city NPC Windurst (Ahko Mhalijikhari in Maze of Shakhrami)

    -- EcoWarrior return to city NPC Bastok (Degga in Gusgen Mines)

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

-- Outgoing menu replies (0x05B). The only consumer so far is EcoWarrior's
-- accept: the city offer menu opens whether you accept or decline, and the
-- reply's option value is the one thing that says which.
ashita.events.register('packet_out', 'packet_out_cb', function(e)
    if e.id ~= 0x005B then return; end
    if e.data == nil or #e.data < 0x14 then return; end
    if tracker.current_char == nil or tracker.current_char == 'Unknown' then return; end
    local option = struct.unpack('I', e.data, 0x08 + 1) or 0;
    local zone   = struct.unpack('H', e.data, 0x10 + 1) or 0;
    local menu   = struct.unpack('H', e.data, 0x12 + 1) or 0;
    on_menu_reply(zone, menu, option);
end);

ashita.events.register('packet_in', 'packet_in_cb', function(e)
    -- Every counter in this addon exists to record something that really
    -- happened. A packet injected by another addon did not happen, so it must
    -- never reach the gain/loss handlers or spend a Dynamis or Limbus entry.
    if e.injected then return; end
    local id = e.id;
    local data = e.data;
    -- Logout packet
    if id == 0x000B then
        if data == nil or #data < 0x08 then return; end
        local logout_state = struct.unpack('I', data, 0x04 + 1);
        if logout_state == 1 then
            -- Flush first: the ki_cache mirror only happens inside save_settings
            -- while kis_initialized is true, so wiping before saving could lose
            -- whatever changed since the last write.
            save_settings();
            tracker.current_char = 'Unknown';
            tracker.next_check_time = 0;
            tracker.login_state.waiting_for_login = true;
            tracker.kis = {};
            tracker.kis_initialized = false;
    tracker.isnm_observed_since = nil;
            print_msg('Logout detected.');
        end
        return;
    end
    -- A charged hourglass arriving. This is the real "you broke a glass" moment:
    -- the chat message fires about a second BEFORE the server sends the item, so
    -- searching the inventory when the text lands finds nothing. The packet
    -- carries the Extra block itself, so no inventory lookup is needed at all.
    if id == 0x0020 then
        if tracker.current_char ~= nil and tracker.current_char ~= 'Unknown' then
            local ok_id, item_id = pcall(function()
                return struct.unpack('H', data, ITEM_PACKET_ID_OFFSET);
            end);
            if ok_id and item_id == PERPETUAL_HOURGLASS_ID then
                local ok_ex, extra = pcall(function()
                    return data:sub(ITEM_PACKET_EXTRA_OFFSET, ITEM_PACKET_EXTRA_OFFSET + 27);
                end);
                if ok_ex then
                    local serial, glass_zone = glass_serial_from_extra(extra);
                    -- An hourglass can reach your bag two ways: you charged one, or
                    -- somebody traded you theirs. They look identical in this packet,
                    -- so the chat line is what tells them apart. A traded glass is
                    -- left alone here and counts when you actually walk in.
                    local was_break = tracker.pending_dynamis_claim ~= nil
                        and (os.time() - tracker.pending_dynamis_claim) <= DYNAMIS_BREAK_WINDOW;
                    -- Only consume the flag when this packet really was a
                    -- charged glass. An unparsable hourglass landing inside the
                    -- five second window used to eat the flag, so the real break
                    -- that followed was misread as a trade.
                    if serial == nil then return; end
                    -- Remember every charged glass that lands in the bag,
                    -- break OR trade, before any early return below. This is
                    -- what identifies the glass at zone-in: the bag read there
                    -- has proven unreliable, the packet has not.
                    remember_held_glass(get_char_data(), serial, glass_zone);
                    local store = get_dynamis_store(tracker.current_char);
                    -- Race, documented rather than papered over: a glass traded
                    -- to you inside the five second window is just as parsable
                    -- as your own, and nothing in the packet distinguishes them.
                    -- Whichever arrives first consumes the flag. Copies of one
                    -- glass share Extra bytes, so an identical serial is the
                    -- same break and can be ignored; a different one inside the
                    -- window is genuinely ambiguous and gets treated as the
                    -- break, which is the safer of the two guesses.
                    if store ~= nil and store.last_break_serial == serial then return; end
                    tracker.pending_dynamis_claim = nil;
                    if not was_break then return; end
                    if serial ~= nil then
                        if store ~= nil and not glass_already_counted(store, serial) then
                            get_char_data();
                            store.claimed_at = os.time();
                            -- Record what this glass was booked for. Walking into
                            -- that same zone shortly after is this run arriving,
                            -- not a second entry - and the serial check alone is
                            -- not enough, because reading the glass back out of
                            -- the inventory at zone-in has proven unreliable.
                            store.last_break_zone = glass_zone;
                            store.last_break_time = os.time();
                            store.last_break_serial = serial;
                            count_dynamis_entry(store, serial, 'glass broken - counted');
                        end
                    end
                end
            end
        end
        return;
    end

    -- Rytaal's tag counter. Opening the menu is enough - no need to take a tag.
    -- This is the only moment the server tells us how many tags are in stock.
    -- 0x032 is the SHORT menu packet most quest NPCs use (Jonette, Rouva,
    -- Justinius). Its fields sit right after the npc id: idx 0x08, zone 0x0A,
    -- menu 0x0C - verified against live captures. 0x034 (below) is the long
    -- form with 32 bytes of event params first.
    if id == 0x0032 then
        if data == nil or #data < 0x0E then return; end
        if tracker.current_char == nil or tracker.current_char == 'Unknown' then return; end
        local mzone = struct.unpack('H', data, 0x0A + 1) or 0;
        local mid   = struct.unpack('H', data, 0x0C + 1) or 0;
        on_quest_menu(mzone, mid);
        return;
    end

    if id == 0x0034 then
        if tracker.current_char ~= nil and tracker.current_char ~= 'Unknown' then
            pcall(function()
                if #data < MENU_OFFSET_MENU_ID + 2 then return; end
                local menu_id = struct.unpack('H', data, MENU_OFFSET_MENU_ID + 1);

                -- Halshaob in Nashmau: menu 302 is the payment, and its
                -- params carry (item id, count, QUEST ID). Captured three
                -- times: 2184x3->101, 2185x1->102, 2186x1->103.
                if menu_id == 302 then
                    if #data < MENU_OFFSET_ZONE + 2 then return; end
                    local mzone = struct.unpack('H', data, MENU_OFFSET_ZONE + 1);
                    if mzone ~= 53 then return; end
                    local qid = struct.unpack('I', data, 0x10 + 1) or 0;
                    if qid >= ASHU.FIRST and qid <= ASHU.LAST then
                        local cd = get_char_data();
                        if cd ~= nil then ASHU.mark_paid(cd, qid); end
                    end
                    return;
                end

                -- Shajaf in Whitegate: which of his four menus opens IS the
                -- ISNM state, so talking to him is a free truth-check - the
                -- same trick as Rytaal's stock counter. Gated on the zone id
                -- because small menu numbers repeat across zones.
                if menu_id >= ISNM_MENU_CAN_BUY and menu_id <= ISNM_MENU_LOCKED then
                    if #data < MENU_OFFSET_ZONE + 2 then return; end
                    local mzone = struct.unpack('H', data, MENU_OFFSET_ZONE + 1);
                    if mzone ~= ISNM_SHAJAF_ZONE then return; end
                    local cd = get_char_data();
                    if cd == nil then return; end
                    local isnm = isnm_data_for(cd);
                    if menu_id == ISNM_MENU_CAN_BUY then
                        isnm.next_buy_time = os.time();   -- purchasable right now
                        isnm.no_badge = nil;
                    elseif menu_id == ISNM_MENU_LOCKED then
                        isnm.next_buy_time = next_jst_midnight(os.time());
                        isnm.no_badge = nil;
                    elseif menu_id == ISNM_MENU_NO_BADGE then
                        isnm.no_badge = true;
                    end
                    -- 161 (already holding) changes nothing: the key item table
                    -- already knows what is held, and the menu does not reveal
                    -- whether the daily lock is also running.
                    save_settings();
                    return;
                end

                -- One of the five mission givers: their menu carries the
                -- mercenary rank and that area's assault points.
                local giver_area = MISSION_GIVER_MENUS[menu_id];
                if giver_area ~= nil then
                    local rank   = struct.unpack('L', data, MENU_PARAM_RANK + 1);
                    local points = struct.unpack('L', data, MENU_PARAM_POINTS + 1);
                    local cd = get_char_data();
                    if cd == nil then return; end
                    if cd.assault_data == nil then cd.assault_data = new_assault_data(); end
                    local a = cd.assault_data;
                    local changed = false;
                    if rank ~= nil and rank >= 1 and rank <= 11 then
                        if a.rank ~= rank then changed = true; end
                        a.rank = rank;
                        a.rank_seen_at = os.time();
                    end
                    if points ~= nil and points < 1000000 then
                        if type(a.points) ~= 'table' then a.points = {}; end
                        if a.points[giver_area] ~= points then
                            a.points[giver_area] = points;
                            changed = true;
                        end
                    end
                    -- Opening a mission giver's menu usually changes nothing, and
                    -- a full serialise per menu open just feeds the save spam.
                    if changed then save_settings(); end
                    return;
                end

                if menu_id ~= RYTAAL_MENU_ID then return; end

                local stock  = struct.unpack('L', data, MENU_PARAM_TAG_STOCK + 1);
                local mission = struct.unpack('L', data, MENU_PARAM_ASSAULT + 1);
                local anchor = struct.unpack('L', data, MENU_PARAM_TAG_TIME + 1);
                -- Anything above the known maximum is a bad read, not a bigger
                -- stock. Previously admitted up to 16 and rendered as "7/3".
                -- Say so once per session: if the server ever raises the cap this
                -- turns a silently stale display into something reportable.
                if stock == nil then return; end
                if stock > 4 then
                    if not tracker.warned_tag_stock then
                        tracker.warned_tag_stock = true;
                        print_msg(string.format(
                            'Rytaal reported %d tags, above the expected maximum - ignoring.', stock));
                    end
                    return;
                end

                local char_data = get_char_data();
                if char_data == nil then return; end
                if char_data.assault_data == nil then char_data.assault_data = new_assault_data(); end
                -- Rytaal reports the account's stock, so it lands in the pool.
                -- currentAssault is personal and stays on the character.
                local ad = get_assault_store(tracker.current_char) or char_data.assault_data;
                char_data.assault_data.current_assault = mission or 0;

                ad.tags_stored     = stock;
                ad.checked_at      = os.time();
                -- The cap is never sent, so infer it upward if we ever see more
                -- than the default. It can legitimately be 4.
                -- Retail allows 4 for a Second Lieutenant who has cleared every
                -- assault; Horizon is a flat 3. The inference used to ratchet up
                -- permanently with no way down, so one garbage packet reading of
                -- 7 would have shown n/7 on every character forever - and now on
                -- a pool everyone shares.
                if stock > (ad.max_stock or ASSAULT_DEFAULT_MAX_STOCK) and stock <= 4 then
                    ad.max_stock = stock;
                end
                -- anchor == 0 means the stock is full and no timer is running.
                -- The anchor field can hold a stale value while the stock is
                -- full - seen in a live capture where Rytaal had all 3 and still
                -- reported a countdown from an earlier cycle. A full stock has no
                -- clock running, so ignore it.
                if stock >= (ad.max_stock or ASSAULT_DEFAULT_MAX_STOCK) then
                    ad.next_tag_time = 0;
                elseif anchor ~= nil and anchor > 0 then
                    ad.next_tag_time = anchor + ASSAULT_TAG_EPOCH;
                else
                    ad.next_tag_time = 0;
                end
                save_settings();
            end);
        end
        return;
    end

    -- Quest log update. The ToAU chunks carry the Ashu Talif chain: chunk
    -- 0x0080 = active bits, 0x00C0 = completed bits, bit index = quest id.
    -- Sent on every zone-in and whenever a flag changes, so a mid-chain
    -- install picks up the true state on the first zoning.
    -- Quest log update. On repeat weeks these bits never move (captured),
    -- so this is only a FIRST-EVER-week bonus: a chain quest turning active
    -- means it was just paid for; its completed bit flipping while aboard
    -- means it was just won. Both funnel into the same state functions the
    -- menu/text signals use.
    if id == 0x056 then
        if data == nil or #data < 0x26 then return; end
        local chunk = struct.unpack('H', data, 0x24 + 1);
        if chunk ~= 0x0080 and chunk ~= 0x00C0 then return; end
        local char_data = get_char_data();
        if char_data == nil then return; end
        local ash = ASHU.data_for(char_data);
        local b = data:byte(4 + 12 + 1) or 0;   -- quests 101..103 live in body byte 12
        local changed = false;
        for q = ASHU.FIRST, ASHU.LAST do
            local set = math.floor(b / 2 ^ (q % 8)) % 2 == 1;
            local key = tostring(q);
            local map = (chunk == 0x0080) and ash.active or ash.completed;
            if (map[key] == true) ~= set then
                map[key] = set or nil;
                changed = true;
                if chunk == 0x0080 and set and ash.paid ~= true and ash.aboard ~= true then
                    ASHU.mark_paid(char_data, q);
                elseif chunk == 0x00C0 and set and ash.aboard == true then
                    ASHU.mark_won(char_data);
                end
            end
        end
        if ash.known ~= true then ash.known = true; changed = true; end
        if changed then save_settings(); end
        return;
    end

    if id == 0x000A then
        if data == nil or #data < 0x94 then return; end
        -- Get zone ID from packet
        local zone_id = struct.unpack('H', data, 0x30 + 1) or 0;
        
        -- The Ashu Talif: boarding starts a fight, leaving ends one. Any way
        -- off the ship counts - homepoint, warp, eject, or a relog straight to
        -- land - because the judgment is simply "left without the win flag".
        -- The win flag itself arrives while still aboard, so a won fight can
        -- never be mistaken for a fail here.
        if tracker.current_char ~= 'Unknown' then
            local cd_ashu = tracker.settings.characters[tracker.current_char];
            if cd_ashu ~= nil and type(cd_ashu.ashu_data) == 'table' then
                if zone_id == ASHU.SHIP_ZONE then
                    -- The same ship hosts the Black Coffin story mission and
                    -- the COR job fight; mark_aboard ignores boardings with
                    -- no paid chain stage.
                    ASHU.mark_aboard(cd_ashu);
                else
                    -- Off the ship while still marked aboard = no "Objective
                    -- complete" was seen = lost (homepoint, warp, eject, D/C).
                    ASHU.mark_failed(cd_ashu);
                end
            end
        end

        -- Check if this is a Dynamis zone.
        -- ORDERING IS LOAD-BEARING: on a fresh login current_char is still
        -- 'Unknown' here, because the waiting_for_login branch further down is
        -- what sets it. The store lookup therefore returns nil and a relog
        -- straight into Dynamis is not counted. That is the safer default - a
        -- relog is not a new entry - but it is a consequence of ordering, so do
        -- not reorder these two blocks without re-testing that case.
        if DYNAMIS_ZONES[zone_id] then
            get_char_data();
            local store = get_dynamis_store(tracker.current_char);
            if store ~= nil then
                -- Count once per glass, identified by its serial. A glass we broke
                -- ourselves was already counted, so walking in changes nothing. A
                -- glass someone else broke - same zone or not - is a new serial and
                -- counts here.
                -- Arriving in the zone we just broke a glass for is that run
                -- starting, so it must not count again. A glass is dead 210
                -- minutes after the break at the outside, so anything older is
                -- a genuinely new run into the same zone.
                local since_break = os.time() - (store.last_break_time or 0);
                if store.last_break_zone == zone_id and since_break <= DYNAMIS_GLASS_LIFETIME then
                    -- already counted when the glass was broken
                else
                    -- The glass remembered from its 0x020 packet first; the
                    -- bag read stays only as a second chance, since on this
                    -- client it usually returns nothing.
                    local cd = tracker.settings.characters[tracker.current_char];
                    local serial = held_glass_serial(cd, zone_id)
                        or find_glass_serial(zone_id);
                    if serial == nil then
                        -- No readable glass. A bare 'zone-N' key swallowed a
                        -- second legitimate run into the same zone; a fixed hour
                        -- bucket split one run across a boundary (relog at :59
                        -- then :01 produced two keys). Instead reuse the key
                        -- this store already holds for this zone if it is still
                        -- inside the hourglass lifetime.
                        local now = os.time();
                        local prefix = 'zone-' .. tostring(zone_id) .. '-';
                        -- '-' is a pattern quantifier in Lua, not a literal
                        -- dash. Unescaped, this guard searched for keys it can
                        -- never match - its own - and so had never fired once.
                        local pat = '^' .. prefix:gsub('%-', '%%-') .. '(%d+)$';
                        for _, sn in ipairs(store.counted_glasses or {}) do
                            local stamp = tostring(sn):match(pat);
                            if stamp ~= nil and (now - tonumber(stamp)) <= DYNAMIS_GLASS_LIFETIME then
                                serial = sn;
                                break;
                            end
                        end
                        if serial == nil then serial = prefix .. tostring(now); end
                    end
                    if not glass_already_counted(store, serial) then
                        count_dynamis_entry(store, serial, 'entry counted');
                    end
                end
            end
        end
        
        if tracker.login_state.waiting_for_login then
            -- Full login - character change
            tracker.login_state.waiting_for_login = false;
            tracker.kis = {};
            tracker.kis_initialized = false;
    tracker.isnm_observed_since = nil;
            local name_offset = 0x84 + 1;
            local raw_name = data:sub(name_offset, name_offset + 15);
            local current_char = raw_name:match("^[%w]+") or 'Unknown';
            if current_char ~= 'Unknown' and current_char ~= '' then
                -- on_character_change already announces this; a second message
                -- here meant two lines for one event.
                on_character_change(current_char);
                tracker.login_state.waiting_for_ki = true;
                tracker.login_state.ki_packets_received = 0;
                -- Also zero this: a stale count of 7 carried over from the
                -- previous session let the timeout backstop treat a genuinely
                -- partial table as a complete baseline.
                tracker.login_state.blocks_this_zone = 0;
                tracker.login_state.suppress_ki_events = true;
                tracker.login_state.suppress_started = os.time();
            end
        else
            -- Zone-in (not a fresh login) - suppress KI events until packets stabilize
            tracker.login_state.suppress_ki_events = true;
            tracker.login_state.suppress_started = os.time();
            tracker.login_state.ki_packets_received = 0;
            tracker.login_state.blocks_this_zone = 0;
        end
        return;
    end
    -- Key Item packet
    if id == 0x0055 then
        if data == nil or #data < 0x85 then return; end
        -- Identifies this packet, so on_ki_gained can tell whether the tag it is
        -- looking at arrived alongside the orders that just vanished.
        ASSAULT_KI_PACKET_SEQ = ASSAULT_KI_PACKET_SEQ + 1;
        local ki_table_type = struct.unpack('B', data, 0x84 + 1);
        -- Seven blocks of 512 ids is the whole space; anything else is junk and
        -- would write nonsense positions into tracker.kis.
        if ki_table_type == nil or ki_table_type > 6 then return; end
        local offset = ki_table_type * 512;
        local suppressed = tracker.login_state.suppress_ki_events;
        local kis = tracker.kis;
        -- 64 bytes, 8 bits each. The old loop re-read the same byte once per bit,
        -- so 512 unpacks per packet and seven packets per zone.
        for byte_index = 0, 63 do
            local ki_byte = struct.unpack('B', data, 0x04 + byte_index + 1);
            if ki_byte ~= nil then
                local base = offset + byte_index * 8;
                for bit_index = 0, 7 do
                    local ki_position = base + bit_index;
                    local has_ki = bit.band(bit.rshift(ki_byte, bit_index), 1) == 1;
                    local was = kis[ki_position];
                    if (not suppressed) and was ~= nil and has_ki ~= was then
                        if has_ki then on_ki_gained(ki_position); else on_ki_lost(ki_position); end
                    end
                    kis[ki_position] = has_ki;
                end
            end
        end
        -- Only count while a zone-in rebaseline is actually running. Ordinary
        -- mid-session key item changes also arrive as 0x055, and after seven of
        -- them this branch used to fire spuriously - a pointless scan and save.
        if not (tracker.login_state.suppress_ki_events or tracker.login_state.waiting_for_ki) then
            return;
        end
        tracker.login_state.ki_packets_received = tracker.login_state.ki_packets_received + 1;
        tracker.login_state.blocks_this_zone = (tracker.login_state.blocks_this_zone or 0) + 1;
        if tracker.login_state.ki_packets_received >= 7 then
            -- All KI packets received - clear suppression and update state
            tracker.login_state.suppress_ki_events = false;
            tracker.login_state.ki_packets_received = 0;
            tracker.kis_initialized = true;
    if tracker.isnm_observed_since == nil then tracker.isnm_observed_since = os.time(); end
            tracker.login_state.waiting_for_ki = false;
            -- Reconcile after EVERY rebaseline, not just the first. Key items
            -- consumed as part of zoning never fire on_ki_lost, because events
            -- are suppressed while the baseline is being rebuilt - so has_ki
            -- would quietly go stale until a manual /hw scan.
            local char_data = get_char_data();
            if char_data ~= nil then
                scan_key_items(true);
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
    -- Render UI (always, imgui handles visibility). Wrapped because a malformed
    -- save would otherwise throw on every single frame.
    if not ui.render_failed then
        -- Count what render_ui pushes so the stack can be unwound if it throws.
        -- Ashita shares one ImGui context across all addons: an unbalanced stack
        -- from one bad frame corrupts every other addon until the game restarts.
        ui.style_colors = 0;
        ui.style_vars = 0;
        ui.fonts_pushed = 0;
        local ok, err = pcall(render_ui);
        if not ok then
            pcall(function()
                if ui.fonts_pushed > 0 then imgui.PopFont(); end
                if ui.style_vars > 0 then imgui.PopStyleVar(ui.style_vars); end
                if ui.style_colors > 0 then imgui.PopStyleColor(ui.style_colors); end
                -- Only End a window that was actually Begun: a throw before
                -- Begin would otherwise leave an unmatched End, which is its own
                -- stack violation in a context shared with every other addon.
                if ui.began then imgui.End(); end
                ui.began = false;
            end);
        end
        if not ok then
            ui.render_failed = true;
            print_error('Display error, window hidden: ' .. tostring(err));
            print_msg('Your tracking data is safe. Use /hw show to try again.');
        end
    end
    
    -- Throttled checks
    local current_time = os.time();
    if current_time - tracker.last_check_time < tracker.check_interval then return; end
    tracker.last_check_time = current_time;

    -- Safety net: suppression is normally lifted by the 7th key item packet, but
    -- if a zone ever delivers fewer the addon would go deaf for the rest of the
    -- session. Clear it on a timer instead of trusting the count alone.
    if tracker.login_state.suppress_ki_events
       and (current_time - (tracker.login_state.suppress_started or 0)) > KI_SUPPRESS_TIMEOUT then
        tracker.login_state.suppress_ki_events = false;
        tracker.login_state.ki_packets_received = 0;
        -- Also clear this: leaving it set meant the packet counter kept
        -- incrementing on ordinary mid-session key item changes, and after seven
        -- of them the rebaseline branch fired spuriously - exactly what the
        -- "only count during a rebaseline" guard was added to stop.
        tracker.login_state.waiting_for_ki = false;
        -- Only trust the baseline if a full set of blocks actually arrived. A
        -- partial one would let a later scan write "not held" across every key
        -- item in the missing blocks.
        if tracker.login_state.blocks_this_zone ~= nil
           and tracker.login_state.blocks_this_zone >= 7
           and next(tracker.kis) ~= nil then
            tracker.kis_initialized = true;
    if tracker.isnm_observed_since == nil then tracker.isnm_observed_since = os.time(); end
        end
    end
    if tracker.next_check_time > 0 and current_time >= tracker.next_check_time then
        reset_tracker();
    end
end);

ashita.events.register('command', 'command_cb', function(e)
    local command = e.command;
    local args = command:args();
    if (#args == 0 or (args[1] ~= '/hw' and args[1] ~= '/homework' and args[1] ~= '/homeworks')) then return; end
    e.blocked = true;
    -- Dispatch on a lowered copy so /hw Weeklys works. args[3] keeps its case,
    -- since character names are matched separately.
    if args[2] ~= nil then args[2] = args[2]:lower(); end
    -- These need no character data, so let them run before the guard rather than
    -- answering "not loaded yet" at the login screen. Bare /hw is #args == 1, so
    -- args[2] is nil: the comment used to claim the toggle was exempt while the
    -- test only ever matched named subcommands.
    local no_char_needed = (#args == 1)
        or args[2] == 'help' or args[2] == 'task' or args[2] == 'tasks'
        or args[2] == 'show' or args[2] == 'hide';
    if no_char_needed then
        -- fall through to the handlers below with no character required
    else
        local probe = get_char_data();
        if probe == nil then print_error('Character not loaded yet. Please wait...'); return; end
    end
    local char_data = get_char_data();
    local current_time = os.time();
    if char_data == nil then char_data = { last_reset = 0 }; end
    local reset_anchor = math.max(tonumber(char_data.last_reset) or 0, newest_last_reset());
    if reset_anchor > 0 and current_time >= calculate_next_reset(reset_anchor) then
        reset_tracker();
    end
    if (#args == 1) then
        -- /hw alone toggles the window
        if ui.is_open[1] then
            ui.is_open[1] = false;
        else
            update_char_list();
            ui.render_failed = false;   -- retry after a display error
            ui.is_open[1] = true;
        end
        return;
    end
    if (args[2] == 'help') then
        print_msg('Available commands:');
        -- green command, grey description, aligned so the dashes line up
        local function help_line(cmd, desc)
            print(string.format('  \30\110%-22s\30\106- \30\071%s\30\106', cmd, desc));
        end
        help_line('/hw',              'Toggle tracking window');
        help_line('/hw weeklys',      'Weekly checklist in chat');
        help_line('/hw timers',       'ENM / Limbus timers in chat');
        help_line('/hw chars',        'All characters and their progress');
        help_line('/hw chars <name>', 'Week & timers for one character');
        print('');
        help_line('/hw <task>',       'Toggle a task complete');
        help_line('/hw task',         'List every task and its short forms');
        help_line('/hw eco',          'Toggle EcoWarrior done / undone');
        help_line('/hw eco <nation>', 'Toggle a nation done (sandy / basty / windy)');
        print('');
        help_line('/hw show',         'Open the window');
        help_line('/hw hide',         'Close the window');
        help_line('/hw scan',         'Scan key items for this character');
        help_line('/hw reset',        'Factory reset (deletes everything)');
        help_line('/hw yes / no',     'Confirm or cancel a pending reset');
        help_line('/hw help',         'Show this help');
        print('');
        print_msg('Also answers to \30\110/homework\30\106 and \30\110/homeworks\30\106.');
        return;
    end
    if (args[2] == 'show') then
        update_char_list();
        ui.render_failed = false;   -- give a failed render another go
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
        if type(eco_data.locked_nations) ~= 'table' then eco_data.locked_nations = {}; end
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
