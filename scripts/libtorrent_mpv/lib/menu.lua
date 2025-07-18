local utils = require("mp.utils")

local Config = require("lib/config")
local State = require("lib/state")
local Client = require("lib/client")

local Menu = {
  item_callbacks = {},
  root_items = {}
}
function Menu.new_prop(item, fn)
  item.id = #Menu.item_callbacks + 1
  Menu.item_callbacks[item.id] = fn
  return item
end

function Menu.get_item(menu_id, index)
  local items = Menu.root_items
  local separator = " > "
  if menu_id == nil or index == nil then return end
  for match in (menu_id .. separator):gmatch("(.-)" .. separator) do
    for _, v in pairs(items) do
      if v.title == match then
        items = v.items
        break
      end
    end
  end
  return items[index]
end

function Menu.generate_playlist(files)
  local playlist = { "#EXTM3U" }
  for _, file in pairs(files) do
    playlist[#playlist + 1] = "#EXTINF:0," .. file.Name
    playlist[#playlist + 1] = "http://" .. State.service_ip .. ":" .. State.service_port .. "/torrents/" .. file.Path
  end
  return table.concat(playlist, "\n")
end

function Menu.create_torrent_menu(menu_id, index)
  Menu.root_items = {}
  Menu.item_callbacks = {}
  local to_update
  State.update()

  -- Add client control items
  local client_control_items = {}
  if State.client_running then
    if State.launched_by_us then
      table.insert(client_control_items, Menu.new_prop({
        title = "Stop Client",
        icon = "stop",
        value = "client_stop"
      }, function(event)
        local item, done = Menu.update(event.menu_id, event.index)
        item.value = "noop"
        item.icon = "spinner"
        done()
        if event.value == "client_stop" then
          Client.close()
        end
        mp.add_timeout(0.75, Menu.update)
      end))
    else
      table.insert(client_control_items, Menu.new_prop({
        title = "Host: " .. State.service_ip .. ':' .. State.service_port
      }))
    end
  else
    table.insert(client_control_items, Menu.new_prop({
      title = "Start Client",
      icon = "play_arrow",
      value = "client_start"
    }, function(event)
      local item, done = Menu.update(event.menu_id, event.index)
      item.value = "noop"
      item.icon = "spinner"
      done()
      if event.value == "client_start" then
        Client.start()
      end
      mp.add_timeout(0.75, Menu.update)
    end))
  end

  table.insert(client_control_items, Menu.new_prop({
    title = "Launch torrent client on mpv start",
    icon = Config.opts.StartClientOnMpvLaunch and "check_box" or "check_box_outline_blank",
    value = Config.opts.StartClientOnMpvLaunch and "toggle_off" or "toggle_on"
  }, function(event)
    if event.value == "toggle_off" then
      Config.opts.StartClientOnMpvLaunch = false
    elseif event.value == "toggle_on" then
      Config.opts.StartClientOnMpvLaunch = true
    end
    Menu.update()
    Config.save_opts()
  end))

  table.insert(client_control_items, Menu.new_prop({
    title = "Search for torrent client on network",
    icon = Config.opts.SearchLocalNetwork and "check_box" or "check_box_outline_blank",
    value = Config.opts.SearchLocalNetwork and "toggle_off" or "toggle_on"
  }, function(event)
    if event.value == "toggle_off" then
      Config.opts.SearchLocalNetwork = false
    elseif event.value == "toggle_on" then
      Config.opts.SearchLocalNetwork = true
    end
    Menu.update()
    Config.save_opts()
  end))

  -- table.insert(client_control_items, Menu.new_prop({
  --   title = "Close torrent client on mpv exit",
  --   icon = Config.opts.CloseClientOnMpvExit and "check_box" or "check_box_outline_blank",
  --   value = Config.opts.CloseClientOnMpvExit and "toggle_off" or "toggle_on"
  -- }, function(event)
  --   if event.value == "toggle_off" then
  --     Config.opts.CloseClientOnMpvExit = false
  --   elseif event.value == "toggle_on" then
  --     Config.opts.CloseClientOnMpvExit = true
  --   end
  --   Menu.update()
  --   Config.save_opts()
  -- end))

  table.insert(Menu.root_items, {
    title = "Client Controls",
    items = client_control_items
  })

  if State.client_running then
    local remove_torrents_items = {}
    for _, v in pairs(State.torrents) do
      -- Add remove torrent items
      table.insert(remove_torrents_items, Menu.new_prop({
        title = v.Name,
        hint = string.format("%.1f GB", v.Length / (1024 * 1024 * 1024)),
        value = v.InfoHash,
        actions = {
          { name = "delete",       icon = "delete",         label = "Delete torrent" },
          { name = "delete_files", icon = "delete_forever", label = "Delete torrent & files" }
        }
      }, function(event)
        local item, done = Menu.update(event.menu_id, event.index)
        item.actions = {}
        item.icon = "spinner"
        done()
        if event.action == "delete" then
          Client.remove(event.value, false)
        elseif event.action == "delete_files" then
          Client.remove(event.value, true)
        end
        Menu.update()
      end))

      local media_files = {}
      for _, file in pairs(v.Files) do
        if string.match(file.MimeType, "video") or string.match(file.MimeType, "audio") then
          table.insert(media_files, file)
        end
      end

      -- Add play torrent items
      local play_torrent_items = {}
      if #media_files > 1 then
        table.insert(play_torrent_items, Menu.new_prop({
          title = "Play all",
          value = "memory://" .. Menu.generate_playlist(media_files),
          actions = {
            { name = "play_all",        icon = "playlist_play", label = "Play all files" },
            { name = "play_all_append", icon = "playlist_add",  label = "Append all files to playlist" }
          }
        }, function(event)
          if event.action == "play_all" then
            mp.commandv("loadlist", event.value)
            mp.commandv("script-message-to", "uosc", "close-menu", "torrent_menu")
          elseif event.action == "play_all_append" then
            mp.commandv("loadlist", event.value, "append")
            local item, done = Menu.update(event.menu_id, event.index)
            item.actions[2].name = "noop"
            item.actions[2].icon = "check"
            done()
            mp.add_timeout(0.5, function()
              Menu.update()
            end)
          end
        end))
      end

      for _, file in pairs(media_files) do
        local URL = "http://" .. State.service_port .. ":" .. State.service_port .. "/torrents/" .. file.Path
        table.insert(play_torrent_items, Menu.new_prop({
          title = file.Name,
          hint = string.format("%.1f MB", file.Length / (1024 * 1024)),
          active = URL == mp.get_property("stream-open-filename", ""),
          value = "memory://" .. Menu.generate_playlist({ file }),
          actions = {
            { name = "play_file",   icon = "play_circle_outline", label = "Play file" },
            { name = "play_append", icon = "add_to_queue",        label = "Queue" },
            { name = "play_next",   icon = "queue_play_next",     label = "Queue and play next" }
          }
        }, function(event)
          if event.action == "play_file" then
            mp.commandv("loadlist", event.value)
            mp.commandv("script-message-to", "uosc", "close-menu", "torrent_menu")
          elseif event.action == "play_append" then
            mp.commandv("loadlist", event.value, "append")
            local item, done = Menu.update(event.menu_id, event.index)
            item.actions[2].name = "noop"
            item.actions[2].icon = "check"
            done()
            mp.add_timeout(0.5, function()
              Menu.update()
            end)
          elseif event.action == "play_next" then
            mp.commandv("loadlist", event.value, "insert-next")
            local item, done = Menu.update(event.menu_id, event.index)
            item.actions[3].name = "noop"
            item.actions[3].icon = "check"
            done()
            mp.add_timeout(0.5, function()
              Menu.update()
            end)
          end
        end))
      end

      table.insert(Menu.root_items, {
        title = v.Name,
        hint = string.format(#media_files == 1 and "%d file" or "%d files", #media_files),
        items = play_torrent_items
      })
    end

    if next(State.torrents) ~= nil then
      table.insert(client_control_items, {
        title = "Remove Torrent",
        items = remove_torrents_items
      })
    end
  end

  if menu_id and index then
    to_update = Menu.get_item(menu_id, index)
  end

  return {
    type = "torrent_menu",
    title = "Torrent Manager",
    items = Menu.root_items,
    callback = { mp.get_script_name(), "menu-callback" }
  }, to_update
end

function Menu.show()
  local menu_data = Menu.create_torrent_menu()
  mp.commandv("script-message-to", "uosc", "open-menu", utils.format_json(menu_data))
end

function Menu.update(menu_id, index)
  local menu_data, to_update = Menu.create_torrent_menu(menu_id, index)
  if to_update then
    return to_update, function()
      mp.commandv("script-message-to", "uosc", "update-menu", utils.format_json(menu_data))
    end
  end
  mp.commandv("script-message-to", "uosc", "update-menu", utils.format_json(menu_data))
end

function Menu.handle_callback(json_event)
  local event = utils.parse_json(json_event)

  local item = Menu.get_item(event.menu_id, event.index)
  if item then
    local fn = Menu.item_callbacks[item.id]
    if fn then
      fn(event)
    end
  end
end

return Menu
