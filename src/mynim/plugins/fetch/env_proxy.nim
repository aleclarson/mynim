## Go-compatible environment selection for the Fetch plugin's default client.

import std/[envvars, httpclient, net, strutils, uri]

type EnvironmentProxy* = object
  httpProxy*, httpsProxy*, noProxy*: string
  cgi*: bool

proc environmentValue(names: openArray[string]): string =
  for name in names:
    let value = getEnv(name)
    if value.len > 0:
      return value

proc fromEnvironment*(): EnvironmentProxy =
  ## Reads lower-case proxy variables first, as Go's HTTP transport does.
  EnvironmentProxy(
    httpProxy: environmentValue(["http_proxy", "HTTP_PROXY"]),
    httpsProxy: environmentValue(["https_proxy", "HTTPS_PROXY"]),
    noProxy: environmentValue(["no_proxy", "NO_PROXY"]),
    cgi: getEnv("REQUEST_METHOD").len > 0
  )

proc parseProxy(value: string): Proxy =
  if value.len == 0:
    return nil
  var proxyUrl: Uri
  try:
    proxyUrl = parseUri(if "://" in value: value else: "http://" & value)
  except ValueError:
    return nil
  if proxyUrl.scheme.len == 0 or proxyUrl.hostname.len == 0:
    return nil
  proxyUrl.scheme = proxyUrl.scheme.toLowerAscii()
  case proxyUrl.scheme
  of "http", "https", "socks5h": discard
  of "socks5": proxyUrl.scheme = "socks5h"
  else:
    raise newException(ValueError,
      "fetch: unsupported proxy scheme " & proxyUrl.scheme.escape())
  newProxy(proxyUrl)

proc urlPort(url: Uri): string =
  if url.port.len > 0:
    return url.port
  case url.scheme.toLowerAscii()
  of "http": "80"
  of "https": "443"
  else: ""

proc splitHostPort(rule: string): tuple[host, port: string] =
  if rule.startsWith("["):
    let closing = rule.find(']')
    if closing < 0:
      return
    result.host = rule[1 ..< closing]
    if closing == rule.high:
      return
    if rule[closing + 1] != ':' or closing + 2 > rule.high:
      result.host.setLen(0)
      return
    result.port = rule[closing + 2 .. ^1]
    if not result.port.allCharsInSet(Digits):
      result.host.setLen(0)
      result.port.setLen(0)
  else:
    let firstColon = rule.find(':')
    let lastColon = rule.rfind(':')
    if firstColon >= 0 and firstColon == lastColon:
      let candidatePort = rule[lastColon + 1 .. ^1]
      if candidatePort.len > 0 and candidatePort.allCharsInSet(Digits):
        result.host = rule[0 ..< lastColon]
        result.port = candidatePort
        return
    result.host = rule

proc ipByte(address: IpAddress; index: int): uint8 =
  case address.family
  of IpAddressFamily.IPv4: address.address_v4[index]
  of IpAddressFamily.IPv6: address.address_v6[index]

proc inPrefix(address, network: IpAddress; bits: int): bool =
  if address.family != network.family:
    return false
  let maxBits = if address.family == IpAddressFamily.IPv4: 32 else: 128
  if bits < 0 or bits > maxBits:
    return false
  for bit in 0 ..< bits:
    let mask = 1'u8 shl (7 - bit mod 8)
    if (ipByte(address, bit div 8) and mask) !=
        (ipByte(network, bit div 8) and mask):
      return false
  true

proc isLoopback(host: string): bool =
  if host.toLowerAscii() == "localhost":
    return true
  var address: IpAddress
  try:
    address = parseIpAddress(host)
  except ValueError:
    return false
  case address.family
  of IpAddressFamily.IPv4:
    address.address_v4[0] == 127
  of IpAddressFamily.IPv6:
    for index in 0 ..< 15:
      if address.address_v6[index] != 0:
        return false
    address.address_v6[15] == 1

proc domainMatch(host, rule: string): bool =
  var suffix = rule
  if suffix.startsWith("*."):
    suffix = suffix[1 .. ^1]
  let matchExact = not suffix.startsWith(".")
  if matchExact:
    suffix = "." & suffix
  if host.endsWith(suffix):
    return true
  matchExact and host == suffix[1 .. ^1]

proc excludedByNoProxy(url: Uri; noProxy: string): bool =
  let host = url.hostname.toLowerAscii()
  let port = url.urlPort()
  for rawRule in noProxy.split(','):
    let rule = rawRule.strip().toLowerAscii()
    if rule.len == 0:
      continue
    if rule == "*":
      return true
    if '/' in rule:
      let slash = rule.rfind('/')
      try:
        let network = parseIpAddress(rule[0 ..< slash])
        let bits = parseInt(rule[slash + 1 .. ^1])
        var address: IpAddress
        try:
          address = parseIpAddress(host)
        except ValueError:
          continue
        if inPrefix(address, network, bits):
          return true
      except ValueError:
        discard
      continue
    let (ruleHost, rulePort) = splitHostPort(rule)
    if ruleHost.len == 0 or (rulePort.len > 0 and rulePort != port):
      continue
    try:
      let ruleIp = parseIpAddress(ruleHost)
      var targetIp: IpAddress
      try:
        targetIp = parseIpAddress(host)
      except ValueError:
        continue
      if inPrefix(targetIp, ruleIp, if ruleIp.family == IpAddressFamily.IPv4: 32 else: 128):
        return true
    except ValueError:
      if domainMatch(host, ruleHost):
        return true

proc proxyForUrl*(url: Uri; environment: EnvironmentProxy): Proxy =
  ## Selects the scheme-specific proxy, or nil for NO_PROXY/loopback URLs.
  let configured =
    case url.scheme.toLowerAscii()
    of "http": environment.httpProxy
    of "https": environment.httpsProxy
    else: ""
  result = parseProxy(configured)
  if result == nil:
    return
  if url.scheme.toLowerAscii() == "http" and environment.cgi:
    raise newException(ValueError,
      "fetch: refusing to use HTTP_PROXY in a CGI environment")
  if isLoopback(url.hostname) or excludedByNoProxy(url, environment.noProxy):
    result = nil
