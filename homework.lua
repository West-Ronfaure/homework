--[[
* Addons - Copyright (c) 2024
* Homework - A weekly checklist addon for Ashita 4
--]]

addon.author   = 'Riquelme';
addon.name     = 'Homework';
addon.version   = '3.0';
addon.desc      = 'Weekly homework tracker for FFXI';
addon.link      = '';

require('common');
local imgui = require('imgui');

-- UI State
local ui = {
    is_open = { false },
    show_settings = false,
    selected_char = { 0 },  -- Shared character selection for both tabs
    char_list = {},
    font_scale = 1.0,
    selected_tab = 0,  -- 0 = Tasks, 1 = Settings
    window_flags = bit.bor(
        ImGuiWindowFlags_NoCollapse
    ),
};

-- Custom settings file handling for Ashita v4
local settings_file = nil;
local display_settings_file = nil;

local function get_settings_path()
    if settings_file == nil then
        settings_file = addon.path .. '/settings/homework.json';
    end
    return settings_file;
end

local function get_display_settings_path()
    if display_settings_file == nil then
        display_settings_file = addon.path .. '/settings/display.json';
    end
    return display_settings_file;
end

-- Known array field names (these should always serialize as [] not {})
-- Note: 'tasks' removed from here since display_settings.tracked uses it as an object {task_name: boolean}
local ARRAY_FIELDS = { locked_nations = true };

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
                local key_str = '"' .. tostring(k) .. '"';
                result = result .. indent .. '  ' .. key_str .. ': ' .. serialize_value(v, indent .. '  ', k);
            end
            if not first then result = result .. '\n' .. indent; end
            return result .. '}';
        end
    elseif t == 'string' then
        return '"' .. val:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n') .. '"';
    elseif t == 'boolean' then
        return val and 'true' or 'false';
    elseif t == 'nil' then
        return 'null';
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
        local s = str:sub(pos + 1, endpos - 1):gsub('\\n', '\n'):gsub('\\"', '"'):gsub('\\\\', '\\');
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

-- Tracker data
local tracker = {
    settings = {
        tasks = {
            'EcoWarrior',
            'Highwind',
            'UnInvited',
            'CookBook',
            'SpiceGals',
            'X\'sKnife'
        },
        characters = {} -- Per-character data: [charname] = { last_reset = 0, enm_timers = {}, xsknife_data = {}, etc }
    },
    current_char = nil,
    next_check_time = 0,
    -- Login detection state
    login_state = {
        waiting_for_login = false,  -- Set true after logout, cleared on next zone-in
        waiting_for_ki = false,     -- Set true after login, cleared after KI packets received
        ki_packets_received = 0     -- Count of 0x0055 packets received (need 7 total)
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
    -- Factory reset confirmation
    pending_reset = false
};

-- Save settings function (must be after tracker is defined)
local function save_settings()
    local path = get_settings_path();
    local dir = addon.path .. '/settings/';
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

-- Display settings structure
local display_settings = {
    font_scale = 1.0,
    tracked = {}  -- Per-character tracking: [char_name] = {tasks = {task1=true, ...}, timers = {timer1=true, ...}}
};

local function save_display_settings()
    local path = get_display_settings_path();
    local dir = addon.path .. '/settings/';
    if not ashita.fs.exists(dir) then
        ashita.fs.create_dir(dir);
    end
    display_settings.font_scale = ui.font_scale;
    local f = io.open(path, 'w');
    if f then
        f:write(serialize_value(display_settings));
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

local ECOWARRIOR_ZONES = {
    sandoria = {
        quest_npc = 'Norejaie',
        field_agent = 'Rojaireaut',
        ki_name = 'Indigested stalagmite',
        zone_name = "Ordelle's Caves",
        city_name = "Southern San d'Oria"
    },
    windurst = {
        quest_npc = 'Lumomo',
        field_agent = 'Ahko Mhalijikhari',
        ki_name = 'Indigested meat',
        zone_name = 'Maze of Shakhrami',
        city_name = 'Windurst Waters'
    },
    bastok = {
        quest_npc = 'Raifa',
        field_agent = 'Degga',
        ki_name = 'Indigested ore',
        zone_name = 'Gusgen Mines',
        city_name = 'Port Bastok'
    }
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
            ecowarrior_data = { step = 'unknown', current_nation = nil, locked_nations = {}, knows_status = false }
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
    -- Remove deprecated tally_tracked field
    if tracker.settings.characters[tracker.current_char].xsknife_data.tally_tracked ~= nil then
        tracker.settings.characters[tracker.current_char].xsknife_data.tally_tracked = nil;
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
    for _, enm in ipairs(ENM_KEY_ITEMS) do
        tracker.kis[enm.ki_id] = player:HasKeyItem(enm.ki_id);
    end
    -- Limbus cards (for floating window display)
    for _, card in ipairs(LIMBUS_CARDS) do
        tracker.kis[card.ki_id] = player:HasKeyItem(card.ki_id);
    end
    tracker.kis[XSKNIFE_KI_ID_FIRST] = player:HasKeyItem(XSKNIFE_KI_ID_FIRST);
    tracker.kis[XSKNIFE_KI_ID_REPEAT] = player:HasKeyItem(XSKNIFE_KI_ID_REPEAT);
    tracker.kis[COOKBOOK_KI_ID] = player:HasKeyItem(COOKBOOK_KI_ID);
    tracker.kis[SPICEGALS_KI_ID] = player:HasKeyItem(SPICEGALS_KI_ID);
    tracker.kis[UNINVITED_KI_ID] = player:HasKeyItem(UNINVITED_KI_ID);
    for _, ki_id in pairs(ECOWARRIOR_KI_IDS) do
        tracker.kis[ki_id] = player:HasKeyItem(ki_id);
    end
    tracker.kis_initialized = true;
    return true;
end

local function scan_key_items(silent)
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
        if char_data.quest_steps.spicegals == 'unknown' or char_data.quest_steps.spicegals == 'scanned' or char_data.quest_steps.spicegals == 'riverne' then
            char_data.quest_steps.spicegals = 'rouva';
            if not silent then print_msg('Found Rivernewort - Go to Rouva!'); end
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
        char_data.quest_steps.spicegals = 'rouva';
        save_settings();
        print_success('Obtained Rivernewort - Go to Rouva!');
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
            if timer_data ~= nil then
                timer_data.has_ki = false;
                save_settings();
                print_msg(string.format('Used %s - Timer continues', enm.ki_name));
            end
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
        if char_data.quest_steps.spicegals == 'rouva' then
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

local function normalize_task(task)
    return task:lower():gsub('%s+', ''):gsub("'", '');
end

local function find_task_name(task)
    local normalized = normalize_task(task);
    for _, v in ipairs(tracker.settings.tasks) do
        if normalize_task(v) == normalized then return v; end
    end
    return nil;
end

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
        spicegals_step = 'riverne';
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
    save_settings();
    print_success('Weekly tracker has been reset for all ' .. reset_count .. ' characters!');
    local next_reset = calculate_next_reset(os.time());
    tracker.next_check_time = next_reset;
end

local function initialize_timer()
    local char_data = get_char_data();
    local current_time = os.time();
    local next_reset = calculate_next_reset(current_time);
    if current_time >= next_reset then reset_tracker(); return; end
    local last_reset_point = calculate_next_reset(char_data.last_reset);
    if current_time >= last_reset_point and char_data.last_reset < last_reset_point then
        reset_tracker(); return;
    end
    tracker.next_check_time = next_reset;
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
        local needs_scan = char_data.quest_steps.uninvited == 'unknown' or
                          char_data.quest_steps.spicegals == 'unknown' or
                          char_data.quest_steps.cookbook == 'unknown';
        if needs_scan then print_msg('Use /hw scan to check key items for this character'); end
        initialize_timer();
    end
end

local function show_list()
    local char_data = get_char_data();
    local current_time = os.time();
    local has_question_mark = false;
    local has_yellow_empty = false;
    local has_eco_unknown = false;
    local has_eco_nation = false;
    local has_eco_scanned_ki = false;
    local has_xsknife_unknown = false;
    local has_xsknife_yellow_empty = false;
    local has_xsknife_yellow_boneyard = false;
    local has_xsknife_yellow_des = false;
    for _, task in ipairs(tracker.settings.tasks) do
        local normalized = normalize_task(task);
        if normalized == 'xsknife' then
            local step = char_data.xsknife_data.step or 'unknown';
            if step == 'unknown' then has_xsknife_unknown = true;
            elseif step == 'scanned_no_ki' then has_xsknife_yellow_empty = true;
            elseif step == 'scanned_has_ki' then has_xsknife_yellow_boneyard = true;
            elseif step == 'scanned_has_ki_used' then has_xsknife_yellow_des = true; end
        elseif normalized == 'highwind' then
            local step = char_data.quest_steps.highwind or 'scanned';
            if step == 'scanned' then has_yellow_empty = true; end
        elseif normalized == 'uninvited' or normalized == 'spicegals' or normalized == 'cookbook' then
            local step = char_data.quest_steps[normalized] or 'unknown';
            if step == 'unknown' then has_question_mark = true;
            elseif step == 'scanned' then has_yellow_empty = true; end
        elseif normalized == 'ecowarrior' then
            local eco_data = char_data.ecowarrior_data or {step = 'unknown'};
            if eco_data.step == 'unknown' then has_eco_unknown = true;
            elseif eco_data.step == 'scanned' then has_eco_nation = true;
            elseif eco_data.step == 'scanned_has_ki' then has_eco_scanned_ki = true; end
        end
    end
    print_msg('Weekly Homework for \30\110' .. tracker.current_char .. '\30\106:');
    if has_question_mark then print('\30\104[ ? ]\30\067 = Use /hw scan to detect progress.'); end
    if has_yellow_empty then print('\30\104[   ]\30\067 = Unknown progress. Resolves at next tally or use /hw <task>.'); end
    if has_eco_unknown then print('\30\104[ ? ]\30\067 (EcoWarrior) = Use /hw eco <nation> or talk to Eeko-Weeko.'); end
    if has_eco_nation then print('\30\104[Nation]\30\067 (EcoWarrior) = Unknown if completed. Resolves at next tally or quest interaction.'); end
    if has_eco_scanned_ki then print('\30\104[Zone - Agent]\30\067 (EcoWarrior) = Has KI but locked nations unknown. Use /hw eco or talk to Eeko-Weeko.'); end
    if has_xsknife_unknown then print('\30\104[ ? ]\30\067 (X\'sKnife) = Use /hw scan or talk to Despachiaire.'); end
    if has_xsknife_yellow_empty then print('\30\104[   ]\30\067 (X\'sKnife) = Unknown if Despachiaire has KI. Resolves at next tally or when KI obtained.'); end
    if has_xsknife_yellow_des then print('\30\104[Despachiaire]\30\067 (X\'sKnife) = Unknown if Despachiaire has KI. Resolves at next tally or when KI obtained.'); end
    if has_xsknife_yellow_boneyard then print('\30\104[Boneyard Gully]\30\067 (X\'sKnife) = Unknown if Despachiaire has another KI. Resolves at next tally or when KI obtained.'); end
    print_msg('=================');
    for _, task in ipairs(tracker.settings.tasks) do
        local normalized = normalize_task(task);
        if normalized == 'xsknife' then
            local step = char_data.xsknife_data.step or 'unknown';
            if step == 'unknown' then print('\30\081[\30\082Homework\30\081]\30\106 \30\104[ ? ]\30\106 ' .. task);
            elseif step == 'scanned_no_ki' then print('\30\081[\30\082Homework\30\081]\30\106 \30\104[   ]\30\106 ' .. task);
            elseif step == 'scanned_has_ki' then print('\30\081[\30\082Homework\30\081]\30\106 \30\104[Boneyard Gully - Requiem of Sin]\30\106 ' .. task);
            elseif step == 'scanned_has_ki_used' then print('\30\081[\30\082Homework\30\081]\30\106 \30\104[Despachiaire]\30\106 ' .. task);
            elseif step == 'despachiaire' then print('\30\081[\30\082Homework\30\081]\30\106 \30\110[Despachiaire]\30\106 ' .. task);
            elseif step == 'boneyard' then print('\30\081[\30\082Homework\30\081]\30\106 \30\110[Boneyard Gully - Requiem of Sin]\30\106 ' .. task);
            elseif step == 'boneyard_2x' then print('\30\081[\30\082Homework\30\081]\30\106 \30\110[2x Boneyard Gully - Requiem of Sin]\30\106 ' .. task);
            elseif step == 'done' then print('\30\081[\30\082Homework\30\081]\30\106 \30\076[X]\30\106 ' .. task);
            else print('\30\081[\30\082Homework\30\081]\30\106 \30\104[   ]\30\106 ' .. task); end
        elseif normalized == 'highwind' then
            local step = char_data.quest_steps.highwind or 'scanned';
            if step == 'scanned' then print('\30\081[\30\082Homework\30\081]\30\106 \30\104[   ]\30\106 ' .. task);
            elseif step == 'start' then print('\30\081[\30\082Homework\30\081]\30\106 \30\110[NM]\30\106 ' .. task);
            elseif step == 'done' then print('\30\081[\30\082Homework\30\081]\30\106 \30\076[X]\30\106 ' .. task); end
        elseif normalized == 'uninvited' then
            local step = char_data.quest_steps.uninvited or 'unknown';
            if step == 'unknown' then print('\30\081[\30\082Homework\30\081]\30\106 \30\104[ ? ]\30\106 ' .. task);
            elseif step == 'scanned' then print('\30\081[\30\082Homework\30\081]\30\106 \30\104[   ]\30\106 ' .. task);
            elseif step == 'justinius' then print('\30\081[\30\082Homework\30\081]\30\106 \30\110[Justinius]\30\106 ' .. task);
            elseif step == 'bcnm' then print('\30\081[\30\082Homework\30\081]\30\106 \30\110[BCNM Monarch]\30\106 ' .. task);
            elseif step == 'justinius_return' then print('\30\081[\30\082Homework\30\081]\30\106 \30\110[Justinius]\30\106 ' .. task);
            elseif step == 'done' then print('\30\081[\30\082Homework\30\081]\30\106 \30\076[X]\30\106 ' .. task); end
        elseif normalized == 'spicegals' then
            local step = char_data.quest_steps.spicegals or 'unknown';
            if step == 'unknown' then print('\30\081[\30\082Homework\30\081]\30\106 \30\104[ ? ]\30\106 ' .. task);
            elseif step == 'scanned' then print('\30\081[\30\082Homework\30\081]\30\106 \30\104[   ]\30\106 ' .. task);
            elseif step == 'riverne' then print('\30\081[\30\082Homework\30\081]\30\106 \30\110[??? Riverne B]\30\106 ' .. task);
            elseif step == 'rouva' then print('\30\081[\30\082Homework\30\081]\30\106 \30\110[Rouva]\30\106 ' .. task);
            elseif step == 'done' then print('\30\081[\30\082Homework\30\081]\30\106 \30\076[X]\30\106 ' .. task); end
        elseif normalized == 'cookbook' then
            local step = char_data.quest_steps.cookbook or 'unknown';
            if step == 'unknown' then print('\30\081[\30\082Homework\30\081]\30\106 \30\104[ ? ]\30\106 ' .. task);
            elseif step == 'scanned' then print('\30\081[\30\082Homework\30\081]\30\106 \30\104[   ]\30\106 ' .. task);
            elseif step == 'jonette' then print('\30\081[\30\082Homework\30\081]\30\106 \30\110[Jonette]\30\106 ' .. task);
            elseif step == 'sacrarium' then print('\30\081[\30\082Homework\30\081]\30\106 \30\110[??? Sacrarium]\30\106 ' .. task);
            elseif step == 'jonette_return' then print('\30\081[\30\082Homework\30\081]\30\106 \30\110[Jonette]\30\106 ' .. task);
            elseif step == 'done' then print('\30\081[\30\082Homework\30\081]\30\106 \30\076[X]\30\106 ' .. task); end
        elseif normalized == 'ecowarrior' then
            local eco_data = char_data.ecowarrior_data or {step = 'unknown', current_nation = nil, locked_nations = {}, knows_status = false};
            local step = eco_data.step or 'unknown';
            local nation = eco_data.current_nation;
            local locked = eco_data.locked_nations or {};
            local knows = eco_data.knows_status;
            local available = {};
            for _, n in ipairs({'sandoria', 'windurst', 'bastok'}) do
                local is_locked = false;
                for _, l in ipairs(locked) do if l == n then is_locked = true; break; end end
                if not is_locked then
                    if n == 'sandoria' then table.insert(available, "San d'Oria");
                    elseif n == 'windurst' then table.insert(available, 'Windurst');
                    elseif n == 'bastok' then table.insert(available, 'Bastok'); end
                end
            end
            local available_text;
            if #available == 3 or #available == 0 then available_text = 'All Nations';
            elseif #available == 2 then available_text = available[1] .. ' & ' .. available[2];
            elseif #available == 1 then available_text = available[1]; end
            -- Color: \30\110 = green (knows_status), \30\104 = yellow (unknown status)
            local color = knows and '\30\110' or '\30\104';
            if step == 'unknown' then print('\30\081[\30\082Homework\30\081]\30\106 \30\104[ ? ]\30\106 ' .. task);
            elseif step == 'scanned' then print('\30\081[\30\082Homework\30\081]\30\106 \30\104[' .. available_text .. ']\30\106 ' .. task);
            elseif step == 'scanned_has_ki' and nation then
                local zone_info = ECOWARRIOR_ZONES[nation];
                if zone_info then print('\30\081[\30\082Homework\30\081]\30\106 \30\104[' .. zone_info.zone_name .. ' - ' .. zone_info.field_agent .. ']\30\106 ' .. task); end
            elseif step == 'ready' then print('\30\081[\30\082Homework\30\081]\30\106 \30\110[' .. available_text .. ']\30\106 ' .. task);
            elseif step == 'field_agent' and nation then
                local zone_info = ECOWARRIOR_ZONES[nation];
                if zone_info then print('\30\081[\30\082Homework\30\081]\30\106 ' .. color .. '[' .. zone_info.zone_name .. ' - ' .. zone_info.field_agent .. ']\30\106 ' .. task); end
            elseif step == 'nm' and nation then
                local zone_info = ECOWARRIOR_ZONES[nation];
                if zone_info then print('\30\081[\30\082Homework\30\081]\30\106 ' .. color .. '[Kill the NM]\30\106 ' .. task); end
            elseif step == 'field_agent_return' and nation then
                local zone_info = ECOWARRIOR_ZONES[nation];
                if zone_info then print('\30\081[\30\082Homework\30\081]\30\106 ' .. color .. '[' .. zone_info.zone_name .. ' - ' .. zone_info.field_agent .. ']\30\106 ' .. task); end
            elseif step == 'reward' and nation then
                local zone_info = ECOWARRIOR_ZONES[nation];
                if zone_info then print('\30\081[\30\082Homework\30\081]\30\106 ' .. color .. '[' .. zone_info.city_name .. ' - ' .. zone_info.quest_npc .. ']\30\106 ' .. task); end
            elseif step == 'done' then print('\30\081[\30\082Homework\30\081]\30\106 \30\076[' .. available_text .. ']\30\106 ' .. task);
            else print('\30\081[\30\082Homework\30\081]\30\106 \30\104[   ]\30\106 ' .. task); end
        end
    end
    local next_reset = calculate_next_reset(current_time);
    local time_left = next_reset - current_time;
    local days = math.floor(time_left / 86400);
    local hours = math.floor((time_left % 86400) / 3600);
    local minutes = math.floor((time_left % 3600) / 60);
    local time_str = '';
    if days > 0 then time_str = string.format('%d day(s)', days);
    elseif hours >= 3 then time_str = string.format('%d hour(s)', hours);
    elseif hours > 0 then time_str = string.format('%d hour(s), %d minute(s)', hours, minutes);
    else time_str = string.format('%d minute(s)', minutes); end
    print('');
    print_msg(string.format('Next reset in %s', time_str));
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
        local timer_data = char_data.enm_timers[enm.name];
        local status_icon = '';
        local status_text = '';
        if timer_data == nil or timer_data.next_ki_time == 0 then
            if timer_data ~= nil and timer_data.has_ki then status_icon = '\30\104[KI]\30\106';
            elseif timer_data ~= nil and not timer_data.has_ki then status_icon = '\30\104[   ]\30\106';
            else status_icon = '\30\104[ ? ]\30\106'; end
            status_text = '\30\071(Unknown)\30\106';
        elseif current_time >= timer_data.next_ki_time then
            if timer_data.has_ki then status_icon = '\30\110[KI]\30\106'; else status_icon = '\30\110[   ]\30\106'; end
            status_text = '\30\071(Ready)\30\106';
        else
            if timer_data.timer_source == 'scan' then
                if timer_data.has_ki then status_icon = '\30\104[KI]\30\106'; else status_icon = '\30\104[   ]\30\106'; end
                status_text = '\30\071(Unknown)\30\106';
            else
                local time_left = timer_data.next_ki_time - current_time;
                local days = math.floor(time_left / 86400);
                local hours = math.floor((time_left % 86400) / 3600);
                if timer_data.has_ki then status_icon = '\30\076[KI]\30\106'; else status_icon = '\30\076[   ]\30\106'; end
                if days > 0 then status_text = string.format('\30\071(%dd %dh)\30\106', days, hours);
                else status_text = string.format('\30\071(%dh)\30\106', hours); end
            end
        end
        print(string.format('\30\081[\30\082Homework\30\081]\30\106 %s %s - %s', status_icon, enm.name, status_text));
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

local function update_char_list()
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
    display_settings.tracked = {};
    ui.font_scale = 1.0;
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
    
    if imgui.Begin('Homework', ui.is_open, ui.window_flags) then
        imgui.PopStyleColor(5);
        imgui.PopStyleVar(2);
        
        -- Apply font scale
        imgui.SetWindowFontScale(ui.font_scale);

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
                elseif step == 'justinius' then icon = '[O]'; color = { 0.0, 1.0, 0.0, 1.0 }; location = 'Justinius';
                elseif step == 'bcnm' then icon = '[O]'; color = { 0.0, 1.0, 0.0, 1.0 }; location = 'BCNM Monarch';
                elseif step == 'justinius_return' then icon = '[O]'; color = { 0.0, 1.0, 0.0, 1.0 }; location = 'Justinius';
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
                elseif step == 'riverne' then icon = '[O]'; color = { 0.0, 1.0, 0.0, 1.0 }; location = 'Riverne B';
                elseif step == 'rouva' then icon = '[O]'; color = { 0.0, 1.0, 0.0, 1.0 }; location = 'Rouva';
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
                elseif step == 'jonette' then icon = '[O]'; color = { 0.0, 1.0, 0.0, 1.0 }; location = 'Jonette';
                elseif step == 'sacrarium' then icon = '[O]'; color = { 0.0, 1.0, 0.0, 1.0 }; location = 'Sacrarium';
                elseif step == 'jonette_return' then icon = '[O]'; color = { 0.0, 1.0, 0.0, 1.0 }; location = 'Jonette';
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
                local locked = eco_data.locked_nations or {};
                local knows = eco_data.knows_status;

                -- Build available nations list
                local available = {};
                for _, n in ipairs({'sandoria', 'windurst', 'bastok'}) do
                    local is_locked = false;
                    for _, l in ipairs(locked) do if l == n then is_locked = true; break; end end
                    if not is_locked then
                        if n == 'sandoria' then table.insert(available, "San d'Oria");
                        elseif n == 'windurst' then table.insert(available, 'Windurst');
                        elseif n == 'bastok' then table.insert(available, 'Bastok'); end
                    end
                end
                local available_text = #available > 0 and table.concat(available, '/') or 'All done';

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
                        if zone_info then location = zone_info.zone_name .. ' - ' .. zone_info.field_agent; end
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
                            if step == 'field_agent' then location = zone_info.zone_name .. ' - ' .. zone_info.field_agent;
                            elseif step == 'nm' then location = 'Kill NM';
                            elseif step == 'field_agent_return' then location = zone_info.zone_name .. ' - ' .. zone_info.field_agent;
                            elseif step == 'reward' then location = zone_info.city_name .. ' - ' .. zone_info.quest_npc; end
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
        local timer_col_status = 160 * ui.font_scale;

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
                        icon = '[KI]'; icon_color = { 1.0, 0.3, 0.3, 1.0 };
                    else
                        icon = '[  ]'; icon_color = { 1.0, 0.3, 0.3, 1.0 };
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
    print_msg('Weekly Homework for \30\110' .. char_name .. '\30\106:');
    print_msg('=================');
    for _, task in ipairs(tracker.settings.tasks) do
        local normalized = normalize_task(task);
        if normalized == 'xsknife' then
            local step = char_data.xsknife_data.step or 'unknown';
            if step == 'unknown' then print('\30\081[\30\082Homework\30\081]\30\106 \30\104[ ? ]\30\106 ' .. task);
            elseif step == 'scanned_no_ki' then print('\30\081[\30\082Homework\30\081]\30\106 \30\104[   ]\30\106 ' .. task);
            elseif step == 'scanned_has_ki' then print('\30\081[\30\082Homework\30\081]\30\106 \30\104[Boneyard Gully - Requiem of Sin]\30\106 ' .. task);
            elseif step == 'scanned_has_ki_used' then print('\30\081[\30\082Homework\30\081]\30\106 \30\104[Despachiaire]\30\106 ' .. task);
            elseif step == 'despachiaire' then print('\30\081[\30\082Homework\30\081]\30\106 \30\110[Despachiaire]\30\106 ' .. task);
            elseif step == 'boneyard' then print('\30\081[\30\082Homework\30\081]\30\106 \30\110[Boneyard Gully - Requiem of Sin]\30\106 ' .. task);
            elseif step == 'boneyard_2x' then print('\30\081[\30\082Homework\30\081]\30\106 \30\110[2x Boneyard Gully - Requiem of Sin]\30\106 ' .. task);
            elseif step == 'done' then print('\30\081[\30\082Homework\30\081]\30\106 \30\076[X]\30\106 ' .. task);
            else print('\30\081[\30\082Homework\30\081]\30\106 \30\104[   ]\30\106 ' .. task); end
        elseif normalized == 'highwind' then
            local step = char_data.quest_steps.highwind or 'scanned';
            if step == 'scanned' then print('\30\081[\30\082Homework\30\081]\30\106 \30\104[   ]\30\106 ' .. task);
            elseif step == 'start' then print('\30\081[\30\082Homework\30\081]\30\106 \30\110[NM]\30\106 ' .. task);
            elseif step == 'done' then print('\30\081[\30\082Homework\30\081]\30\106 \30\076[X]\30\106 ' .. task); end
        elseif normalized == 'uninvited' then
            local step = char_data.quest_steps.uninvited or 'unknown';
            if step == 'unknown' then print('\30\081[\30\082Homework\30\081]\30\106 \30\104[ ? ]\30\106 ' .. task);
            elseif step == 'scanned' then print('\30\081[\30\082Homework\30\081]\30\106 \30\104[   ]\30\106 ' .. task);
            elseif step == 'justinius' then print('\30\081[\30\082Homework\30\081]\30\106 \30\110[Justinius]\30\106 ' .. task);
            elseif step == 'bcnm' then print('\30\081[\30\082Homework\30\081]\30\106 \30\110[BCNM Monarch]\30\106 ' .. task);
            elseif step == 'justinius_return' then print('\30\081[\30\082Homework\30\081]\30\106 \30\110[Justinius]\30\106 ' .. task);
            elseif step == 'done' then print('\30\081[\30\082Homework\30\081]\30\106 \30\076[X]\30\106 ' .. task); end
        elseif normalized == 'spicegals' then
            local step = char_data.quest_steps.spicegals or 'unknown';
            if step == 'unknown' then print('\30\081[\30\082Homework\30\081]\30\106 \30\104[ ? ]\30\106 ' .. task);
            elseif step == 'scanned' then print('\30\081[\30\082Homework\30\081]\30\106 \30\104[   ]\30\106 ' .. task);
            elseif step == 'riverne' then print('\30\081[\30\082Homework\30\081]\30\106 \30\110[??? Riverne B]\30\106 ' .. task);
            elseif step == 'rouva' then print('\30\081[\30\082Homework\30\081]\30\106 \30\110[Rouva]\30\106 ' .. task);
            elseif step == 'done' then print('\30\081[\30\082Homework\30\081]\30\106 \30\076[X]\30\106 ' .. task); end
        elseif normalized == 'cookbook' then
            local step = char_data.quest_steps.cookbook or 'unknown';
            if step == 'unknown' then print('\30\081[\30\082Homework\30\081]\30\106 \30\104[ ? ]\30\106 ' .. task);
            elseif step == 'scanned' then print('\30\081[\30\082Homework\30\081]\30\106 \30\104[   ]\30\106 ' .. task);
            elseif step == 'jonette' then print('\30\081[\30\082Homework\30\081]\30\106 \30\110[Jonette]\30\106 ' .. task);
            elseif step == 'sacrarium' then print('\30\081[\30\082Homework\30\081]\30\106 \30\110[??? Sacrarium]\30\106 ' .. task);
            elseif step == 'jonette_return' then print('\30\081[\30\082Homework\30\081]\30\106 \30\110[Jonette]\30\106 ' .. task);
            elseif step == 'done' then print('\30\081[\30\082Homework\30\081]\30\106 \30\076[X]\30\106 ' .. task); end
        elseif normalized == 'ecowarrior' then
            local eco_data = char_data.ecowarrior_data or {step = 'unknown', current_nation = nil, locked_nations = {}, knows_status = false};
            local step = eco_data.step or 'unknown';
            local nation = eco_data.current_nation;
            local locked = eco_data.locked_nations or {};
            local knows = eco_data.knows_status;
            local available = {};
            for _, n in ipairs({'sandoria', 'windurst', 'bastok'}) do
                local is_locked = false;
                for _, l in ipairs(locked) do if l == n then is_locked = true; break; end end
                if not is_locked then
                    if n == 'sandoria' then table.insert(available, "San d'Oria");
                    elseif n == 'windurst' then table.insert(available, 'Windurst');
                    elseif n == 'bastok' then table.insert(available, 'Bastok'); end
                end
            end
            local available_text;
            if #available == 3 or #available == 0 then available_text = 'All Nations';
            elseif #available == 2 then available_text = available[1] .. ' & ' .. available[2];
            elseif #available == 1 then available_text = available[1]; end
            local color = knows and '\30\110' or '\30\104';
            if step == 'unknown' then print('\30\081[\30\082Homework\30\081]\30\106 \30\104[ ? ]\30\106 ' .. task);
            elseif step == 'scanned' then print('\30\081[\30\082Homework\30\081]\30\106 \30\104[' .. available_text .. ']\30\106 ' .. task);
            elseif step == 'scanned_has_ki' and nation then
                local zone_info = ECOWARRIOR_ZONES[nation];
                if zone_info then print('\30\081[\30\082Homework\30\081]\30\106 \30\104[' .. zone_info.zone_name .. ' - ' .. zone_info.field_agent .. ']\30\106 ' .. task); end
            elseif step == 'ready' then print('\30\081[\30\082Homework\30\081]\30\106 \30\110[' .. available_text .. ']\30\106 ' .. task);
            elseif step == 'field_agent' and nation then
                local zone_info = ECOWARRIOR_ZONES[nation];
                if zone_info then print('\30\081[\30\082Homework\30\081]\30\106 ' .. color .. '[' .. zone_info.zone_name .. ' - ' .. zone_info.field_agent .. ']\30\106 ' .. task); end
            elseif step == 'nm' and nation then
                print('\30\081[\30\082Homework\30\081]\30\106 ' .. color .. '[Kill the NM]\30\106 ' .. task);
            elseif step == 'field_agent_return' and nation then
                local zone_info = ECOWARRIOR_ZONES[nation];
                if zone_info then print('\30\081[\30\082Homework\30\081]\30\106 ' .. color .. '[' .. zone_info.zone_name .. ' - ' .. zone_info.field_agent .. ']\30\106 ' .. task); end
            elseif step == 'reward' and nation then
                local zone_info = ECOWARRIOR_ZONES[nation];
                if zone_info then print('\30\081[\30\082Homework\30\081]\30\106 ' .. color .. '[' .. zone_info.city_name .. ' - ' .. zone_info.quest_npc .. ']\30\106 ' .. task); end
            elseif step == 'done' then print('\30\081[\30\082Homework\30\081]\30\106 \30\076[' .. available_text .. ']\30\106 ' .. task);
            else print('\30\081[\30\082Homework\30\081]\30\106 \30\104[   ]\30\106 ' .. task); end
        end
    end
    local next_reset = calculate_next_reset(current_time);
    local days_until = math.floor((next_reset - current_time) / 86400);
    print_msg(string.format('Next reset in %d day(s)', days_until));
    print('');
    print_msg('ENM & Limbus Timers for \30\110' .. char_name .. '\30\106:');
    print_msg('====================');
    for _, enm in ipairs(ENM_KEY_ITEMS) do
        local timer_data = char_data.enm_timers[enm.name];
        local status_icon = '\30\104[ ? ]\30\106';
        local status_text = '\30\071(Unknown)\30\106';
        if timer_data ~= nil then
            if timer_data.next_ki_time == 0 then
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
                if timer_data.has_ki then status_icon = '\30\076[KI]\30\106'; else status_icon = '\30\076[   ]\30\106'; end
                if days > 0 then status_text = string.format('\30\071(%dd %dh)\30\106', days, hours);
                else status_text = string.format('\30\071(%dh)\30\106', hours); end
            end
        end
        print(string.format('\30\081[\30\082Homework\30\081]\30\106 %s %s - %s', status_icon, enm.name, status_text));
    end
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
        if char_data.quest_steps.spicegals == 'done' then char_data.quest_steps.spicegals = 'riverne'; print_success('Unmarked ' .. proper_name .. ' for ' .. tracker.current_char);
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
    local dir = addon.path .. '/settings/';
    if not ashita.fs.exists(dir) then
        ashita.fs.create_dir(dir);
    end
    local loaded_settings = load_settings();
    if loaded_settings ~= nil then
        tracker.settings = loaded_settings;
        if tracker.settings.characters == nil then tracker.settings.characters = {}; end
        local needs_save = false;
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
        if populate_kis_from_memory() then
            scan_key_items(true);
            print_success('Auto-scanned key items.');
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
    
    -- Base mode 142: Highwind completion
    if base_mode == 142 then
        if is_in_highwind_zone() and message:contains('Obtained 3000 gil') then
            char_data.quest_steps.highwind = 'done';
            save_settings();
            print_success('Highwind complete!');
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
    -- Login packet
    if id == 0x000A then
        if tracker.login_state.waiting_for_login then
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
            end
        end
        return;
    end
    -- Key Item packet
    if id == 0x0055 then
        local offset = struct.unpack('B', data, 0x84 + 1) * 512;
        for i = 0, 511 do
            local ki_position = i + offset;
            local byte_index = math.floor(i / 8);
            local bit_index = i % 8;
            local ki_byte = struct.unpack('B', data, 0x04 + byte_index + 1);
            local has_ki = bit.band(bit.rshift(ki_byte, bit_index), 1) == 1;
            if (tracker.kis[ki_position] ~= nil) and (has_ki ~= tracker.kis[ki_position]) then
                if has_ki then on_ki_gained(ki_position); else on_ki_lost(ki_position); end
            end
            tracker.kis[ki_position] = has_ki;
        end
        if tracker.login_state.waiting_for_ki then
            tracker.login_state.ki_packets_received = tracker.login_state.ki_packets_received + 1;
            if tracker.login_state.ki_packets_received >= 7 then
                tracker.login_state.waiting_for_ki = false;
                tracker.login_state.ki_packets_received = 0;
                tracker.kis_initialized = true;
                local char_data = get_char_data();
                if char_data ~= nil then
                    scan_key_items(true);
                    print_success('Auto-scanned key items.');
                end
            end
        else
            tracker.kis_initialized = true;
        end
        return;
    end
    return;
end);

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
    if char_data.last_reset > 0 then
        local last_reset_point = calculate_next_reset(char_data.last_reset);
        if current_time >= last_reset_point and char_data.last_reset < last_reset_point then reset_tracker(); end
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
        print_msg('Type /hw yes to confirm, or /hw no to cancel.');
        tracker.pending_reset = true;
        return;
    end
    if (args[2] == 'yes') then
        if tracker.pending_reset then
            factory_reset();
            tracker.pending_reset = false;
        else
            print_error('Nothing to confirm.');
        end
        return;
    end
    if (args[2] == 'no') then
        if tracker.pending_reset then
            print_msg('Reset cancelled.');
            tracker.pending_reset = false;
        else
            print_error('Nothing to cancel.');
        end
        return;
    end
    if (args[2] == 'scan') then
        if not tracker.kis_initialized then populate_kis_from_memory(); end
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