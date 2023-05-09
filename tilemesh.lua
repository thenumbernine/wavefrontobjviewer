--[[
mesh = mesh with texcoords
omesh = mesh to tile

mesh is modified
--]]
local ffi = require 'ffi'
local range = require 'ext.range'
local table = require 'ext.table'
local timer = require 'ext.timer'
local vec2f = require 'vec-ffi.vec2f'
local vec3f = require 'vec-ffi.vec3f'
local box2f = require 'vec-ffi.box2f'
local quatf = require 'vec-ffi.quatf'
local vector = require 'ffi.cpp.vector'
local matrix_ffi = require 'matrix.ffi'

local function tileMesh(mesh, omesh)


	-- list of column-vectors
	-- transform from uv-space to placement-space
-- [[
	local scale = vec3f(.5, .5, .5)
	local placementCoordXForm = matrix_ffi{
		{1, 0},
		{0, 1},
	}
--]]
--[[
	local scale = vec3f(.1, .05, .1) * .9
	local placementCoordXForm = matrix_ffi{
		{.2, .1},
		{0, .1},
	}
--]]
	local placementCoordXFormInv = placementCoordXForm:inv()
print('placementXForm', placementCoordXForm)
print('placementXFormInv', placementCoordXFormInv)
	assert((placementCoordXForm * placementCoordXFormInv - matrix_ffi{{1,0},{0,1}}):normSq() < 1e-7)

	mesh:generateTriBasis()

	-- for each tri
	mesh.tilePlaces = table()
	for ti=0,mesh.triIndexes.size-3,3 do
		local t = assert(mesh.tris[ti/3+1])
		local tp = mesh.triIndexes.v + ti
		local tvtxs = range(0,2):mapi(function(i)
			return mesh.vtxs.v[tp[i]]
		end)
		-- uvorigin2D/uvorigin3D can be any texcoord/pos as long as they're from the same vtx
		local uvorigin2D = vec2f():set(tvtxs[1].texcoord:unpack())
		local uvorigin3D = vec3f():set(tvtxs[1].pos:unpack())
print('uv origin', ti, uvorigin2D, uvorigin3D)
		-- find uv min max
		-- maybe stretch bounds to include edges of placements?
		-- interpolate across uv
		-- find lattice locations where an instance should be placed
		-- place mesh
		local placementBBox = box2f.empty()
		for j=0,2 do
			assert(tp[j] >= 0 and tp[j] < mesh.vtxs.size)
			local v = mesh.vtxs.v[tp[j]]
			--local tc = v.texcoord
			-- for the sake of scale, we have to remap the texcoords using the orthornormalized basis (which was derived from the texcoords so e_x = d/du)
			local dvpos = v.pos - uvorigin3D
			local tc = vec2f(
				dvpos:dot(t.basis[1]),
				dvpos:dot(t.basis[2])
			) + uvorigin2D
			local placementCoord = placementCoordXFormInv * matrix_ffi{tc.x, tc.y}
			placementCoord = vec2f(placementCoord:unpack())
			placementBBox:stretch(placementCoord)
print('stretching', placementCoord)
		end
		local from = box2f(placementBBox)
		placementBBox.min = placementBBox.min:map(math.floor) - 1
		placementBBox.max = placementBBox.max:map(math.ceil) + 1
print('placementBBox', from, 'to' , placementBBox)
		for pu=placementBBox.min.x,placementBBox.max.x+.01 do
			for pv=placementBBox.min.y,placementBBox.max.y+.01 do
				local uv = placementCoordXForm * matrix_ffi{pu,pv}
				uv = vec2f(uv:unpack())
--print(uv)
				local duv = uv - uvorigin2D
				--[[
				texcoord = basis * (vtxpos - uvorigin3D) + uvorigin2D
				vtxpos = uvbasis * (texcoord - uvorigin2D) + uvorigin3D

				with placement-lattice transforms
				placementCoords = placementXForm * texcoord
				placementXFormInv * placementCoords = texcoord
				--]]
				local vtxpos = t.basis[1] * duv.x + t.basis[2] * duv.y + uvorigin3D
				-- if in tri (barycentric coord test)
				local inside = t:insideBCC(vtxpos, mesh)
--print(uv, inside)
				if inside then
					-- then place an instance of omesh
					-- get the transform rotation and scale to the location on the poly
					-- if unwrapuv() was just run then .tri[] .uvbasis3D and 2D will still exist
					mesh.tilePlaces:insert{
						-- scale, rotate, offset ...
						pos = vec3f(vtxpos),	-- not so necessary
						basis = t.basis:mapi(function(v) return vec3f(v) end),
						scale = vec3f(scale),
						-- not necessary
						uv = vec2f(uv),
					}
				end
			end
		end
	end
print('#tilePlaces', #mesh.tilePlaces)

	-- place instances
	local nvtxs = vector'MeshVertex_t'
	local indexesPerGroup = table()
	for _,place in ipairs(mesh.tilePlaces) do
		local firstVtx = nvtxs.size
		for i=0,omesh.vtxs.size-1 do
			local srcv = omesh.vtxs.v[i]
			local dstv = nvtxs:emplace_back()
			dstv.pos = srcv.pos
			dstv.texcoord = srcv.texcoord
			-- scale, rotate, normalize the normals
			dstv.normal.x = srcv.normal.x * place.scale.x
			dstv.normal.y = srcv.normal.y * place.scale.y
			dstv.normal.z = srcv.normal.z * place.scale.z
			dstv.normal = place.basis[1] * dstv.normal.x
						+ place.basis[2] * dstv.normal.y
						+ place.basis[3] * dstv.normal.z
			dstv.normal = dstv.normal:normalize()
			-- scale, rotate, translate the positions
			-- TODO switch to y-up, because someone was a n00b when learning OpenGL a long time ago, and so now we all have to suffer.
			-- scale
			dstv.pos.x = dstv.pos.x * place.scale.x
			dstv.pos.y = dstv.pos.y * place.scale.y
			dstv.pos.z = dstv.pos.z * place.scale.z
			-- rotate
			dstv.pos = place.basis[1] * dstv.pos.x
					+ place.basis[2] * dstv.pos.y
					+ place.basis[3] * dstv.pos.z
			-- translate
			dstv.pos = dstv.pos + place.pos
		end
		local lastVtx = nvtxs.size
		for _,g in ipairs(omesh.groups) do
			indexesPerGroup[g.name] = indexesPerGroup[g.name] or table()
			for i=3*g.triFirstIndex,3*(g.triFirstIndex+g.triCount)-1 do
				local srci = omesh.triIndexes.v[i]
				assert(srci >= 0 and srci < omesh.vtxs.size)
				local dsti = srci + firstVtx
				assert(dsti >= firstVtx and dsti < lastVtx)
				indexesPerGroup[g.name]:insert(dsti)
			end
		end
	end

	local ntris = vector'uint32_t'
	for _,g in ipairs(omesh.groups) do
		g.triFirstIndex = ntris.size
		for _,i in ipairs(indexesPerGroup[g.name] or {}) do
			ntris:emplace_back()[0] = i
		end
		g.triCount = ntris.size - g.triFirstIndex
	end

	assert(nvtxs.size == omesh.vtxs.size * #mesh.tilePlaces)
	assert(ntris.size == omesh.triIndexes.size * #mesh.tilePlaces)
print('nvtxs.size', nvtxs.size)
print('ntris.size', ntris.size)

	-- replace
	mesh.vtxs = nvtxs
	mesh.triIndexes = ntris

	-- reset
	mesh:rebuildTris()

	-- invalidate
	mesh.edges = nil
	mesh.edgeIndexBuf = nil
	mesh.allOverlappingEdges = nil
	mesh.loadedGL = nil
	mesh.vtxBuf = nil
	mesh.vtxAttrs = nil
	mesh.vao = nil

	mesh:calcBBox()
	mesh:findEdges()
	mesh:calcCOMs()

	mesh.mtlFilenames = omesh.mtlFilenames
	local g = mesh.groups[1]
	g.triFirstIndex = 0
	g.triCount = mesh.triIndexes.size/3

	--[[ adds another 40 seconds for the cube->bricks simple example
	timer('merging after shellmapping', function()
		mesh:mergeMatchingVertexes()
	end)
	--]]
end

local function drawTileMeshPlaces(mesh)
	if not mesh.tilePlaces then return end
	gl.glPointSize(3)
	gl.glColor3f(1,1,0)
	gl.glBegin(gl.GL_POINTS)
	for _,p in ipairs(mesh.tilePlaces) do
		gl.glVertex3f(p.pos:unpack())
	end
	gl.glPointSize(1)
	gl.glLineWidth(3)
	gl.glBegin(gl.GL_LINES)
	for _,p in ipairs(mesh.tilePlaces) do
		gl.glColor3f(1,0,0)
		gl.glVertex3f(p.pos:unpack())
		gl.glVertex3f((p.pos + p.basis[1]):unpack())
		gl.glColor3f(0,1,0)
		gl.glVertex3f(p.pos:unpack())
		gl.glVertex3f((p.pos + p.basis[2]):unpack())
		gl.glColor3f(0,0,1)
		gl.glVertex3f(p.pos:unpack())
		gl.glVertex3f((p.pos + p.basis[3]):unpack())
	end
	gl.glEnd()
	gl.glLineWidth(1)
end

return {
	tileMesh = tileMesh,
	drawTileMeshPlaces = drawTileMeshPlaces,
}
