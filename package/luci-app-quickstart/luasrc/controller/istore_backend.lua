-- Copyright 2022 xiaobao <xiaobao@linkease.com>
-- Licensed to the public under the MIT License

local http = require "luci.http"
local nixio = require "nixio"
local ltn12 = require "luci.ltn12"
local table = require "table"
local util = require "luci.util"

module("luci.controller.istore_backend", package.seeall)

local BLOCKSIZE = 2048
local ISTOREOS_PORT = 3038

function index()
    entry({"istore"}, call("istore_backend")).leaf=true
end

local function sink_socket(sock, io_err) 
  if sock then 
    return function(chunk, err) 
      if not chunk then 
        return 1 
      else 
        return sock:send(chunk)
      end 
    end 
  else 
    return ltn12.sink.error(io_err or "unable to send socket") 
  end
end

local function session_retrieve(sid, allowed_users)
  local sdat = util.ubus("session", "get", { ubus_rpc_session = sid })
  if type(sdat) == "table" and
      type(sdat.values) == "table" and
      type(sdat.values.token) == "string" and
      (not allowed_users or
      util.contains(allowed_users, sdat.values.username))
  then
      return sid, sdat.values
  end
  return nil, nil
end

local function get_session()
  local sid
  local key
  local sdat
  for _, key in ipairs({"sysauth_https", "sysauth_http", "sysauth"}) do
    sid = http.getcookie(key)
    if sid then
      sid, sdat = session_retrieve(sid, nil)
      if sid and sdat then
        return sid, sdat
      end
    end
  end
  return nil, nil
end

local function chunksource(sock, buffer)
	buffer = buffer or ""
	return function()
		local output
		local _, endp, count = buffer:find("^([0-9a-fA-F]+);?.-\r\n")
		while not count and #buffer <= 1024 do
			local newblock, code = sock:recv(1024 - #buffer)
			if not newblock then
				return nil, code
			end
			buffer = buffer .. newblock  
			_, endp, count = buffer:find("^([0-9a-fA-F]+);?.-\r\n")
		end
		count = tonumber(count, 16)
		if not count then
			return nil, -1, "invalid encoding"
		elseif count == 0 then
			return nil
		elseif count + 2 <= #buffer - endp then
			output = buffer:sub(endp+1, endp+count)
			buffer = buffer:sub(endp+count+3)
			return output
		else
			output = buffer:sub(endp+1, endp+count)
			buffer = ""
			if count - #output > 0 then
				local remain, code = sock:recvall(count-#output)
				if not remain then
					return nil, code
				end
				output = output .. remain
				count, code = sock:recvall(2)
			else
				count, code = sock:recvall(count+2-#buffer+endp)
			end
			if not count then
				return nil, code
			end
			return output
		end
	end
end

-- 与 quickstart 守护进程建立连接。
--
-- 事实依据（直接拆官方 iStoreOS 25.12.5 固件得到的，两条都成立）：
--   1) quickstart 0.13.0 二进制的默认监听地址是 TCP 127.0.0.1:3038
--      （二进制内日志字符串 "start serve at" + "127.0.0.1:3038"），
--      官方固件的 istore_backend.lua 也正是连它 —— 这是官方验证过的路径。
--   2) init 脚本额外传了 --unix /var/run/quickstart/local.sock，
--      二进制里有独立的 UnixRouterInit，故 unix socket 同样可用。
--
-- 因此先连 TCP，失败再退 Unix socket。
--
-- ⚠ 踩过的坑：nixio 的 Socket:connect 原型是 connect(host, port)，
--   对 AF_UNIX 也必须给 port（0）。少传 port 时底层 luaL_checkint(nil)
--   直接抛 Lua 错 → 控制器整体 500 → 用户看到
--   「网络异常：500 Internal Server Error」。
--   这里所有连接尝试一律 pcall，任何异常只当作「这条不通」，绝不外抛。
local UNIX_SOCK = "/var/run/quickstart/local.sock"

local function nfsobj()
  local ok, fs = pcall(require, "nixio.fs")
  if ok and fs then return fs end
  return nixio.fs
end

local function connect_unix(path)
  local ok, sk = pcall(function()
    local s = nixio.socket("unix", "stream")
    if not s then return nil end
    -- AF_UNIX：host 是 socket 路径，port 必须给数值（0）
    if s:connect(path, 0) == nil then return nil end
    return s
  end)
  if ok and sk then return sk end
  return nil
end

local function connect_backend()
  local why = {}

  -- 1) TCP 127.0.0.1:3038（官方默认监听地址）
  local ok, sk = pcall(nixio.connect, "127.0.0.1", ISTOREOS_PORT)
  if ok and sk then return sk, "tcp" end
  why[#why+1] = "tcp 127.0.0.1:" .. tostring(ISTOREOS_PORT) .. " failed"

  -- 2) Unix socket（init 里 --unix 指定的路径）
  local fs = nfsobj()
  if fs and fs.access and fs.access(UNIX_SOCK) then
    sk = connect_unix(UNIX_SOCK)
    if sk then return sk, "unix" end
    why[#why+1] = "unix " .. UNIX_SOCK .. " connect failed"
  else
    why[#why+1] = "unix " .. UNIX_SOCK .. " not found"
  end

  return nil, table.concat(why, " | ")
end

function istore_backend() 
  local sock, how = connect_backend()
  if not sock then
    -- 502 比 500 贴切：这是「上游后端连不上」的网关错误。
    -- 把两条通道各自的失败原因写进正文，可直接在浏览器里定位。
    http.status(502, "quickstart backend unreachable")
    http.prepare_content("text/plain; charset=utf-8")
    http.write("quickstart backend unreachable\n" .. (how or "unknown") .. "\n")
    return
  end
  local input = {}
  input[#input+1] = http.getenv("REQUEST_METHOD") .. " " .. http.getenv("REQUEST_URI") .. " HTTP/1.1"
  local req = http.context.request
  local start = "HTTP_"
  local start_len = string.len(start)
  local ctype = http.getenv("CONTENT_TYPE")
  if ctype then 
    input[#input+1] = "Content-Type: " .. ctype 
  end
  for k, v in pairs(req.message.env) do
    if string.sub(k, 1, start_len) == start and not string.find(k, "FORWARDED") then 
      input[#input+1] = string.sub(k, start_len+1, string.len(k)) .. ": " .. v
    end
  end
  local sid, sdat = get_session()
  if sdat ~= nil then
    input[#input+1] = "X-Forwarded-Sid: " .. sid
    input[#input+1] = "X-Forwarded-Token: " .. sdat.token
  end
  -- input[#input+1] = "X-Forwarded-For: " .. http.getenv("REMOTE_HOST") ..":".. http.getenv("REMOTE_PORT")
  local num = tonumber(http.getenv("CONTENT_LENGTH")) or 0
  input[#input+1] = "Content-Length: " .. tostring(num)
  input[#input+1] = "\r\n"
  local source = ltn12.source.cat(ltn12.source.string(table.concat(input, "\r\n")), http.source())
  local ret = ltn12.pump.all(source, sink_socket(sock, "write sock error")) 
  if ret ~= 1 then
    sock:close()
    http.status(500, "proxy error")
    return
  end

  local linesrc = sock:linesource()
  local line, code, error = linesrc()
  if not line then
    sock:close()
    http.status(500, "response parse failed")
    return
  end

  local protocol, status, msg = line:match("^([%w./]+) ([0-9]+) (.*)")
  if not protocol then
    sock:close()
    http.status(500, "response protocol error")
    return
  end
  num = tonumber(status) or 0
  http.status(num, msg)

  local chunked = 0
  line = linesrc()
  while line and line ~= "" do
    local key, val = line:match("^([%w-]+)%s?:%s?(.*)")
    if key and key ~= "Status" then
      if key == "Transfer-Encoding" and val == "chunked" then
        chunked = 1
      end
      if key ~= "Connection" and key ~= "Transfer-Encoding" and key ~= "Content-Length" then 
        http.header(key, val)
      end
    end
    line = linesrc()
  end
  if not line then
    sock:close()
    http.status(500, "parse header failed")
    return
  end

  local body_buffer = linesrc(true)
  if chunked == 1 then
    ltn12.pump.all(chunksource(sock, body_buffer), http.write)
  else
    local body_source = ltn12.source.cat(ltn12.source.string(body_buffer), sock:blocksource())
    ltn12.pump.all(body_source, http.write)
  end

  sock:close()
end

