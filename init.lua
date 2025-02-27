local http = minetest.request_http_api()
local settings = minetest.settings

local port = settings:get('discord.port') or 8080
local timeout = 10

discord = {}

discord.text_colorization = settings:get('discord.text_color') or '#ffffff'

discord.registered_on_messages = {}

local irc_enabled = minetest.get_modpath("irc")

function discord.register_on_message(func)
    table.insert(discord.registered_on_messages, func)
end

discord.chat_send_all = minetest.chat_send_all

local byte, len, sub, tconcat = utf8.byte, utf8.len, utf8.sub, table.concat
local function remove_emoji(message)
    local s = {}
    for i = 1, len(message) do
        if byte(message, i) >= 32 and byte(message, i) <= 1105 then
            s[#s + 1] = sub(message, i, i)
        end
    end

    return tconcat(s)
end

-- Allow the chat message format to be customised by other mods
function discord.format_chat_message(name, msg)
    -- Has to be here because chat_anticurse currently optionally depends on
    -- discordmt
    if minetest.global_exists("chat_anticurse") then
        local has_bad_words, censored_msg = chat_anticurse.check_curse(msg)
        if has_bad_words then
            msg = censored_msg
        end
    end
    return remove_emoji(('%s@Discord: %s'):format(name, msg))
end

function discord.handle_response(response)
    local data = response.data
    if data == '' or data == nil then
        return
    end
    local data = minetest.parse_json(response.data)
    if not data then
        return
    end
    if data.messages then
        for _, message in pairs(data.messages) do
            for _, func in pairs(discord.registered_on_messages) do
                func(message.author, message.content)
            end
            local msg = discord.format_chat_message(message.author, message.content)
            discord.chat_send_all(minetest.colorize(discord.text_colorization, msg))
            if irc_enabled then
                irc.say(msg)
            end
            minetest.log('action', '[Discord] Message: '..msg)
        end
    end
    if data.commands then
        local commands = minetest.registered_chatcommands
        for _, v in pairs(data.commands) do
            if commands[v.command] then
                if minetest.get_ban_description(v.name) ~= '' then
                    discord.send('You cannot run commands because you are banned.', v.context or nil)
                    return
                end
                local player_privs = minetest.get_player_privs(v.name)
                --[[if not player_privs.ban then
                    discord.send('Only server staff can use commands.', v.context or nil)
                    return
                end]]
                -- Check player privileges
                local required_privs = commands[v.command].privs or {}
                for priv, value in pairs(required_privs) do
                    if player_privs[priv] ~= value then
                        discord.send('Insufficient privileges.', v.context or nil)
                        return
                    end
                end
                local old_chat_send_player = minetest.chat_send_player
                minetest.chat_send_player = function(name, message)
                    old_chat_send_player(name, message)
                    if name == v.name then
                        discord.send(message, v.context or nil)
                    end
                end
                minetest.log('warning', '[Discord] Command: ' .. v.command .. " executed with param: ".. dump(v.params or '') .. " by " .. v.name)

                local command = commands[v.command]
                local success, err_msg, ret_val = pcall(function()
                    return command.func(v.name, v.params or '')
                end)

                if not success then
                    minetest.log("error", "[Discord] Error executing command " .. v.command .. ": " ..
                        tostring(err_msg))
                    return
                end

                if type(ret_val) == "string" and ret_val ~= "" then
                    discord.send(ret_val, v.context or nil)
                end
                minetest.chat_send_player = old_chat_send_player
            else
                discord.send(('Command not found: `%s`'):format(v.command), v.context or nil)
            end
        end
    end
    if data.logins then
        local auth = minetest.get_auth_handler()
        for _, v in pairs(data.logins) do
            local authdata = auth.get_auth(v.username)
            local result = false
            if authdata then
                result = minetest.check_password_entry(v.username, authdata.password, v.password)
            end
            local request = {
                type = 'DISCORD_LOGIN_RESULT',
                user_id = v.user_id,
                username = v.username,
                success = result
            }
            http.fetch({
                url = 'localhost:'..tostring(port),
                timeout = timeout,
                post_data = minetest.write_json(request)
            }, discord.handle_response)
        end
    end
end

function discord.send(message, id)
    local data = {
        type = 'DISCORD-RELAY-MESSAGE',
        content = minetest.strip_colors(message)
    }
    if id then
        data['context'] = id
    end
    http.fetch({
        url = 'localhost:'..tostring(port),
        timeout = timeout,
        post_data = minetest.write_json(data)
    }, function(_) end)
end

function minetest.chat_send_all(message)
    discord.chat_send_all(message)
    discord.send(message)
end

-- Register the chat message callback after other mods load so that anything
-- that overrides chat will work correctly
minetest.after(0, minetest.register_on_chat_message, function(name, message)
    if minetest.check_player_privs(name, "shout") then
        discord.send(minetest.format_chat_message(name, message))
    end
end)

local timer = 0
minetest.register_globalstep(function(dtime)
    if dtime then
        timer = timer + dtime
        if timer > 0.2 then
            http.fetch({
                url = 'localhost:'..tostring(port),
                timeout = timeout,
                post_data = minetest.write_json({
                    type = 'DISCORD-REQUEST-DATA'
                })
            }, discord.handle_response)
            timer = 0
        end
    end
end)

minetest.register_on_shutdown(function()
    discord.send('*** Server shutting down...')
end)

if irc_enabled then
    discord.old_irc_sendLocal = irc.sendLocal
    function irc.sendLocal(msg)
        discord.old_irc_sendLocal(msg)
        discord.send(msg)
    end
end

discord.send('*** Server started!')
