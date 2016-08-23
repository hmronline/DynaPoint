#!/usr/bin/lua

require "uci"
require "ubus"
require "uloop"
log = require "nixio"

--open sys-logging
log.openlog("DynaPoint", "ndelay", "cons", "nowait");

local uci_cursor = uci.cursor()

-- revert all non-persistent wireless related uci-changes
uci_cursor:revert("wireless")


-- get all config sections with the given type
function getConfType(conf_file,type)
  local ifce={}
  uci_cursor:foreach(conf_file,type,function(s) ifce[s[".index"]]=s end)
  return ifce
end


ubus = ubus.connect()
if not ubus then
  error("Failed to connect to ubusd")
end
ubus:call("network", "reload", {})

local interval = uci_cursor:get("dynapoint", "internet", "interval")
local timeout = uci_cursor:get("dynapoint", "internet", "timeout")
local offline_threshold = tonumber(uci_cursor:get("dynapoint", "internet", "offline_threshold"))
local hosts = uci_cursor:get("dynapoint", "internet", "hosts")
local numhosts = #hosts
local curl = tonumber(uci_cursor:get("dynapoint", "internet", "use_curl"))
if (curl == 1) then
  curl_interface = uci_cursor:get("dynapoint", "internet", "curl_interface")
end
if (tonumber(uci_cursor:get("dynapoint", "internet", "add_hostname_to_ssid")) == 1 ) then
  localhostname = uci_cursor:get("system", "system", "hostname")
end

local table_names_rule = {}
local table_names_not_rule = {}
local ssids_with_hostname = {}
local ssids_not_rule = {}

function get_dynapoint_sections(t)
  for pos,val in pairs(t) do
    if (type(val)=="table") then
      get_dynapoint_sections(val);
    elseif (type(val)=="string") then
      if (pos == "dynapoint_rule") then
        if (val == "internet") then
          table_names_rule[#table_names_rule+1] = t[".name"]
        elseif (val == "!internet") then
          table_names_not_rule[#table_names_not_rule+1] = t[".name"]
          if (localhostname) then
            ssids_not_rule[#ssids_not_rule+1] = t[".ssid"]
            ssids_with_hostname[#ssids_with_hostname+1] = t[".ssid"].."_"..localhostname
          end
        end
      end
    end
  end
end


--print(table.getn(hosts))

get_dynapoint_sections(getConfType("wireless","wifi-iface"))

local online = true
if (tonumber(uci_cursor:get("wireless", table_names_rule[1], "disabled")) == 1) then
  online = false
end

local timer
local offline_counter = 0
uloop.init()

function do_internet_check(host)
  if (curl == 1 ) then
    if (curl_interface) then
      result = os.execute("curl -s -m "..timeout.." --max-redirs 0 --interface "..curl_interface.." --head "..host.." > /dev/null")
    else
      result = os.execute("curl -s -m "..timeout.." --max-redirs 0 --head "..host.." > /dev/null")
    end
  else
    result = os.execute("wget -q --timeout="..timeout.." --spider "..host)
  end
  if (result == 0) then
    return true
  else
    return false
  end
end

function change_wireless_config(switch_to_offline)
  if (switch_to_offline == 1) then
    log.syslog("info","Switched to OFFLINE")

    for i = 1, #table_names_not_rule do
      uci_cursor:set("wireless",table_names_not_rule[i], "disabled", "0")
      if (localhostname) then
        uci_cursor:set("wireless", table_names_not_rule[i], "ssid", ssids_with_hostname[i])
        log.syslog("info","Bring up new AP "..ssids_with_hostname[i])
      else
        log.syslog("info","Bring up new AP "..ssids_not_rule[i])
      end
    end

    for i = 1, #table_names_rule do
      uci_cursor:set("wireless",table_names_rule[i], "disabled", "1")
    end

  else
    log.syslog("info","Switched to ONLINE")
    for i = 1, #table_names_not_rule do
      uci_cursor:set("wireless",table_names_not_rule[i], "disabled", "1")
      if (localhostname) then
        uci_cursor:set("wireless", table_names_not_rule[i], "ssid", ssids_not_rule[i])
      end
    end
    for i = 1, #table_names_rule do
      uci_cursor:set("wireless",table_names_rule[i], "disabled", "0")
      log.syslog("info","Bring up new AP "..uci_cursor:get("wireless", table_names_rule[i], "ssid"))
    end
  end
  uci_cursor:save("wireless")
  ubus:call("network", "reload", {})
end


local hostindex = 1

function check_internet_connection()
  print("checking "..hosts[hostindex].."...")
  if (do_internet_check(hosts[hostindex]) == true) then
    -- online
    print("...seems to be online")
    offline_counter = 0
    if (online == false) then
      print("changed state to online")
      online = true
      change_wireless_config(0)
    end
  else
    --offline
    print("...seems to be offline")
    hostindex = hostindex + 1
    if (hostindex > numhosts) then
      hostindex = 1
      -- and activate offline-mode
      print("all hosts offline")
      if (online == true) then
        offline_counter = offline_counter + 1
        if (offline_counter == offline_threshold) then
          print("changed state to offline")
          online = false
          change_wireless_config(1)
        end
      end
    end
  end
  timer:set(interval * 1000)
end

timer = uloop.timer(check_internet_connection)
timer:set(interval * 1000)

uloop.run()
