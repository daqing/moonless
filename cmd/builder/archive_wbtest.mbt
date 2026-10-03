///|
// Raw-tar crafting helpers: build ustar archives byte by byte so malicious
// inputs (path traversal, absolute paths, symlinks) can be fed to the
// unpacker exactly as an attacker would ship them.

///|
fn write_str(header : FixedArray[Byte], offset : Int, text : String) -> Unit {
  let bytes = @utf8.encode(text)
  for i in 0..<bytes.length() {
    header[offset + i] = bytes[i]
  }
}

///|
fn write_octal(
  header : FixedArray[Byte],
  offset : Int,
  digits : Int,
  value : Int,
) -> Unit {
  let mut v = value
  let mut i = digits - 1
  for ;; {
    header[offset + i] = (v % 8 + 48).to_byte()
    v = v / 8
    if i == 0 {
      break
    }
    i -= 1
  }
}

///|
// One 512-byte ustar header for a regular file, checksum included.
fn tar_file_header(name : String, size : Int, typeflag : Int) -> Bytes {
  let header : FixedArray[Byte] = FixedArray::makei(512, _ => b'\x00')
  write_str(header, 0, name)
  write_str(header, 100, "0000644")
  write_str(header, 108, "0000000")
  write_str(header, 116, "0000000")
  write_octal(header, 124, 11, size)
  write_str(header, 136, "00000000000")
  // checksum placeholder: eight spaces while summing
  for i in 148..<156 {
    header[i] = b' '
  }
  header[156] = typeflag.to_byte()
  write_str(header, 257, "ustar")
  header[263] = b'0'
  header[264] = b'0'
  let mut sum = 0
  for i in 0..<512 {
    sum += header[i].to_int()
  }
  write_octal(header, 148, 6, sum)
  header[154] = b'\x00'
  header[155] = b' '
  Bytes::from_array(header[:])
}

///|
fn tar_archive(entries : Array[(String, String)]) -> Bytes {
  let mut out : Bytes = b""
  for pair in entries {
    let (name, content) = pair
    let data = @utf8.encode(content)
    out = out + tar_file_header(name, data.length(), 48)
    out = out + data
    let pad = (512 - data.length() % 512) % 512
    out = out + Bytes::make(pad, b'\x00')
  }
  out + Bytes::make(1024, b'\x00')
}

///|
test "tar_entries rejects zip-slip and absolute paths" {
  try tar_entries(tar_archive([("../evil.txt", "pwned")])) catch {
    @shared.InvalidArchive(message) =>
      assert_true(message.contains("traversal"))
    _ => fail("expected InvalidArchive")
  } noraise {
    _ => fail("expected ../ entry to be rejected")
  }
  try tar_entries(tar_archive([("/etc/passwd", "pwned")])) catch {
    @shared.InvalidArchive(message) => assert_true(message.contains("absolute"))
    _ => fail("expected InvalidArchive")
  } noraise {
    _ => fail("expected absolute path to be rejected")
  }
  try tar_entries(tar_archive([("a/../../evil.txt", "pwned")])) catch {
    @shared.InvalidArchive(message) =>
      assert_true(message.contains("traversal"))
    _ => fail("expected InvalidArchive")
  } noraise {
    _ => fail("expected nested .. to be rejected")
  }
}

///|
test "tar_entries rejects symlink entries" {
  // typeflag '2' (50) = symlink
  let evil = tar_file_header("innocent.txt", 3, 50) + @utf8.encode("../")
  try
    tar_entries(evil + Bytes::make(509, b'\x00') + Bytes::make(1024, b'\x00'))
  catch {
    @shared.InvalidArchive(_) => ()
    _ => fail("expected InvalidArchive")
  } noraise {
    _ => fail("expected symlink entry to be rejected")
  }
}

///|
async test "extract_tar_gz round-trips a crafted archive under dest" {
  let dest = @fs.tmpdir(prefix="moonless-extract-test-")
  // Reuse the system tar for the happy path (it produces real gzip).
  let fixture_dir = @fs.tmpdir(prefix="moonless-fixture-")
  write_fixture_files(fixture_dir, [
    ("moon.mod", "name = \"x\"\n"),
    ("sub/dir/note.txt", "nested\n"),
  ])
  let archive = pack_tar_gz(fixture_dir)
  let files = extract_tar_gz(archive, dest)
  assert_true(has_entry(files, "moon.mod"))
  assert_true(has_entry(files, "sub/dir/note.txt"))
  assert_true(@fs.exists(dest + "/moon.mod"))
  let nested = (@fs.read_file(dest + "/sub/dir/note.txt") catch {
    _ => raise FixtureError("nested file missing")
  }).text() catch {
    _ => raise FixtureError("not text")
  }
  assert_eq(nested, "nested\n")
}
