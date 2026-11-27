///|
fn to_sigv4_credentials(credentials : Credentials) -> @sigv4.Credentials {
  match credentials.session_token {
    Some(token) =>
      @sigv4.Credentials(
        credentials.access_key_id,
        credentials.secret_access_key,
        session_token=token,
      )
    None =>
      @sigv4.Credentials(
        credentials.access_key_id,
        credentials.secret_access_key,
      )
  }
}
