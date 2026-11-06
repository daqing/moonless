///|
priv struct FunctionSemaphore {
  limit : Int32
  sem : @semaphore.Semaphore
}

///|
async fn load_registry_record(
  data_root : String,
  name : String,
) -> @shared.RegistryRecord? noraise {
  let content = @fs.read_file(data_root + "/registry/registry.json") catch {
    _ => return None
  }
  let json = @json.parse(content.text() catch { _ => "" }) catch {
    _ => return None
  }
  guard json is Object(records) && records.get(name) is Some(value) else {
    return None
  }
  let record = @shared.RegistryRecord::from_json(value) catch {
    _ => return None
  }
  Some(record)
}

///|
async fn load_function_limits(
  data_root : String,
  name : String,
) -> @shared.FunctionLimits noraise {
  match load_registry_record(data_root, name) {
    Some(record) => record.manifest.limits
    None => @shared.FunctionLimits()
  }
}

///|
fn function_semaphore(
  cfg : RunnerConfig,
  name : String,
  limit : Int32,
) -> @semaphore.Semaphore {
  match cfg.function_sems.get(name) {
    Some(current) => if current.limit == limit { return current.sem }
    None => ()
  }
  let sem = @semaphore.Semaphore(limit)
  cfg.function_sems[name] = { limit, sem, }
  sem
}
