import "CoreLibs/graphics"
import "CoreLibs/timer"

local pd  = playdate
local gfx = pd.graphics
gfx.setBackgroundColor(gfx.kColorWhite)

-- =================== Config ===================
local SCREEN_W, SCREEN_H = 400, 240
local CLIP_X, CLIP_Y, CLIP_W, CLIP_H = 6, 18, SCREEN_W - 12, 178
local PROMPT_Y = CLIP_Y + CLIP_H + 8

local MIN_SIDES, MAX_SIDES = 2, 20
local COMMON_DICE = { 4, 6, 8, 10, 12, 20 }

-- Modes: 0=Normal, 1=Adv, 2=Dis
local RM_NORMAL, RM_ADV, RM_DIS = 0, 1, 2
local ROLLNAMES = { "Norm", "Adv", "Dis" }
local rollmode = RM_NORMAL
local TITLE_SCALE = 0.34 

local TAU = math.pi * 2
-- ============ Angle wrapping & D6 debug ============
local function wrapTau(a)
  -- Keep angles bounded to avoid FP drift
  -- Range: [0, TAU)
  a = a % TAU
  if a < 0 then a = a + TAU end
  return a
end

-- was IDLE_ANGLE; now mutable so title → game matches
local idleAngle = TAU * 0.125

local SPIN_TIME_MIN, SPIN_TIME_MAX = 1.35, 2.05
local TURNS_MIN, TURNS_MAX = 2, 3

-- Title animation (slow roll + morph between standard dice)
local TITLE_ROT_SPEED   = 0.35
local TITLE_SWITCH_SECS = 1.8
-- Title view: 0 = wireframe, 1 = per-face procedural dither
local TITLE_VIEW_WIREFRAME, TITLE_VIEW_PROC = 0, 1
local titleView = TITLE_VIEW_WIREFRAME


local title_time_acc = 0
local title_ang      = 0
local title_idx      = 1
local last_ts        = pd.getCurrentTimeMilliseconds() / 1000

-- =================== State ===================
local S_TITLE, S_IDLE, S_SPIN, S_RESULT = 1, 2, 3, 4
local state = S_TITLE

local sin, cos, floor = math.sin, math.cos, math.floor
local unpack          = table.unpack

local sides      = 20
local last_detail = nil
local last_result = nil

local spin_t0, spin_t1 = 0, 0
local ang0, ang1       = 0, 0

local shadingEnabled = false   -- default OFF (current behavior is wireframe)
local menuInited = false
local shadingMenuItem = nil

-- Keep all stage drawing inside this inner border
local STAGE_PAD = 6
local function stageRect()
  return CLIP_X + STAGE_PAD, CLIP_Y + STAGE_PAD, CLIP_W - 2 * STAGE_PAD, CLIP_H - 2 * STAGE_PAD
end

local SCALE_IDLE = 0.46
local SCALE_SPIN = 0.48
local currentScale = SCALE_IDLE

-- Idle animation speed (radians per second)
local IDLE_ROT_SPEED = 0.6

-- =================== RNG ===================
local function randint(lo, hi) return math.floor(math.random() * (hi - lo + 1)) + lo end
local function randf(a, b)     return a + math.random() * (b - a) end

-- Minimal state we care about persisting:
local SAVEFILE = "db_dice_settings"

local function saveState()
  playdate.datastore.write({
    sides       = sides,
    rollmode    = rollmode,
    state       = state,        -- S_TITLE / S_IDLE / etc.
    last_result = last_result,
    shading     = shadingEnabled
  }, SAVEFILE)
end

local function loadState()
  local d = playdate.datastore.read(SAVEFILE)
  if d then
    sides       = math.max(MIN_SIDES, math.min(MAX_SIDES, d.sides or sides))
    rollmode    = tonumber(d.rollmode) or RM_NORMAL
    last_result = d.last_result
    shadingEnabled = (d.shading == nil) and shadingEnabled or (d.shading and true or false)
    -- optional: restore last state sensibly
    if d.state == S_RESULT then state = S_IDLE else state = S_TITLE end
  end
end

-- =================== Geometry helpers ===================
local function normalizeVerts(V)
  local maxr = 0
  for i = 1, #V do
    local x, y, z = unpack(V[i])
    local r = math.sqrt(x * x + y * y + z * z)
    if r > maxr then maxr = r end
  end
  if maxr == 0 then return V end
  local out = {}
  for i = 1, #V do
    local x, y, z = unpack(V[i])
    out[i] = { x / maxr, y / maxr, z / maxr }
  end
  return out
end

-- connect pairs at the shortest edge length
local function buildEdgesFromVerts(verts)
  local dmin = nil
  local pairs = {}
  for i = 1, #verts - 1 do
    local ax, ay, az = unpack(verts[i])
    for j = i + 1, #verts do
      local bx, by, bz = unpack(verts[j])
      local dx, dy, dz = ax - bx, ay - by, az - bz
      local d2 = dx * dx + dy * dy + dz * dz
      if dmin == nil or d2 < dmin then dmin = d2 end
      pairs[#pairs + 1] = { i, j, d2 }
    end
  end
  local eps = dmin * 1.00001
  local edges = {}
  for _, p in ipairs(pairs) do
    if p[3] <= eps then edges[#edges + 1] = { p[1], p[2] } end
  end
  return edges
end

-- Build coplanar polygon faces with consistent outward winding (centroid-based)
local function facesFromVerts(V)
  local n = #V
  local eps_plane = 1e-4
  local eps_norm  = 1e-6
  local function cross(ax, ay, az, bx, by, bz) return ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx end
  local function dot(ax, ay, az, bx, by, bz)  return ax * bx + ay * by + az * bz end

  local planes, planeVerts = {}, {}

  local function isSupportingPlane(nx, ny, nz, d)
    local minS, maxS = 1e9, -1e9
    for m = 1, n do
      local vm = V[m]
      local s = nx * vm[1] + ny * vm[2] + nz * vm[3] - d
      if s < minS then minS = s end
      if s > maxS then maxS = s end
      if minS < -eps_plane and maxS > eps_plane then return false end
    end
    return true
  end

  for i = 1, n - 2 do
    local vi = V[i]
    for j = i + 1, n - 1 do
      local vj = V[j]
      local ux, uy, uz = vj[1] - vi[1], vj[2] - vi[2], vj[3] - vi[3]
      for k = j + 1, n do
        local vk = V[k]
        local vx, vy, vz = vk[1] - vi[1], vk[2] - vi[2], vk[3] - vi[3]
        local nx, ny, nz = cross(ux, uy, uz, vx, vy, vz)
        local nn = math.sqrt(nx * nx + ny * ny + nz * nz)
        if nn > eps_norm then
          nx, ny, nz = nx / nn, ny / nn, nz / nn

          -- Canonicalize normal for grouping (sign flip to keep the dominant axis positive)
          local ax, ay, az = math.abs(nx), math.abs(ny), math.abs(nz)
          if     ax > ay and ax > az then if nx < 0 then nx, ny, nz = -nx, -ny, -nz end
          elseif ay > az              then if ny < 0 then nx, ny, nz = -nx, -ny, -nz end
          else                             if nz < 0 then nx, ny, nz = -nx, -ny, -nz end end

          local d = dot(nx, ny, nz, vi[1], vi[2], vi[3])

          if isSupportingPlane(nx, ny, nz, d) then
            local q = string.format("%.4f,%.4f,%.4f|%.4f", nx, ny, nz, d)
            if not planes[q] then
              local idxs = {}
              for m = 1, n do
                local vm = V[m]
                local dist = nx * vm[1] + ny * vm[2] + nz * vm[3] - d
                if math.abs(dist) <= eps_plane then idxs[#idxs + 1] = m end
              end
              if #idxs >= 3 then
                table.sort(idxs)
                local sk = table.concat(idxs, ",")
                if not planeVerts[sk] then
                  planes[q] = true
                  planeVerts[sk] = { list = idxs }
                end
              end
            end
          end
        end
      end
    end
  end

  local polys = {}
  for _, rec in pairs(planeVerts) do
    local idxs = rec.list

    -- Build a stable (u,v) basis for sorting
    local a3, b3, c3 = V[idxs[1]], V[idxs[2]], V[idxs[3]]
    local ux0, uy0, uz0 = b3[1] - a3[1], b3[2] - a3[2], b3[3] - a3[3]
    local vx0, vy0, vz0 = c3[1] - a3[1], c3[2] - a3[2], c3[3] - a3[3]
    local nx0, ny0, nz0 = ux0 * vz0 - uz0 * vy0, uz0 * vx0 - ux0 * vz0, ux0 * vy0 - uy0 * vx0
    local nlen = math.sqrt(nx0 * nx0 + ny0 * ny0 + nz0 * nz0)
    if nlen < 1e-6 then nx0, ny0, nz0 = 0, 0, 1 else nx0, ny0, nz0 = nx0 / nlen, ny0 / nlen, nz0 / nlen end

    -- Make (u,v) axes orthonormal to n0
    local refx, refy, refz = 1, 0, 0
    if math.abs(nx0) > 0.9 then refx, refy, refz = 0, 1, 0 end
    local ux, uy, uz = ny0 * refz - nz0 * refy, nz0 * refx - nx0 * refz, nx0 * refy - ny0 * refx
    local ul = math.sqrt(ux * ux + uy * uy + uz * uz); ux, uy, uz = ux / ul, uy / ul, uz / ul
    local vx, vy, vz = ny0 * uz - nz0 * uy, nz0 * ux - nx0 * uz, nx0 * uy - ny0 * ux

    -- Project to (u,v), sort CCW around centroid in plane
    local pts, cx, cy = {}, 0, 0
    for _, i in ipairs(idxs) do
      local p = V[i]
      local px = p[1] * ux + p[2] * uy + p[3] * uz
      local py = p[1] * vx + p[2] * vy + p[3] * vz
      pts[#pts + 1] = { i = i, x = px, y = py }
      cx, cy = cx + px, cy + py
    end
    cx, cy = cx / #pts, cy / #pts
    for _, p in ipairs(pts) do p.a = math.atan(p.y - cy, p.x - cx) end
    table.sort(pts, function(p, q) return p.a < q.a end)

    local ordered = {}
    for _, p in ipairs(pts) do ordered[#ordered + 1] = p.i end

    -- Enforce outward winding: face normal should point away from origin.
    local cx3, cy3, cz3 = 0, 0, 0
    for _, i in ipairs(ordered) do local v = V[i]; cx3, cy3, cz3 = cx3 + v[1], cy3 + v[2], cz3 + v[3] end
    cx3, cy3, cz3 = cx3 / #ordered, cy3 / #ordered, cz3 / #ordered

    if #ordered >= 3 then
      local A = V[ordered[1]]
      local B = V[ordered[2]]
      local C = V[ordered[3]]
      local abx, aby, abz = B[1] - A[1], B[2] - A[2], B[3] - A[3]
      local acx, acy, acz = C[1] - A[1], C[2] - A[2], C[3] - A[3]
      local fnx, fny, fnz = aby * acz - abz * acy, abz * acx - abx * acz, abx * acy - aby * acx
      if (fnx * cx3 + fny * cy3 + fnz * cz3) < 0 then
        local i, j = 1, #ordered
        while i < j do ordered[i], ordered[j] = ordered[j], ordered[i]; i = i + 1; j = j - 1 end
      end
    end

    polys[#polys + 1] = ordered
  end
  return polys
end

-- =================== Meshes ===================
local V_TETRA = normalizeVerts({ { 1, 1, 1 }, { -1, -1, 1 }, { -1, 1, -1 }, { 1, -1, -1 } })
local E_TETRA = buildEdgesFromVerts(V_TETRA)
local F_TETRA = facesFromVerts(V_TETRA)

local V_CUBE = normalizeVerts({
  { -1, -1, -1 }, {  1, -1, -1 }, {  1,  1, -1 }, { -1,  1, -1 },
  { -1, -1,  1 }, {  1, -1,  1 }, {  1,  1,  1 }, { -1,  1,  1 },
})
local E_CUBE = {
  { 1, 2 }, { 2, 3 }, { 3, 4 }, { 4, 1 },
  { 5, 6 }, { 6, 7 }, { 7, 8 }, { 8, 5 },
  { 1, 5 }, { 2, 6 }, { 3, 7 }, { 4, 8 },
}
local F_CUBE = {
  {4, 3, 2, 1},  -- back
  {5, 6, 7, 8},  -- front
  {1, 2, 6, 5},  -- bottom
  {2, 3, 7, 6},  -- right
  {3, 4, 8, 7},  -- top
  {4, 1, 5, 8},  -- left
}

local V_OCTA = normalizeVerts({
  { 1, 0, 0 }, { -1, 0, 0 },
  { 0, 1, 0 }, { 0, -1, 0 },
  { 0, 0, 1 }, { 0, 0, -1 },
})
local E_OCTA = buildEdgesFromVerts(V_OCTA)
local F_OCTA = facesFromVerts(V_OCTA)

local function makePentBipyramid()
  local V = {}
  local h, r = 1.0, 1.0
  V[#V + 1] = { 0, 0, h }
  for i = 0, 4 do
    local a = TAU * (i / 5.0)
    V[#V + 1] = { r * math.cos(a), r * math.sin(a), 0 }
  end
  V[#V + 1] = { 0, 0, -h }
  local E = {}
  for i = 2, 6 do E[#E + 1] = { 1, i } end
  for i = 2, 6 do E[#E + 1] = { 7, i } end
  for i = 2, 6 do local j = (i < 6) and (i + 1) or 2; E[#E + 1] = { i, j } end
  return V, E
end
local V_D10, E_D10 = makePentBipyramid()
V_D10 = normalizeVerts(V_D10)
local F_D10 = facesFromVerts(V_D10)

local function makeIcosa()
  local phi = (1 + math.sqrt(5)) * 0.5
  local V = {
    { 0, 1,  phi }, { 0, -1,  phi }, { 0, 1,  -phi }, { 0, -1, -phi },
    { 1, phi, 0 },  { -1, phi, 0 },  { 1, -phi, 0 },  { -1, -phi, 0 },
    { phi, 0, 1 },  { -phi, 0, 1 },  { phi, 0, -1 },  { -phi, 0, -1 },
  }
  local E = buildEdgesFromVerts(V)
  return V, E
end
local V_D20, E_D20 = makeIcosa()
V_D20 = normalizeVerts(V_D20)
local F_D20 = facesFromVerts(V_D20)

local function makeDodeca()
  local phi = (1 + math.sqrt(5)) * 0.5
  local inv = 1.0 / phi
  local V = {
    { -1, -1, -1 }, { 1, -1, -1 }, { 1, 1, -1 }, { -1, 1, -1 },
    { -1, -1, 1 },  { 1, -1, 1 },  { 1, 1, 1 },  { -1, 1, 1 },
    { 0, -inv, -phi }, { 0, inv, -phi }, { 0, -inv, phi }, { 0, inv, phi },
    { -inv, -phi, 0 }, { inv, -phi, 0 }, { -inv, phi, 0 }, { inv, phi, 0 },
    { -phi, 0, -inv }, { -phi, 0, inv }, { phi, 0, -inv }, { phi, 0, inv },
  }
  local E = buildEdgesFromVerts(V)
  return V, E
end
local V_D12, E_D12 = makeDodeca()
V_D12 = normalizeVerts(V_D12)
local F_D12 = facesFromVerts(V_D12)

local function meshForSides(n)
  local best, bd = 4, math.huge
  for _, v in ipairs({ 4, 6, 8, 10, 12, 20 }) do
    local d = math.abs(v - n); if d < bd then bd, best = d, v end
  end
  if     best == 4  then return V_TETRA, E_TETRA, F_TETRA
  elseif best == 6  then return V_CUBE,  E_CUBE,  F_CUBE
  elseif best == 8  then return V_OCTA,  E_OCTA,  F_OCTA
  elseif best == 10 then return V_D10,   E_D10,   F_D10
  elseif best == 12 then return V_D12,   E_D12,   F_D12
  else                    return V_D20,   E_D20,   F_D20
  end
end

-- =================== Projection ===================
local _ZOFF, _NEAR, _SCALE = 260.0, 30.0, 180.0

local function clipCenter()
  local x, y, w, h = stageRect()
  return x + math.floor(w / 2), y + math.floor(h / 2)
end

local function halfSize()
  local _, _, w, h = stageRect()
  return math.max(8, math.floor(math.min(w, h) * currentScale))
end

local function centerOr(cx, cy)
  if cx ~= nil and cy ~= nil then return cx, cy end
  return clipCenter()
end

-- Float projector for solid fill (no integer rounding here)
local function rotProjectVertsF(verts, t, scale, cx, cy)
  t = wrapTau(t)
  local S = scale or halfSize()
  local CXC, CYC = centerOr(cx, cy)
  local ca, sa = cos(t), sin(t)
  local cb, sb = cos(t * 0.7 + 1.1), sin(t * 0.7 + 1.1)

  local P2, R3 = {}, {}
  for i = 1, #verts do
    local x, y, z = unpack(verts[i])
    x, y, z = x * S, y * S, z * S
    local xz = x * ca - y * sa
    local yz = x * sa + y * ca
    local y2 = yz * cb - z * sb
    local z2 = yz * sb + z * cb
    local denom = z2 + _ZOFF; if denom < _NEAR then denom = _NEAR end
    local d = _SCALE / denom
    P2[i] = { CXC + xz * d, CYC + y2 * d }
    R3[i] = { xz, y2, z2 }
  end
  return P2, R3
end

-- Rotate + perspective-project; also keep camera-space coords for normals
local function rotProjectVerts(verts, t, scale, cx, cy)
  t = wrapTau(t)
  local S = scale or halfSize()
  local CXC, CYC = centerOr(cx, cy)
  local ca, sa = cos(t), sin(t)
  local cb, sb = cos(t * 0.7 + 1.1), sin(t * 0.7 + 1.1)

  local P2, R3 = {}, {}
  for i = 1, #verts do
    local x, y, z = unpack(verts[i])
    x, y, z = x * S, y * S, z * S
    local xz = x * ca - y * sa
    local yz = x * sa + y * ca
    local y2 = yz * cb - z * sb
    local z2 = yz * sb + z * cb
    local denom = z2 + _ZOFF; if denom < _NEAR then denom = _NEAR end
    local d = _SCALE / denom
    P2[i] = { floor(CXC + xz * d + 0.5), floor(CYC + y2 * d + 0.5) }
    R3[i] = { xz, y2, z2 }
  end
  return P2, R3
end

local function projectMeshEdgesAt(verts, edges, t, cx, cy, halfSizePx)
  t = wrapTau(t)
  local S = halfSizePx or halfSize()
  local cx0, cy0 = centerOr(cx, cy)
  local ca, sa = cos(t), sin(t)
  local cb, sb = cos(t * 0.7 + 1.1), sin(t * 0.7 + 1.1)

  local P = {}
  for i = 1, #verts do
    local x, y, z = unpack(verts[i])
    x, y, z = x * S, y * S, z * S
    local xz = x * ca - y * sa
    local yz = x * sa + y * ca
    local y2 = yz * cb - z * sb
    local z2 = yz * sb + z * cb
    local denom = z2 + _ZOFF; if denom < _NEAR then denom = _NEAR end
    local d = _SCALE / denom
    P[i] = { floor(cx0 + xz * d + 0.5), floor(cy0 + y2 * d + 0.5) }
  end

  local out = {}
  for i = 1, #edges do
    local a, b = edges[i][1], edges[i][2]
    local p0, p1 = P[a], P[b]
    out[i] = { p0[1], p0[2], p1[1], p1[2] }
  end
  return out
end


-- === Edges ===
local function drawEdges(edges)
  gfx.setColor(gfx.kColorBlack)
  for i = 1, #edges do
    local e = edges[i]
    gfx.drawLine(e[1], e[2], e[3], e[4])
  end
end

-- =================== View-dependent Proc Dither ===================
local DITHER_LEVELS = {
  0.06, 0.10, 0.14, 0.18, 0.22, 0.26,
  0.30, 0.34, 0.40, 0.48, 0.58, 0.70
}

local function hash32(x)
  x = (x ~ (x >> 16)) & 0xFFFFFFFF
  x = (x * 0x45d9f3b) & 0xFFFFFFFF
  x = (x ~ (x >> 16)) & 0xFFFFFFFF
  x = (x * 0x45d9f3b) & 0xFFFFFFFF
  x = (x ~ (x >> 16)) & 0xFFFFFFFF
  return x
end


-- stable base shade per face index & mesh signature
local function baseShadeForFace(faceIndex, numFaces, numVerts)
  local key = (faceIndex * 73856093 + numFaces * 19349663 + numVerts * 83492791) & 0xFFFFFFFF
  local h = hash32(key)
  local idx = (h % #DITHER_LEVELS) + 1
  return DITHER_LEVELS[idx]
end

local function quantizeShade(x)
  local best, bd = DITHER_LEVELS[1], 9e9
  for _, lv in ipairs(DITHER_LEVELS) do
    local d = math.abs(x - lv)
    if d < bd then bd, best = d, lv end
  end
  return best
end

local function densityScale(_numFaces) return 1.0 end

local function modulateByView(base, nx, ny, nz, numFaces)
  local len = math.sqrt(nx * nx + ny * ny + nz * nz)
  if len < 1e-6 then return quantizeShade(base) end
  local nzN = nz / len
  local face = math.max(-1, math.min(1, -nzN))
  local t = (face + 1) * 0.5
  local add  = 0.22 * t
  local bias = 0.06
  local scaled = (base + add + bias) * densityScale(numFaces)
  if scaled < 0.02 then scaled = 0.02 end
  if scaled > 0.98 then scaled = 0.98 end
  return quantizeShade(scaled)
end

local function precomputeFaceData(V, F)
  local FC, FN = {}, {}
  for fi = 1, #F do
    local idxs = F[fi]
    local cx, cy, cz = 0, 0, 0
    for _, i in ipairs(idxs) do
      local v = V[i]; cx, cy, cz = cx + v[1], cy + v[2], cz + v[3] end
    local inv = 1 / #idxs; cx, cy, cz = cx*inv, cy*inv, cz*inv
    FC[fi] = { cx, cy, cz }

    local nx, ny, nz = 0, 0, 0
    for i = 1, #idxs do
      local a = V[idxs[i]]
      local b = V[idxs[(i % #idxs) + 1]]
      nx = nx + (a[2] - b[2]) * (a[3] + b[3])
      ny = ny + (a[3] - b[3]) * (a[1] + b[1])
      nz = nz + (a[1] - b[1]) * (a[2] + b[2])
    end
    local nlen = math.sqrt(nx*nx + ny*ny + nz*nz)
    if nlen > 1e-9 then nx, ny, nz = nx/nlen, ny/nlen, nz/nlen else nz = 1 end
    FN[fi] = { nx, ny, nz }
  end
  return FC, FN
end

-- Cache per-mesh face centroids and object-space normals (stable)
local faceCache = setmetatable({}, { __mode = "k" })

-- Optional: warm faceCache so first PROC frame never stalls
local function warmFaceCaches()
  local FC, FN
  FC, FN = precomputeFaceData(V_TETRA, F_TETRA); faceCache[F_TETRA] = { FC = FC, FN = FN }
  FC, FN = precomputeFaceData(V_CUBE,  F_CUBE ); faceCache[F_CUBE ] = { FC = FC, FN = FN }
  FC, FN = precomputeFaceData(V_OCTA,  F_OCTA ); faceCache[F_OCTA ] = { FC = FC, FN = FN }
  FC, FN = precomputeFaceData(V_D10,   F_D10  ); faceCache[F_D10  ] = { FC = FC, FN = FN }
  FC, FN = precomputeFaceData(V_D12,   F_D12  ); faceCache[F_D12  ] = { FC = FC, FN = FN }
  FC, FN = precomputeFaceData(V_D20,   F_D20  ); faceCache[F_D20  ] = { FC = FC, FN = FN }
end
warmFaceCaches()

-- remembers front/back state per face to add hysteresis near nz ≈ 0
local faceVisCache = setmetatable({}, { __mode = "k" })


local function drawDieSolid(V, E, F, t, cx, cy, halfSizePx)
  local P2 = select(1, rotProjectVertsF(V, t, halfSizePx, cx, cy))

  local cache = faceCache[F]
  local FC, FN
  if cache then FC, FN = cache.FC, cache.FN else
    FC, FN = precomputeFaceData(V, F)
    faceCache[F] = { FC = FC, FN = FN }
  end

  local ca, sa = math.cos(wrapTau(t)), math.sin(wrapTau(t))
  local cb, sb = math.cos(wrapTau(t) * 0.7 + 1.1), math.sin(wrapTau(t) * 0.7 + 1.1)
  local function rotCam(x, y, z)
    local xz = x*ca - y*sa
    local yz = x*sa + y*ca
    local y2 = yz*cb - z*sb
    local z2 = yz*sb + z*cb
    return xz, y2, z2
  end

  local order = {}
  local NUMF = #F
  for fi = 1, NUMF do
    local cxo, cyo, czo = table.unpack(FC[fi])
    local _, _, zc = rotCam(cxo, cyo, czo)
    local zbias = 1e-4 * (fi / NUMF)
    order[#order + 1] = { fi = fi, z = zc + zbias }
  end
  table.sort(order, function(a, b) if a.z == b.z then return a.fi < b.fi else return a.z < b.z end end)

  gfx.setImageDrawMode(gfx.kDrawModeCopy)
  gfx.setColor(gfx.kColorBlack)

  local numFaces = #F

  local visRec = faceVisCache[F]
  local ENTER_T, EXIT_T = -0.002, 0.002

    if not visRec then
    visRec = { front = {} }
    faceVisCache[F] = visRec
   end

  local function roundAndPruneInt(pts)
    local ipts = {}
    for i = 1, #pts do ipts[i] = { math.floor(pts[i][1] + 0.5), math.floor(pts[i][2] + 0.5) } end
    local tmp = {}
    for i = 1, #ipts do
      local a = ipts[i]
      local b = ipts[(i % #ipts) + 1]
      if not (a[1] == b[1] and a[2] == b[2]) then tmp[#tmp + 1] = a end
    end
    ipts = tmp
    if #ipts < 3 then return ipts end
    local function area2(a, b, c) return (b[1]-a[1])*(c[2]-a[2]) - (b[2]-a[2])*(c[1]-a[1]) end
    local changed = true
    while changed and #ipts >= 3 do
      changed = false
      for i = 1, #ipts do
        local A = ipts[(i - 2) % #ipts + 1]
        local B = ipts[i]
        local C = ipts[(i) % #ipts + 1]
        if area2(A, B, C) == 0 then table.remove(ipts, i); changed = true; break end
      end
    end
    return ipts
  end

  local function fillConvexScanline(poly)
    local n = #poly
    if n < 3 then return end
    local rx, ry, rw, rh = gfx.getClipRect()
    if rx == nil then rx, ry, rw, rh = 0, 0, SCREEN_W, SCREEN_H end
    local xMin, xMax = rx, rx + rw - 1
    local yMinBand, yMaxBand = ry, ry + rh - 1

    local edges = {}
    local ymin, ymax = 1e9, -1e9
    for i = 1, n do
      local a = poly[i]
      local b = poly[(i % n) + 1]
      local x0, y0 = a[1], a[2]
      local x1, y1 = b[1], b[2]
      if y0 ~= y1 then
        if y0 > y1 then x0, x1, y0, y1 = x1, x0, y1, y0 end
        local yStart = math.floor(y0 + 0.5)
        local yEnd   = math.floor(y1 + 0.5) - 1
        if yEnd >= yMinBand and yStart <= yMaxBand then
          if yStart < yMinBand then yStart = yMinBand end
          if yEnd > yMaxBand then yEnd = yMaxBand end
          if yStart <= yEnd then
            local invm = (x1 - x0) / (y1 - y0)
            local xAtStart = x0 + (yStart - y0) * invm
            edges[#edges + 1] = { yStart = yStart, yEnd = yEnd, x = xAtStart, invm = invm }
            if yStart < ymin then ymin = yStart end
            if yEnd > ymax then ymax = yEnd end
          end
        end
      end
    end
    if #edges < 2 or ymin > ymax then return end

    for y = ymin, ymax do
      local xs, k = {}, 0
      for i = 1, #edges do
        local e = edges[i]
        if y >= e.yStart and y <= e.yEnd then
          k = k + 1
          xs[k] = e.x
          e.x = e.x + e.invm
        end
      end
      if k >= 2 then
        if k == 2 and xs[1] > xs[2] then xs[1], xs[2] = xs[2], xs[1] else table.sort(xs) end
        for i = 1, k - 1, 2 do
          local xa = math.floor(xs[i] + 0.5)
          local xb = math.floor(xs[i + 1] + 0.5)
          if xb >= xMin and xa <= xMax then
            if xa < xMin then xa = xMin end
            if xb > xMax then xb = xMax end
            if xb >= xa then gfx.drawLine(xa, y, xb, y) end
          end
        end
      end
    end
  end

  for _, o in ipairs(order) do
    local fi   = o.fi
    local idxs = F[fi]

    local nxo, nyo, nzo = table.unpack(FN[fi])
    local nx, ny, nz = rotCam(nxo, nyo, nzo)

    local wasFront = visRec.front[fi]
    local isFront
    if wasFront then isFront = (nz < EXIT_T) else isFront = (nz < ENTER_T) end
    visRec.front[fi] = isFront

    if isFront then
      local base  = baseShadeForFace(fi, numFaces, #V)
      local shade = modulateByView(base, nx, ny, nz, numFaces)

      local pts = {}
      do
        local EPS_UV = 1e-6
        for i = 1, #idxs do
          local p = P2[idxs[i]]
          local px, py = p[1], p[2]
          local dup = false
          for j = 1, #pts do
            local qx, qy = pts[j][1], pts[j][2]
            if math.abs(px - qx) < EPS_UV and math.abs(py - qy) < EPS_UV then dup = true; break end
          end
          if not dup then pts[#pts + 1] = { px, py } end
        end
      end

      if #pts >= 3 then
        local cx2, cy2 = 0, 0
        for i = 1, #pts do cx2, cy2 = cx2 + pts[i][1], cy2 + pts[i][2] end
        cx2, cy2 = cx2 / #pts, cy2 / #pts
        table.sort(pts, function(a, b)
          return math.atan(a[2] - cy2, a[1] - cx2) < math.atan(b[2] - cy2, b[1] - cx2)
        end)

        local minEdge = 1e9
        for i = 1, #pts do
          local a = pts[i]
          local b = pts[(i % #pts) + 1]
          local dx, dy = b[1] - a[1], b[2] - a[2]
          local L = math.sqrt(dx*dx + dy*dy)
          if L < minEdge then minEdge = L end
        end
        local E0, K = 2.0, 0.20
        local raw = (minEdge > E0) and ((minEdge - E0) * K) or 0.0
        local INSET_BASE
        if     numFaces >= 20 then INSET_BASE = 0.16
        elseif numFaces >= 12 then INSET_BASE = 0.20
        elseif numFaces <=  8 then INSET_BASE = 0.28 else INSET_BASE = 0.25 end
        local INSET_PX = math.min(INSET_BASE, raw)
        if INSET_PX > 0 then
          local icx, icy = 0, 0
          for i = 1, #pts do icx, icy = icx + pts[i][1], icy + pts[i][2] end
          icx, icy = icx / #pts, icy / #pts
          for i = 1, #pts do
            local x, y = pts[i][1], pts[i][2]
            local dx, dy = icx - x, icy - y
            local L = math.sqrt(dx*dx + dy*dy)
            if L > 0 then
              pts[i][1] = x + (dx / L) * INSET_PX
              pts[i][2] = y + (dy / L) * INSET_PX
            end
          end
        end

        local ipts = roundAndPruneInt(pts)
        if #ipts >= 3 then
          gfx.setDitherPattern(shade)
          fillConvexScanline(ipts)
        end
      end
    end
  end

  gfx.setDitherPattern(1.0)
  gfx.setImageDrawMode(gfx.kDrawModeCopy)

  local ecx, ecy = centerOr(cx, cy)
  local ehs = halfSizePx or halfSize()
  drawEdges(projectMeshEdgesAt(V, E, t, ecx, ecy, ehs))
end

-- === Wireframe (used in-game) ===
local function drawDieWireframe(V, E, t, cx, cy, halfSizePx)
  local edges = projectMeshEdgesAt(V, E, t, cx, cy, halfSizePx)
  drawEdges(edges)
end

-- Renders based on the user's "Shading" checkbox:
local function drawDieCurrent(V, E, F, t, cx, cy, halfSizePx)
  if shadingEnabled then
    -- Solid with procedural dither (this function already overlays edges)
    drawDieSolid(V, E, F, t, cx, cy, halfSizePx)
  else
    -- Classic wireframe
    drawDieWireframe(V, E, t, cx, cy, halfSizePx)
  end
end

-- ============= Pretty UI helpers =============
local function drawRoundRect(x, y, w, h, r)
  if gfx.drawRoundRect then gfx.drawRoundRect(x, y, w, h, r) else gfx.drawRect(x, y, w, h) end
end

local function drawTextCenteredInRect(text, x, y, w, h)
  local tw, th = gfx.getTextSize(text)
  gfx.drawText(text, math.floor(x + (w - tw) / 2), math.floor(y + (h - th) / 2))
end

local function drawPill(x, y, w, h, text)
  gfx.setColor(gfx.kColorBlack)
  drawRoundRect(x, y, w, h, 6)
  gfx.fillRoundRect(x + 1, y + 1, w - 2, h - 2, 6)
  gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
  drawTextCenteredInRect(text, x, y, w, h)
  gfx.setImageDrawMode(gfx.kDrawModeCopy)
end

local function drawStageFrame()
  local rx = 8
  gfx.setColor(gfx.kColorBlack)
  drawRoundRect(CLIP_X - 2, CLIP_Y - 2, CLIP_W + 4, CLIP_H + 4, rx)
  drawRoundRect(CLIP_X, CLIP_Y, CLIP_W, CLIP_H, rx - 2)
  for yy = CLIP_Y + 8, CLIP_Y + CLIP_H - 8, 16 do
    for xx = CLIP_X + 8, CLIP_X + CLIP_W - 8, 16 do
      gfx.drawPixel(xx, yy)
    end
  end
end

local function drawTextCentered(text, y)
  local w, h = gfx.getTextSize(text)
  gfx.drawText(text, math.floor((SCREEN_W - w) / 2), y)
end

-- =================== 7-segment digits ===================
local function segH(x, y, w, t) gfx.fillRect(x, y, w, t) end
local function segV(x, y, h, t) gfx.fillRect(x, y, t, h) end

local DIGIT_SEGS = {
  [0] = { A = 1, B = 1, C = 1, D = 1, E = 1, F = 1 },
  [1] = { B = 1, C = 1 },
  [2] = { A = 1, B = 1, G = 1, E = 1, D = 1 },
  [3] = { A = 1, B = 1, G = 1, C = 1, D = 1 },
  [4] = { F = 1, G = 1, B = 1, C = 1 },
  [5] = { A = 1, F = 1, G = 1, C = 1, D = 1 },
  [6] = { A = 1, F = 1, G = 1, E = 1, C = 1, D = 1 },
  [7] = { A = 1, B = 1, C = 1 },
  [8] = { A = 1, B = 1, C = 1, D = 1, E = 1, F = 1, G = 1 },
  [9] = { A = 1, B = 1, C = 1, D = 1, F = 1, G = 1 },
}

local function drawDigitMed(x, y, ch)
  local d = tonumber(ch); if not d then return end
  local W, H, T, M = 12, 20, 2, 1
  local mid = y + math.floor(H / 2 - T / 2)
  local xL, xR = x, x + W - T
  local yT, yB = y, y + H - T
  local yU0, yU1 = y + M, mid - 2
  local yL0, yL1 = mid + 2, y + H - M - 1
  local s = DIGIT_SEGS[d] or {}
  local function segH2(x0, y0, w) gfx.fillRect(x0, y0, w, T) end
  local function segV2(x0, y0, h) gfx.fillRect(x0, y0, T, h) end
  if s.A then segH2(x + M, yT, W - 2 * M) end
  if s.G then segH2(x + M, mid, W - 2 * M) end
  if s.D then segH2(x + M, yB, W - 2 * M) end
  if s.F then segV2(xL, yU0, yU1 - yU0 + 1) end
  if s.B then segV2(xR, yU0, yU1 - yU0 + 1) end
  if s.E then segV2(xL, yL0, yL1 - yL0 + 1) end
  if s.C then segV2(xR, yL0, yL1 - yL0 + 1) end
end

local function drawMedStrCentered(s, bx, by, bw, bh)
  local per = 13
  local w = (#s > 0) and (#s * per - (per - 12)) or 0
  local x0 = bx + math.max(0, math.floor((bw - w) / 2))
  local y0 = by + math.max(0, math.floor((bh - 20) / 2))
  for i = 1, #s do drawDigitMed(x0 + (i - 1) * per, y0, s:sub(i, i)) end
end

local function drawDigitBig(x, y, ch)
  if ch == "-" then segH(x + 2, y + 24, 20, 3); return end
  local d = tonumber(ch); if not d then return end
  local W, H, T, M = 24, 40, 3, 2
  local mid = y + math.floor(H / 2 - T / 2)
  local xL, xR = x, x + W - T
  local yT, yB = y, y + H - T
  local yU0, yU1 = y + M, mid - 2
  local yL0, yL1 = mid + 2, y + H - M - 1
  local s = DIGIT_SEGS[d] or {}
  if s.A then segH(x + M, yT, W - 2 * M, T) end
  if s.G then segH(x + M, mid, W - 2 * M, T) end
  if s.D then segH(x + M, yB, W - 2 * M, T) end
  if s.F then segV(xL, yU0, yU1 - yU0 + 1, T) end
  if s.B then segV(xR, yU0, yU1 - yU0 + 1, T) end
  if s.E then segV(xL, yL0, yL1 - yL0 + 1, T) end
  if s.C then segV(xR, yL0, yL1 - yL0 + 1, T) end
end

local function drawNumberBig(n)
  local s = tostring(n)
  local per = 26
  local total = #s * per - 2
  local sx, sy, sw, sh = stageRect()
  local cx = sx + math.floor(sw / 2)
  local x0 = cx - math.floor(total / 2)
  local y0 = sy + math.floor(sh / 2) - 22
  for i = 1, #s do drawDigitBig(x0 + (i - 1) * per, y0, s:sub(i, i)) end
end

local function drawAdvDisBoxes(a, b, chosen, mode)
  local clipT, clipB = CLIP_Y, CLIP_Y + CLIP_H
  local cx = CLIP_X + math.floor(CLIP_W / 2)
  local w, h, gap = 44, 24, 28
  local y = clipT + 10
  if y + h > clipB - 1 then y = clipB - 1 - h end

  local leftX  = cx - math.floor(gap / 2) - w
  local rightX = cx + math.floor(gap / 2)

  gfx.drawRect(leftX, y, w, h)
  gfx.drawRect(rightX, y, w, h)

  drawMedStrCentered(tostring(a), leftX + 2, y + 2, w - 4, h - 4)
  drawMedStrCentered(tostring(b), rightX + 2, y + 2, w - 4, h - 4)

  local gapL = leftX + w
  local gapR = rightX
  local axc  = math.floor((gapL + gapR) / 2)
  local ay   = y + math.floor(h / 2)
  local L, head = 10, 3

  if chosen == a then
    local tip, tail = axc - math.floor(L / 2), axc - math.floor(L / 2) + L
    gfx.drawLine(tip + head, ay, tail, ay)
    gfx.drawLine(tip + head, ay - 2, tip, ay)
    gfx.drawLine(tip + head, ay + 2, tip, ay)
  else
    local tip, tail = axc + math.floor(L / 2), axc + math.floor(L / 2) - L
    gfx.drawLine(tail, ay, tip - head, ay)
    gfx.drawLine(tip - head, ay - 2, tip, ay)
    gfx.drawLine(tip - head, ay + 2, tip, ay)
  end

  local label = (mode == RM_ADV) and "A" or "D"
  local lw, lh = gfx.getTextSize(label)
  local sx, sy, sw, sh = stageRect()
  local labelY = y + h + 4
  if labelY + lh > sy + sh - 1 then labelY = sy + sh - 1 - lh end
  gfx.drawText(label, math.floor(cx - lw / 2), labelY)
end

-- =================== UI ===================
local function drawHUD(text)
  gfx.clearClipRect()
  local barY, barH = PROMPT_Y - 2, 22
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(0, barY, SCREEN_W, barH)
  gfx.setColor(gfx.kColorWhite)
  gfx.drawLine(0, barY, SCREEN_W, barY)

  gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
  if text and #text > 0 then gfx.drawTextInRect(text, 6, barY + 4, SCREEN_W - 12, barH - 6) end

  local rm = tonumber(rollmode) or RM_NORMAL
  rm = rm % 3
  local modeLabel = ROLLNAMES[rm + 1]
  local mw = gfx.getTextSize(modeLabel) + 18
  drawPill(SCREEN_W - mw - 6, barY + 6, mw, 12, modeLabel)

  local dn = "D" .. tostring(sides)
  local dw = gfx.getTextSize(dn) + 18
  drawPill(math.floor((SCREEN_W - dw) / 2), barY + 6, dw, 12, dn)

  gfx.setImageDrawMode(gfx.kDrawModeCopy)
end

-- === Title screen ===

-- Deterministic 32-bit checksum (no bitwise ops)
local function vertsChecksum(V)
  local h = 5381.0
  for i = 1, #V do
    local x, y, z = V[i][1], V[i][2], V[i][3]
    for _, v in ipairs{ x, y, z } do
      local s = string.format("%.9f", v)
      for k = 1, #s do
        h = (h * 33.0 + string.byte(s, k)) % 4294967296.0
      end
    end
  end
  return math.floor(h)
end

-- One baseline for the cube
local CUBE_CSUM0 = vertsChecksum(V_CUBE)

-- If you use the version that always checks the cube:
local function drawD6DebugLabels(t, cx, cy, halfSizePx)
  local P = select(1, rotProjectVerts(V_CUBE, t, halfSizePx, cx, cy))
  gfx.setImageDrawMode(gfx.kDrawModeCopy)
  gfx.setColor(gfx.kColorBlack)
  for i = 1, #P do
    local px, py = P[i][1], P[i][2]
    gfx.fillCircleAtPoint(px, py, 2)
    local label = tostring(i)
    local tw, th = gfx.getTextSize(label)
    gfx.drawText(label, px - math.floor(tw / 2), py - th - 2)
  end
  local live = vertsChecksum(V_CUBE)
  local sx, sy = stageRect()
  local tag = (live == CUBE_CSUM0) and "OK" or "MISMATCH"
  gfx.drawText(string.format("D6 Σ: 0x%08X  %s", live, tag), sx + 4, sy + 4)
end


local function drawTitle()
  gfx.clearClipRect()
  gfx.setImageDrawMode(gfx.kDrawModeCopy)
  gfx.setColor(gfx.kColorBlack)
  gfx.clear(gfx.kColorWhite)
  gfx.setImageDrawMode(gfx.kDrawModeCopy)
  gfx.setColor(gfx.kColorBlack)

  drawTextCentered("Digital Bard Dice", 14)

  local n = COMMON_DICE[((title_idx - 1) % #COMMON_DICE) + 1]
  local V, E, F = meshForSides(n)

  local cx = math.floor(SCREEN_W / 2)
  local cy = math.floor(SCREEN_H * 0.56)
  local halfSizePx = math.floor(math.min(SCREEN_W, SCREEN_H) * TITLE_SCALE)

  drawDieCurrent(V, E, F, title_ang, cx, cy, halfSizePx)
end

-- =================== In-game rendering (WIREFRAME ONLY) ===================
local function redrawIdle()
  currentScale = SCALE_IDLE
  gfx.clear(gfx.kColorWhite)
  drawStageFrame()

  local sx, sy, sw, sh = stageRect()
  gfx.setClipRect(sx, sy, sw, sh)

  local V, E, F = meshForSides(sides)
  gfx.setColor(gfx.kColorBlack)
  drawDieCurrent(V, E, F, idleAngle)

  -- D6 vertex labels + checksum overlay
  if sides == 6 then
    local cx, cy = clipCenter()
    local hs = halfSize()
    -- drawD6DebugLabels(idleAngle, cx, cy, hs)
  end

  gfx.clearClipRect()
  drawHUD("")
end


-- =================== Easing ===================
local function easeOutCubic(u)
  if u <= 0 then return 0 end
  if u >= 1 then return 1 end
  local t = 1 - u
  return 1 - t * t * t
end

local function easeRollNatural(u)
  if u <= 0 then return 0 end
  if u >= 1 then return 1 end
  return 1 - (1 - u) * (1 - u)
end



-- =================== Rolling ===================
local function startSpin()
  state = S_SPIN
  currentScale = SCALE_SPIN
  spin_t0 = playdate.getCurrentTimeMilliseconds() / 1000
  local dur = randf(SPIN_TIME_MIN, SPIN_TIME_MAX)
  spin_t1 = spin_t0 + dur

  ang0 = wrapTau(idleAngle)                 -- keep this wrapped
  local turns = randint(TURNS_MIN, TURNS_MAX)
  ang1 = ang0 + turns * TAU + randf(0.15, 0.85) * TAU
end

local function finishSpin()
  state = S_RESULT
  local a = randint(1, sides)
  local chosen, b = a, nil
  if rollmode ~= RM_NORMAL then
    b = randint(1, sides)
    chosen = (rollmode == RM_ADV) and math.max(a, b) or math.min(a, b)
    last_detail = { a = a, b = b, chosen = chosen }
  else
    last_detail = nil
  end

  last_result = chosen
  saveState()

  gfx.clear(gfx.kColorWhite)
  drawStageFrame()

  local sx, sy, sw, sh = stageRect()
  gfx.setClipRect(sx, sy, sw, sh)

  gfx.setColor(gfx.kColorBlack)
  drawNumberBig(chosen)
  if last_detail then drawAdvDisBoxes(last_detail.a, last_detail.b, last_detail.chosen, rollmode) end

  gfx.clearClipRect()
  drawHUD("Result: " .. tostring(chosen) .. "   A: OK")
end

-- =================== Helpers ===================
local function quickNext()
  if sides == COMMON_DICE[1] or sides == COMMON_DICE[2] or sides == COMMON_DICE[3]
     or sides == COMMON_DICE[4] or sides == COMMON_DICE[5] or sides == COMMON_DICE[6] then
    for i, v in ipairs(COMMON_DICE) do if v == sides then sides = COMMON_DICE[(i % #COMMON_DICE) + 1]; return end end
  else
    for i, v in ipairs(COMMON_DICE) do if v >= sides then sides = v; return end end
    sides = COMMON_DICE[#COMMON_DICE]
  end
end

local function quickPrev()
  if sides == COMMON_DICE[1] or sides == COMMON_DICE[2] or sides == COMMON_DICE[3]
     or sides == COMMON_DICE[4] or sides == COMMON_DICE[5] or sides == COMMON_DICE[6] then
    for i, v in ipairs(COMMON_DICE) do if v == sides then sides = COMMON_DICE[((i - 2) % #COMMON_DICE) + 1]; return end end
  else
    for i = #COMMON_DICE, 1, -1 do local v = COMMON_DICE[i]; if v <= sides then sides = v; return end end
    sides = COMMON_DICE[1]
  end
end

local function setupSystemMenu()
  if menuInited then return end
  local menu = playdate.getSystemMenu()
  shadingMenuItem = menu:addCheckmarkMenuItem("Shading", shadingEnabled, function(checked)
    shadingEnabled = checked
    saveState()
    -- If we're on title, redraw immediately to reflect mode change:
    if state == S_TITLE then drawTitle() end
  end)
  menuInited = true
end

-- =================== Main loop ===================
function playdate.update()
  if state == S_TITLE then
    local now = pd.getCurrentTimeMilliseconds() / 1000
    local dt  = now - last_ts
    last_ts   = now

    title_ang      = wrapTau(title_ang + TITLE_ROT_SPEED * dt)
    title_time_acc = title_time_acc + dt
    if title_time_acc >= TITLE_SWITCH_SECS then
      title_time_acc = title_time_acc - TITLE_SWITCH_SECS
      title_idx = title_idx + 1
      if title_idx > #COMMON_DICE then title_idx = 1 end
    end

    drawTitle()

    if pd.buttonJustPressed(pd.kButtonA) then
      -- Capture the exact view you saw on title so idle matches
      idleAngle = wrapTau(title_ang)
      state = S_IDLE
      redrawIdle()
      return
    end
    if pd.buttonJustPressed(pd.kButtonB) then
      shadingEnabled = not shadingEnabled
      if shadingMenuItem then shadingMenuItem:setValue(shadingEnabled) end
      saveState()
      drawTitle()
    end
    return

  elseif state == S_IDLE then
    -- input
    if pd.buttonJustPressed(pd.kButtonLeft)  then sides = math.max(MIN_SIDES, sides - 1); saveState() end
    if pd.buttonJustPressed(pd.kButtonRight) then sides = math.min(MAX_SIDES, sides + 1); saveState() end
    if pd.buttonJustPressed(pd.kButtonUp)    then quickNext();  saveState() end
    if pd.buttonJustPressed(pd.kButtonDown)  then quickPrev();  saveState() end
    if pd.buttonJustPressed(pd.kButtonB)     then rollmode = (rollmode + 1) % 3;             end
    if pd.buttonJustPressed(pd.kButtonA)     then startSpin(); return end

    -- animate + draw every frame
    local now = pd.getCurrentTimeMilliseconds() / 1000
    local dt  = now - last_ts
    last_ts   = now
    idleAngle = wrapTau(idleAngle + IDLE_ROT_SPEED * dt)
    redrawIdle()
    return

  elseif state == S_SPIN then
    local now = pd.getCurrentTimeMilliseconds() / 1000
    local u = (now - spin_t0) / (spin_t1 - spin_t0)
    if u < 0 then u = 0 elseif u > 1 then u = 1 end
    local e = easeRollNatural(u)
    local ang = wrapTau(ang0 + (ang1 - ang0) * e)

    gfx.setColor(gfx.kColorWhite)
    gfx.fillRect(CLIP_X - 3, CLIP_Y - 3, CLIP_W + 6, CLIP_H + 6)
    drawStageFrame()

    local sx, sy, sw, sh = stageRect()
    gfx.setClipRect(sx, sy, sw, sh)

    currentScale = SCALE_SPIN
    local V, E, F = meshForSides(sides)
    gfx.setColor(gfx.kColorBlack)
    drawDieCurrent(V, E, F, ang)

    -- D6 labels during spin too
    if sides == 6 then
      local cx, cy = clipCenter()
      local hs = halfSize()
      --drawD6DebugLabels(ang, cx, cy, hs)
    end

    gfx.clearClipRect()
    drawHUD("Rolling…")

    if now >= spin_t1 then finishSpin() end
    return

  elseif state == S_RESULT then
    if pd.buttonJustPressed(pd.kButtonA) then startSpin(); return end
    if pd.buttonJustPressed(pd.kButtonB) then
      rollmode = (rollmode + 1) % 3
      saveState()
      drawHUD("Result: " .. tostring(last_result) .. "   A: OK")
    end
    if pd.buttonJustPressed(pd.kButtonLeft)  then sides = math.max(MIN_SIDES, sides - 1); state = S_IDLE; redrawIdle(); return end
    if pd.buttonJustPressed(pd.kButtonRight) then sides = math.min(MAX_SIDES, sides + 1); state = S_IDLE; redrawIdle(); return end
    if pd.buttonJustPressed(pd.kButtonUp)    then quickNext();  state = S_IDLE; redrawIdle(); return end
    if pd.buttonJustPressed(pd.kButtonDown)  then quickPrev();  state = S_IDLE; redrawIdle(); return end
    return
  end
end


function playdate.gameWillPause()
  -- If you add timers later, pause them:
  if playdate.timer and playdate.timer.pauseTimers then playdate.timer.pauseTimers() end
  -- If you add audio later, mute/stop here.
  saveState()
end

function playdate.gameWillResume()
  if playdate.timer and playdate.timer.resumeTimers then playdate.timer.resumeTimers() end
  -- Ensure a fresh frame is drawn after resume:
  if state == S_IDLE then
    redrawIdle()
  elseif state == S_TITLE then
    -- force a redraw of title
    last_ts = playdate.getCurrentTimeMilliseconds() / 1000
    drawTitle()
  end
end

function playdate.gameWillTerminate()
  saveState()
end

function playdate.deviceWillLock()
  saveState()
end

function playdate.deviceDidUnlock()
  -- Optional: redraw; same idea as resume
  if state == S_IDLE then redrawIdle() else drawTitle() end
end

-- =================== Init ===================
do
  local ms = math.floor(pd.getCurrentTimeMilliseconds() or 0)
  local s  = (pd.getSecondsSinceEpoch and pd.getSecondsSinceEpoch() or 0)
  math.randomseed(ms ~ s)
  math.random()
end

loadState()
setupSystemMenu()
pd.display.setRefreshRate(50)
state = S_TITLE
