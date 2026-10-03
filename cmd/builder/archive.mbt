///|
// Extraction of uploaded packages: tar parsing lives in src/shared; the
// builder writes the sanitized entries out under the isolated work dir.

///|
// Decompresses a .tar.gz archive and writes its entries under dest,
// creating parent directories as needed. Returns the extracted file paths.
async fn extract_tar_gz(
  archive_gz : Bytes,
  dest : String,
) -> Array[String] raise @shared.SharedError {
  let plain = @shared.gunzip(archive_gz)
  let extracted = []
  for entry in @shared.tar_entries(plain) {
    let target = dest + "/" + entry.path
    if entry.is_dir {
      mkdir_recursive(target)
    } else {
      ensure_parent(target)
      (
        @fs.write_file(target, entry.data[:]) catch {
          err =>
            raise @shared.InvalidArchive(
              "failed to write \{entry.path}: \{@debug.to_string(err)}",
            )
        } : Unit)
      extracted.push(entry.path)
    }
  }
  extracted
}

///|
async fn mkdir_recursive(path : String) -> Unit raise @shared.SharedError {
  @fs.mkdir(path, recursive=true, allow_exist=true) catch {
    err =>
      raise @shared.InvalidArchive(
        "failed to create \{path}: \{@debug.to_string(err)}",
      )
  }
}

///|
async fn ensure_parent(path : String) -> Unit raise @shared.SharedError {
  match path.rev_split_once("/") {
    Some((dir, _)) => mkdir_recursive(dir.to_owned())
    None => ()
  }
}
