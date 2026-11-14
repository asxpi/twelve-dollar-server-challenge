local ffi = require("ffi"); local bit = require("bit")
local band, bor, bxor, bnot, rshift = bit.band, bit.bor, bit.bxor, bit.bnot, bit.rshift
local hexb = ffi.new("uint8_t[16]"); ffi.copy(hexb, "0123456789abcdef", 16)
local V = {}
-- the slow, always-correct loop from i..e
local function slow(dst, o, src, i, e)
  for i = i, e - 1 do
    local c = src[i]
    if c >= 32 and c ~= 34 and c ~= 92 then dst[o] = c; o = o + 1
    else
      dst[o] = 92
      if c == 34 or c == 92 then dst[o + 1] = c; o = o + 2
      elseif c == 10 then dst[o + 1] = 110; o = o + 2
      elseif c == 13 then dst[o + 1] = 114; o = o + 2
      elseif c == 9 then dst[o + 1] = 116; o = o + 2
      elseif c == 8 then dst[o + 1] = 98; o = o + 2
      elseif c == 12 then dst[o + 1] = 102; o = o + 2
      else dst[o + 1] = 117; dst[o + 2] = 48; dst[o + 3] = 48
        dst[o + 4] = hexb[rshift(c, 4)]; dst[o + 5] = hexb[band(c, 15)]; o = o + 6 end
    end
  end
  return o
end
V.v0_orig = function(dst, o, src, s, n) return slow(dst, o, src, s, s + n) end
-- scan (no stores), then one copy
V.v1_scan_copy = function(dst, o, src, s, n)
  local e = s + n
  for i = s, e - 1 do
    local c = src[i]
    if c < 32 or c == 34 or c == 92 then
      local k = i - s
      if k > 0 then ffi.copy(dst + o, src + s, k) end
      return slow(dst, o + k, src, i, e)
    end
  end
  if n > 0 then ffi.copy(dst + o, src + s, n) end
  return o + n
end
-- branch-free scan with a class table, then one copy
local cls = ffi.new("uint8_t[256]"); for c = 0, 31 do cls[c] = 1 end; cls[34] = 1; cls[92] = 1
V.v2_table_acc = function(dst, o, src, s, n)
  local acc = 0
  for i = s, s + n - 1 do acc = bor(acc, cls[src[i]]) end
  if acc == 0 then
    if n > 0 then ffi.copy(dst + o, src + s, n) end
    return o + n
  end
  return slow(dst, o, src, s, s + n)
end
-- table scan with early exit
V.v3_table_exit = function(dst, o, src, s, n)
  local e = s + n
  for i = s, e - 1 do
    if cls[src[i]] ~= 0 then
      local k = i - s
      if k > 0 then ffi.copy(dst + o, src + s, k) end
      return slow(dst, o + k, src, i, e)
    end
  end
  if n > 0 then ffi.copy(dst + o, src + s, n) end
  return o + n
end
-- 32-bit SWAR (the earlier attempt)
local u32p = ffi.typeof("const uint32_t *")
V.v4_swar32 = function(dst, o, src, s, n)
  local p = ffi.cast(u32p, src + s)
  local k, words = 0, rshift(n, 2)
  while k < words do
    local x = p[k]
    local y, z = bxor(x, 0x22222222), bxor(x, 0x5c5c5c5c)
    if band(bor(band(x - 0x20202020, bnot(x)), band(y - 0x01010101, bnot(y)), band(z - 0x01010101, bnot(z))), 0x80808080) ~= 0 then break end
    k = k + 1
  end
  k = k * 4
  if k > 0 then ffi.copy(dst + o, src + s, k); o = o + k end
  return slow(dst, o, src, s + k, s + n)
end
-- 64-bit SWAR on uint64_t cdata
local u64p = ffi.typeof("const uint64_t *")
local L20, L22, L5c, L01, L80 = 0x2020202020202020ULL, 0x2222222222222222ULL, 0x5c5c5c5c5c5c5c5cULL, 0x0101010101010101ULL, 0x8080808080808080ULL
V.v5_swar64 = function(dst, o, src, s, n)
  local p = ffi.cast(u64p, src + s)
  local k, words = 0, rshift(n, 3)
  while k < words do
    local x = p[k]
    local y, z = bxor(x, L22), bxor(x, L5c)
    if band(bor(band(x - L20, bnot(x)), band(y - L01, bnot(y)), band(z - L01, bnot(z))), L80) ~= 0 then break end
    k = k + 1
  end
  k = k * 8
  if k > 0 then ffi.copy(dst + o, src + s, k); o = o + k end
  return slow(dst, o, src, s + k, s + n)
end
-- copy first (always), then scan the copy branch-free; redo slowly only if dirty
V.v6_copy_then_acc = function(dst, o, src, s, n)
  if n == 0 then return o end
  ffi.copy(dst + o, src + s, n)
  local acc = 0
  for i = o, o + n - 1 do acc = bor(acc, cls[dst[i]]) end
  if acc == 0 then return o + n end
  return slow(dst, o, src, s, s + n)
end
-- v2 with the scan unrolled four bytes at a time
V.v8_table_acc4 = function(dst, o, src, s, n)
  local acc, i, e = 0, s, s + n
  local e4 = e - 3
  while i < e4 do
    acc = bor(acc, cls[src[i]], cls[src[i + 1]], cls[src[i + 2]], cls[src[i + 3]])
    i = i + 4
  end
  while i < e do acc = bor(acc, cls[src[i]]); i = i + 1 end
  if acc == 0 then
    if n > 0 then ffi.copy(dst + o, src + s, n) end
    return o + n
  end
  return slow(dst, o, src, s, s + n)
end
-- copy first, then check the copy through an aligned int32 view of the output buffer made once
-- (V.bind(dst)); bytes of the first and last word outside [o, o+n) are forced to 0xff
local d32
local lowm = ffi.new("int32_t[4]", 0, 0xff, 0xffff, 0xffffff)                      -- bytes before o
local highm = ffi.new("int32_t[4]", bit.tobit(0xffffff00), bit.tobit(0xffff0000), bit.tobit(0xff000000), 0)  -- bytes after the last
function V.bind(dst) d32 = ffi.cast("int32_t *", dst) end
V.v9_copy_swar32 = function(dst, o, src, s, n)
  if n == 0 then return o end
  ffi.copy(dst + o, src + s, n)
  local w0, last = rshift(o, 2), o + n - 1
  local w1 = rshift(last, 2)
  local acc = 0
  local x = bor(d32[w0], lowm[band(o, 3)])
  if w0 == w1 then
    x = bor(x, highm[band(last, 3)])
    local y, z = bxor(x, 0x22222222), bxor(x, 0x5c5c5c5c)
    acc = bor(band(x - 0x20202020, bnot(x)), band(y - 0x01010101, bnot(y)), band(z - 0x01010101, bnot(z)))
  else
    local y, z = bxor(x, 0x22222222), bxor(x, 0x5c5c5c5c)
    acc = bor(band(x - 0x20202020, bnot(x)), band(y - 0x01010101, bnot(y)), band(z - 0x01010101, bnot(z)))
    for w = w0 + 1, w1 - 1 do
      x = d32[w]
      y, z = bxor(x, 0x22222222), bxor(x, 0x5c5c5c5c)
      acc = bor(acc, band(x - 0x20202020, bnot(x)), band(y - 0x01010101, bnot(y)), band(z - 0x01010101, bnot(z)))
    end
    x = bor(d32[w1], highm[band(last, 3)])
    y, z = bxor(x, 0x22222222), bxor(x, 0x5c5c5c5c)
    acc = bor(acc, band(x - 0x20202020, bnot(x)), band(y - 0x01010101, bnot(y)), band(z - 0x01010101, bnot(z)))
  end
  if band(acc, 0x80808080) == 0 then return o + n end
  return slow(dst, o, src, s, s + n)
end
-- floors (not correct escapes): copy only, and nothing at all
V.x_copy_only = function(dst, o, src, s, n) ffi.copy(dst + o, src + s, n); return o + n end
V.x_nop = function(dst, o, src, s, n) return o + n end
-- inline copy+check in one byte loop without the escape branches: store always, accumulate class
V.v10_store_acc = function(dst, o, src, s, n)
  local acc = 0
  for i = 0, n - 1 do
    local c = src[s + i]
    dst[o + i] = c
    acc = bor(acc, cls[c])
  end
  if acc == 0 then return o + n end
  return slow(dst, o, src, s, s + n)
end
-- no loop for strings up to 128 bytes: overlapping unaligned 64-bit words, straight-line code,
-- generated so that no helper function is called (a helper becomes its own trace and aborts).
-- A word flags bytes < 0x20, '"' and '\\'. Needs 7 readable bytes after a string shorter than 8.
local function gen()
  local function chk(x)   -- text of the flag expression for the word expression x
    return ("bor(band(%s - L20, bnot(%s)), band(bxor(%s, L22) - L01, bnot(bxor(%s, L22))), band(bxor(%s, L5c) - L01, bnot(bxor(%s, L5c))))")
      :format(x, x, x, x, x, x)
  end
  local function words(n, a, b)   -- n words from pointer a, n from pointer b
    local t = {}
    for i = 0, n - 1 do t[#t + 1] = "local x" .. i .. " = " .. a .. "[" .. i .. "]" end
    for i = 0, n - 1 do t[#t + 1] = "local y" .. i .. " = " .. b .. "[" .. i .. "]" end
    local e = {}
    for i = 0, n - 1 do e[#e + 1] = chk("x" .. i); e[#e + 1] = chk("y" .. i) end
    -- a balanced tree of bor() keeps every call binary
    while #e > 1 do
      local f = {}
      for i = 1, #e, 2 do f[#f + 1] = e[i + 1] and ("bor(" .. e[i] .. ", " .. e[i + 1] .. ")") or e[i] end
      e = f
    end
    return table.concat(t, "\n    ") .. "\n    acc = " .. e[1]
  end
  local src = [[
local ffi, bit, big, slow = ...
local band, bor, bxor, bnot, lshift = bit.band, bit.bor, bit.bxor, bit.bnot, bit.lshift
local cast, copy = ffi.cast, ffi.copy
local u64p = ffi.typeof("const uint64_t *")
local L20, L22, L5c, L01, L80 = 0x2020202020202020ULL, 0x2222222222222222ULL, 0x5c5c5c5c5c5c5c5cULL, 0x0101010101010101ULL, 0x8080808080808080ULL
local ONES = 0xffffffffffffffffULL
return function(dst, o, src, s, n)
  if n > 128 then return big(dst, o, src, s, n) end
  if n == 0 then return o end
  local p = src + s
  local q = cast(u64p, p)
  local acc
  if n < 8 then
    local x0 = bor(q[0], lshift(ONES, 8 * n))
    acc = ]] .. chk("x0") .. [[

  elseif n <= 16 then
    local t = cast(u64p, p + (n - 8))
    ]] .. words(1, "q", "t") .. [[

  elseif n <= 32 then
    local t = cast(u64p, p + (n - 16))
    ]] .. words(2, "q", "t") .. [[

  elseif n <= 64 then
    local t = cast(u64p, p + (n - 32))
    ]] .. words(4, "q", "t") .. [[

  else
    local t = cast(u64p, p + (n - 64))
    ]] .. words(8, "q", "t") .. [[

  end
  if band(acc, L80) == 0 then
    copy(dst + o, p, n)
    return o + n
  end
  return slow(dst, o, src, s, s + n)
end
]]
  return assert(loadstring(src, "=escape(generated)"))(ffi, bit, V.v8_table_acc4, slow)
end
V.v11_swar64_noloop = gen()
return V
