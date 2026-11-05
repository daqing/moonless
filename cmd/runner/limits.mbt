///|
priv struct FunctionSemaphore {
  limit : Int32
  sem : @semaphore.Semaphore
}

///|
async fn load_function_limits(
  data_root : String,
  name : String,
) -> @shared.FunctionLimits noraise {
  let content = @fs.read_file(data_root + "/registry/registry.json") catch {
    _ => return @shared.FunctionLimits()
  }
  let json = @json.parse(content.text() catch { _ => "" }) catch {
    _ => return @shared.FunctionLimits()
  }
  guard json is Object(records) && records.get(name) is Some(value) else {
    return @shared.FunctionLimits()
  }
  let record = @shared.RegistryRecord::from_json(value) catch {
    _ => return @shared.FunctionLimits()
  }
  record.manifest.limits
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
