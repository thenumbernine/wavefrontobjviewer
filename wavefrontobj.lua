--  https://en.wikipedia.org/wiki/Wavefront_.obj_file
local ffi = require 'ffi'
local class = require 'ext.class'
local table = require 'ext.table'
local string = require 'ext.string'
local file = require 'ext.file'
local math = require 'ext.math'
local timer = require 'ext.timer'
local quat = require 'vec.quat'
local matrix = require 'matrix'
local vector = require 'ffi.cpp.vector'
local vec2f = require 'vec-ffi.vec2f'
local vec3f = require 'vec-ffi.vec3f'
local Image = require 'image'

local mergeVertexesOnLoad = true
local mergeEdgesOnLoad = true
local unwrapUVsOnLoad = true

ffi.cdef[[
typedef struct {
	vec3f_t pos;
	vec3f_t normal;		//loaded normal
	vec3f_t normal2;	//generated normal ... because i want the viewer to toggle between the two
	vec3f_t texCoord;
	
	// per-triangle stats (duplicated 3x per-vertex)
	float area;
	vec3f_t com;		//com of tri containing this vertex.  only good for un-indexed drawing.
} obj_vertex_t;
]]

local function triArea(a,b,c)
	local ab = b - a
	local ac = c - a
	local n = ab:cross(ac)
	return .5 * n:norm()
end

local function pathOfFilename(fn)
	-- find the last index of / in fn
	local lastSlashIndex
	for i=#fn,1,-1 do
		if fn:sub(i,i) == '/' then
			lastSlashIndex = i
			break
		end
	end
	if not lastSlashIndex then return './' end	-- relative to current dir
	return fn:sub(1,lastSlashIndex)
end

local function wordsToVec3(w)
	return matrix{3}:lambda(function(i)
		return tonumber(w[i]) or 0
	end)
end

-- used for colors
local function wordsToColor(w)
	-- TODO error if not 3 or 4?
	local r,g,b,a = w:mapi(function(x) return tonumber(x) end):unpack(1, 4)
	r = r or 0
	g = g or 0
	b = b or 0
	a = a or 1
	return matrix{r,g,b,a}
end

local WavefrontOBJ = class()

function WavefrontOBJ:init(filename)
	local vs = table()
	local vts = table()
	local vns = table()

	self.relpath = file(filename):getdir()
	self.mtlFilenames = table()

	timer('loading', function()
		self.tris = table() -- triangulation of all faces
		
		-- map of materials
		self.mtllib = {}
		local curmtl = ''
		self.mtllib[curmtl] = {
			name = curmtl,
			-- TODO instead of redundantly storing faces,
			-- how about storing lookups into self.tris per-poly?
			-- and assert the tris are in a certain layout (tri fan?) for reconstructing faces?
			-- since this is only used in saving anymore.  and faceiter().
			faces = table(),
			triFirstIndex = 1,	-- index into first instance of self.tris for this material
			triCount = 0,	-- number of tris used in this material
		}
		assert(file(filename):exists(), "failed to find material file "..filename)
		for line in io.lines(filename) do
			local words = string.split(string.trim(line), '%s+')
			local lineType = words:remove(1):lower()
			if lineType == 'v' then
				assert(#words >= 2)
				vs:insert(wordsToVec3(words))
			elseif lineType == 'vt' then
				assert(#words >= 2)
				vts:insert(wordsToVec3(words))
			elseif lineType == 'vn' then
				assert(#words >= 2)
				vns:insert(wordsToVec3(words))
			-- TODO lineType == 'vp'
			elseif lineType == 'f' then
				local usingMtl = curmtl
				local vis = table()
				local foundVT = false
				for _,vertexIndexString in ipairs(words) do
					local vertexIndexStringParts = string.split(vertexIndexString, '/')	-- may be empty string
					local vertexIndices = vertexIndexStringParts:mapi(function(x) return tonumber(x) end)	-- may be nil
					local vi, vti, vni = unpack(vertexIndices, 1, 3)
					if vti then foundVT = true end
					vis:insert{v=vi, vt=vti, vn=vni}
				end

				-- TODO hmm really?
				-- if no vt found then we can still use the Ks Kd etc from the mtl
				-- we just have to take care when drawing it not to have the texture bound
				-- (unlike the other faces in the mtl which do have vt's)
				--if not foundVT then usingMtl = '' end

				local mtl = self.mtllib[usingMtl]
				local facesPerPolySize = mtl.faces
				if not facesPerPolySize then
					facesPerPolySize = {}
					mtl.faces = facesPerPolySize
				end
				assert(#words >= 3, "got a bad polygon ... does .obj support lines or points?")
				local nvtx = #words
				facesPerPolySize[nvtx] = facesPerPolySize[nvtx] or table()
				facesPerPolySize[nvtx]:insert(vis)
				for i=2,nvtx-1 do
					-- store a copy of the vertex indices per triangle index
					self.tris:insert{
						-- [1..3] are face index structures (with .v .vt .vn)
						table(vis[1]):setmetatable(nil),
						table(vis[i]):setmetatable(nil),
						table(vis[i+1]):setmetatable(nil),
						-- keys:
						index = #self.tris+1,	-- so far only used for debugging
						mtl = mtl,
					}
					if not mtl.triFirstIndex then mtl.triFirstIndex = #self.tris end
					mtl.triCount = #self.tris - mtl.triFirstIndex + 1
				end
			elseif lineType == 's' then
				-- TODO then smooth is on
				-- for all subsequent polys, or for the entire group (including previously defined polys) ?
			elseif lineType == 'g' then
				-- TODO then we start a new named group
			elseif lineType == 'o' then
				-- TODO then we start a new named object
			elseif lineType == 'usemtl' then
				curmtl = assert(words[1])
			elseif lineType == 'mtllib' then
				-- TODO this replaces %s+ with space ... so no tabs or double-spaces in filename ...
				self:loadMtl(words:concat' ')
			end
		end
		-- could've done this up front...
		self.vs = vs
		self.vts = vts
		self.vns = vns
	end)

	print('#tris', #self.tris)

--[[ testing ... remove everything with x > 1
	for i=#self.vs,1,-1 do
		if self.vs[i][1] > 1 then
			self:removeVertex(i)
		end
	end
--]]

-- [[ calculate bbox.  do this before merging vtxs.
	local box3 = require 'vec.box3'
	self.bbox = box3(-math.huge)
	for _,v in ipairs(self.vs) do
		self.bbox:stretch(v)
	end
--]]
-- TODO maybe calc bounding radius? Here or later?  That takes COM, which, for COM2/COM3 takes tris.  COM1 takes edges... should COM1 consider merged edges always?  probably... 

-- [[ merge vtxs.  TODO make this an option with specified threshold.
-- do this before detecting edges.
-- do this after bbox bounds (so I can use a %age of the bounds for the vtx dist threshold)
	if mergeVertexesOnLoad then
		timer('merging vertexes', function()
			-- ok the bbox hyp is 28, the smallest maybe valid dist is .077, and everything smalelr is 1e-6 ...
			-- that's a jump from 1/371 to 1/20,000,000
			-- so what's the smallest ratio I should allow?  maybe 1/1million?
			local bboxCornerDist = (self.bbox.max - self.bbox.min):norm()
			local vtxMergeThreshold = bboxCornerDist * 1e-6
			print('vtxMergeThreshold', vtxMergeThreshold)	
			print('before merge vtx count', #self.vs, 'tri count', #self.tris)
			for i=#self.vs,2,-1 do
				for j=1,i-1 do
					local dist = (self.vs[i] - self.vs[j]):norm()
		--print(dist)
					if dist < vtxMergeThreshold then
		--print('merging vtxs '..i..' and '..j)
						self:mergeVertex(i,j)
						break
					end
				end
			end
			print('after merge vtx count', #self.vs, 'tri count', #self.tris)
		end)
	end
--]]

-- [[ we also have to merge ..... edges .... smh.
	if mergeEdgesOnLoad then
		timer("finding edges that should've been merged by whoever made the model", function()
			--[[
			these are whatever mesh edges are partially overlapping one another.
			they are a result of a shitty artist.
			because of which, there is no guarantee with this table that each tri has 3 edges, and each edge has only 2 tris.
			instead it's a shitfest shitstorm.
			--]]
			self.allOverlappingEdges = {}
			for _,t in ipairs(self.tris) do
				t.allOverlappingEdges = table()
			end
			local function addEdge(i1, i2, j1, j2, dist, s11, s12, s21, s22, planeOrigin, planeNormal)
				-- in my loop i2 < i1, but i want it ordered lowest-first, so ... swap them
				assert(i2 < i1)
				self.allOverlappingEdges[i2] = self.allOverlappingEdges[i2] or {}
				self.allOverlappingEdges[i2][i1] = self.allOverlappingEdges[i2][i1] or {
					[1] = i2,
					[2] = i1,
					triVtxIndexes = {j2, j1},
					intervals = {{s21,s22}, {s11,s12}},
					tris = table(),
					dist = dist,
					planeOrigin = planeOrigin,
					planeNormal = planeNormal
				}
				local e = self.allOverlappingEdges[i2][i1]
				local t1 = self.tris[i1]
				local t2 = self.tris[i2]
				e.tris:insertUnique(t2)
				e.tris:insertUnique(t1)
				t1.allOverlappingEdges:insertUnique(e)
				t2.allOverlappingEdges:insertUnique(e)
			end
			for i1=#self.tris,2,-1 do
				local t1 = self.tris[i1]
				for j1=1,3 do
					-- t1's j1'th edge
					local v11 = self.vs[t1[j1].v]
					local v12 = self.vs[t1[j1%3+1].v]
					local n1 = v12 - v11
					local n1NormSq = n1:normSq()
					if n1NormSq  > 1e-3 then
						n1 = n1 / math.sqrt(n1NormSq)
						for i2=i1-1,1,-1 do
							local t2 = self.tris[i2]
							for j2=1,3 do
								local v21 = self.vs[t2[j2].v]
								local v22 = self.vs[t2[j2%3+1].v]
								local n2 = v22 - v21
								local n2NormSq = n2:normSq()
								if n2NormSq  > 1e-3 then
									n2 = n2 / math.sqrt(n2NormSq)
									if math.abs(n1:dot(n2)) > 1 - 1e-3 then
										-- normals align, calculate distance 
										local planeOrigin = v11	-- pick any point on line v1: v11 or v12
										local planeNormal = n1
										local dv = v21 - planeOrigin	-- ray from the v1 line to any line on v2
										dv = dv - planeNormal * dv:dot(planeNormal)		-- project onto the plane normal
										local dist = dv:norm()
										if dist < 1e-3 then
											
											-- now find where along plane normal the intervals {v11,v12} and {v21,v22}
											local s11 = 0	--(v11 - planeOrigin):dot(planeNormal) -- assuming v11 is the plane origin
											local s12 = (v12 - planeOrigin):dot(planeNormal)
											-- based on n1 being the plane normal, s11 and s12 are already sorted 
											local s21 = (v21 - planeOrigin):dot(planeNormal)
											local s22 = (v22 - planeOrigin):dot(planeNormal)
											-- since these aren't, they have to be sorted
											if s21 > s22 then s21, s22 = s22, s21 end
											if s11 < s22 and s12 > s21 then
												addEdge(i1, i2, j1, j2, dist, s11, s12, s21, s22, planeOrigin, planeNormal)
											end
										end
									end
								end
							end
						end
					end
				end
			end
			for a,o in pairs(self.allOverlappingEdges) do
				for b,e in pairs(o) do
					print(
						'edges', e[1], e.triVtxIndexes[1],
						'and', e[2], e.triVtxIndexes[2],
						'align with dist', e.dist,
						'with projected intervals', table.concat(e.intervals[1], ', '),
						'and', table.concat(e.intervals[2], ', '))
				end
			end
		end)
	end
--]]

-- TODO all this per-material-group
-- should meshes have their own vtx lists?
-- or should they just index into a master list (like obj files do?)

	-- store tri area
	for _,t in ipairs(self.tris) do
		local a = matrix(self.vs[t[1].v])
		local b = matrix(self.vs[t[2].v])
		local c = matrix(self.vs[t[3].v])
		t.area = triArea(a, b, c)
		t.com = (a + b + c) / 3
		-- TODO what if the tri is degenerate to a line?
		t.normal = (b - a):cross(c - b)
		if t.normal:normSq() < 1e-3 then
			t.normal = matrix{0,0,0}
		else
			t.normal = t.normal:unit()
			if not math.isfinite(t.normal:normSq()) then
				t.normal = (b - a):unit()
				if not math.isfinite(t.normal:normSq()) then
					t.normal = matrix{0,0,0}
				end
			end
		end
	end

	-- and just for kicks, track all edges
	timer('edges', function()
		self.edges = {}
		local function addEdge(a,b,t)
			if a > b then return addEdge(b,a,t) end
			self.edges[a] = self.edges[a] or {}
			self.edges[a][b] = self.edges[a][b] or {
				[1] = a,
				[2] = b,
				tris = table(),
				length = (self.vs[a] - self.vs[b]):norm(),
			}
			local e = self.edges[a][b]
			e.tris:insert(t)
			t.edges:insert(e)
		end
		for _,t in ipairs(self.tris) do
			assert(not t.edges)
			t.edges = table()
			local a,b,c = table.unpack(t)
			addEdge(a.v, b.v, t)
			addEdge(a.v, c.v, t)
			addEdge(b.v, c.v, t)
		end
	end)

-- [[ TODO all this can go in a superclass for all 3d obj file formats
-- TODO store these?  or only calculate upon demand?
	timer('com0', function()
		self.com0 = self:calcCOM0()
	end)
	print('com0 = '..self.com0)
	timer('com1', function()
		self.com1 = self:calcCOM1()
	end)
	print('com1 = '..self.com1)
	timer('com2', function()
		self.com2 = self:calcCOM2()
	end)
	print('com2 = '..self.com2)
	timer('com3', function()
		self.com3 = self:calcCOM3()
	end)
	print('com3 = '..self.com3)
	-- can only do this with com2 and com3 since they use tris, which are stored per-material
	-- ig i could with edges and vtxs too if I flag them per-material
	timer('mtl com2/3', function()
		for mtlname,mtl in pairs(self.mtllib) do
			mtl.com2 = self:calcCOM2(mtlname)
			mtl.com3 = self:calcCOM3(mtlname)
		end
	end)
--]]

-- [[ calculate unique volumes / calculate any distinct pieces on them not part of the volume
	if unwrapUVsOnLoad then
		timer('unwrapping uvs', function()
			self:unwrapUVs()
		end)
	end
--]]

	--self:save('asdf.obj')
end

function WavefrontOBJ:loadMtl(filename)
	self.mtlFilenames:insert(filename)
	local mtl
	filename = file(self.relpath)(filename).path
	-- TODO don't assert, and just flag what material files loaded vs didn't?
	if not file(filename):exists() then
		io.stderr:write("failed to find material file "..filename..'\n')
		return
	end
	for line in io.lines(filename) do
		local words = string.split(string.trim(line), '%s+')
		local lineType = words:remove(1):lower()
		if lineType == 'newmtl' then
			mtl = {}
			mtl.name = assert(words[1])
			mtl.faces = table()
			mtl.triFirstIndex = 1
			mtl.triCount = 0
			-- TODO if a mtllib comes after a face then this'll happen:
			if self.mtllib[mtl.name] then print("warning: found two mtls of the name "..mtl.name) end
			self.mtllib[mtl.name] = mtl
		-- elseif lineType == 'illum' then
		--[[
			0. Color on and Ambient off
			1. Color on and Ambient on
			2. Highlight on
			3. Reflection on and Ray trace on
			4. Transparency: Glass on, Reflection: Ray trace on
			5. Reflection: Fresnel on and Ray trace on
			6. Transparency: Refraction on, Reflection: Fresnel off and Ray trace on
			7. Transparency: Refraction on, Reflection: Fresnel on and Ray trace on
			8. Reflection on and Ray trace off
			9. Transparency: Glass on, Reflection: Ray trace off
			10. Casts shadows onto invisible surfaces
		--]]
		elseif lineType == 'ka' then	-- ambient color
			assert(mtl)
			mtl.Ka = wordsToColor(words)
		elseif lineType == 'kd' then	-- diffuse color
			assert(mtl)
			mtl.Kd = wordsToColor(words)
		elseif lineType == 'ks' then	-- specular color
			assert(mtl)
			mtl.Ks = wordsToColor(words)
		elseif lineType == 'ns' then	-- specular exponent 
			assert(mtl)
			mtl.Ns = tonumber(words[1]) or 1
		-- 'd' = alpha
		-- 'Tr' = 1 - d = opacity
		-- 'Tf' = "transmission filter color"
		-- 'Tf xyz' = same but using CIEXYZ specs
		-- 'Tf spectral filename.rfl [factor]'
		-- 'Ni' = index of refraction aka optical density
		elseif lineType == 'map_kd' then	-- diffuse map
			assert(mtl)
			local function getTexOpts(w)
				local opts = {}
				local found
				repeat
					found = false
					local function parse(n)
						w:remove(1)
						local res = table()
						for i=1,n do
							local v = w[1]
							if n == 3 then	-- colors have optionally 1 thru 3 numeric args
								v = tonumber(v)
								if not v then break end
							else
								v = tonumber(v) or v
							end
							w:remove(1)
							res:insert(v)
						end
						found = true
						return res
					end
					local valid = {
						blendu = 1,
						blendv = 1,
						boost = 1,
						mm = 2,	-- only 2 numeric
						o = 3,	-- up to 3 numeric
						s = 3,	-- up to 3 numeric
						t = 3,	-- up to 3 numeric
						texres = 1,
						clamp = 1,
						bm = 1,
						imfchan = 1,
						type = 1,	-- for reflection maps only
					}
					local l = w[1]:lower()
					if l:sub(1,1) == '-' then
						local k = l:sub(2)
						local v = valid[k]
						if v then
							opts[k] = parse(v)
						end
					end
				until not found
			end
			local opts = getTexOpts(words)
			-- TODO this replaces %s+ with space ... so no tabs or double-spaces in filename ...
			local localpath = words:concat' '
			localpath = localpath:gsub('\\\\', '/')	-- why do I see windows mtl files with \\ as separators instead of just \ (let alone /) ?  is \\ a thing for mtl windows?
			localpath = localpath:gsub('\\', '/')
			local path = file(self.relpath)(localpath)
			if not path:exists() then
				print("couldn't load map_Kd "..tostring(path))
			else
				mtl.map_Kd = path.path
				-- TODO
				-- load textures?
				-- what if the caller isn't using GL?
				-- load images instead?
				-- just store filename and let the caller deal with it?
				mtl.image_Kd = Image(mtl.map_Kd)
				print('loaded map_Kd '..mtl.map_Kd..' as '..mtl.image_Kd.width..' x '..mtl.image_Kd.height..' x '..mtl.image_Kd.channels..' ('..mtl.image_Kd.format..')')
				-- TODO here ... maybe I want a console .obj editor that doesn't use GL
				-- in which case ... when should the .obj class load the gl textures?
				-- manually?  upon first draw?  both?
			end
		--elseif lineType == 'map_ks' then	-- specular color map
		--elseif lineType == 'map_ns' then	-- specular highlight map
		--elseif lineType == 'map_bump' or lineType == 'bump' then
		--elseif lineType == 'disp' then
		--elseif lineType == 'decal' then
		-- and don't forget textre map options
		end
	end
end

-- replace all instances of one vertex index with another
function WavefrontOBJ:replaceVertex(from,to)
--print('replacing vertex ' ..from..' with '..to)	
	assert(from > to)
	assert(from >= 1 and from <= #self.vs)
	assert(to >= 1 and to <= #self.vs)
	-- replace in .tris
	for _,t in ipairs(self.tris) do
		for i=1,3 do
			if t[i].v == from then t[i].v = to end
		end
	end
	-- replace in .mtllib[].faces
	for mtlname,mtl in pairs(self.mtllib) do
		for polySize,faces in pairs(mtl.faces) do
			for _,f in ipairs(faces) do
				for i=1,polySize do
					if f[i].v == from then f[i].v = to end
				end
			end
		end
	end
end

function WavefrontOBJ:removeDegenerateTriangles()
	for i=#self.tris,1,-1 do
		local t = self.tris[i]
		for j=3,2,-1 do
			if t[j].v == t[j-1].v then
				table.remove(t,j)
				break
			end
		end
		if #t < 3 then
--print('removing degenerate tri '..i..' with duplicate vertices')
			self:removeTri(i)
		end
	end
	-- remove in .mtllib[].faces
	for mtlname,mtl in pairs(self.mtllib) do
		for _,n in ipairs(table.keys(mtl.faces)) do
			local faces = mtl.faces[n]
			for i=#faces,1,-1 do
				local f = faces[i]
				for j=n,2,-1 do
					if f[j].v == f[j-1].v then
--print('removing degenerate poly vtx')
						table.remove(j)
						break
					end
				end
				if #f < 3 then
					faces:remove(i)
				end
			end
			if #faces == 0 then
				mtl.faces[n] = nil
			end
		end
	end
end

function WavefrontOBJ:removeTri(i)
	self.tris:remove(i)
	for mtlname,mtl in pairs(self.mtllib) do
		if i < mtl.triFirstIndex then
			mtl.triFirstIndex = mtl.triFirstIndex - 1
		elseif i >= mtl.triFirstIndex and i < mtl.triFirstIndex + mtl.triCount then
			mtl.triCount = mtl.triCount - 1
		end
	end
end

-- remove all instances of a veretx index
-- remove the vertex from the elf.vs[] list
-- decrement the indexes greater
function WavefrontOBJ:removeVertex(vi)
	assert(vi >= 1 and vi <= #self.vs)
	self.vs:remove(vi)
	-- remove in .tris
	-- if you did :replaceVertex and :removeDegenerateFaces first then the rest shouldn't be necessary at all (except for error checking)
	-- if you just straight up remove a vertex then the tris and faces might go out of sync
	for j=#self.tris,1,-1 do
		local t = self.tris[j]
		for i=1,3 do
			if t[i].v == vi then
				--error("found a to-be-removed vertex index in a tri.  you should merge it first, or delete tris containing it first.")
				self:removeTri(j)
				break
			elseif t[i].v > vi then
				t[i].v = t[i].v - 1
			end
		end
	end
	-- remove in .mtllib[].faces
	for mtlname,mtl in pairs(self.mtllib) do
		for polySize,faces in pairs(mtl.faces) do
			for j=#faces,1,-1 do
				local f = faces[j]
				for i=1,polySize do
					if f[i].v == vi then
						--error("found a to-be-removed vertex index in a tri.  you should merge it first, or delete tris containing it first.")
						faces:remove(j)
						break
					elseif f[i].v > vi then
						f[i].v = f[i].v - 1
					end			
				end
			end
		end
	end
end

--[[
1) replace the 'from' with the 'to'
2) remove any degenerate triangles/faces
3) remove the to vertex from the list
--]]
function WavefrontOBJ:mergeVertex(from,to)
	assert(from > to)
	self:replaceVertex(from,to)
	self:removeDegenerateTriangles()
	self:removeVertex(from)
end

-- common interface?  for dif 3d format types?
function WavefrontOBJ:vtxiter()
	return coroutine.wrap(function()
		for i,v in ipairs(self.vs) do
			coroutine.yield(v)
		end
	end)
end

function WavefrontOBJ:getTriIndexesForMaterial(mtlname)
	if mtlname then
		local mtl = self.mtllib[mtlname]
		if mtl then
			return mtl.triFirstIndex, mtl.triFirstIndex + mtl.triCount - 1
		else
			return 1, 0
		end
	else
		return 1, #self.tris
	end
end

-- yields with each material collection for a particular material name
-- default = no name = iterates over all materials
function WavefrontOBJ:mtliter(mtlname)
	return coroutine.wrap(function()
		if mtlname then
			local mtl = self.mtllib[mtlname]
			if mtl then coroutine.yield(mtl, mtlname) end
		else
			for mtlname, mtl in pairs(self.mtllib) do
				coroutine.yield(mtl, mtlname)
			end
		end
	end)
end

-- yields with each face in a particular material or in all materials
function WavefrontOBJ:faceiter(mtlname)
	return coroutine.wrap(function()
		for mtl in self:mtliter(mtlname) do
			local facesPerPolySize = assert(mtl.faces)
			-- order not guaranteed:
			--for polySize,faces in pairs(facesPerPolySize) do
			-- order guaranteed, but fails for no-triangles
			--for polySize=3,table.maxn(facesPerPolySize) do
			-- involves a sort so ..
			for _,polySize in ipairs(table.keys(facesPerPolySize):sort()) do
				local faces = facesPerPolySize[polySize]
				for _,vis in ipairs(faces) do
					coroutine.yield(vis)	-- has [1].v [2].v [3].v for vtx indexes
				end
			end
		end
	end)
end

-- yields with the triangle
-- triangles have [1][2][3] as vi objects which has  .v .vt .vn as indexes into .vs[] .vts[] .vns[]
function WavefrontOBJ:triiter(mtlname)
	return coroutine.wrap(function()
		for mtl, mtlname in self:mtliter(mtlname) do
			for i=mtl.triFirstIndex,mtl.triFirstIndex+mtl.triCount-1 do
				coroutine.yield(self.tris[i], i)	-- should all pairs/ipairs yield the value first? my table.map does it.  javascript forEach does it.  hmm...
			end
		end
	end)
end

-- same as above, but then yield for each vi individually
function WavefrontOBJ:triindexiter(mtlname)
	return coroutine.wrap(function()
		for t in self:triiter(mtlname) do
			for i=1,3 do
				coroutine.yield(t[i])
			end
		end
	end)
end

-- calculate COM by 0-forms (vertexes)
function WavefrontOBJ:calcCOM0()
	local result = self.vs:sum() / #self.vs
	assert(math.isfinite(result:normSq()))
	return result
end

-- calculate COM by 1-forms (edges)
-- depend on self.edges being stored
function WavefrontOBJ:calcCOM1()
	local totalCOM = matrix{0,0,0}
	local totalLen = 0
	for a,bs in pairs(self.edges) do
		for b in pairs(bs) do
			local v1 = self.vs[a]
			local v2 = self.vs[b]
			-- volume = *<Q,Q> = *(Q∧*Q) where Q = (b-a)
			-- for 1D, volume = |b-a|
			local length = (v1 - v2):norm()
			local com = (v1 + v2) * .5
			totalCOM = totalCOM + com * length
			totalLen = totalLen + length
		end
	end
	if totalLen == 0 then
		return self:calcCOM0()
	end
	local result = totalCOM / totalLen
	assert(math.isfinite(result:normSq()))
	return result
end

-- calculate COM by 2-forms (triangles)
-- volume = *<Q,Q> = *(Q∧*Q) where Q = (b-a) ∧ (c-a)
-- for 2D, volume = |(b-a)x(c-a)|
function WavefrontOBJ:calcCOM2(mtlname)
	local totalCOM = matrix{0,0,0}
	local totalArea = 0
	local i1, i2 = self:getTriIndexesForMaterial(mtlname)
	for i=i1,i2 do
		local t = self.tris[i]
		totalCOM = totalCOM + t.com * t.area
		totalArea = totalArea + t.area
	end
	if totalArea == 0 then
		return self:calcCOM1(mtlname)
	end
	local result = totalCOM / totalArea
	assert(math.isfinite(result:normSq()))
	return result
end

-- calculate COM by 3-forms (enclosed volume)
function WavefrontOBJ:calcCOM3(mtlname)
	local totalCOM = matrix{0,0,0}
	local totalVolume = 0
	local i1, i2 = self:getTriIndexesForMaterial(mtlname)
	for i=i1,i2 do
		local t = self.tris[i]
		local a = self.vs[t[1].v]
		local b = self.vs[t[2].v]
		local c = self.vs[t[3].v]

		-- using [a,b,c,0] as the 4 pts of our tetrahedron
		-- volume = *<Q,Q> = *(Q∧*Q) where Q = (a-0) ∧ (b-0) ∧ (c-0)
		-- for 3D, volume = det|a b c|
		local com = (a + b + c) * (1/4)

		-- this should be scaled by 1/6, but since we're weighting the COM by the volume, scale factors don't matter
		local volume = 0
		volume = volume + a[1] * b[2] * c[3]
		volume = volume + a[2] * b[3] * c[1]
		volume = volume + a[3] * b[1] * c[2]
		volume = volume - c[1] * b[2] * a[3]
		volume = volume - c[2] * b[3] * a[1]
		volume = volume - c[3] * b[1] * a[2]

		totalCOM = totalCOM + com * volume
		totalVolume = totalVolume + volume
	end
	-- if there's no volume then technically this can't exist ... but just fallback
	if totalVolume == 0 then
		return self:calcCOM2(mtlname)
	end
	local result = totalCOM / totalVolume
	assert(math.isfinite(result:normSq()))
	return result
end

-- calculates volume bounded by triangles
function WavefrontOBJ:calcVolume()
	local volume = 0
	for _,t in ipairs(self.tris) do
		local i,j,k = table.unpack(t)
		-- volume of parallelogram with vertices at 0, a, b, c
		local a = self.vs[i.v]
		local b = self.vs[j.v]
		local c = self.vs[k.v]

		volume = volume + a[1] * b[2] * c[3]
		volume = volume + a[2] * b[3] * c[1]
		volume = volume + a[3] * b[1] * c[2]
		volume = volume - c[1] * b[2] * a[3]
		volume = volume - c[2] * b[3] * a[1]
		volume = volume - c[3] * b[1] * a[2]
	end
	if volume < 0 then volume = -volume end
	volume = volume / 6
	return volume
end

function WavefrontOBJ:save(filename)
	local o = assert(file(filename):open'w')
	-- TODO write smooth flag, groups, etc
	for _,mtl in ipairs(self.mtlFilenames) do
		o:write('mtllib ', mtl, '\n')
	end
	for _,v in ipairs(self.vs) do
		o:write('v ', table.concat(v, ' '), '\n')
	end
	for _,vt in ipairs(self.vts) do
		o:write('vt ', table.concat(vt, ' '), '\n')
	end
	for _,vn in ipairs(self.vns) do
		o:write('vn ', table.concat(vn, ' '), '\n')
	end
	local mtlnames = table.keys(self.mtllib):sort()
	assert(mtlnames[1] == '')	-- should always be there 
	for _,mtlname in ipairs(mtlnames) do
		local mtl = self.mtllib[mtlname]
		if mtlname ~= '' then
			o:write('usemtl ', mtlname, '\n')
		end
		local fs = mtl.faces
		for k=3,table.maxn(fs) do
			for _,vis in ipairs(fs[k]) do
				o:write('f ', table.mapi(vis, function(vi)
					local vs = table{vi.v, vi.vt, vi.vn}
					for i=1,vs:maxn() do vs[i] = vs[i] or '' end
					return vs:concat'/'
				end):concat' ', '\n')
			end
		end
	end
	o:close()
end


-- all the draw functionality is tied tightly with view.lua so ... 
-- idk if i should move it from one or the other


-- upon ctor the images are loaded (in case the caller isn't using GL)
-- so upon first draw - or upon manual call - load the gl textures
function WavefrontOBJ:loadGL(shader)
	if self.loadedGL then return end
	self.loadedGL = true
	
	local gl = require 'gl'
	local glreport = require 'gl.report'
	local GLTex2D = require 'gl.tex2d'
	local GLArrayBuffer = require 'gl.arraybuffer'
	local GLAttribute = require 'gl.attribute'
	local GLVertexArray = require 'gl.vertexarray'

	-- load textures
	for mtlname, mtl in pairs(self.mtllib) do
		if mtl.image_Kd then
			mtl.tex_Kd = GLTex2D{
				image = mtl.image_Kd,
				minFilter = gl.GL_NEAREST,
				magFilter = gl.GL_LINEAR,
			}
		end
	end

	-- calculate vertex normals
	-- TODO store this?  in its own self.vn2s[] or something?
--print('zeroing vertex normals')				
	local vtxnormals = self.vs:mapi(function(v)
		return matrix{0,0,0}
	end)
--print('accumulating triangle normals into vertex normals')				
	for t in self:triiter(mtlname) do
		if math.isfinite(t.normal:normSq()) then
			for _,vi in ipairs(t) do
				vtxnormals[vi.v] = vtxnormals[vi.v] + t.normal * t.area
			end
		end
	end
--print('normals vertex normals')				
	for k=1,#vtxnormals do
		if vtxnormals[k]:normSq() > 1e-3 then
			vtxnormals[k] = vtxnormals[k]:normalize()
		end
--print(k, vtxnormals[k])
	end

	-- mtl will just index into this.
	-- why does mtl store a list of tri indexes?  it should just store an offset
print('allocating cpu buffer of obj_vertex_t of size', #self.tris * 3)
	local vtxCPUBuf = vector('obj_vertex_t', #self.tris * 3)
	self.vtxCPUBuf = vtxCPUBuf
		
	for i,t in ipairs(self.tris) do
		for j,vi in ipairs(t) do
			local dst = vtxCPUBuf.v + (j-1) + 3 * (i-1)
			dst.pos:set(self.vs[vi.v]:unpack())
			if vi.vt then
				if vi.vt < 1 or vi.vt > #self.vts then
					print("found an oob vt "..vi.vt)
					dst.texCoord:set(0,0,0)
				else
					dst.texCoord:set(self.vts[vi.vt]:unpack())
				end
			end
			if vi.vn then
				if vi.vn < 1 or vi.vn > #self.vns then
					print("found an oob fn "..vi.vn)
					dst.normal:set(0,0,0)
				else
					dst.normal:set(self.vns[vi.vn]:unpack())
				end
			end
			dst.normal2:set(vtxnormals[vi.v]:unpack())
			dst.area = t.area
			dst.com:set(t.com:unpack())
		end
	end
	
print('creating array buffer of size', self.vtxCPUBuf.size)
	self.vtxBuf = GLArrayBuffer{
		size = self.vtxCPUBuf.size * ffi.sizeof'obj_vertex_t',
		data = self.vtxCPUBuf.v,
		usage = gl.GL_STATIC_DRAW,
	}
	assert(glreport'here')

	self.vtxAttrs = {}
	for _,info in ipairs{
		{name='pos', size=3},
		{name='texCoord', size=3},
		{name='normal', size=3},
		{name='normal2', size=3},
		{name='com', size=3},
	} do
		local srcAttr = shader.attrs[info.name]
		if srcAttr then
			self.vtxAttrs[info.name] = GLAttribute{
				buffer = self.vtxBuf,
				size = info.size,
				type = gl.GL_FLOAT,
				stride = ffi.sizeof'obj_vertex_t',
				offset = ffi.offsetof('obj_vertex_t', info.name),
			}
			assert(glreport'here')
		end
	end
	shader:use()
	assert(glreport'here')
	self.vao = GLVertexArray{
		program = shader,
		attrs = self.vtxAttrs,
	}
	shader:setAttrs(self.vtxAttrs)
	shader:useNone()
	assert(glreport'here')
end

function WavefrontOBJ:draw(args)
	local gl = require 'gl'
	
	self:loadGL()	-- load if not loaded
	
	local curtex
	for mtlname, mtl in pairs(self.mtllib) do
		--[[
		if mtl.Kd then
			gl.glColor4f(mtl.Kd:unpack())
		else
			gl.glColor4f(1,1,1,1)
		end
		--]]
		--[[
		if mtl
		and mtl.tex_Kd
		and not (args and args.disableTextures)
		then
			-- TODO use .Ka, Kd, Ks, Ns, etc
			-- with fixed pipeline?  opengl lighting?
			-- with a shader in the wavefrontobj lib?
			-- with ... nothing?
			curtex = mtl.tex_Kd
			curtex:enable()
			curtex:bind()
		else
			if curtex then
				curtex:unbind()
				curtex:disable()
				curtex = nil
			end
		end
		--]]
		if args.beginMtl then args.beginMtl(mtl) end
		
		--[[ immediate mode
		gl.glBegin(gl.GL_TRIANGLES)
		for vi in self:triindexiter(mtlname) do
			-- TODO store a set of unique face v/vt/vn index-vertexes
			-- and then bake those into a unique vertex array, and store its index alongside face's other indexes
			-- that'll be most compat with GL indexed arrays
			if vi.vt then
				gl.glTexCoord2f(self.vts[vi.vt]:unpack())
			end
			if vi.vn then
				gl.glNormal3f(self.vns[vi.vn]:unpack())
			end
			gl.glVertex3f(self.vs[vi.v]:unpack())
		end
		gl.glEnd()
		--]]
		--[[ vertex client arrays
		gl.glVertexPointer(3, gl.GL_FLOAT, ffi.sizeof'obj_vertex_t', mtl.vtxCPUBuf.v[0].pos.s)
		gl.glTexCoordPointer(3, gl.GL_FLOAT, ffi.sizeof'obj_vertex_t', mtl.vtxCPUBuf.v[0].texCoord.s)
		gl.glNormalPointer(gl.GL_FLOAT, ffi.sizeof'obj_vertex_t', mtl.vtxCPUBuf.v[0].normal.s)
		gl.glEnableClientState(gl.GL_VERTEX_ARRAY)
		gl.glEnableClientState(gl.GL_TEXTURE_COORD_ARRAY)
		gl.glEnableClientState(gl.GL_NORMAL_ARRAY)
		gl.glDrawArrays(gl.GL_TRIANGLES, 0, mtl.vtxCPUBuf.size)
		gl.glDisableClientState(gl.GL_VERTEX_ARRAY)
		gl.glDisableClientState(gl.GL_TEXTURE_COORD_ARRAY)
		gl.glDisableClientState(gl.GL_NORMAL_ARRAY)
		--]]
		--[[ vertex attrib pointers ... requires specifically-named attrs in the shader
		gl.glVertexAttribPointer(args.shader.attrs.pos.loc, 3, gl.GL_FLOAT, gl.GL_FALSE, ffi.sizeof'obj_vertex_t', mtl.vtxCPUBuf.v[0].pos.s)
		gl.glVertexAttribPointer(args.shader.attrs.texCoord.loc, 3, gl.GL_FLOAT, gl.GL_FALSE, ffi.sizeof'obj_vertex_t', mtl.vtxCPUBuf.v[0].texCoord.s)
		gl.glVertexAttribPointer(args.shader.attrs.normal.loc, 3, gl.GL_FLOAT, gl.GL_TRUE, ffi.sizeof'obj_vertex_t', mtl.vtxCPUBuf.v[0].normal.s)
		gl.glEnableVertexAttribArray(args.shader.attrs.pos.loc)
		gl.glEnableVertexAttribArray(args.shader.attrs.texCoord.loc)
		gl.glEnableVertexAttribArray(args.shader.attrs.normal.loc)
		gl.glDrawArrays(gl.GL_TRIANGLES, 0, mtl.vtxCPUBuf.size)
		gl.glDisableVertexAttribArray(args.shader.attrs.pos.loc)
		gl.glDisableVertexAttribArray(args.shader.attrs.texCoord.loc)
		gl.glDisableVertexAttribArray(args.shader.attrs.normal.loc)
		--]]
		-- [[ vao ... getting pretty tightly coupled with the view.lua file ...
		if mtl.triCount > 0 then
			self.vao:use()
			gl.glDrawArrays(gl.GL_TRIANGLES, (mtl.triFirstIndex-1) * 3, mtl.triCount * 3)
			self.vao:useNone()
		end
		--]]
		if args.endMtl then args.endMtl(mtl) end
	end
	--[[
	if curtex then
		curtex:unbind()
		curtex:disable()
	end
	--]]
	require 'gl.report''here'
end

-- make sure my edges match my faces
-- can't handle mtl-group explode dist because edges aren't stored associted with materials ...
-- they are per-tri, which is per-face, which is per-material, but there can be multiple materials per edge.
function WavefrontOBJ:drawEdges(triExplodeDist, groupExplodeDist)
	local gl = require 'gl'
	gl.glLineWidth(3)
	gl.glColor3f(1,1,0)
	gl.glBegin(gl.GL_LINES)
	for a,other in pairs(self.edges) do
		for b,edge in pairs(other) do
			-- avg of explode offsets of all touching tris
			local offset = matrix{0,0,0}
			for _,t in ipairs(edge.tris) do
				-- get mtl for tri, then do groupExplodeDist too
				-- matches the shader in view.lua
				local groupExplodeOffset = (t.mtl.com3 - self.com3) * groupExplodeDist
				local triExplodeOffset = (t.com - t.mtl.com3) * triExplodeDist
				offset = offset + groupExplodeOffset + triExplodeOffset 
			end
			offset = offset / #edge.tris
			gl.glVertex3f((self.vs[a] + offset):unpack())
			gl.glVertex3f((self.vs[b] + offset):unpack())
		end
	end
	gl.glEnd()
	gl.glLineWidth(1)
end

function WavefrontOBJ:drawStoredNormals()
	local gl = require 'gl'
	gl.glColor3f(0,1,1)
	gl.glBegin(gl.GL_LINES)
	for _,t in ipairs(self.tris) do
		for _,vi in ipairs(t) do
			if vi.vn then
				local v = self.vs[vi.v]
				local vn = self.vns[vi.vn]
				gl.glVertex3f(t.com:unpack())
				gl.glVertex3f((t.com + vn):unpack())
				--gl.glVertex3f((v.com + v.normal2):unpack())
			end
		end
	end
	gl.glEnd()
end

function WavefrontOBJ:drawVertexNormals()
	local gl = require 'gl'
	gl.glColor3f(0,1,1)
	gl.glBegin(gl.GL_LINES)
	for mtlname,mtl in pairs(self.mtllib) do
		if mtl.vtxCPUBuf then
			for i=0,mtl.vtxCPUBuf.size-1,3 do
				local v = mtl.vtxCPUBuf.v[i]
				gl.glVertex3f(v.pos:unpack())
				gl.glVertex3f((v.pos + v.normal2):unpack())
			end
		end
	end
	gl.glEnd()
end

function WavefrontOBJ:drawTriNormals()
	local gl = require 'gl'
	gl.glColor3f(0,1,1)
	gl.glBegin(gl.GL_LINES)
	for _,t in ipairs(self.tris) do
		gl.glVertex3f(t.com:unpack())
		gl.glVertex3f((t.com + t.normal):unpack())
	end
	gl.glEnd()
end

function WavefrontOBJ:drawUVs(_3D)
	local gl = require 'gl'
	local GLTex2D = require 'gl.tex2d'
	self.uvMap = self.uvMap or GLTex2D{
		image = Image(64, 64, 3, 'unsigned char', function(u,v)
			return (u+.5)/64*255, (v+.5)/64*255, 127
		end),
		minFilter = gl.GL_NEAREST,
		magFilter = gl.GL_LINEAR,
		wrap = {s = gl.GL_REPEAT, t = gl.GL_REPEAT},
	}
	gl.glColor3f(1,1,1)
	self.uvMap:enable()
	self.uvMap:bind()
	gl.glBegin(gl.GL_TRIANGLES)
	for _,t in ipairs(self.tris) do
		for _,tv in ipairs(t) do
			uv = tv.uv or {0,0}
			gl.glTexCoord2f(uv[1], uv[2])
			if _3D then
				gl.glVertex3f(self.vs[tv.v]:unpack())
			else
				gl.glVertex2f(uv[1], uv[2])
			end
		end
	end
	gl.glEnd()
	self.uvMap:unbind()
	self.uvMap:disable()
end
function WavefrontOBJ:drawUVUnwrapEdges(_3D)
	local gl = require 'gl'
	local eps = 1e-3
	-- [[ show unwrap info
	gl.glColor3f(0,1,1)
	gl.glBegin(gl.GL_LINES)
	for _,info in ipairs(self.unwrapUVEdges or {}) do
		for i,t in ipairs(info) do
			if info.floodFill == true then
				gl.glColor3f(0,0,1)
			else
				if i==1 then
					gl.glColor3f(0,1,0)
				else
					gl.glColor3f(1,0,0)
				end
			end
			if _3D then
				gl.glVertex3f((t.com + eps * t.normal):unpack())
			else
				local com = (t[1].uv + t[2].uv + t[3].uv) / 3
				gl.glVertex2f(com:unpack(1,2))
			end
		end
	end
	gl.glEnd()
	gl.glPointSize(3)
	gl.glColor3f(0,1,1)
	gl.glBegin(gl.GL_POINTS)
	for _,v in ipairs(self.unwrapUVOrigins or {}) do
		gl.glVertex3f(v:unpack())
	end
	gl.glEnd()
	gl.glPointSize(1)
	--]]
end


-- this belongs in its own place, outside this project


function WavefrontOBJ:unwrapUVs()
-- TODO put this all in its own function or its own app
	local numSharpEdges = 0
	for a,other in pairs(self.allOverlappingEdges) do
		for b,edge in pairs(other) do
			-- #tris == 0 is an edge construction error
			-- #tris == 1 is a sharp edge ... which means a non-convex
			-- #tris == 2 is good
			-- any more ... we have something weird
			if #edge.tris == 0 then
				error'here'
			elseif #edge.tris == 1 then
				numSharpEdges = numSharpEdges + 1
			elseif #edge.tris > 2 then
				print('found an edge with != 2 tris: ' ..#edge.tris)
			end
		end
	end
	print('numSharpEdges = '..numSharpEdges)

	-- how about count area per cube sides?
	-- total vector, l=0 s.h.
	local avgNormal = matrix{0,0,0}
	for _,t in ipairs(self.tris) do
		avgNormal = avgNormal + t.normal * t.area
	end
	local avgNormalIsZero = avgNormal:normSq() < 1e-7
	if not avgNormalIsZero then avgNormal = avgNormal:normalize() end
	print('avg normal = '..avgNormal)

	-- the same idea as the l=1 spherical harmonics
	local range = require 'ext.range'
	local areas = matrix{6}:zeros()
	for _,t in ipairs(self.tris) do
		local _,i = table.sup(t.normal:map(math.abs))
		assert(i)
		local dir = t.normal[i] > 0 and 1 or 2
		local index = dir + 2 * (i-1)
		areas[index] = areas[index] + t.area
	end
	print('per-side x plus/minus normal distribution = '..require 'ext.tolua'(areas))

	local bestNormal
-- TODO snap-to-axis for within epsilon
--	if not avgNormalIsZero then
--		bestNormal = matrix(avgNormal)
do--	else
		local _, besti = table.sup(areas)
		local bestdir = math.floor((besti-1)/2)+1
		bestNormal = matrix{0,0,0}
		bestNormal[bestdir] = bestdir%2 == 0 and -1 or 1
	end
	print('bestNormal', bestNormal)

	-- for all faces (not checked)
	--  traverse neighbors by edge and make sure the normals align
	--  complain if the normals flip
	--  or should this be robust enough to determine volume without correct normals / tri order?
	--  I'll assume ccw polys for now.
	local function findLocalIndex(t, v)
		for i=1,3 do
			if t[i].v == v then return i end
		end
	end
	local function getEdgeOppositeTri(e, t)
		assert(#e.tris == 2)
		local t1,t2 = table.unpack(e.tris)
		if t2 == t then
			t1, t2 = t2, t1
		end
		assert(t1 == t)
		return t2, t1
	end
	local function calcUVBasis(t, tsrc, esrc)
		assert(not t[1].uv and not t[2].uv and not t[3].uv)
		-- t[1] is our origin
		-- t[1]->t[2] is our x axis with unit length
		local v = matrix{3,3}:lambda(function(i,j) return self.vs[t[i].v][j] end)
--print('v\n'..v)					
		local d1 = v[2] - v[1]
		local d2 = v[3] - v[2]
		local n = d1:cross(d2)
		local nlen = n:norm()
--print('|d1 x d2| = '..nlen)
		if not math.isfinite(nlen)
		or nlen < 1e-9
		then
			t.normal = d1:normalize()
			-- can't fold this because i'ts not a triangle ... it's a line
			-- should I even populate the uv fields?  nah, just toss it in the caller
			return true
		end
		n = n / nlen
--print('n = '..n)
		t.normal = matrix(n)
	
		--if true then
		if not tsrc then	-- first basis
			t.uvorigin2D = matrix{0,0}
			-- modularity for choosing which point on the tri is the uv origin
			--[[ use the first point
			t.uvorigin3D = matrix(v[1])
			--]]
			-- [[ use the y-lowest point
			t.uvorigin3D = matrix(v[select(2, range(3):mapi(function(i) return v[i][2] end):inf())])
			self.unwrapUVOrigins:insert(t.uvorigin3D * .7 + t.com * .3)
			--]]

--print('uv2D = '..t.uvorigin2D)
--print('uv3D = '..t.uvorigin3D)
			
			-- modularity for choosing initial basis
			--[[ use first base of the triangle
			local ex = d1:normalize()
			--]]
			--[[ preference to align the first axis in the xz plane
			-- first find the best option of the 3 deltas
			-- close to the same as choosing n cross y+
			-- but the first set of tris are not so good
			local d3 = v[1] - v[3]
			local ex
			if math.abs(d1[2]) < math.abs(d2[2]) then	-- d1 < d2
				if math.abs(d1[2]) < math.abs(d3[2]) then	-- d1 < d2 and d1 < d3
					ex = d1:normalize()
				else			-- d3 < d1 < d2
					ex = d3:normalize()
				end
			else	-- d2 < d1
				if math.abs(d2[2]) < math.abs(d3[2]) then	-- d2 < d1 and d2 < d3
					ex = d2:normalize()
				else			-- d3 < d2 < d1
					ex = d3:normalize()
				end
			end
			--]]
			-- [[ just use n cross y+
			-- BEST FOR CARTESIAN ALIGNED
			-- best for top
			-- crashes for sides
			local ex = n:cross(bestNormal):normalize()
			--]]
			--[[ just use n cross x+ or z+ ...
			-- ... gets nans
			local ex = n:cross{0,0,1}:normalize()
			--]]
			--[[ pick whatever is most perpendicular to n and another cartesian basis
			-- a[i] = 1, i = sup(|n[i]|) gives same as n cross y+, good for tops, but crashes for sides.
			-- a[i] = 1, i = inf(|n[i]|) doesn't crash for sides but gives bad tops results.
			-- a[i+1] = 1, i = inf(|n[i]|) crashes on sides, but same as n cross y+ on top
			local _, i = table.sup(n:map(math.abs))
			local a = matrix{0,0,0}
			a[i] = 1
			local ex = n:cross(a):normalize()
			assert(math.isfinite(ex:normSq()))
			--]]
			--[[ draw a line between the lowest two points
			if v[1][2] > v[2][2] then
				if v[1][2] > v[3][2] then	-- 1 highest
					ex = (v[3] - v[2]):normalize()
				else	-- 3 highest
					ex = (v[2] - v[1]):normalize()
				end
			else
				if v[2][2] > v[3][2] then	-- 2 highest
					ex = (v[1] - v[3]):normalize()
				else	-- 3 highest
					ex = (v[2] - v[1]):normalize()
				end
			end
			--]]

			-- fallback, if n is nan or zero
			local exNormSq = ex:normSq()
			if exNormSq < 1e-3						-- can't use zero
			or not math.isfinite(exNormSq)			-- can't use nan
			or math.abs(ex:dot(n)) > 1 - 1e-3	-- can't use ex perp to n
			then
print('failed to find u vector based on bestNormal, picked ex='..ex..' from bestNormal '..bestNormal)
				-- pick any basis perpendicular to 'n'
				local ns = matrix{3}:lambda(function(i)
					local a = matrix{0,0,0}
					a[i] = 1
					return n:cross(a)
				end)
--print('choices\n'..ns)				
				local lens = matrix{3}:lambda(function(i) return ns[i]:normSq() end)
				local _, i = table.sup(lens)	-- best normal
--print('biggest cross '..i)
				ex = ns[i]:unit()
--print('picking fallback ', ex)				
			end

--print('ex = '..ex)			
			-- tangent space.  store as row vectors i.e. transpose, hence the T
			t.uvbasisT = matrix{
				ex,
				n:cross(ex):normalize(),
				n,
			}
--print('ey = '..t.uvbasisT[2])			
		else
			assert(tsrc[1].uv and tsrc[2].uv and tsrc[3].uv)
		
--[[
tsrc.v3      tsrc.v2
	   *-------* t.v2
	   |   ___/|
	   |__/    |
tsrc.v1*-------*
	  t.v3   t.v1
--]]
--print('folding from', tsrc.index, 'to', t.index)
			--[[ using .edges
			local i11 = findLocalIndex(tsrc, esrc[1])	-- where in tsrc is the edge's first?
			local i12 = findLocalIndex(tsrc, esrc[2])	-- where in tsrc is the edge's second?
			local i21 = findLocalIndex(t, esrc[1])	-- where in t is the edge's first?
			local i22 = findLocalIndex(t, esrc[2])	-- where in t is the edge's second?
			assert(i11 and i12 and i21 and i22)
			assert(tsrc[i11].v == t[i21].v)	-- esrc[1] matches between tsrc and t
			assert(tsrc[i12].v == t[i22].v)	-- esrc[2] matches between tsrc and t
			assert(tsrc[i11].v == esrc[1])
			assert(tsrc[i12].v == esrc[2])
			assert(t[i21].v == esrc[1])
			assert(t[i22].v == esrc[2])
			--]]
			-- [[ using .allOverlappingEdges
			local i11 = esrc.triVtxIndexes[1]
			local i12 = i11 % 3 + 1
			local i21 = esrc.triVtxIndexes[2]
			local i22 = i21 % 3 + 1
			assert(i11 and i12 and i21 and i22)
			--]]
--print('edge local vtx indexes: tsrc', i11, i12, 't', i21, i22)					
			-- tables are identical

			local isrc
			if tsrc[i11].uv then
				isrc = i11
			elseif tsrc[i12].uv then
				isrc = i12
			else
				error("how can we fold a line when the src tri doesn't have uv coords for it?")
			end
			t.uvorigin2D = matrix(tsrc[isrc].uv)			-- copy matching uv from edge neighbor
			t.uvorigin3D = matrix(self.vs[tsrc[isrc].v])	-- copy matching 3D position
--print('uv2D = '..t.uvorigin2D)
--print('uv3D = '..t.uvorigin3D)

			-- modularity for choosing unwrap rotation
			--[[ reset basis every time. dumb.
			local ex = d1:normalize()
			t.uvbasisT = matrix{
				ex,
				n:cross(ex):normalize(),
				n,
			}
			--]]
			--[[ subsequent tri basis should be constructed from rotating the prev tri basis
			-- find the rotation from normal 1 to normal 2
			-- that'll just be the matrix formed from n1 and n2's basis ...
			local q = quat():vectorRotate(tsrc.normal, t.normal)
			t.uvbasisT = matrix{
				q:rotate(tsrc.uvbasisT[1]),
				q:rotate(tsrc.uvbasisT[2]),
				n,
			}
			--]]
			-- [[ pick the rotation along the cardinal axis that has the greatest change
			-- BEST FOR CARTESIAN ALIGNED
			local dn = t.normal - tsrc.normal
			local q
			if dn:normSq() < 1e-3 then
				q = quat(0,0,0,1)
			else
				-- pick smallest changing axis in normal?
				local _, i = table.inf(dn:map(math.abs))
				if i == 1 then
					local degrees = math.deg(math.atan2(n[3], n[2]) - math.atan2(tsrc.normal[3], tsrc.normal[2]))
--print(t.normal, tsrc.normal, dn, 'rot on x-axis by', degrees)
					q = quat():fromAngleAxis(1, 0, 0, degrees)
				elseif i == 2 then
					local degrees = math.deg(math.atan2(n[1], n[3]) - math.atan2(tsrc.normal[1], tsrc.normal[3]))
--print(t.normal, tsrc.normal, dn, 'rot on y-axis by', degrees)
					q = quat():fromAngleAxis(0, 1, 0, degrees)
				elseif i == 3 then
					local degrees = math.deg(math.atan2(n[2], n[1]) - math.atan2(tsrc.normal[2], tsrc.normal[1]))
--print(t.normal, tsrc.normal, dn, 'rot on z-axis by', degrees)
					q = quat():fromAngleAxis(0, 0, 1, degrees)
				end
			end
--print('q', q)
--print('n', n)
--print('tsrc ex = '..tsrc.uvbasisT[1])
--print('tsrc ey = '..tsrc.uvbasisT[2])			
			t.uvbasisT = matrix{
				q:rotate(tsrc.uvbasisT[1]),
				q:rotate(tsrc.uvbasisT[2]),
				n,
			}
			--]]
			
--print('|ez-n| = '..matrix(q:rotate(tsrc.uvbasisT[3]) - n):norm())
--print('ex = '..t.uvbasisT[1])
--print('ey = '..t.uvbasisT[2])			
		end

		for i=1,3 do
			local d = v[i] - t.uvorigin3D
			local m = matrix{t.uvbasisT[1], t.uvbasisT[2]}
--print('d = '..d)
--print('m\n'..m)
--print('m * d = '..(m * d))
			t[i].uv = m * d + t.uvorigin2D
--print('uv = '..t[i].uv)
			if not math.isfinite(t[i].uv:normSq()) then
				print('tri has nans in its basis')
			end
		end
	end
	
	self.unwrapUVOrigins = table()
	self.unwrapUVEdges = table()	-- keep track of how it's made for visualization's sake ...
	
	local notDoneYet = table(self.tris)
	local done = table()
	
	local function calcUVBasisAndAddNeighbors(t, tsrc, e, todo)
		if tsrc then self.unwrapUVEdges:insert{tsrc, t} end
		-- calc the basis by rotating it around the edge
		assert((tsrc == nil) == (e == nil))
		local gotBadTri = calcUVBasis(t, tsrc, e)
		-- TODO roof actually looks good with always retarting ... but not best
		if not gotBadTri then
			done:insert(t)
			assert(t[1].uv and t[2].uv and t[3].uv)
			-- insert neighbors into a to-be-calcd list
--print('tri', t.index)
			for _,e in ipairs(t.allOverlappingEdges) do
--print('edge length', e.length)
				-- for all edges in the t, go to the other faces matching.
				-- well, if there's more than 2 faces shared by an edge, that's a first hint something's wrong.
				do--if #e.tris == 2 then	-- if we're using any overlapping edge then this guarantee goes out the window
					local t2 = getEdgeOppositeTri(e, t)
-- if our tri 
-- ... isn't in the 'todo' pile either ...
-- ... is still in the notDoneYet pile ...
					if not todo:find(t2)
					and not done:find(t2)
					then
						local i = notDoneYet:find(t2)
						if i then
							assert(not t2[1].uv and not t2[2].uv and not t2[3].uv)
							notDoneYet:remove(i)
							todo:insert(t2)
						end
					end
				end
			end
		end
	end

	local function floodFillMatchingNormalNeighbors(t, tsrc, e, alreadyFilled)
		alreadyFilled:insertUnique(t)
		if t[1].uv then return end
		if tsrc then self.unwrapUVEdges:insert{tsrc, t, floodFill=true} end
		assert((tsrc == nil) == (e == nil))
		if not calcUVBasis(t, tsrc, e) then
			done:insert(t)
			assert(t[1].uv and t[2].uv and t[3].uv)
			for _,e in ipairs(t.allOverlappingEdges) do
				if #e.tris == 2 then
					local t2 = getEdgeOppositeTri(e, t)
					if not alreadyFilled:find(t2) then
						if t.normal:dot(t2.normal) > 1 - 1e-3 then
							floodFillMatchingNormalNeighbors(t2, t, e, alreadyFilled)
						else
							alreadyFilled:insertUnique(t)
						end
					end
				end
			end
		end
	end

	while #notDoneYet > 0 do
		print('starting unwrapping process with '..#notDoneYet..' left')
		
		-- I will be tracking all live edges
		-- so process the first tri as the starting point
		-- then add its edges into the 'todo' list

		-- modularity heuristic of picking best starting edge
		--[[ take the first one regardless 
		local todo = table{notDoneYet:remove(1)}
		--]]
		--[[ largest tri first
		notDoneYet:sort(function(a,b) return a.area > b.area end)
		local todo = table{notDoneYet:remove(1)}
		--]]
		--[[ choose the first edge that starts closest to the ground (lowest y value)
		-- ... but this does some whose sharp edges touches
		-- i really want only those with flat edges at the base
		notDoneYet:sort(function(a,b)
			return math.min(
				self.vs[a[1].v][2],
				self.vs[a[2].v][2],
				self.vs[a[3].v][2]
			) < math.min(
				self.vs[b[1].v][2],
				self.vs[b[2].v][2],
				self.vs[b[3].v][2]
			)
		end)
		local todo = table{notDoneYet:remove(1)}
		--]]
		--[[ same as above but pick the lowest *edge* , not *vtx*, cuz we want the base edges aligned with the bottom 
		notDoneYet:sort(function(a,b)
			local aEdgeYMin = matrix{3}:lambda(function(i)
				return .5 * (self.vs[a[i].v][2] + self.vs[a[i%3+1].v][2])
			end):min()
			local bEdgeYMin = matrix{3}:lambda(function(i)
				return .5 * (self.vs[b[i].v][2] + self.vs[b[i%3+1].v][2])
			end):min()
			return aEdgeYMin < bEdgeYMin
		end)
		local todo = table{notDoneYet:remove(1)}
		--]]	
		--[=[ choose *all* tris whose flat edges are at the minimum y
		local vtxsNotDoneYet = {}
		for _,t in ipairs(notDoneYet) do
			for i=1,3 do
				vtxsNotDoneYet[t[i].v] = true
			end
		end
		-- convert set of keys to list
		vtxsNotDoneYet = table.keys(vtxsNotDoneYet):sort(function(a,b)
			return self.vs[a][2] < self.vs[b][2]	-- sort by y axis
		end)
		local eps = (self.bbox.max[2] - self.bbox.min[2]) * 1e-5
		local ymin = self.vs[vtxsNotDoneYet[1]][2]
		print('y min', ymin)
		-- now go thru all tris not done yet
		-- if any have 2/3 vtxs at the min then add them
		local todo = table()
		for i=#notDoneYet,1,-1 do
			local t = notDoneYet[i]
			local mincount = 0
			for j=1,3 do
				if self.vs[t[j].v][2] < ymin + eps then mincount = mincount + 1 end
			end
			if mincount >= 2 then
				todo:insert(notDoneYet:remove(i))
			end
		end
		-- if none were added then add one with 1/3 vtxs at the min
		if #todo == 0 then
			for i=#notDoneYet,1,-1 do
				local t = notDoneYet[i]
				for j=1,3 do
					if self.vs[t[j].v][2] < ymin + eps then
						todo:insert(notDoneYet:remove(i))
						break
					end
				end
				if #todo > 0 then break end
			end
		end
print('number to initialize with', #todo)
		-- ... and process them all once first, adding their neigbors to the 'todo' pile
		--]=]
		-- [=[ choose tris with any edges that are 90' from the guide normal
		-- but not if the vector from the com to the edges is towards the guide normal
		local todo = table()
		for i=#notDoneYet,1,-1 do
			local t = notDoneYet[i]
			for j=1,3 do
				local a = self.vs[t[j].v]
				local b = self.vs[t[j%3+1].v]
				if math.abs((b - a):normalize():dot(bestNormal)) < 1e-5 then
					-- exclude tops
					if (.5 * (b + a) - t.com):dot(bestNormal) > 0 then
						notDoneYet:remove(i)
						todo:insert(t)
						break
					end
				end
			end
		end
		-- if finding a y-perpendicular downward-pointing edge was too much to ask,
		-- ... then pick one at random?
		if #todo == 0 then
print("couldn't find any perp-to-bestNormal edges to initialize with...")
			todo:insert(notDoneYet:remove(1))
		end
		--]=]
		
		-- [[ first pass to make sure all the first picked are considered
		-- during this first pass, immediately fold across any identical normals
		print('starting first pass with #todo', #todo)
		for i=#todo,1,-1 do
			local t = todo:remove(i)
			-- for 't', flood-fill through anything with matching normal
			-- while flood-filling, continue adding neighbors to 'todo'
			local filled = table()
			floodFillMatchingNormalNeighbors(t, nil, nil, filled)
			for _,t in ipairs(filled) do
				if not t[1].uv then
					todo:insertUnique(t)
				end
			end
		end
		print('after first pass, #todo', #todo, '#done', #done)
		--]]

		while #todo > 0 do
			local t, tsrc, e

			-- pick best edge between any triangle in 'done' and any in 'todo'
			local edgesToCheck = table()
			for _,t in ipairs(todo) do
				for _,e in ipairs(t.allOverlappingEdges) do
					if #e.tris == 2 then
						local t2 = getEdgeOppositeTri(e, t)
						if done:find(t2) then
							edgesToCheck:insert{tri=t, edge=e, prevtri=t2}
						end
					end
				end
			end
			if #edgesToCheck == 0 then
				-- same as first iter
				print("no edges to check ...")
				t = todo:remove(math.random(#todo))
			else
				-- assert from prevoius iteration that the first is the best
				-- modularity heuristic for picking best continuing edge
				-- sort last instead of first, so first iteration and first entry is removed, so I can guarantee that all entries have .prevtri and .edge
				edgesToCheck:sort(function(a,b)
					local ea, eb = a.edge, b.edge
					--[[ prioritize longest edge ... cube makes a long straight shape with one bend.
					-- looks best for cone.  just does two solid pieces for the base and sides
					-- looks best for cube.  does the cubemap t.
					return ea.length > eb.length
					--]]
					--[[ prioritize shortest edge ... cube makes a zigzag
					return ea.length < eb.length
					--]]
					--[[ prioritize biggest area
					local atriarea = a.tri.area + a.prevtri.area
					local btriarea  = b.tri.area + b.prevtri.area
					return atriarea > btriarea
					--]]
					--[[ prioritize smallest area
					local atriarea = a.tri.area + a.prevtri.area
					local btriarea  = b.tri.area + b.prevtri.area
					return atriarea < btriarea
					--]]
					-- [[ prioritize rotation angle
					-- LOOKS THE BEST SO FAR
					local ra = a.tri.normal:dot(a.prevtri.normal)
					local rb = b.tri.normal:dot(b.prevtri.normal)
					return ra > rb
					--]]
					-- TODO Try prioritizing discrete curvature (mesh angle & area info combined?)
					--[[ prioritize by rotation.
					-- first priority is no-rotation
					-- next is predominantly y-axis rotations
					local dn = a.tri.normal - a.prevtri.normal
					local _, i = table.inf(dn:map(math.abs))
					--]]
				end)
				local check = edgesToCheck[1]
				t, e, tsrc = check.tri, check.edge, check.prevtri
				assert(t)
				assert(e)
				assert(tsrc)
				assert(tsrc[1].uv and tsrc[2].uv and tsrc[3].uv)
				todo:removeObject(t)
			end
			for _,t in ipairs(todo) do
				assert(not t[1].uv and not t[2].uv and not t[3].uv)
			end
			if t then
				calcUVBasisAndAddNeighbors(t, tsrc, e, todo)
			end
		end
		for _,t in ipairs(done) do
			assert(t[1].uv and t[2].uv and t[3].uv)
		end		
	end
end

return WavefrontOBJ
