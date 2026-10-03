///|
// Minimal ustar/tar reading for function packages, shared by the builder
// (extraction) and the gateway (reading moonless.toml out of an upload).
// Only regular files and directories are honored; links, symlinks, and
// GNU long-name headers are refused, and any entry that would escape the
// extraction root (zip-slip: absolute paths or ".." segments) is rejected.

///|
pub struct TarEntry {
  path : String // sanitized, relative to the extraction root
  is_dir : Bool
  data : Bytes
}

///|
pub fn TarEntry::TarEntry(
  path~ : String,
  is_dir~ : Bool,
  data~ : Bytes,
) -> TarEntry {
  { path, is_dir, data, }
}

///|
// Parses a plain (uncompressed) tar archive into sanitized entries.
// Checksums are not verified; pax extension headers ('x'/'g') are skipped.
pub fn tar_entries(archive : Bytes) -> Array[TarEntry] raise SharedError {
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
      raise InvalidArchive("truncated tar archive at entry \{full_name}")
    }
    let data = archive[data_start:data_start + size].to_owned()
    offset = data_start + padded
    match type_byte {
      48 | 0 => {
        // '0' regular file
        let path = sanitize_tar_name(full_name)
        if path != "" {
          entries.push(TarEntry(path~, is_dir=false, data~))
        }
      }
      53 => {
        // '5' directory
        let path = sanitize_tar_name(full_name)
        if path != "" {
          entries.push(TarEntry(path~, is_dir=true, data~))
        }
      }
      120 | 103 => () // 'x'/'g' pax headers: metadata only, skip
      76 | 75 =>
        raise InvalidArchive(
          "GNU long-name entries are not supported: \{full_name}",
        )
      _ => raise InvalidArchive("unsupported tar entry: \{full_name}")
    }
  }
  entries
}

///|
pub async fn gunzip(data : Bytes) -> Bytes raise SharedError {
  let reader = @io.MemoryReader(w => w.write(data[:]))
  let decoder = @gzip.Decoder(reader)
  (decoder.read_all() catch {
    err => raise InvalidArchive("invalid gzip stream: \{@debug.to_string(err)}")
  }).binary()
}

///|
// Reads one text file out of a .tar.gz archive (the gateway uses this for
// moonless.toml). Returns None when the entry is absent.
pub async fn tar_gz_read_text(
  archive_gz : Bytes,
  path : String,
) -> String? raise SharedError {
  let plain = gunzip(archive_gz)
  for entry in tar_entries(plain) {
    if !entry.is_dir && entry.path == path {
      return Some(@utf8.decode_lossy(entry.data[:]))
    }
  }
  None
}

///|
fn sanitize_tar_name(name : String) -> String raise SharedError {
  let name = if name.has_prefix("./") { name[2:].to_owned() } else { name }
  if name == "" || name == "." {
    return ""
  }
  if name[0] == '/' {
    raise InvalidArchive("absolute path in archive: \{name}")
  }
  for segment in name.split("/") {
    if segment == ".." {
      raise InvalidArchive("path traversal in archive: \{name}")
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
fn tar_cstr(bytes : Bytes, offset : Int, len : Int) -> String raise SharedError {
  let mut end = offset + len
  for i in offset..<(offset + len) {
    if bytes[i] == b'\x00' {
      end = i
      break
    }
  }
  @utf8.decode(bytes[offset:end]) catch {
    _ => raise InvalidArchive("tar entry name is not valid UTF-8")
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
