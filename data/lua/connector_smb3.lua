--[[
Copyright (c) 2024 MooingLemur
Portions adapted from connector_bizhawk_generic.lua, Copyright (c) 2023 Zunawe

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
]]

local SCRIPT_VERSION = 1

-- Set to log incoming requests
-- Will cause lag due to large console output
local DEBUG = true

--[[
This script expects to receive JSON and will send JSON back. A message should
be a list of 1 or more requests which will be executed in order. Each request
will have a corresponding response in the same order.

Every individual request and response is a JSON object with at minimum one
field `type`. The value of `type` determines what other fields may exist.

To get the script version, instead of JSON, send "VERSION" to get the script
version directly (e.g. "2").

#### Ex. 1

Request: `[{"type": "PING"}]`

Response: `[{"type": "PONG"}]`

]]

local bizhawk_version = client.getversion()
local bizhawk_major, bizhawk_minor, bizhawk_patch = bizhawk_version:match("(%d+)%.(%d+)%.?(%d*)")
bizhawk_major = tonumber(bizhawk_major)
bizhawk_minor = tonumber(bizhawk_minor)
if bizhawk_patch == "" then
    bizhawk_patch = 0
else
    bizhawk_patch = tonumber(bizhawk_patch)
end

local lua_major, lua_minor = _VERSION:match("Lua (%d+)%.(%d+)")
lua_major = tonumber(lua_major)
lua_minor = tonumber(lua_minor)

if lua_major > 5 or (lua_major == 5 and lua_minor >= 3) then
    require("lua_5_3_compat")
end

local base64 = require("base64")
local socket = require("socket")
local json = require("json")

local SOCKET_PORT_FIRST = 43055
local SOCKET_PORT_RANGE_SIZE = 5
local SOCKET_PORT_LAST = SOCKET_PORT_FIRST + SOCKET_PORT_RANGE_SIZE

local STATE_NOT_CONNECTED = 0
local STATE_CONNECTED = 1

local server = nil
local client_socket = nil

local current_state = STATE_NOT_CONNECTED

local timeout_timer = 0
local message_timer = 0
local message_interval = 0
local prev_time = 0
local current_time = 0

local locked = false

local rom_hash = nil

-- ## Archipelago unlocks ##
-- 0 = walking, 1 = running, 2 = p-speed
local ap_progressive_speed = 2
-- 0 = small, 1 = mush, 2 = fire, 3 = raccoon
-- 4 = frog, 5 = tanooki, 6 = hammer
local ap_progressive_powerup = 3
-- Star allowed
local ap_starman_progression = 0
-- 

-- ## Archipelago state ##
local aps_entered_world = nil
local aps_entered_y = nil
local aps_entered_xhi = nil
local aps_entered_x = nil

function queue_push (self, value)
    self[self.right] = value
    self.right = self.right + 1
end

function queue_is_empty (self)
    return self.right == self.left
end

function queue_shift (self)
    value = self[self.left]
    self[self.left] = nil
    self.left = self.left + 1
    return value
end

function new_queue ()
    local queue = {left = 1, right = 1}
    return setmetatable(queue, {__index = {is_empty = queue_is_empty, push = queue_push, shift = queue_shift}})
end

local message_queue = new_queue()

function lock ()
    locked = true
    client_socket:settimeout(2)
end

function unlock ()
    locked = false
    client_socket:settimeout(0)
end

request_handlers = {
    ["PING"] = function (req)
        local res = {}

        res["type"] = "PONG"

        return res
    end,

    ["HASH"] = function (req)
        local res = {}

        res["type"] = "HASH_RESPONSE"
        res["value"] = rom_hash

        return res
    end,

    ["LOCK"] = function (req)
        local res = {}

        res["type"] = "LOCKED"
        lock()

        return res
    end,

    ["UNLOCK"] = function (req)
        local res = {}

        res["type"] = "UNLOCKED"
        unlock()

        return res
    end,

    ["DISPLAY_MESSAGE"] = function (req)
        local res = {}

        res["type"] = "DISPLAY_MESSAGE_RESPONSE"
        message_queue:push(req["message"])

        return res
    end,

    ["SET_MESSAGE_INTERVAL"] = function (req)
        local res = {}

        res["type"] = "SET_MESSAGE_INTERVAL_RESPONSE"
        message_interval = req["value"]

        return res
    end,

    ["default"] = function (req)
        local res = {}

        res["type"] = "ERROR"
        res["err"] = "Unknown command: "..req["type"]

        return res
    end,
}

function process_request (req)
    if request_handlers[req["type"]] then
        return request_handlers[req["type"]](req)
    else
        return request_handlers["default"](req)
    end
end

-- Receive data from AP client and send message back
function send_receive ()
    local message, err = client_socket:receive()

    -- Handle errors
    if err == "closed" then
        if current_state == STATE_CONNECTED then
            print("Connection to client closed")
        end
        current_state = STATE_NOT_CONNECTED
        return
    elseif err == "timeout" then
        unlock()
        return
    elseif err ~= nil then
        print(err)
        current_state = STATE_NOT_CONNECTED
        unlock()
        return
    end

    -- Reset timeout timer
    timeout_timer = 5

    -- Process received data
    if DEBUG then
        print("Received Message ["..emu.framecount().."]: "..'"'..message..'"')
    end

    if message == "VERSION" then
        client_socket:send(tostring(SCRIPT_VERSION).."\n")
    else
        local res = {}
        local data = json.decode(message)
        local failed_guard_response = nil
        for i, req in ipairs(data) do
            if failed_guard_response ~= nil then
                res[i] = failed_guard_response
            else
                -- An error is more likely to cause an NLua exception than to return an error here
                local status, response = pcall(process_request, req)
                if status then
                    res[i] = response

                    -- If the GUARD validation failed, skip the remaining commands
                    if response["type"] == "GUARD_RESPONSE" and not response["value"] then
                        failed_guard_response = response
                    end
                else
                    if type(response) ~= "string" then response = "Unknown error" end
                    res[i] = {type = "ERROR", err = response}
                end
            end
        end

        client_socket:send(json.encode(res).."\n")
    end
end

function initialize_server ()
    local err
    local port = SOCKET_PORT_FIRST
    local res = nil

    server, err = socket.socket.tcp4()
    while res == nil and port <= SOCKET_PORT_LAST do
        res, err = server:bind("localhost", port)
        if res == nil and err ~= "address already in use" then
            print(err)
            return
        end

        if res == nil then
            port = port + 1
        end
    end

    if port > SOCKET_PORT_LAST then
        print("Too many instances of connector script already running. Exiting.")
        return
    end

    res, err = server:listen(0)

    if err ~= nil then
        print(err)
        return
    end

    server:settimeout(0)
end

-- SMB3 bank detection
-- Bank Addr Magic
-- 00   C000 08 0C
-- 01   A000 A0 D3
-- 02   A000 35 AA
-- 03   A000 46 B4
-- 04   A000 2A B2
-- 05   A000 B5 B1
-- 06   C000 00 FF
-- 07   A000 A8 A8
-- 08   A000 FF 00
-- 09   A000 00 02
-- 10   C000 29 08
-- 11   A000 00 01
-- 12   A000 88 DC
-- 13   A000 FC 4E
-- 14   C000 FC 3B
-- 15   A000 FC 3B*   A400 25 50
-- 16   A000 FC 4E
-- 17   A000 FC 3B*   A400 1F 4A
-- 18   A000 FF FF**  A400 0A 4C
-- 19   A000 FC 2B
-- 20   A000 FC 7F
-- 21   A000 FC 3B*   A400 11 5A
-- 22   C000 FD FD
-- 23   A000 FF FF**  A400 24 5C
-- 24   A000 AD FD
-- 25   C000 01 28
-- 26   A000 20 E6
-- 27   A000 AD 11
-- 28   A000 A9 FF
-- 29   C000 98 56
-- 30   8000 00 60
-- 31   E000 55 55

function is_prg01 ()
    return (memory.read_u16_be(0xA000) == 0xA0D3)
end

function is_prg08 ()
    return (memory.read_u16_be(0xA000) == 0xFF00)
end

function is_prg10 ()
    return (memory.read_u16_be(0xC000) == 0x2908)
end

function is_prg11 ()
    return (memory.read_u16_be(0xA000) == 0x0001)
end

function is_prg12 ()
    return (memory.read_u16_be(0xA000) == 0x88DC)
end

function is_prg24 ()
    return (memory.read_u16_be(0xA000) == 0xADFD)
end

function is_prg26 ()
    return (memory.read_u16_be(0xA000) == 0x20E6)
end

function cb_titlescreen_playersel ()
    -- This prevents the player from selecting a 2 player game
    if is_prg24() then
        if DEBUG then
            gui.addmessage("DEBUG: Archipelago is 1P only")
        end
        emu.setregister("A", 0) -- force "1 player game"
    end
end

function cb_reenter_level ()
    if is_prg10() then
        local world_map_tile = memory.read_u8(0x00E5)
        if bit.band(world_map_tile, 0x3F) == 0 or world_map_tile == 0x60 then -- completed mario tile or fortress rubble
            emu.setregister("PC", 0xCEA7) -- force level entry
            if DEBUG then
                gui.addmessage("DEBUG: Re-entering completed level")
            end
        end
    end
end

function cb_normal_level_entry ()
    if is_prg10() then
        if DEBUG then
            gui.addmessage("DEBUG: Normal level entry")
        end
    end
end

function cb_powerup_mushroom ()
    if is_prg01() then
        if ap_progressive_powerup < 1 then
            emu.setregister("PC", 0xA8B0) -- collect mushroom without effect
            if DEBUG then
                gui.addmessage("DEBUG: Mushroom denied")
            end
        end
    end
end

function cb_powerup_fireflower ()
    if is_prg01() then
        if ap_progressive_powerup < 2 then
            emu.setregister("PC", 0xAA13) -- collect fireflower without effect
            if DEBUG then
                gui.addmessage("DEBUG: Fireflower denied")
            end
        end
    end
end

function cb_powerup_superleaf ()
    if is_prg01() then
        if ap_progressive_powerup < 3 then
            emu.setregister("PC", 0xAC3B) -- collect superleaf without effect
            if DEBUG then
                gui.addmessage("DEBUG: Superleaf denied")
            end
        end
    end
end

function cb_powerup_star_or_suit ()
    if is_prg01() then
        local powerup_type = emu.getregister("A")
        if powerup_type == 0 then -- starman
            if ap_starman_progression < 1 then
                emu.setregister("PC", 0xA834) -- collect starman without effect
                if DEBUG then
                    gui.addmessage("DEBUG: Starman denied")
                end
            end
        elseif ap_progressive_powerup < powerup_type then
            emu.setregister("PC", 0xA834) -- collect suit without effect
            if DEBUG then
                gui.addmessage("DEBUG: Suit " .. powerup_type .. " denied")
            end
        end
    end
end

function cb_player_speed ()
    if is_prg08() then
        local topspeed = emu.getregister("Y")
        if ap_progressive_speed == 0 and topspeed > 0x18 then
            emu.setregister("Y", 0x18) -- Max walking speed
            if DEBUG then
                gui.addmessage("DEBUG: Limiting speed to walking")
            end
        elseif ap_progressive_speed == 1 and topspeed > 0x28 then
            emu.setregister("Y", 0x28) -- Max running speed
            local player_power = memory.read_u8(0x03DD)
            if player_power == 0x7F then
                memory.write_u8(0x03DD, 0x3F) -- deny P speed
            end
            if DEBUG then
                gui.addmessage("DEBUG: Limiting speed to running")
            end
        end
    end
end

function cb_level_clear ()
    if is_prg11() then
        if DEBUG then
            gui.addmessage("DEBUG: level clear")
        end
    end
end

function cb_inventory_flip ()
    if is_prg10() then
        -- load inventory
        local inv = {}
        local j = 1
        inv[0] = 0x0C -- warp whistle
        if DEBUG then
            -- in debug mode, add cloud
            inv[j] = 0x07
            j = j + 1
        end
        for i=0,27 do
            local item = memory.read_u8(0x7D80+i)
            if item == 0x0C then goto continue end
            if DEBUG and item == 0x07 then goto continue end
            inv[j] = memory.read_u8(0x7D80+i)
            j = j + 1
            ::continue::
        end
        for i=0,27 do
            if inv[i] == nil then
                memory.write_u8(0x7D80+i, 0)
            else
                memory.write_u8(0x7D80+i, inv[i])
            end
        end
        if DEBUG then
            gui.addmessage("DEBUG: ensuring inventory contains base itmes")
        end
    end
end

function cb_use_item_star ()
    if is_prg26() then
        if ap_starman_progression < 1 then
            emu.setregister("PC", 0xA687) -- deny item use
            if DEBUG then
                gui.addmessage("DEBUG: Starman item denied")
            end
        end
    end
end

function cb_use_item_powerup ()
    if is_prg26() then
        local powerup_item = emu.getregister("X")
        if powerup_item == 8 and (ap_progressive_speed < 2 or ap_progressive_powerup < 3) then -- P-wing
            emu.setregister("PC", 0xA687) -- deny item use
            if DEBUG then
                gui.addmessage("DEBUG: P-Wing item denied")
            end
        elseif powerup_item <= 6 and ap_progressive_powerup < powerup_item then
            emu.setregister("PC", 0xA687) -- deny item use
            if DEBUG then
                gui.addmessage("DEBUG: Progressive item denied")
            end
        end
    end
end

function cb_world_loaded ()
    if is_prg12() then
        local world_num = memory.read_u8(0x0727)
        if world_num == 8 then -- World 9, zero-indexed
            -- form a path between the rows of the warp zone
            -- Level data starts at 0x6000
            -- World map data starts at 0x6110
            -- We don't care about the first 4 rows
            -- The first row we change starts at 0x6150
            -- and then we continue down
            memory.write_u8(0x6154, 0xDB)
            memory.write_u8(0x6164, 0xDD)
            memory.write_u8(0x6174, 0xDB)
            memory.write_u8(0x6184, 0xDD)
            -- now fill out the row with level 8
            memory.write_u8(0x6185, 0xDA)
            memory.write_u8(0x6186, 0xBC) -- pipe for World 1
            memory.write_u8(0x6187, 0xDA)
            -- connect the nub
            memory.write_u8(0x6188, 0xDC)
            -- and repair the island
            memory.write_u8(0x6195, 0x85)
            memory.write_u8(0x6196, 0x85)
            memory.write_u8(0x6197, 0x85)
            if DEBUG then
                gui.addmessage("DEBUG: Populate extra World 9 structure")
            end
        end
    end
end

function cb_video_do_update ()
    -- this is in always-loaded bank #30
    -- check to see if we just drew the warp zone banner
    if emu.getregister("A") == 0x2B then
        memory.write_u8(0x28B1, 0xBC, "PPU Bus") -- A
        memory.write_u8(0x28B2, 0xD9, "PPU Bus") -- P
        memory.write_u8(0x28B3, 0xFE, "PPU Bus") -- _
        memory.write_u8(0x28B4, 0xD8, "PPU Bus") -- W
        memory.write_u8(0x28B5, 0xF0, "PPU Bus") -- O
        memory.write_u8(0x28B6, 0xE9, "PPU Bus") -- R
        memory.write_u8(0x28B7, 0xEC, "PPU Bus") -- L
        memory.write_u8(0x28B8, 0xEE, "PPU Bus") -- D
        memory.write_u8(0x28B9, 0xFE, "PPU Bus") -- _
        -- place a sprite for the pipe we added
        -- for World 1
        memory.write_u8(0x02C4, 0x7F) -- Y 
        memory.write_u8(0x02C5, 0xF0) -- Tile
        memory.write_u8(0x02C6, 0x01) -- Attr
        memory.write_u8(0x02C7, 0x64) -- X
        if DEBUG then
            gui.addmessage("DEBUG: Modify WZ banner")
        end
    end
end


function register_hypercalls ()
    event.onmemoryexecute(cb_titlescreen_playersel, 0xAC68)
    event.onmemoryexecute(cb_normal_level_entry, 0xCEA7)
    event.onmemoryexecute(cb_reenter_level, 0xCEDF)
    event.onmemoryexecute(cb_powerup_mushroom, 0xA89A)
    event.onmemoryexecute(cb_powerup_fireflower, 0xAA05)
    event.onmemoryexecute(cb_powerup_superleaf, 0xAC37)
    event.onmemoryexecute(cb_powerup_star_or_suit, 0xA801)
    event.onmemoryexecute(cb_player_speed, 0xAB83)
    event.onmemoryexecute(cb_level_clear, 0xBA67)
    event.onmemoryexecute(cb_inventory_flip, 0xC439)
    event.onmemoryexecute(cb_use_item_star, 0xA671)
    event.onmemoryexecute(cb_use_item_powerup, 0xA5CB)
    event.onmemoryexecute(cb_world_loaded, 0xA4C1)
    event.onmemoryexecute(cb_video_do_update, 0x94EE)
end

function main ()
    while true do
        if server == nil then
            initialize_server()
        end

        current_time = socket.socket.gettime()
        timeout_timer = timeout_timer - (current_time - prev_time)
        message_timer = message_timer - (current_time - prev_time)
        prev_time = current_time

        if message_timer <= 0 and not message_queue:is_empty() then
            gui.addmessage(message_queue:shift())
            message_timer = message_interval
        end

        if current_state == STATE_NOT_CONNECTED then
            if emu.framecount() % 30 == 0 then
                print("Looking for client...")
                local client, timeout = server:accept()
                if timeout == nil then
                    print("Client connected")
                    current_state = STATE_CONNECTED
                    client_socket = client
                    server:close()
                    server = nil
                    client_socket:settimeout(0)
                end
            end
        else
            repeat
                send_receive()
            until not locked

            if timeout_timer <= 0 then
                print("Client timed out")
                current_state = STATE_NOT_CONNECTED
            end
        end

        coroutine.yield()
    end
end

event.onexit(function ()
    print("\n-- Restarting Script --\n")
    if server ~= nil then
        server:close()
    end
end)

if bizhawk_major < 2 or (bizhawk_major == 2 and bizhawk_minor < 7) then
    print("Must use BizHawk 2.7.0 or newer")
elseif bizhawk_major > 2 or (bizhawk_major == 2 and bizhawk_minor > 9) then
    print("Warning: This version of BizHawk is newer than this script. If it doesn't work, consider downgrading to 2.9.")
else
    if emu.getsystemid() == "NULL" then
        print("No ROM is loaded. Please load a ROM.")
        while emu.getsystemid() == "NULL" do
            emu.frameadvance()
        end
    end

    rom_hash = gameinfo.getromhash()

    if rom_hash == "6BD518E85EB46A4252AF07910F61036E84B020D1" then
        print("SMB3 ROM found")

        print("Registering hypercalls")
        register_hypercalls()

        print("Waiting for client to connect. This may take longer the more instances of this script you have open at once.\n")

        local co = coroutine.create(main)
        function tick ()
            local status, err = coroutine.resume(co)

            if not status and err ~= "cannot resume dead coroutine" then
                print("\nERROR: "..err)
                print("Consider reporting this crash.\n")

                if server ~= nil then
                    server:close()
                end

                co = coroutine.create(main)
            end
        end

        while true do
            emu.frameadvance()
        end
    else
        print("Unsupported ROM")
    end
end

