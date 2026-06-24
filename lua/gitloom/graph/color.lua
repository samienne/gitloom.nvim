--- Pure colour maths for lane-colour generation (specification.md §5.5).
---
--- Converts between packed 24-bit sRGB (`0xRRGGBB`) and OKLab/OKLCH (Björn
--- Ottosson's perceptual space), and generates well-separated overflow colours
--- by golden-angle hue rotation at a fixed lightness/chroma. No Neovim
--- dependency — graph.lua realises the packed RGB into highlight groups.
local M = {}

local GOLDEN = 137.50776405003785 -- golden angle in degrees (≈ 360 / φ²)

local function clamp01(x)
    if x < 0 then return 0 elseif x > 1 then return 1 else return x end
end

-- Real cube root (Lua's ^ rejects negative bases with a fractional exponent).
local function cbrt(x)
    if x < 0 then return -((-x) ^ (1 / 3)) end
    return x ^ (1 / 3)
end

-- sRGB gamma <-> linear light, on 0..1 channels.
local function linearize(c)
    if c <= 0.04045 then return c / 12.92 end
    return ((c + 0.055) / 1.055) ^ 2.4
end

local function delinearize(c)
    if c <= 0.0031308 then return 12.92 * c end
    return 1.055 * (c ^ (1 / 2.4)) - 0.055
end

--- Unpack `0xRRGGBB` into linear-light r,g,b (0..1).
---@param rgb integer
local function unpack_linear(rgb)
    local r = math.floor(rgb / 65536) % 256
    local g = math.floor(rgb / 256) % 256
    local b = rgb % 256
    return linearize(r / 255), linearize(g / 255), linearize(b / 255)
end

--- Pack linear-light r,g,b (0..1) back into a clamped `0xRRGGBB`.
local function pack_linear(r, g, b)
    local function chan(c) return math.floor(clamp01(delinearize(c)) * 255 + 0.5) end
    return chan(r) * 65536 + chan(g) * 256 + chan(b)
end

--- sRGB (`0xRRGGBB`) -> OKLab.
---@param rgb integer
---@return number L, number a, number b
function M.srgb_to_oklab(rgb)
    local r, g, bch = unpack_linear(rgb)
    local l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * bch
    local m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * bch
    local s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * bch
    local l_, m_, s_ = cbrt(l), cbrt(m), cbrt(s)
    return
        0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
        1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
        0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
end

--- OKLab -> sRGB (`0xRRGGBB`, gamut-clamped).
---@param L number
---@param a number
---@param b number
---@return integer
function M.oklab_to_srgb(L, a, b)
    local l_ = L + 0.3963377774 * a + 0.2158037573 * b
    local m_ = L - 0.1055613458 * a - 0.0638541728 * b
    local s_ = L - 0.0894841775 * a - 1.2914855480 * b
    local l, m, s = l_ * l_ * l_, m_ * m_ * m_, s_ * s_ * s_
    local r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
    local g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
    local bch = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
    return pack_linear(r, g, bch)
end

--- sRGB (`0xRRGGBB`) -> OKLCH (lightness, chroma, hue in degrees 0..360).
---@param rgb integer
---@return number L, number C, number H
function M.rgb_to_oklch(rgb)
    local L, a, b = M.srgb_to_oklab(rgb)
    local C = math.sqrt(a * a + b * b)
    local H = math.deg(math.atan2(b, a))
    if H < 0 then H = H + 360 end
    return L, C, H
end

--- OKLCH (hue in degrees) -> sRGB (`0xRRGGBB`, gamut-clamped).
---@param L number
---@param C number
---@param H number  degrees
---@return integer
function M.oklch_to_rgb(L, C, H)
    local rad = math.rad(H)
    return M.oklab_to_srgb(L, C * math.cos(rad), C * math.sin(rad))
end

--- Generate the `ordinal`-th overflow colour: golden-angle hue rotation from the
--- anchor's base hue, at the anchor's lightness/chroma (so generated colours sit
--- in the theme's key while staying perceptually separated at any count).
---@param anchor { L: number, C: number, base_hue: number }
---@param ordinal integer  1-based
---@return integer rgb  `0xRRGGBB`
function M.generate(anchor, ordinal)
    local H = (anchor.base_hue + ordinal * GOLDEN) % 360
    return M.oklch_to_rgb(anchor.L, anchor.C, H)
end

M.GOLDEN = GOLDEN

return M
