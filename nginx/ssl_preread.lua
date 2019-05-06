local rpc = require('unixrpc')
local json = require('json')
local memcached = require('resty.memcached')
local constants = require('constants')

local shared = ngx.shared.webspace
shared:set('unix', true)
local matches, err = ngx.re.match(ngx.var.ssl_preread_server_name, constants.webspace_regex)
if not matches then
  ngx.log(ngx.DEBUG, 'not a webspace')
  shared:set('peer', constants.https_sock)
  return
end

local memc, err = memcached:new()
if not memc then
  ngx.log(ngx.ERR, 'failed to create memcached instance: ', err)
  shared:set('peer', constants.https_error_sock)
  return
end
local ok, err = memc:connect(constants.memcached_sock)
if not ok then
  ngx.log(ngx.ERR, 'failed to connect memcached: ', err)
  shared:set('peer', constants.https_error_sock)
  return
end

local res, err = rpc.call(constants.webspaced_sock, 'boot_and_host', matches[1], true)
if not res then
  ngx.log(ngx.ERR, json.encode(err))
  shared:set('peer', constants.https_error_sock)
  memc:set('error_type', 'webspaced_request')
elseif res[1] == 'nil' then
  ngx.log(ngx.ERR, res[2])
  shared:set('peer', constants.https_error_sock)
  memc:set('error_type', 'webspaced_'..res[2])
else
  ngx.log(ngx.INFO, res[1]..'://'..res[2])
  if res[1] == 'https' then
    ngx.log(ngx.DEBUG, 'user wants their own ssl')
    shared:set('peer', res[2] .. ':443')
    shared:set('unix', false)
  else
    ngx.log(ngx.DEBUG, 'doing ssl termination')
    shared:set('peer', constants.https_sock)
    local ok, err = memc:set('ssl_source', ngx.var.remote_addr)
    if not ok then
      ngx.log(ngx.ERR, 'failed to set memcached value: ', err)
      shared:set('peer', constants.https_error_sock)
    end
  end
end

local ok, err = memc:set_keepalive(10000, 100)
if not ok then
  ngx.log(ngx.ERR, 'failed to set memcached keepalive: ', err)
  shared:set('peer', constants.https_error_sock)
  return
end