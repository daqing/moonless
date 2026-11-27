///|
pub struct RedisClient {
  conn : @socket.Tcp
}

///|
/// 连接建立过程中的错误
pub(all) suberror ConnectError {
  /// AUTH 认证失败
  AuthFailed(String)
  /// SELECT 选择数据库失败
  SelectFailed(String)
  /// Redis URL 格式非法
  InvalidUrl(String)
}

///|
/// 建立到 Redis 服务器的连接。
///
/// 连接建立后可选地自动完成认证和选库：
/// - `password?`：提供时自动发送 AUTH；
///   同时提供 `username?` 时使用 Redis 6+ ACL 形式 `AUTH <username> <password>`。
///   单独提供 `username?` 而不提供 `password?` 时不发送 AUTH（Redis 没有仅用户名的认证）。
/// - `db?`：提供时自动发送 `SELECT <db>` 切换到指定数据库。
///
/// 认证或选库失败时会关闭连接并抛出 `ConnectError`。
pub async fn connect(
  host : StringView,
  port~ : Int32 = 6379,
  protocol? : @socket.IpProtocolPreference,
  username? : String,
  password? : String,
  db? : Int32,
) -> RedisClient {
  let conn = @socket.Tcp::connect_to_host(host, port~, protocol?)
  conn.enable_keepalive()
  let client : RedisClient = { conn, }
  if password is Some(password) {
    let args = match username {
      Some(username) => ["AUTH", username, password]
      None => ["AUTH", password]
    }
    match client.send(args) {
      SimpleString("OK") => ()
      Error(e) => {
        client.close()
        raise AuthFailed(e)
      }
      resp => {
        client.close()
        raise AuthFailed("unexpected response: \{resp}")
      }
    }
  }
  if db is Some(db) {
    match client.send(["SELECT", db.to_string()]) {
      SimpleString("OK") => ()
      Error(e) => {
        client.close()
        raise SelectFailed(e)
      }
      resp => {
        client.close()
        raise SelectFailed("unexpected response: \{resp}")
      }
    }
  }
  client
}

///|
/// 用 Redis URL 建立连接。
///
/// 支持 `redis://[[username]:[password]@]host[:port][/db]`：
/// - 省略端口时使用 6379，省略数据库时使用默认库；
/// - 用户名和密码中的百分号编码会自动解码；
/// - 仅支持 `redis://`，其他 scheme 会抛出 `InvalidUrl`。
pub async fn connect_with_url(
  url : StringView,
  protocol? : @socket.IpProtocolPreference,
) -> RedisClient {
  let parsed = parse_redis_url(url)
  connect(
    parsed.host,
    port=parsed.port,
    protocol?,
    username?=parsed.username,
    password?=parsed.password,
    db?=parsed.db,
  )
}

///|
priv struct RedisUrl {
  host : String
  port : Int32
  username : String?
  password : String?
  db : Int32?
}

///|
fn parse_redis_url(url : StringView) -> RedisUrl raise ConnectError {
  let rest : StringView = match url.strip_prefix("redis://") {
    Some(rest) => rest
    None => raise InvalidUrl("Redis URL must use the redis:// scheme: \{url}")
  }
  let (authority, path) = match rest.find("/") {
    Some(index) => (rest[:index], Some(rest[index + 1:]))
    None => (rest, None)
  }
  let (userinfo, host_port) = match authority.rev_find("@") {
    Some(index) => (Some(authority[:index]), authority[index + 1:])
    None => (None, authority)
  }
  let (username, password) = match userinfo {
    None => (None, None)
    Some(userinfo) => {
      let (username, password) = match userinfo.split_once(":") {
        Some((username, password)) => (Some(username), Some(password))
        None => (Some(userinfo), None)
      }
      let username = match username {
        Some(username) if !username.is_empty() =>
          Some(decode_url_component(username))
        _ => None
      }
      let password = match password {
        Some(password) => Some(decode_url_component(password))
        None => None
      }
      (username, password)
    }
  }
  let (host, port_view) = if host_port.has_prefix("[") {
    let close = match host_port.find("]") {
      Some(close) => close
      None => raise InvalidUrl("invalid IPv6 host in Redis URL: \{host_port}")
    }
    let suffix = host_port[close + 1:]
    let port = if suffix.is_empty() {
      None
    } else if suffix.has_prefix(":") {
      Some(suffix[1:])
    } else {
      raise InvalidUrl("invalid IPv6 host in Redis URL: \{host_port}")
    }
    (host_port[1:close], port)
  } else {
    match host_port.rev_find(":") {
      Some(index) => (host_port[:index], Some(host_port[index + 1:]))
      None => (host_port, None)
    }
  }
  if host.is_empty() {
    raise InvalidUrl("Redis URL is missing a host: \{url}")
  }
  let port = match port_view {
    None => 6379
    Some(port) =>
      @string.parse_int(port) catch {
        _ => raise InvalidUrl("invalid port in Redis URL: \{port}")
      }
  }
  if port < 1 || port > 65535 {
    raise InvalidUrl("port out of range in Redis URL: \{port}")
  }
  let db = match path {
    None => None
    Some(path) => {
      let db = match path.split_once("?") {
        Some((db, _)) => db
        None => path
      }
      if db.is_empty() {
        None
      } else {
        let db = @string.parse_int(db) catch {
          _ => raise InvalidUrl("invalid database index in Redis URL: \{db}")
        }
        if db < 0 {
          raise InvalidUrl("database index must not be negative: \{db}")
        }
        Some(db)
      }
    }
  }
  { host: host.to_owned(), port, username, password, db, }
}

///|
fn decode_url_component(value : StringView) -> String raise ConnectError {
  @percent.decode(value) catch {
    _ => raise InvalidUrl("invalid percent-encoding in Redis URL: \{value}")
  }
}

///|
pub async fn RedisClient::send(
  self : RedisClient,
  args : Array[String],
) -> RedisValue {
  // println(args)
  let buf = StringBuilder()
  buf.write_string("*" + args.length().to_string() + "\r\n")
  for arg in args {
    buf.write_string("$\{arg.length()}\r\n\{arg}\r\n")
  }
  self.conn.write(buf.to_string())
  self.read_redis_value()
}

///|
pub async fn RedisClient::read_response(self : RedisClient) -> String {
  let buf = FixedArray::make(4096, b'0')
  if self.conn.read(buf) is n && n > 0 {
    let response_bytes = buf.unsafe_reinterpret_as_bytes()[0:n]
    @encoding/utf8.decode(response_bytes)
  } else {
    ""
  }
}

///|
/// 读取Redis响应并解析为RedisValue类型
pub async fn RedisClient::read_redis_value(self : RedisClient) -> RedisValue {
  let raw_response = self.read_response()
  // println(raw_response)
  parse_redis_response(raw_response)
}

///|
pub async fn RedisClient::write(self : RedisClient, data : String) -> Unit {
  self.conn.write(data)
}

///|
pub async fn RedisClient::read(
  self : RedisClient,
  buf : FixedArray[Byte],
) -> Int32 {
  self.conn.read(buf)
}

///|
pub fn RedisClient::close(self : RedisClient) -> Unit {
  self.conn.close()
}
