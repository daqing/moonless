///|
async fn register_runner_loop(
  gateway_url : String,
  public_url : String,
) -> Unit {
  for ;; {
    let payload : Json = { "id": public_url, "url": public_url }
    ignore(
      @shared.http_post_json(
        gateway_url + "/api/runners/register",
        payload,
        timeout_ms=5_000,
      ) catch {
        _ => {
          @shared.log_warn(
            service="runner",
            message="gateway registration failed; retrying in 5s",
          )
          Json::null()
        }
      },
    )
    @async.sleep(30_000)
  }
}
