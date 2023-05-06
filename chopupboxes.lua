#!/usr/bin/env luajit
local table = require 'ext.table'
local timer = require 'ext.timer'
local vec3i = require 'vec-ffi.vec3i'
local vec4f = require 'vec-ffi.vec4f'

local infn, outfn = ...
assert(infn, "expected "..arg[0].." input-filename")

local loader = require 'mesh.objloader'()
local mesh = loader:load(infn)
mesh:calcBBox()
print('bbox', mesh.bbox)
for i=1,3 do
	mesh.bbox.min[i] = math.floor(mesh.bbox.min[i])
	mesh.bbox.max[i] = math.ceil(mesh.bbox.max[i])
end
print('bbox after rounding', mesh.bbox)
mesh:breakTriangles()

-- 1) bin all triangles
local comEps = .01
local normalStepEps = .01
local trisForBox = {}
local mini = vec3i(999,999,999)
local maxi = -mini
local tboxes = table()
for i=0,mesh.triIndexBuf.size-3,3 do
	local a,b,c = mesh:triVtxPos(i)
	local com = mesh.triCOM(a,b,c)
	local normal, area = mesh.triNormal(a,b,c)

	-- calc tri bounds
	local tmini = vec3i(999,999,999)
	local tmaxi = -mini

	for j=0,2 do
		local v = mesh.vtxs.v[mesh.triIndexBuf.v[i+j]].pos
		v = v * (1 - comEps) + com * comEps - normal * normalStepEps
		local iv = vec3i()
		for k=0,2 do
			-- TODO maybe pull slightly towards tri com and against normal
			iv.s[k] = math.floor(v.s[k])
			mini.s[k] = math.min(mini.s[k], iv.s[k])
			maxi.s[k] = math.max(maxi.s[k], iv.s[k])
			tmini.s[k] = math.min(tmini.s[k], iv.s[k])
			tmaxi.s[k] = math.max(tmaxi.s[k], iv.s[k])
		end
		tboxes:insert{tmini, tmaxi}
		
		for ix=tmini.x,tmaxi.x do
			for iy=tmini.y,tmaxi.y do
				for iz=tmini.z,tmaxi.z do
					trisForBox[ix] = trisForBox[ix] or {}
					trisForBox[ix][iy] = trisForBox[ix][iy] or {}
					trisForBox[ix][iy][iz] = trisForBox[ix][iy][iz] or {}
					trisForBox[ix][iy][iz][i] = true
				end
			end
		end
	end
end
print('# bounding boxes', #tboxes)
--print('boxes', require 'ext.tolua'(trisForBox))

local function touches(b1,b2)
	return b1[1].x <= b2[2].x
		and b1[2].x >= b2[1].x
		and b1[1].y <= b2[2].y
		and b1[2].y >= b2[1].y
		and b1[1].z <= b2[2].z
		and b1[2].z >= b2[1].z
end

-- 2) group bins where triangles span multiple bins
for i=#tboxes,2,-1 do
	local k = i	-- holder of original i'th pieces
	for j=i-1,1,-1 do
		if touches(tboxes[i], tboxes[j]) then
			-- move from k to j
			local dstx = tboxes[j][1].x
			local dsty = tboxes[j][1].y
			local dstz = tboxes[j][1].z
			print('merging', k, 'into', j)
			for _,srcbox in ipairs{tboxes[k], tboxes[j]} do
				for ix=srcbox[1].x,srcbox[2].x do
					for iy=srcbox[1].y,srcbox[2].y do
						for iz=srcbox[1].z,srcbox[2].z do
							if not (ix == dstx and iy == dsty and iz == dstz) then
								trisForBox[dstx] = trisForBox[dstx] or {}
								trisForBox[dstx][dsty] = trisForBox[dstx][dsty] or {}
								trisForBox[dstx][dsty][dstz] = trisForBox[dstx][dsty][dstz] or {}
								trisForBox[dstx][dsty][dstz] = table(trisForBox[dstx][dsty][dstz], trisForBox[ix][iy][iz]):setmetatable(nil)
								trisForBox[ix][iy][iz] = nil
								--[[
								if not next(trisForBox[ix][iy]) then
									trisForBox[ix][iy] = nil
									if not next(trisForBox[ix]) then
										trisForBox[ix] = nil
									end
								end
								--]]
							end
						end
					end
				end
			end
			-- j is the new k / dst tbox with this cluster's nodes
			k = j
			-- don't break out of the loop
			-- so the pieces go thru the cluster and collect at the smallest index 
		end
	end
	if k ~= i then	-- moved?
		tboxes:remove(i)
	end
end
for i=#tboxes,1,-1 do
	local tbox = tboxes[i]
	local empty = true
	for ix=tbox[1].x,tbox[2].x do
		for iy=tbox[1].y,tbox[2].y do
			for iz=tbox[1].z,tbox[2].z do
				if trisForBox[ix] 
				and trisForBox[ix][iy] 
				and trisForBox[ix][iy][iz]
				then
					if next(trisForBox[ix][iy][iz]) then
						empty = false
					else
						trisForBox[ix][iy][iz]= nil
						if not next(trisForBox[ix][iy]) then
							trisForBox[ix][iy] = nil
							if not next(trisForBox[ix]) then
								trisForBox[ix] = nil
							end
						end
					end
				end
			end
		end
	end
	if empty then
		print('erasing', i)
		tboxes:remove(i)
	end
end

tboxes:sort(function(a,b)
	if a[1].z < b[1].z then return true end
	if a[1].z > b[1].z then return false end
	if a[1].y < b[1].y then return true end
	if a[1].y > b[1].y then return false end
	return a[1].x > b[1].x
end)
local numBinnedTris = 0
for _,b in ipairs(tboxes) do
	local tris = table.keys(trisForBox[b[1].x][b[1].y][b[1].z]):sort()
	numBinnedTris = numBinnedTris + #tris 
	print(b[1], b[2], tris:concat', ')
end
print('# clusters left', #tboxes)
print('# binned tris', numBinnedTris)
print('# orig tris', mesh.triIndexBuf.size/3)
print('ibounds', mini, maxi)

-- now convert tboxes tris into unique materials
-- and export
mesh.mtllib = {
	[''] =  {
		name = '',
		triFirstIndex = 0,
		triCount = 0,
	}
}
mesh.triIndexBuf:resize(0)
mesh.mtlFilenames = {(outfn:gsub('%.obj$', '.mtl'))}
for i,tbox in ipairs(tboxes) do
	local x,y,z = tbox[1]:unpack()
	local tris = table.keys(trisForBox[x][y][z]):sort()
	local mtlname = 'm'..i
	mesh.mtllib[mtlname] = {
		name = mtlname,
		triFirstIndex = mesh.triIndexBuf.size / 3,
		triCount = #tris,
		Kd = vec4f(
			tonumber(x - mini.x) / tonumber(maxi.x - mini.x),
			tonumber(y - mini.y) / tonumber(maxi.y - mini.y),
			tonumber(z - mini.z) / tonumber(maxi.z - mini.z),
			1),
	}
	for _,j in ipairs(tris) do
		for k=0,2 do
			mesh.triIndexBuf:push_back(j+k)
		end
	end
end

loader:save(outfn, mesh)
loader:saveMtl(mesh.mtlFilenames[1], mesh)