## Upload files to Amazon S3 and compatible services with Signature Version 4.

import std/[algorithm, os, osproc, streams, strutils, tables, tempfiles,
  times, uri]
import ../mynim/internal/sha256

type
  S3Config* = object
    bucket*, prefix*, region*, endpoint*: string
    pathStyle*, pathStyleSet*: bool

  S3Client* = ref object
    bucket, prefix, region, scheme, host: string
    pathStyle: bool
    accessKey, secretKey, sessionToken: string

  SigV4Result* = object
    canonicalRequest*, stringToSign*, signedHeaders*, signature*,
      authorization*: string

proc bytes(value: string): seq[byte] =
  result = newSeq[byte](value.len)
  for index, ch in value:
    result[index] = byte(ord(ch))

proc hmacSha256(key: openArray[byte]; message: string): seq[byte] =
  const blockSize = 64
  var keyBytes: seq[byte]
  if key.len > blockSize:
    for value in sha256Sum(key):
      keyBytes.add value
  else:
    keyBytes = @key

  var inner = newSeq[byte](blockSize + message.len)
  var outer = newSeq[byte](blockSize + 32)
  for index in 0 ..< blockSize:
    let value = if index < keyBytes.len: keyBytes[index] else: 0'u8
    inner[index] = value xor 0x36
    outer[index] = value xor 0x5c
  for index, ch in message:
    inner[blockSize + index] = byte(ord(ch))
  let innerHash = sha256Sum(inner)
  for index, value in innerHash:
    outer[blockSize + index] = value
  for value in sha256Sum(outer):
    result.add value

proc hexBytes(data: openArray[byte]): string =
  for value in data:
    result.add toHex(int(value), 2).toLowerAscii()

proc collapseWhitespace(value: string): string =
  value.splitWhitespace().join(" ")

proc signRequestV4*(httpMethod, path, host, region, accessKey, secretKey,
    dateTime, payloadHash: string;
    headers: openArray[tuple[name, value: string]]): SigV4Result =
  ## Signs a canonical S3 request; dateTime is UTC in YYYYMMDDTHHMMSSZ form.
  if dateTime.len < 8 or path.len == 0 or path[0] != '/':
    raise newException(ValueError, "invalid Signature Version 4 request")
  var values = initTable[string, string]()
  values["host"] = host
  values["x-amz-date"] = dateTime
  values["x-amz-content-sha256"] = payloadHash
  for header in headers:
    let name = header.name.strip().toLowerAscii()
    if name.len == 0 or '\r' in name or '\n' in name:
      raise newException(ValueError, "invalid request header name")
    values[name] = collapseWhitespace(header.value)

  var names: seq[string]
  for name in values.keys:
    names.add name
  names.sort()
  var canonicalHeaders: string
  for name in names:
    canonicalHeaders.add name & ":" & values[name] & "\n"
  result.signedHeaders = names.join(";")
  result.canonicalRequest = httpMethod & "\n" & path & "\n\n" &
    canonicalHeaders & "\n" & result.signedHeaders & "\n" & payloadHash
  let date = dateTime[0 ..< 8]
  let scope = date & "/" & region & "/s3/aws4_request"
  result.stringToSign = "AWS4-HMAC-SHA256\n" & dateTime & "\n" & scope &
    "\n" & sha256Hex(result.canonicalRequest)

  var signingKey = hmacSha256(bytes("AWS4" & secretKey), date)
  signingKey = hmacSha256(signingKey, region)
  signingKey = hmacSha256(signingKey, "s3")
  signingKey = hmacSha256(signingKey, "aws4_request")
  result.signature = hexBytes(hmacSha256(signingKey, result.stringToSign))
  result.authorization = "AWS4-HMAC-SHA256 Credential=" & accessKey & "/" &
    scope & ", SignedHeaders=" & result.signedHeaders & ", Signature=" &
    result.signature

proc newS3Client*(config: S3Config): S3Client =
  if config.bucket.len == 0:
    raise newException(ValueError, "updates.s3 needs a bucket")
  if config.bucket.contains({'\c', '\L'}) or
      config.prefix.contains({'\c', '\L'}):
    raise newException(ValueError, "updates.s3 bucket and prefix cannot contain newlines")

  result = S3Client(bucket: config.bucket,
    prefix: config.prefix.strip(chars = {'/'}),
    region: config.region, pathStyle: config.pathStyle)
  if result.region.len == 0:
    result.region = getEnv("AWS_REGION")
  if result.region.len == 0:
    result.region = getEnv("AWS_DEFAULT_REGION")
  if result.region.len == 0:
    result.region = "us-east-1"

  let accessKey = getEnv("AWS_ACCESS_KEY_ID")
  let secretKey = getEnv("AWS_SECRET_ACCESS_KEY")
  if accessKey.len == 0 or secretKey.len == 0:
    raise newException(ValueError,
      "uploading to updates.s3 needs AWS_ACCESS_KEY_ID and " &
      "AWS_SECRET_ACCESS_KEY")
  result.accessKey = accessKey
  result.secretKey = secretKey
  result.sessionToken = getEnv("AWS_SESSION_TOKEN")

  if config.endpoint.len == 0:
    result.scheme = "https"
    result.host = "s3." & result.region & ".amazonaws.com"
    if not config.pathStyleSet:
      result.pathStyle = config.bucket.contains('.')
  else:
    let endpoint = try: parseUri(config.endpoint)
      except CatchableError:
        raise newException(ValueError,
          "updates.s3.endpoint is not an HTTP(S) URL")
    if endpoint.scheme.toLowerAscii() notin ["http", "https"] or
        endpoint.hostname.len == 0:
      raise newException(ValueError,
        "updates.s3.endpoint is not an HTTP(S) URL")
    if endpoint.path.strip(chars = {'/' }).len > 0 or endpoint.query.len > 0 or
        endpoint.anchor.len > 0 or endpoint.username.len > 0 or
        endpoint.password.len > 0:
      raise newException(ValueError,
        "updates.s3.endpoint must be the service URL without a path")
    result.scheme = endpoint.scheme.toLowerAscii()
    result.host = if endpoint.isIpv6: "[" & endpoint.hostname & "]"
      else: endpoint.hostname
    if endpoint.port.len > 0:
      result.host.add ":" & endpoint.port
    if not config.pathStyleSet:
      result.pathStyle = true
  if config.pathStyleSet:
    result.pathStyle = config.pathStyle

proc s3Escape*(value: string): string =
  const digits = "0123456789ABCDEF"
  for index in 0 ..< value.len:
    let ch = value[index]
    if ch in {'a'..'z', 'A'..'Z', '0'..'9', '-', '.', '_', '~', '/'}:
      result.add ch
    else:
      result.add '%'
      result.add digits[ord(ch) shr 4]
      result.add digits[ord(ch) and 0x0f]

proc objectKey*(client: S3Client; name: string): string =
  if client.prefix.len == 0: name else: client.prefix & "/" & name

proc objectUrl*(client: S3Client; key: string):
    tuple[url, host, path: string] =
  result.host = client.host
  if not client.pathStyle:
    result.host = client.bucket & "." & result.host
  result.path = "/" & s3Escape(key)
  if client.pathStyle:
    result.path = "/" & s3Escape(client.bucket) & result.path
  result.url = client.scheme & "://" & result.host & result.path

proc hashFile(path: string): tuple[digest: string, size: int64] =
  let stream = newFileStream(path, fmRead)
  if stream.isNil:
    raise newException(IOError, "could not read upload file: " & path)
  defer: stream.close()
  result.size = getFileSize(path)
  var state = sha256Init()
  var buffer = newString(64 * 1024)
  while true:
    let count = stream.readData(addr buffer[0], buffer.len)
    if count <= 0:
      break
    state.sha256Update(buffer.toOpenArrayByte(0, count - 1))
  result.digest = sha256Hex(state.sha256Final())

proc curlQuote(value: string): string =
  result.add '"'
  for ch in value:
    if ch in {'\0', '\r', '\n'}:
      raise newException(ValueError,
        "S3 upload settings cannot contain control characters")
    if ch in {'\\', '"'}:
      result.add '\\'
    result.add ch
  result.add '"'

proc responseDetails(path: string):
    tuple[code: int, status, region: string] =
  if not fileExists(path):
    return
  for line in readFile(path).splitLines():
    if line.startsWith("HTTP/"):
      let fields = line.splitWhitespace()
      if fields.len >= 2:
        try:
          result.code = parseInt(fields[1])
          result.status = line
        except ValueError:
          discard
    elif line.toLowerAscii().startsWith("x-amz-bucket-region:"):
      let colon = line.find(':')
      result.region = line[colon + 1 .. ^1].strip()

proc put*(client: S3Client; key, path: string;
    headers: openArray[tuple[name, value: string]]) =
  let curl = findExe("curl")
  if curl.len == 0:
    raise newException(IOError, "uploading to updates.s3 needs curl on PATH")
  let info = getFileInfo(path, followSymlink = false)
  if info.kind != pcFile:
    raise newException(IOError, "S3 upload is not a regular file: " & path)
  let (location, payloadHash) = (client.objectUrl(key), hashFile(path))
  let dateTime = getTime().utc.format("yyyyMMdd'T'HHmmss'Z'")
  var signingHeaders = @headers
  signingHeaders.add ("User-Agent", "mynim")
  if client.sessionToken.len > 0:
    signingHeaders.add ("x-amz-security-token", client.sessionToken)
  let signed = signRequestV4("PUT", location.path, location.host,
    client.region, client.accessKey, client.secretKey, dateTime,
    payloadHash.digest, signingHeaders)

  let temporary = createTempDir("mynim-s3-upload-", "")
  defer:
    if dirExists(temporary):
      removeDir(temporary)
  when defined(posix):
    setFilePermissions(temporary, {fpUserRead, fpUserWrite, fpUserExec})
  let configPath = temporary / "curl.conf"
  let responsePath = temporary / "response"
  let responseHeaders = temporary / "headers"
  var configLines = @[
    "url = " & curlQuote(location.url),
    "upload-file = " & curlQuote(path),
    "output = " & curlQuote(responsePath),
    "dump-header = " & curlQuote(responseHeaders),
    "http1.1",
    "path-as-is",
    "silent",
    "show-error",
    "max-time = 3600",
    "max-filesize = 65536",
    "proto = \"=https,http\"",
    "header = " & curlQuote("Host: " & location.host),
    "header = " & curlQuote("Authorization: " & signed.authorization),
    "header = " & curlQuote("X-Amz-Date: " & dateTime),
    "header = " & curlQuote("X-Amz-Content-Sha256: " & payloadHash.digest)]
  for header in signingHeaders:
    configLines.add "header = " &
      curlQuote(header.name & ": " & header.value)
  writeFile(configPath, configLines.join("\n") & "\n")
  when defined(posix):
    setFilePermissions(configPath, {fpUserRead, fpUserWrite})

  let process = startProcess(curl,
    args = ["--disable", "--config", configPath],
    options = {poUsePath, poStdErrToStdOut})
  var output = ""
  var code = -1
  try:
    output = process.outputStream.readAll()
    code = process.waitForExit()
  finally:
    process.close()
  if code != 0:
    raise newException(IOError,
      "uploading to s3://" & client.bucket & "/" & key & " failed" &
      (if output.strip().len > 0: ": " & output.strip() else: ""))

  let response = responseDetails(responseHeaders)
  if response.code div 100 != 2:
    var message = if response.status.len > 0: response.status
      else: "the upload returned no HTTP status"
    if fileExists(responsePath) and getFileSize(responsePath) <= 65536:
      let body = readFile(responsePath).strip()
      if body.len > 0:
        message.add ": " & body
    if response.region.len > 0 and response.region != client.region:
      message.add " (the bucket is in " & response.region &
        ": set updates.s3.region)"
    raise newException(IOError,
      "uploading to s3://" & client.bucket & "/" & key & ": " & message)
