import "CoreLibs/graphics"

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
-- ============ Angle wrapping ============
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
local last_detail_mode = RM_NORMAL  -- roll mode that produced last_detail
local last_result = nil
local redrawResult                  -- forward declaration (defined after the renderers)

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
    last_result = last_result,
    shading     = shadingEnabled
  }, SAVEFILE)
end

-- The game always starts on the title screen; only settings are restored.
local function loadState()
  local d = playdate.datastore.read(SAVEFILE)
  if type(d) ~= "table" then return end

  local n = tonumber(d.sides)
  if n then sides = math.max(MIN_SIDES, math.min(MAX_SIDES, math.floor(n))) end

  local rm = tonumber(d.rollmode)
  if rm == RM_NORMAL or rm == RM_ADV or rm == RM_DIS then rollmode = rm else rollmode = RM_NORMAL end

  last_result = tonumber(d.last_result)
  if type(d.shading) == "boolean" then shadingEnabled = d.shading end
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
  local candidates = {}
  for i = 1, #verts - 1 do
    local ax, ay, az = unpack(verts[i])
    for j = i + 1, #verts do
      local bx, by, bz = unpack(verts[j])
      local dx, dy, dz = ax - bx, ay - by, az - bz
      local d2 = dx * dx + dy * dy + dz * dz
      if dmin == nil or d2 < dmin then dmin = d2 end
      candidates[#candidates + 1] = { i, j, d2 }
    end
  end
  local eps = dmin * 1.00001
  local edges = {}
  for _, p in ipairs(candidates) do
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
  for _, v in ipairs(COMMON_DICE) do
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

-- Rotation for angle t: spin about Z by t, then tilt about X by 0.7t + 1.1
local function rotationFor(t)
  t = wrapTau(t)
  local tb = t * 0.7 + 1.1
  return cos(t), sin(t), cos(tb), sin(tb)
end

-- Rotate a point into camera space (+z points away from the viewer)
local function rotCam(x, y, z, ca, sa, cb, sb)
  local yz = x * sa + y * ca
  return x * ca - y * sa, yz * cb - z * sb, yz * sb + z * cb
end

-- Rotate + perspective-project verts to screen space (unrounded)
local function projectVerts(verts, S, cx, cy, ca, sa, cb, sb)
  local P = {}
  for i = 1, #verts do
    local v = verts[i]
    local x, y, z = rotCam(v[1] * S, v[2] * S, v[3] * S, ca, sa, cb, sb)
    local denom = z + _ZOFF; if denom < _NEAR then denom = _NEAR end
    local d = _SCALE / denom
    P[i] = { cx + x * d, cy + y * d }
  end
  return P
end

local function drawProjectedEdge(P, ia, ib)
  local a, b = P[ia], P[ib]
  gfx.drawLine(floor(a[1] + 0.5), floor(a[2] + 0.5), floor(b[1] + 0.5), floor(b[2] + 0.5))
end

-- Assign contrasting, stable dither levels to faces sharing an edge.
local DITHER_LEVELS = { 0.12, 0.88, 0.50, 0.30, 0.70, 0.20, 0.80, 0.40, 0.60 }

local function sharedEdge(a, b)
  local shared = 0
  for i = 1, #a do
    for j = 1, #b do
      if a[i] == b[j] then shared = shared + 1; break end
    end
  end
  return shared >= 2
end

local function faceShades(F)
  local shades = {}
  for fi = 1, #F do
    local best, bestDistance = DITHER_LEVELS[1], -1
    for _, candidate in ipairs(DITHER_LEVELS) do
      local distance = 1
      for other = 1, fi - 1 do
        if sharedEdge(F[fi], F[other]) then
          distance = math.min(distance, math.abs(candidate - shades[other]))
        end
      end
      if distance > bestDistance then best, bestDistance = candidate, distance end
    end
    shades[fi] = best
  end
  return shades
end

-- Object-space unit normal per face (Newell's method)
local function faceNormals(V, F)
  local FN = {}
  for fi = 1, #F do
    local idxs = F[fi]
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
  return FN
end

-- Per-mesh face normals and shades, keyed by face list; built once at load
local faceCache = {}
for _, mesh in ipairs({
  { V_TETRA, F_TETRA }, { V_CUBE, F_CUBE }, { V_OCTA, F_OCTA },
  { V_D10, F_D10 }, { V_D12, F_D12 }, { V_D20, F_D20 },
}) do
  local V, F = mesh[1], mesh[2]
  faceCache[F] = { FN = faceNormals(V, F), shades = faceShades(F) }
end

-- Remembers front/back state per face to add hysteresis near nz ≈ 0
local faceVisCache = {}
local ENTER_T, EXIT_T = -0.002, 0.002

-- Round to whole pixels, then drop repeated and collinear points
local function area2(a, b, c) return (b[1]-a[1])*(c[2]-a[2]) - (b[2]-a[2])*(c[1]-a[1]) end

local function roundAndPruneInt(pts)
  local ipts = {}
  for i = 1, #pts do
    local a = pts[i]
    local b = pts[(i % #pts) + 1]
    local ax, ay = floor(a[1] + 0.5), floor(a[2] + 0.5)
    if not (ax == floor(b[1] + 0.5) and ay == floor(b[2] + 0.5)) then ipts[#ipts + 1] = { ax, ay } end
  end
  local changed = true
  while changed and #ipts >= 3 do
    changed = false
    for i = 1, #ipts do
      local A = ipts[(i - 2) % #ipts + 1]
      local B = ipts[i]
      local C = ipts[i % #ipts + 1]
      if area2(A, B, C) == 0 then table.remove(ipts, i); changed = true; break end
    end
  end
  return ipts
end

-- === Shaded: dithered front faces + visible edges ===
local function drawDieSolid(V, E, F, t, cx, cy, halfSizePx)
  local ca, sa, cb, sb = rotationFor(t)
  local cx0, cy0 = centerOr(cx, cy)
  local P = projectVerts(V, halfSizePx or halfSize(), cx0, cy0, ca, sa, cb, sb)

  local cache = faceCache[F]
  local FN, shades = cache.FN, cache.shades
  local front = faceVisCache[F]
  if not front then front = {}; faceVisCache[F] = front end

  local EDGE_KEY = #V + 1   -- packs a vertex pair (a < b) into one table key
  local visibleEdges = {}

  gfx.setImageDrawMode(gfx.kDrawModeCopy)
  gfx.setColor(gfx.kColorBlack)

  -- The dice are convex, so front faces never overlap and need no depth sort
  for fi = 1, #F do
    local n = FN[fi]
    local _, _, nz = rotCam(n[1], n[2], n[3], ca, sa, cb, sb)
    local isFront
    if front[fi] then isFront = (nz < EXIT_T) else isFront = (nz < ENTER_T) end
    front[fi] = isFront

    if isFront then
      local idxs = F[fi]
      local pts = {}
      for i = 1, #idxs do
        local a, b = idxs[i], idxs[(i % #idxs) + 1]
        pts[i] = P[a]
        if a > b then a, b = b, a end
        visibleEdges[a * EDGE_KEY + b] = true
      end

      -- Face vertices are already in winding order, so no re-sort is needed
      local ipts = roundAndPruneInt(pts)
      if #ipts >= 3 then
        local coords = {}
        for i = 1, #ipts do
          coords[2 * i - 1] = ipts[i][1]
          coords[2 * i]     = ipts[i][2]
        end
        gfx.setDitherPattern(shades[fi], gfx.image.kDitherTypeBayer8x8)
        gfx.fillPolygon(unpack(coords))
      end
    end
  end

  gfx.setDitherPattern(1.0)

  -- Outline only edges that border a visible face; hidden back edges stay hidden
  gfx.setColor(gfx.kColorBlack)
  for i = 1, #E do
    local ia, ib = E[i][1], E[i][2]
    local lo, hi = ia, ib
    if lo > hi then lo, hi = hi, lo end
    if visibleEdges[lo * EDGE_KEY + hi] then drawProjectedEdge(P, ia, ib) end
  end
end

-- === Wireframe: every edge ===
local function drawDieWireframe(V, E, t, cx, cy, halfSizePx)
  local cx0, cy0 = centerOr(cx, cy)
  local P = projectVerts(V, halfSizePx or halfSize(), cx0, cy0, rotationFor(t))
  gfx.setColor(gfx.kColorBlack)
  for i = 1, #E do drawProjectedEdge(P, E[i][1], E[i][2]) end
end

-- Renders based on the user's "Shading" setting
local function drawDieCurrent(V, E, F, t, cx, cy, halfSizePx)
  if shadingEnabled then
    drawDieSolid(V, E, F, t, cx, cy, halfSizePx)
  else
    drawDieWireframe(V, E, t, cx, cy, halfSizePx)
  end
end

-- ============= Pretty UI helpers =============
local function drawTextCenteredInRect(text, x, y, w, h)
  local tw, th = gfx.getTextSize(text)
  gfx.drawText(text, math.floor(x + (w - tw) / 2), math.floor(y + (h - th) / 2))
end

local function drawPill(x, y, w, h, text)
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRoundRect(x, y, w, h, 6)
  gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
  drawTextCenteredInRect(text, x, y, w, h)
  gfx.setImageDrawMode(gfx.kDrawModeCopy)
end

local function drawStageFrame()
  local rx = 8
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRoundRect(CLIP_X - 2, CLIP_Y - 2, CLIP_W + 4, CLIP_H + 4, rx)
  gfx.drawRoundRect(CLIP_X, CLIP_Y, CLIP_W, CLIP_H, rx - 2)
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

-- Draw one digit W x H px with segment thickness T and margin M
local function drawDigit(x, y, ch, W, H, T, M)
  local s = DIGIT_SEGS[tonumber(ch)]; if not s then return end
  local mid = y + math.floor(H / 2 - T / 2)
  local xL, xR = x, x + W - T
  local yU0, yU1 = y + M, mid - 2
  local yL0, yL1 = mid + 2, y + H - M - 1
  if s.A then gfx.fillRect(x + M, y,         W - 2 * M, T) end
  if s.G then gfx.fillRect(x + M, mid,       W - 2 * M, T) end
  if s.D then gfx.fillRect(x + M, y + H - T, W - 2 * M, T) end
  if s.F then gfx.fillRect(xL, yU0, T, yU1 - yU0 + 1) end
  if s.B then gfx.fillRect(xR, yU0, T, yU1 - yU0 + 1) end
  if s.E then gfx.fillRect(xL, yL0, T, yL1 - yL0 + 1) end
  if s.C then gfx.fillRect(xR, yL0, T, yL1 - yL0 + 1) end
end

local function drawDigitMed(x, y, ch) drawDigit(x, y, ch, 12, 20, 2, 1) end
local function drawDigitBig(x, y, ch) drawDigit(x, y, ch, 24, 40, 3, 2) end

local function drawMedStrCentered(s, bx, by, bw, bh)
  local per = 13
  local w = (#s > 0) and (#s * per - (per - 12)) or 0
  local x0 = bx + math.max(0, math.floor((bw - w) / 2))
  local y0 = by + math.max(0, math.floor((bh - 20) / 2))
  for i = 1, #s do drawDigitMed(x0 + (i - 1) * per, y0, s:sub(i, i)) end
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
local function drawTitle()
  gfx.clearClipRect()
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

-- =================== In-game rendering ===================
local function redrawIdle()
  currentScale = SCALE_IDLE
  gfx.clear(gfx.kColorWhite)
  drawStageFrame()

  local sx, sy, sw, sh = stageRect()
  gfx.setClipRect(sx, sy, sw, sh)

  local V, E, F = meshForSides(sides)
  gfx.setColor(gfx.kColorBlack)
  drawDieCurrent(V, E, F, idleAngle)

  gfx.clearClipRect()
  drawHUD("")
end

-- =================== Easing ===================
local function easeRollNatural(u)
  if u <= 0 then return 0 end
  if u >= 1 then return 1 end
  return 1 - (1 - u) * (1 - u)
end



-- =================== Result screen ===================
local function resultHudText()
  return "Result: " .. tostring(last_result) .. "  A: Reroll"
end

redrawResult = function()
  gfx.clear(gfx.kColorWhite)
  drawStageFrame()

  local sx, sy, sw, sh = stageRect()
  gfx.setClipRect(sx, sy, sw, sh)

  gfx.setColor(gfx.kColorBlack)
  if last_result then drawNumberBig(last_result) end
  if last_detail then
    drawAdvDisBoxes(last_detail.a, last_detail.b, last_detail.chosen, last_detail_mode)
  end

  gfx.clearClipRect()
  drawHUD(resultHudText())
end

-- Switch to the idle preview without a large first-frame time step
local function enterIdle()
  state = S_IDLE
  last_ts = pd.getCurrentTimeMilliseconds() / 1000
  redrawIdle()
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
  last_detail_mode = rollmode
  -- Carry the final spin pose into idle so the die doesn't jump
  idleAngle = wrapTau(ang1)

  redrawResult()
end

-- =================== Helpers ===================
-- Position of each common die in COMMON_DICE, e.g. COMMON_INDEX[8] == 3
local COMMON_INDEX = {}
for i, v in ipairs(COMMON_DICE) do COMMON_INDEX[v] = i end

-- Up: on a common die, step to the next one (wrapping); otherwise snap up to the nearest
local function quickNext()
  local i = COMMON_INDEX[sides]
  if i then sides = COMMON_DICE[(i % #COMMON_DICE) + 1]; return end
  for _, v in ipairs(COMMON_DICE) do if v >= sides then sides = v; return end end
  sides = COMMON_DICE[#COMMON_DICE]
end

-- Down: on a common die, step to the previous one (wrapping); otherwise snap down to the nearest
local function quickPrev()
  local i = COMMON_INDEX[sides]
  if i then sides = COMMON_DICE[((i - 2) % #COMMON_DICE) + 1]; return end
  for j = #COMMON_DICE, 1, -1 do if COMMON_DICE[j] <= sides then sides = COMMON_DICE[j]; return end end
  sides = COMMON_DICE[1]
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
    -- Settings are persisted by the pause/lock/sleep/terminate hooks
    if pd.buttonJustPressed(pd.kButtonLeft)  then sides = math.max(MIN_SIDES, sides - 1) end
    if pd.buttonJustPressed(pd.kButtonRight) then sides = math.min(MAX_SIDES, sides + 1) end
    if pd.buttonJustPressed(pd.kButtonUp)    then quickNext() end
    if pd.buttonJustPressed(pd.kButtonDown)  then quickPrev() end
    if pd.buttonJustPressed(pd.kButtonB)     then rollmode = (rollmode + 1) % 3 end
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

    gfx.clearClipRect()
    drawHUD("Rolling…")

    if now >= spin_t1 then finishSpin() end
    return

  elseif state == S_RESULT then
    if pd.buttonJustPressed(pd.kButtonA) then startSpin(); return end
    if pd.buttonJustPressed(pd.kButtonB) then
      rollmode = (rollmode + 1) % 3
      drawHUD(resultHudText())
    end
    if pd.buttonJustPressed(pd.kButtonLeft)  then sides = math.max(MIN_SIDES, sides - 1); enterIdle(); return end
    if pd.buttonJustPressed(pd.kButtonRight) then sides = math.min(MAX_SIDES, sides + 1); enterIdle(); return end
    if pd.buttonJustPressed(pd.kButtonUp)    then quickNext();  enterIdle(); return end
    if pd.buttonJustPressed(pd.kButtonDown)  then quickPrev();  enterIdle(); return end
    return
  end
end


function playdate.gameWillPause()
  saveState()
end

-- Redraw the current screen after the game was paused, locked or asleep.
-- Resets the frame clock so animations don't jump by the time spent away.
local function redrawCurrent()
  last_ts = playdate.getCurrentTimeMilliseconds() / 1000
  if state == S_IDLE then
    redrawIdle()
  elseif state == S_TITLE then
    drawTitle()
  elseif state == S_RESULT then
    redrawResult()
  end
  -- S_SPIN redraws every frame on its own
end

function playdate.gameWillResume()
  redrawCurrent()
end

function playdate.gameWillTerminate()
  saveState()
end

function playdate.deviceWillLock()
  saveState()
end

function playdate.deviceWillSleep()
  saveState()
end

function playdate.deviceDidUnlock()
  redrawCurrent()
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
pd.display.setRefreshRate(30)
state = S_TITLE
