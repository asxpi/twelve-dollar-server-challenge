local ffi = require("ffi"); local V = require("esc")
-- a feed's strings: 20 x (body, created_at, username), realistic lengths, at odd offsets
local strs = {}
math.randomseed(7)
local function rnd(n) local t = {} for i = 1, n do t[i] = string.char(math.random(97, 122)) end return table.concat(t) end
for i = 1, 20 do
  strs[#strs + 1] = rnd(8) .. " says hi at 2026-11-14T01:02:03.456Z (VU " .. math.random(1, 300000) .. ", iter " .. math.random(0, 20) .. ")"
  strs[#strs + 1] = "2026-11-14T01:02:03.456Z"
  strs[#strs + 1] = "user_" .. math.random(1, 20000)
end
-- seed bodies are longer prose; mix some in
for i = 1, 60, 6 do strs[i] = rnd(40) .. " " .. rnd(60) .. ". " .. rnd(50) end
local src = ffi.new("uint8_t[8192]"); local offs, lens, pos = {}, {}, 3
for i, s in ipairs(strs) do ffi.copy(src + pos, s, #s); offs[i] = pos; lens[i] = #s; pos = pos + #s + 5 end
local dst = ffi.new("uint8_t[65536]"); V.bind(dst); local bindf = V.bind; V.bind = nil
local N = #strs
local ref, tb, d2
local names = {} for k in pairs(V) do names[#names + 1] = k end table.sort(names)
local rounds = tonumber(arg[1]) or 3
for r = 1, rounds do
  for _, name in ipairs(names) do
    local f = V[name]
    local iters = 100000
    local t = os.clock(); local sink = 0
    for it = 1, iters do
      local o = 0
      for i = 1, N do o = f(dst, o, src, offs[i], lens[i]) end
      sink = sink + o
    end
    local dt = os.clock() - t
    if r == rounds then io.write(string.format("%-18s %7.1f ns/feed  (%.2f ns/byte)\n", name, dt / iters * 1e9, dt / sink * 1e9)) end
  end
end

-- correctness against v0 on random data
ref = V.v0_orig
tb, d2 = ffi.new("uint8_t[300]"), ffi.new("uint8_t[2000]")
for _, name in ipairs(names) do
  local f = V[name]
  for it = 1, (name:sub(1,2) == "x_") and 0 or 30000 do
    local l, s = math.random(0, it % 3 == 0 and 200 or 70), math.random(0, 9)
    for i = 0, l - 1 do local r = math.random(); tb[s + i] = r < 0.02 and math.random(0, 31) or r < 0.04 and 34 or r < 0.06 and 92 or math.random(32, 255) end
    local a = ref(dst, 7, tb, s, l); bindf(d2); local b = f(d2, 7, tb, s, l); bindf(dst)
    assert(a == b and ffi.string(dst + 7, a - 7) == ffi.string(d2 + 7, b - 7), name)
  end
end
print("all variants match v0")
