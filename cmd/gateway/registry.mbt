///|
// The function registry: a JSON file under <data>/registry/ holding one
// RegistryRecord per function (manifest + current build id). Mutations
// take the registry lock and rewrite the file atomically (temp + rename).

///|
priv struct GatewayConfig {
  data_root : String
  builder_url : String
  runner_url : String
  registry_lock : @async.Mutex
}

///|
fn load_gateway_config() -> GatewayConfig {
  let data_root = @env.get_env_var("MOONLESS_DATA").unwrap_or(
    "/var/lib/moonless",
  )
  let builder_url = @env.get_env_var("MOONLESS_BUILDER_URL").unwrap_or(
    "http://builder:8081",
  )
  let runner_url = @env.get_env_var("MOONLESS_RUNNER_URL").unwrap_or(
    "http://runner:8082",
  )
  { data_root, builder_url, runner_url, registry_lock: @async.Mutex::Mutex(), }
}

///|
fn registry_path(cfg : GatewayConfig) -> String {
  cfg.data_root + "/registry/registry.json"
}

///|
async fn registry_load(
  cfg : GatewayConfig,
) -> Map[String, @shared.RegistryRecord] {
  let records : Map[String, @shared.RegistryRecord] = Map([])
  let content = @fs.read_file(registry_path(cfg)) catch { _ => return records }
  let json = @json.parse(content.text() catch { _ => "" }) catch {
    _ => {
      @shared.log_warn(
        service="gateway",
        message="registry file is not valid JSON; starting empty",
      )
      return records
    }
  }
  guard json is Object(obj) else { return records }
  for name, value in obj {
    let record : @shared.RegistryRecord? = try
      @shared.RegistryRecord::from_json(value)
    catch {
      _ => None
    } noraise {
      r => Some(r)
    }
    match record {
      Some(r) => records[name] = r
      None =>
        @shared.log_warn(
          service="gateway",
          message="skipping unreadable registry record for \{name}",
        )
    }
  } nobreak {
    records
  }
}

///|
// Atomic write: serialize to a temp file, then rename over the target so
// readers never observe a half-written registry.
async fn registry_save(
  cfg : GatewayConfig,
  records : Map[String, @shared.RegistryRecord],
) -> Unit raise @shared.SharedError {
  let path = registry_path(cfg)
  match path.rev_split_once("/") {
    Some((dir, _)) =>
      @fs.mkdir(dir.to_owned(), recursive=true, allow_exist=true) catch {
        _ => raise @shared.RunError("cannot create registry directory")
      }
    None => ()
  }
  let entries : Map[String, Json] = Map([])
  for name, record in records {
    entries[name] = record.to_json()
  }
  let tmp = path + ".tmp"
  @fs.write_file(tmp, Json::object(entries).stringify()) catch {
    _ => raise @shared.RunError("cannot write registry temp file")
  }
  @fs.rename(tmp, path, replace=true) catch {
    _ => raise @shared.RunError("cannot finalize registry write")
  }
}

///|
async fn registry_set(
  cfg : GatewayConfig,
  record : @shared.RegistryRecord,
) -> Unit {
  cfg.registry_lock.acquire()
  defer cfg.registry_lock.release()
  let records = registry_load(cfg)
  records[record.name] = record
  registry_save(cfg, records) catch {
    _ =>
      @shared.log_error(
        service="gateway",
        message="failed to persist registry update for \{record.name}",
      )
  }
}

///|
async fn registry_all(
  cfg : GatewayConfig,
) -> Map[String, @shared.RegistryRecord] {
  cfg.registry_lock.acquire()
  defer cfg.registry_lock.release()
  registry_load(cfg)
}
