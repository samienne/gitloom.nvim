--- Tests for gitloom.color (spec §5.5): OKLab/OKLCH conversion and golden-angle
--- colour generation. Pure maths — no Neovim state needed.
local color = require("gitloom.graph.color")

local function channels(rgb)
    return math.floor(rgb / 65536) % 256, math.floor(rgb / 256) % 256, rgb % 256
end

local function close(a, b, tol)
    return math.abs(a - b) <= (tol or 1)
end

describe("color OKLab/OKLCH conversions", function()
    local samples = {
        0x000000, 0xffffff, 0xff0000, 0x00ff00, 0x0000ff,
        0x808080, 0x123456, 0xabcdef, 0xff8800, 0x2e7d32,
    }

    it("round-trips sRGB through OKLab", function()
        for _, rgb in ipairs(samples) do
            local L, a, b = color.srgb_to_oklab(rgb)
            local back = color.oklab_to_srgb(L, a, b)
            local r1, g1, b1 = channels(rgb)
            local r2, g2, b2 = channels(back)
            assert.is_true(close(r1, r2) and close(g1, g2) and close(b1, b2),
                ("OKLab round-trip %06x -> %06x"):format(rgb, back))
        end
    end)

    it("round-trips sRGB through OKLCH", function()
        for _, rgb in ipairs(samples) do
            local L, C, H = color.rgb_to_oklch(rgb)
            local back = color.oklch_to_rgb(L, C, H)
            local r1, g1, b1 = channels(rgb)
            local r2, g2, b2 = channels(back)
            assert.is_true(close(r1, r2) and close(g1, g2) and close(b1, b2),
                ("OKLCH round-trip %06x -> %06x"):format(rgb, back))
        end
    end)

    it("places white near L=1 and black near L=0 with ~zero chroma", function()
        local Lw, Cw = color.rgb_to_oklch(0xffffff)
        local Lk, Ck = color.rgb_to_oklch(0x000000)
        assert.is_true(Lw > 0.99 and Cw < 0.01, "white")
        assert.is_true(Lk < 0.01 and Ck < 0.01, "black")
    end)
end)

describe("color.generate", function()
    it("produces in-gamut integer colours", function()
        local anchor = { L = 0.72, C = 0.12, base_hue = 30 }
        for ord = 1, 40 do
            local rgb = color.generate(anchor, ord)
            assert.is_true(rgb >= 0 and rgb <= 0xffffff, "in gamut")
            assert.equals(rgb, math.floor(rgb)) -- packed integer
        end
    end)

    it("is deterministic per ordinal", function()
        local anchor = { L = 0.7, C = 0.1, base_hue = 0 }
        assert.equals(color.generate(anchor, 7), color.generate(anchor, 7))
        assert.equals(color.generate(anchor, 13), color.generate(anchor, 13))
    end)

    it("spaces consecutive hues by the golden angle", function()
        -- Low chroma keeps every hue inside the sRGB gamut, so no clamping
        -- distorts the measured hue and the golden-angle spread is visible.
        local anchor = { L = 0.7, C = 0.05, base_hue = 0 }
        local hues = {}
        for ord = 1, 12 do
            local _, _, H = color.rgb_to_oklch(color.generate(anchor, ord))
            hues[#hues + 1] = H
        end
        for i = 1, #hues do
            for j = i + 1, #hues do
                local d = math.abs(hues[i] - hues[j]) % 360
                d = math.min(d, 360 - d)
                assert.is_true(d > 10,
                    ("hues %d/%d too close: %.1f vs %.1f"):format(i, j, hues[i], hues[j]))
            end
        end
    end)
end)
