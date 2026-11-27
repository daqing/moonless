///|
fn xml_text(input : String, tag : String) -> String? raise {
  let open = "<\{tag}>"
  let close = "</\{tag}>"
  match input.find(open) {
    None => None
    Some(start) => {
      let value_start = start + open.length()
      match input[value_start:].find(close) {
        None => raise S3Error::InvalidResponse("missing closing tag </\{tag}>")
        Some(end) => {
          let text = input[value_start:value_start + end]
          Some(xml_unescape_text(text))
        }
      }
    }
  }
}

///|
fn xml_unescape_text(input : StringView) -> String {
  let out = StringBuilder()
  let mut rest = input
  while rest.find("&") is Some(start) {
    out.write_stringview(rest[:start])
    let after_amp = rest[start + 1:]
    match after_amp.find(";") {
      None => {
        out.write_stringview(rest[start:])
        return out.to_string()
      }
      Some(end) => {
        let entity = after_amp[:end]
        match xml_entity_value(entity) {
          Some(value) => out.write_stringview(value)
          None => {
            out.write_char('&')
            out.write_stringview(entity)
            out.write_char(';')
          }
        }
        rest = after_amp[end + 1:]
      }
    }
  } nobreak {
    out.write_stringview(rest)
    out.to_string()
  }
}

///|
fn xml_entity_value(entity : StringView) -> String? {
  match entity {
    "amp" => Some("&")
    "lt" => Some("<")
    "gt" => Some(">")
    "quot" => Some("\"")
    "apos" => Some("'")
    _ => xml_numeric_entity_value(entity)
  }
}

///|
fn xml_numeric_entity_value(entity : StringView) -> String? {
  if entity.length() < 2 || entity[0] != '#' {
    return None
  }
  let value = if entity[1] == 'x' || entity[1] == 'X' {
    parse_xml_entity_digits(entity[2:], 16)
  } else {
    parse_xml_entity_digits(entity[1:], 10)
  }
  match value {
    Some(codepoint) =>
      if is_xml_char_codepoint(codepoint) {
        Some(codepoint.unsafe_to_char().to_string())
      } else {
        None
      }
    None => None
  }
}

///|
fn parse_xml_entity_digits(input : StringView, radix : Int32) -> Int32? {
  if input.is_empty() {
    return None
  }
  let mut value = 0
  for ch in input {
    match xml_digit_value(ch) {
      Some(digit) =>
        if digit < radix {
          value = value * radix + digit
        } else {
          return None
        }
      None => return None
    }
  }
  Some(value)
}

///|
fn xml_digit_value(ch : Char) -> Int32? {
  if ch >= '0' && ch <= '9' {
    Some(ch.to_int() - '0'.to_int())
  } else if ch >= 'a' && ch <= 'f' {
    Some(ch.to_int() - 'a'.to_int() + 10)
  } else if ch >= 'A' && ch <= 'F' {
    Some(ch.to_int() - 'A'.to_int() + 10)
  } else {
    None
  }
}

///|
fn is_xml_char_codepoint(codepoint : Int32) -> Bool {
  codepoint == 0x9 ||
  codepoint == 0xA ||
  codepoint == 0xD ||
  (codepoint >= 0x20 && codepoint <= 0xD7FF) ||
  (codepoint >= 0xE000 && codepoint <= 0xFFFD) ||
  (codepoint >= 0x10000 && codepoint <= 0x10FFFF)
}

///|
fn xml_blocks(input : String, tag : String) -> Array[String] raise {
  let open = "<\{tag}>"
  let close = "</\{tag}>"
  let result : Array[String] = []
  let mut rest = input
  while true {
    match rest.find(open) {
      None => return result
      Some(start) => {
        let value_start = start + open.length()
        match rest[value_start:].find(close) {
          None =>
            raise S3Error::InvalidResponse("missing closing tag </\{tag}>")
          Some(end) => {
            result.push(rest[value_start:value_start + end].to_owned())
            rest = rest[value_start + end + close.length():].to_owned()
          }
        }
      }
    }
  } nobreak {
    result
  }
}

///|
fn parse_bool_text(value : String?, field : String) -> Bool raise {
  match value {
    Some("true") => true
    Some("false") => false
    Some(text) =>
      raise S3Error::InvalidResponse("invalid boolean for \{field}: \{text}")
    None => raise S3Error::InvalidResponse("missing \{field}")
  }
}

///|
fn parse_int64_text(value : String?, field : String) -> Int64 raise {
  match value {
    Some(text) => parse_non_negative_int64(text, field)
    None => raise S3Error::InvalidResponse("missing \{field}")
  }
}

///|
fn parse_non_negative_int64(text : String, field : String) -> Int64 raise {
  if text.length() == 0 {
    raise S3Error::InvalidResponse("missing \{field}")
  }
  let mut value = 0L
  for ch in text {
    if ch >= '0' && ch <= '9' {
      value = value * 10L + (ch.to_int() - '0'.to_int()).to_int64()
    } else {
      raise S3Error::InvalidResponse("invalid integer for \{field}: \{text}")
    }
  }
  value
}

///|
fn required_xml_text(
  input : String,
  tag : String,
  context : String,
) -> String raise {
  match xml_text(input, tag) {
    Some(value) => value
    None => raise S3Error::InvalidResponse("missing <\{tag}> in \{context}")
  }
}

///|
fn parse_list_buckets(xml : String) -> ListBucketsResult raise {
  let buckets : Array[Bucket] = []
  for block in xml_blocks(xml, "Bucket") {
    buckets.push({
      name: required_xml_text(block, "Name", "Bucket"),
      creation_date: xml_text(block, "CreationDate"),
    })
  }
  {
    owner_id: xml_text(xml, "ID"),
    owner_display_name: xml_text(xml, "DisplayName"),
    prefix: xml_text(xml, "Prefix"),
    continuation_token: xml_text(xml, "ContinuationToken"),
    buckets,
  }
}

///|
fn parse_list_objects_v2(xml : String) -> ListObjectsV2Result raise {
  let contents : Array[ListedObject] = []
  for block in xml_blocks(xml, "Contents") {
    let key = required_xml_text(block, "Key", "Contents")
    let size = parse_int64_text(xml_text(block, "Size"), "Contents.Size")
    contents.push({ key, size, etag: xml_text(block, "ETag"), })
  }
  let common_prefixes : Array[String] = []
  for block in xml_blocks(xml, "CommonPrefixes") {
    common_prefixes.push(required_xml_text(block, "Prefix", "CommonPrefixes"))
  }
  {
    is_truncated: parse_bool_text(xml_text(xml, "IsTruncated"), "IsTruncated"),
    next_continuation_token: xml_text(xml, "NextContinuationToken"),
    contents,
    common_prefixes,
  }
}
