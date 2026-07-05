-- list_components.lua
-- Show all components attached to the network (compact single-page view)

local component = require("component")

local components = {}
for ctype, addr in component.list() do
  table.insert(components, {type = ctype, addr = addr:sub(1, 8)})
end

-- Sort by type, then address
table.sort(components, function(a, b)
  if a.type ~= b.type then return a.type < b.type end
  return a.addr < b.addr
end)

local currentType = nil
local count = 0
for _, comp in ipairs(components) do
  if comp.type ~= currentType then
    currentType = comp.type
    io.write(string.format("%-15s ", comp.type))
    count = 0
  else
    io.write(string.rep(" ", 15))
  end
  print(comp.addr)
  count = count + 1
end

print("\n" .. #components .. " components found")
