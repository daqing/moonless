local methods = {
  ["REST.GET.OBJECT"] = "get",
  ["REST.PUT.OBJECT"] = "put",
  ["REST.POST.OBJECT"] = "post",
  ["REST.DELETE.OBJECT"] = "delete",
  ["BATCH.DELETE.OBJECT"] = "delete",
}

function map_s3_event(tag, timestamp, record)
  local event = methods[record["operation"]]
  local status = tonumber(record["status"])
  local key = record["key"]
  if event == nil or status == nil or status < 200 or status >= 300 or key == nil or key == "" then
    return -1, 0, 0
  end
  record["source"] = "s3"
  record["event"] = event
  return 1, timestamp, record
end
