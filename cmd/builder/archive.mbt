///|
// Minimal ustar/tar reader for uploaded function packages. Only regular
// files and directories are honored; links, symlinks, and GNU long-name
// headers are refused, and any entry that would escape the destination
// directory (zip-slip: absolute paths or ".." segments) is rejected.

///|
priv struct TarEntry {
  path : String // sanitized, relative to the extraction root
  is_dir : Bool
  data : Bytes
}

///|
// Parses a plain (uncompressed) tar archive into sanitized entries.
// Checksums are not verified; pax extension headers ('x'/'g') are skipped.
fn tar_entries(archive : Bytes) -> Array[TarEntry] raise @shared.SharedError {
  let entries : Array[TarEntry] = []
  let total = archive.length()
  let mut offset = 0
  for ;; {
    if offset + 512 > total {
      break
    }
    if is_all_zero(archive[offset:offset + 512]) {
      break
    }
    let name = tar_cstr(archive, offset, 100)
    let size = tar_octal(archive, offset + 124, 12)
    let type_byte = archive[offset + 156].to_int()
    let prefix = tar_cstr(archive, offset + 345, 155)
    let full_name = if prefix == "" { name } else { prefix + "/" + name }
    let data_start = offset + 512
    let padded = (size + 511) / 512 * 512
    if data_start + size > total {
      raise @shared.InvalidArchive(
        "truncated tar archive at entry \{full_name}",
      )
    }
    let data = archive[data_start:data_start + size].to_owned()
    offset = data_start + padded
    match type_byte {
      48 | 0 => {
        // '0' regular file
        let path = sanitize_tar_name(full_name)
        if path != "" {
          entries.push({ path, is_dir: false, data, })
        }
      }
      53 => {
        // '5' directory
        let path = sanitize_tar_name(full_name)
        if path != "" {
          entries.push({ path, is_dir: true, data, })
        }
      }
      120 | 103 => () // 'x'/'g' pax headers: metadata only, skip
      76 | 75 =>
        raise @shared.InvalidArchive(
          "GNU long-name entries are not supported: \{full_name}",
        )
      _ => raise @shared.InvalidArchive("unsupported tar entry: \{full_name}")
    }
  }
  entries
}

///|
// Decompresses a .tar.gz archive and writes its entries under dest,
// creating parent directories as needed. Returns the extracted file paths.
async fn extract_tar_gz(
  archive_gz : Bytes,
  dest : String,
) -> Array[String] raise @shared.SharedError {
  let plain = gunzip(archive_gz)
  let extracted = []
  for entry in tar_entries(plain) {
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
async fn gunzip(data : Bytes) -> Bytes raise @shared.SharedError {
  let reader = @io.MemoryReader(w => w.write(data[:]))
  let decoder = @gzip.Decoder(reader)
  (decoder.read_all() catch {
    err =>
      raise @shared.InvalidArchive(
        "invalid gzip stream: \{@debug.to_string(err)}",
      )
  }).binary()
}

///|
fn sanitize_tar_name(name : String) -> String raise @shared.SharedError {
  let name = if name.has_prefix("./") { name[2:].to_owned() } else { name }
  if name == "" || name == "." {
    return ""
  }
  if name[0] == '/' {
    raise @shared.InvalidArchive("absolute path in archive: \{name}")
  }
  for segment in name.split("/") {
    if segment == ".." {
      raise @shared.InvalidArchive("path traversal in archive: \{name}")
    }
  }
  name
}

///|
fn is_all_zero(block : BytesView) -> Bool {
  for byte in block {
    if byte != b'\x00' {
      return false
    }
  }
  true
}

///|
fn tar_cstr(
  bytes : Bytes,
  offset : Int,
  len : Int,
) -> String raise @shared.SharedError {
  let mut end = offset + len
  for i in offset..<(offset + len) {
    if bytes[i] == b'\x00' {
      end = i
      break
    }
  }
  @utf8.decode(bytes[offset:end]) catch {
    _ => raise @shared.InvalidArchive("tar entry name is not valid UTF-8")
  }
}

///|
fn tar_octal(bytes : Bytes, offset : Int, len : Int) -> Int {
  let mut value = 0
  for i in offset..<(offset + len) {
    let byte = bytes[i].to_int()
    if byte >= 48 && byte <= 55 {
      // '0'..'7'
      value = value * 8 + (byte - 48)
    } else if byte != 0 && byte != 32 {
      break
    }
  }
  value
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
