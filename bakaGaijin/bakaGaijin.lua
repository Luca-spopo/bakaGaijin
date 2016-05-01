--[[

GARBAGE COLLECTION ON ACTIVE TOKENS:
The only way I can think of is reference counting.
And the way to check if the GC has collected tokens would be
to set a timer to maintain a list of indices in ATinterner and
monitor all changes...
So this would be a "second level GC" sitting on top of the actual GC.
This one would be timed, since I am too stupid to make one that depends on loads.
Host will maintain assignment of PTs sent to each resource
When an AT is GCed, the non-host sends a signal to the host, host removes the resource from assigned list.
When a resource dies, the host checks if it was in the assigned

--One resource:
local kek = {}
bakaGaijin["var1"] = kek;
kek.anothertable = {{1}, {2}, {3}}
local y = "Hello "
kek.fun = function(x) print y..x; return 42, kek.fun end; end

--Other resource:

local rec = bakaGaijin("OneResource")
local table = rec.var1
table.a = 20 --Sets it to 20 live in the other resource
local deb = table.anothertable --deb is also a token
table.fun("Luca") --Calls fun live in the other VM and returns value (prints "Hello Luca" and returns 42, fun2)

Note that I use the word "element" to denote a function/table/activate-token/userdata(maybe)
basically anything that cannot be shared with other resources as it is

Every resource has a gaijinPool, which contains elements it is exposing outside.
gaijinPool has tables inside it for each resource, so if a resource shuts down I just
remove the table and let GC do the work.
Every element in the gaijinPool has it's lifetime linked to a resource.

UPDATES:
passive tokens have 3 feilds
__gaijin_id, which is the index they have in the host pool
__gaijin_res, the resource that holds the element associated with this token. (Host resource)

FUTURE ISSUES:
Functions passed are implemented as tables with a __call, so type(fun) wont give function

Active tokens are not memoized, so everytime a resource sends a PToken to another, the
resulting object it receives everytime is different.
This means identity tests for two "same" active tokens wont work.
So rec.var1 == rec.var1 is false
rec.var1 will request a passive token from rec, convert it into an active token.
The second rec.var1 will do the exact same thing, and will generate it's own active token.
These tokens are not the same.
I could overload comparison (and in fact, addition (vectors) and all such activities) to happen
at the host using metatables.
But I dont know if the metatable overrides index identities. Let's see.
EDIT: Tested it out. Getting operations like equality to work is easy
But indexing does not use equality apparantly. Even if a == b through metatables, table[a] ~= table[b]
Interning seems like the only option.
So, we keep another table of resources, each mapped to a table of active tokens
And when we receive a passive token and need to activate it, we check if we already have active instances of it.

Things to test...

local a = rec1.table
local b = rec1.table
kek[a] = true
kek[b] = false
assert(kek[a] == false)

]]

--[[
outputConsole( "---TESTING STARTS---" )
local a = {}
local b = {}

local eqt = function (op1, op2)
	return true
end
local eqf = function (op1, op2)
	return false
end

local m = {__eq = eqt}
setmetatable(a, m)
setmetatable(b, m)

local table = {}
table[a] = 3;
table[b] = 4

outputConsole( tostring(table[a]) )
outputConsole( tostring(table[b]) )


outputConsole( "---TESTING ENDS---" )
-------------------]]

local LOAD_GAIN_TOLERANCE = 1.4
--If a resource keeps locking lots of objects and actually uses them, it's allowance is increased.
--LOAD_GAIN_TOLERANCE tells bakaGaijin how much to increase the allowance each time it's exceeded.
--A value of 1.4 means allowance will increase by 40%. This makes the GC elastic and dynamic.
local LOAD_MIN = 100 --The minimum number of items a resource is allowed to lock before it's asked to check it's actual usage and send unsub messages
local COLLECTOR_WAITS = 10 --Number of bakaGaijin's GC's sweeps before the Lua GC is invoked
local ATC_TIME = 60000 --Miliseconds between each "sweep" of bakaGaijin's GC

LOAD_MIN = LOAD_MIN/LOAD_GAIN_TOLERANCE
--Precomputing stuff.

local resourceName = resource:getName();
local exports = exports
local weak_meta = {__mode = "v"}

--Some forward declarations
local ATmeta
local getElemFromPToken
local getPTokenFromElem
local updateATC

local multimap = {}
do
	local multimapFun = function(self, index)
		self[index] = multimap.new(getmetatable(self).cardinality-1)
		return self[index]
	end
	multimap.new = function(cardinality)
		assert(cardinality>0, "Invalid cardinality")
		if cardinality == 1 then
			local temp = {}
			setmetatable(temp, weak_meta) --specially for this script
			return temp
		else
			local self = {}
			setmetatable(self, {cardinality = cardinality, __index = multimapFun})
			return self
		end
	end
end

--vocabulary:
--Host resource = Resource that contains the actual table or function that will be used
--Client resource = Resouce that wishes to access variables of the host resource.
--primative = boolean, number, string, nil, userdata
--AT = Active Token. Present in client resource. Client resource uses an AT as a handler to
--interact with a candidate on the host resource
--PT = Passive Token. Can be transferred accross resources without information loss. Is technically also a candidate.
--Used to pass a candidate to another resource. AT is constructed from a PT at the client resource.
--candidate = table or function, but not AT
--elem = primative, AT or candidate

-- tokenid -> candidate
local gaijinPool = {}

-- tokenid -> stamp
local stampLookup = {}
--Not neccesarily a time stamp, but used to ensure that
--a new exported gaijin with the same token_id as an older expired one
--is not misinterpreted as the older one by a different resource.
--Also acts as a "password" as other resources can't fake the stamp unless
--they actually got the object

-- {candidate, AT} -> PT(table)
local tokenLookup = {}
setmetatable(tokenLookup, {__mode="k"})

-- token_id -> < resname(string) -> {true, nil} >
local ownLookup = {}
--Lists the resources that are using an exported gaijin
--Named gaijins are used by the host resource itself

-- resname(string) -> count(int)
local loads = {}
--Number of objects held for a particular resource
-- resname(string) -> count(int)
local loadsShadow = {}
--Last known number of objects actually used by a resource
--Used as reference by GC to expand allowance

-- resname(string), id -> AT
local ATinterner = multimap.new(2)
--The <id -> AT> part is weak.
--Used for interning all active tokens

-- resname(string), id -> stamp
local ATcache = multimap.new(2)
--The shadow of ATinterner
--Syncs with it everytime updateATC is called
--Used as reference to detect Active Tokens that have been GCed by Lua

-- string -> PT
local nameCache = {}
--Used by other resources to refer to a variable exposed by the host resource

do
	local counter = 1
	updateATC = function(GC)
		counter = counter + 1
		if GC or counter >= COLLECTOR_WAITS then
			collectgarbage();
			counter = 0
		end
		for rec, table in pairs(ATcache) do
			for id, existed in pairs(table) do
				if not ATinterner[rec][id] then --It existed, but not anymore
					local stamp = ATcache[rec][id]
					ATcache[rec][id] = nil --Anyway, marked as "not existing anymore"
					if getResourceFromName(rec) then
						--outputDebugString( "unsubbing" )
						exports[rec]:bakaGaijin_export("unsub", id, stamp)
					end
				end
			end
		end
	end
	setTimer(updateATC, ATC_TIME, 0)
end

 --Generate metatable for an AToken being made form a PToken
 do
	local __index = function(t, k)
		t = tokenLookup[t]
		assert(getResourceFromName(t.__gaijin_res), "Gaijin tried accessing dead resource.")
		return getElemFromPToken(exports[t.__gaijin_res]:bakaGaijin_export("get",t.__gaijin_id, t.__gaijin_stamp,  getPTokenFromElem(k))) --Lots of scope for optimization
	end
	local __newindex = function(t, k, v)
		t = tokenLookup[t]
		assert(getResourceFromName(t.__gaijin_res), "Gaijin tried accessing dead resource.")
		exports[t.__gaijin_res]:bakaGaijin_export( "set", t.__gaijin_id, t.__gaijin_stamp, getPTokenFromElem(k), getPTokenFromElem(v)) --Lots of scope for optimization
	end
	local __tostring = function(t)
		t = tokenLookup[t]
		assert(getResourceFromName(t.__gaijin_res), "Gaijin tried accessing dead resource.")
		return "gaijin_object: " .. exports[t.__gaijin_res]:bakaGaijin_export( "str", t.__gaijin_id, t.__gaijin_stamp)
	end
	local __call = function(t, ...)
		t = tokenLookup[t]
		local args = {...}
		for i, v in ipairs(args) do
			args[i] = getPTokenFromElem(v)
		end
		assert(getResourceFromName(t.__gaijin_res), "Gaijin tried accessing dead resource.")
		local temp = { exports[t.__gaijin_res]:bakaGaijin_export("call", t.__gaijin_id, t.__gaijin_stamp, unpack(args)) }
		for i, v in ipairs(temp) do
			temp[i] = getElemFromPToken(v);
		end
		return unpack(temp)
	end
	ATmeta = {__index = __index, __newindex = __newindex, __tostring = __tostring, __call = __call}
end


getPTokenFromElem = function(object)
	--[[Get PT or primative from an elem. Such that the result is portable accross resources.
	If not an candidate, return as it is
	If Active token, return passive version
	else tokenize and return.
		PASSIVE TOKENS ARE TOKENIZED AND RETURNED as a PT to a PT
		because passive tokens are just regular tables.
	]]
	local typ = type(object)
	if typ~="table" and typ~="function" then
		return object --Not a candidate
	end
	
	if tokenLookup[object] then --Tokenized earlier or AT
		return tokenLookup[object] --Returned interned PT
	end

	local ans = {}
	local count = #gaijinPool+1
	gaijinPool[count] = object
	ownLookup[count] = {}
	stampLookup[count] = math.random(50000) --random stamp

	ans.__gaijin_id = count
	ans.__gaijin_res = resourceName; --Host resource
	ans.__gaijin_stamp = stampLookup[count]
	if typ=="function" then
		ans.__gaijin_fun = true
	end
	tokenLookup[object] = ans;
	
	return ans --Manufacture and return PT
end


getElemFromPToken = function(token)
	--If received a valid passive token, fetches and returns associated object (if this is host res)
	--or turns it into an AT (and updates ATinterner and ATcache) if it is from another resource.
	--Active tokens are returned as they are.
	--Everything else, returns "token" arg as it is.
	if type(token) ~= "table" then return token end;
	local hostres = token.__gaijin_res
	local id = token.__gaijin_id
	if hostres == resourceName then
		if token.__gaijin_stamp ~= stampLookup[id] then
			outputDebugString("Stamp mismatch", 1)
			return nil
		end
		return gaijinPool[id] --CHECK: stampLookup must be nil when an object is removed from gaijinPool
	elseif hostres then --Is a PT
		if ATinterner[hostres][id] then
			return ATinterner[hostres][id]
		end
		
		assert(getResourceFromName(hostres), "Gaijin tried accessing dead resource.")

		--Guaranteed to reach here only when creating a new AToken
		--which represents an elem in another resource.
		--Safe to register it in ATcache here.
		--Safe to fire the subscribe signal here.
		if not exports[hostres]:bakaGaijin_export("sub", id, token.__gaijin_stamp) then
			error("Expired PToken being converted to AToken \n"..debug.traceback())
		end

		local AToken
		if token.__gaijin_fun then
			AToken = function(...)
				return ATmeta.__call(AToken, ...)
			end
		else
			AToken = {}
			setmetatable(AToken, ATmeta)
		end
		tokenLookup[AToken] = token

		ATinterner[hostres][id] = AToken;
		ATcache[hostres][id] = token.__gaijin_stamp;
		
		return AToken;
	else
		return token
	end
end

-- local function removeElemByTokenID(tokenid)
-- 	tokenLookup[gaijinPool[tokenid]] = nil --its weak anyway
-- 	-- local temp = getmetatable( gaijinPool[tokenid] )
-- 	-- if temp and temp.__bakaKill then
-- 	-- 	temp.__bakaKill(gaijinPool[tokenid])
-- 	-- end
-- 	gaijinPool[tokenid] = nil
-- 	--TODO: Reduce loads
-- 	ownLookup[tokenid] = nil
-- 	return true
-- end

-- local function removeElemByPToken(token)
-- 	local id = token.__gaijin_id
-- 	local res = token.__gaijin_res
-- 	if res == resourceName then
-- 		return removeElemByTokenID(id)
-- 	else
-- 		assert(getResourceFromName(res), "Gaijin tried accessing dead resource.")
-- 		return exports[res]:bakaGaijin_export("kill", id, t.__gaijin_stamp)
-- 	end
-- end


local function getProp(res, tokenid, key)
	--Takes a passive token and gets a value (in PT form) from it's associated table.
	--Only makes sense if this is the hostres
	--res is the resource that requested the operation. Use it to implement permissions if you want.
	key = getElemFromPToken(key)
	local elem = gaijinPool[tokenid]
	if type(elem) ~= "table" then
		error("Attempted to index a non-table", 4)
	end
	return getPTokenFromElem(elem[key])
end

local function pairsByID(tokenid)
	--Generates a table of PT to send to a client resource to let them use pairs on it
	--Assumes this is hostres
	local elem = gaijinPool[tokenid]
	if type(elem) ~= "table" then
		return nil
	end
	local ans = {}
	for i, v in pairs(elem) do
		ans[ getPTokenFromElem(i) ] = getPTokenFromElem(v) 
	end
	return ans
end

local function ipairsByID(tokenid)
	local elem = gaijinPool[tokenid]
	if type(elem) ~= "table" then
		return nil
	end
	local ans = {}
	for i=1, #elem do
		ans[ i ] = getPTokenFromElem(elem[i]) 
	end
	return ans
end

local function setProp(res, tokenid, key, val)
	key = getElemFromPToken(key)
	val = getElemFromPToken(val)
	local elem = gaijinPool[tokenid]
	if type(elem) ~= "table" then
		error("Attempted to set key on a non-table")
	end
	elem[key] = val
end

local function callFun(res, tokenid, ...)
	--Calls a function, table or userdata
	--Assumes this resource is hostres
	local elem = gaijinPool[tokenid]
	if type(elem) ~= "function" then
		if type(elem) ~= "table" and type(elem) ~= "userdata" then
			error("Attempted to call un uncallable")
		end
		outputDebugString("Attempted to call a non-function, ignore if you are using userdata or __call metamethod.", 2)
	end
	local args = {...}
	for i, v in ipairs(args) do
		args[i] = getElemFromPToken(v)
	end
	local rets = {elem(unpack(args))}
	for i, v in ipairs(rets) do
		rets[i] = getPTokenFromElem(v)
	end
	return unpack(rets)
end


local function unsubByID(id, res)
	--Informs bakaGaijin that res no longer needs candidate with given id
	if ownLookup[id] then
		if(ownLookup[id][res]) then
			if loads[res] == 1 then
				loads[res] = nil
			else
				loads[res] = loads[res] - 1
			end
		else
			outputDebugString(resourceName.." got a double unsub from "..res.." for "..id.."\n"..debug.traceback(), 2)
		end
		ownLookup[id][res] = nil;
	else
		return nil; --bad unsub
	end

	--The rest of this function stops exporting a candidate if it's not needed anymore.

	for i in pairs(ownLookup[id]) do
		return true; --Break if even one lock remains
	end
	tokenLookup[gaijinPool[id]] = nil;
	gaijinPool[id] = nil;
	ownLookup[id] = nil
	stampLookup[id] = nil
end

local function subByID(id, res)
	--Informs bakaGaijin that res is using candidate with given id
	if not ownLookup[id][res] then
		loads[res] = (loads[res] or 0) + 1
	else
		outputDebugString(resourceName.." got a double sub from "..res.." for "..id.."\n"..debug.traceback())
	end
	ownLookup[id][res] = true;
	if loads[res] > LOAD_GAIN_TOLERANCE*(loadsShadow[res] or LOAD_MIN) then
		if res == resourceName then
			bakaGC()
		else
			exports[res]:bakaGaijin_export("free")
		end
		loadsShadow[res] = math.max(loads[res], LOAD_MIN);
		--outputDebugString( "Load threshold for "..res.." set to "..loadsShadow[res]*LOAD_GAIN_TOLERANCE )
		--DEBUG: Remove line above
	end
	return true
end



--bakaGaijin["name"] = element (to "export" it and make it availiable to others.)
--bakaGaijin("resource").name to get something publicly exported by that resource
--Host should implement reference counting.

local recmeta = {
	__index = function(t, index)
		return getElemFromPToken(exports[t.res_name]:bakaGaijin_export("s2t", index))
	end,
	__newindex = function()
		error("You cannot set data for another resource.", 2)
	end
}
local bakaGaijin_meta = {
	-- __newindex = function(t, index, value)
	-- 	assert(type(index) == "string", "You can only keep string keys for exports through bakaGaijin")
	-- 	nameCache[index] = value
	-- end,
	-- __index = function(t, index)
	-- 	assert(type(index) == "string", "You can only keep string keys for exports through bakaGaijin")
	-- 	return nameCache[index]
	-- end,
	__call = function(t, rec)
		local proxy = {res_name = rec}
		setmetatable(proxy, recmeta)
		return proxy
	end
}

-------------------
-----GLOBALS-------

bakaGaijin = nameCache
setmetatable(bakaGaijin, bakaGaijin_meta)

bakaUpdateATC = updateATC

function bakaGC()
	collectgarbage()
	updateATC()
end

function bakaGaijin_export(typ, tokenid, stamp, ...)
	local sourceResource = getResourceName( sourceResource )
	if typ=="s2t" then	--String to token
		return getPTokenFromElem(nameCache[tokenid])
	elseif typ=="free" then
		return bakaGC()
	end
	--[[
	if typ == "sub" then
		outputConsole(table.concat({resourceName , " is about to register that ",tokenid , ", ", tostring(gaijinPool[tokenid]) , " is used by ",sourceResource}))
	elseif typ == "unsub" then
		outputConsole(table.concat({resourceName , " is about to register that ",tokenid," is NO LONGER used by ",sourceResource}))
	end
	--]]
	if not gaijinPool[tokenid] or stamp ~= stampLookup[tokenid] then
		return nil
		--outputConsole(table.concat({"Bad item: Request received at ", resourceName , " for id ",tokenid,", stamp: ", stamp, ", task: ",typ}))
		--outputConsole(debug.traceback(), 0, 100, 100, 200)
		--error(table.concat({"Bad item: Request received at ", resourceName , " for id ",tokenid,", task: ",typ}), 4)
	end
	if typ=="get" then
		return getProp(sourceResource, tokenid, ...)
	elseif typ=="set" then
		return setProp(sourceResource, tokenid, ...)
	elseif typ=="call" then
		return callFun(sourceResource, tokenid, ...)
	-- elseif typ=="kill" then
	-- 	return removeElemByTokenID(tokenid)
	elseif typ=="sub" then
		return subByID(tokenid, sourceResource);
	elseif typ=="unsub" then
		return unsubByID(tokenid, sourceResource)
	elseif typ=="pairs" then
		return pairsByID(tokenid)
	elseif typ=="ipairs" then
		return ipairsByID(tokenid)
	elseif typ=="str" then
		return tostring(gaijinPool[tokenid])
	elseif typ=="len" then
		return #gaijinPool[tokenid]
	else
		error("bakaGaijin_export called incorrectly by "..sourceResource)
	end
	--Add removeElemByToken for typ=="kill" ? To kill a token?	
end


-- function killBaka(AToken)
-- 	local temp = getmetatable(AToken)
-- 	if temp and temp.__bakaToken then
-- 		return removeElemByPToken(temp.__bakaToken)
-- 	elseif tokenLookup[AToken] then
-- 		return removeElemByPToken(tokenLookup[AToken]) --? investigate?
-- 	else
-- 		return false
-- 	end
-- end

--There is a TODO: in removeElemByID before killBaka and "kill" export can be allowed

-- function chownBaka(AToken, res)
-- 	local meta = getmetatable(AToken)
-- 	if meta and meta.__bakaToken then
-- 		chownBakaP(meta.__bakaToken, res)
-- 	else
-- 		local pt = tokenLookup[AToken]
-- 		if pt then
-- 			chownBakaP(pt, res)
-- 		else
-- 			outputDebugString( "chownBaka: Used on a non gaijin! Kono baka!" )
-- 		end
-- 	end
-- end

-- local function flat(arg)
-- 	if type(arg) ~= "table" then
-- 		return tostring(arg)
-- 	end
-- 	local kek = {}
-- 	for i, v in pairs(arg) do
-- 		table.insert (kek, tostring(i).." --> "..tostring(v))
-- 	end
-- 	return table.concat(kek, "\n")
-- end

function getBaka()
	--Debug function: Returns table of resourcenames and objects under them in gaijinPool
	local exporting = {}
	local exp_count = 0
	local using = {}
	local use_count = 0
	for id, elem in pairs(gaijinPool) do
		exp_count = exp_count + 1
	end
	for id, table in pairs(ownLookup) do
		for rec in pairs(table) do
			exporting[rec] = (exporting[rec] or 0) + 1;
		end
	end
	for rec, table in pairs(ATinterner) do
		for id, AT in pairs(table) do
			use_count = use_count + 1;
			local kek = using[ tokenLookup[AT].__gaijin_res ]
			using[ tokenLookup[AT].__gaijin_res ] = (kek or 0) + 1
		end
	end
	return exp_count, use_count, exporting, using
end

function showBaka(verbose, out)
	if not out then
		out = outputConsole
	end
	out("Called getBaka() for "..resourceName)
	local ec, uc, exporting, using = getBaka()
	out( table.concat({"Exporting ", ec, " gaijins."}) )
	if verbose then
		for i, v in pairs(exporting) do
			out( table.concat({i, " -> ", v}) )
		end
	end
	out( table.concat({"Using ", uc, " gaijins."}) )
	if verbose then
		for i, v in pairs(using) do
			out( table.concat({i, " -> ", v}) )
		end
	end
end

function isBaka(kek)
	local temp = tokenLookup[kek]
	if temp and temp.__gaijin_res ~= resourceName then
		return true
	else
		return false
	end
end

function len(t)
	local pt = tokenLookup[t]
	if pt and pt.__gaijin_res ~= resourceName then
		return exports[pt.__gaijin_res]:bakaGaijin_export("len", pt.__gaijin_id, pt.__gaijin_stamp)
	else
		return #t
	end
end


------------------
----OVERRIDES-----
raw_ipairs = ipairs
raw_pairs = pairs
local ipairs_it = ipairs({})
local pairs_it = pairs({})
function ipairs(table)
	local pt = tokenLookup[table]
	if pt and pt.__gaijin_res ~= resourceName then
		local tableofpt = exports[pt.__gaijin_res]:bakaGaijin_export("ipairs", pt.__gaijin_id, pt.__gaijin_stamp)
		local ans = {}
		for i, v in pairs(tableofpt) do
			ans[i] = getElemFromPToken(v)
		end
		return ipairs_it, ans, 0
	else
		return ipairs_it, table, 0
	end
end
function pairs(table)
	local pt = tokenLookup[table]
	if pt and pt.__gaijin_res ~= resourceName then
		local tableofpt = exports[pt.__gaijin_res]:bakaGaijin_export("pairs", pt.__gaijin_id, pt.__gaijin_stamp)
		local ans = {}
		for i, v in pairs(tableofpt) do
			ans[getElemFromPToken(i)] = getElemFromPToken(v)
		end
		return pairs_it, ans, nil
	else
		return pairs_it, table, nil
	end
end
------------------

 addEventHandler( "onClientResourceStop", getRootElement( ),
    function ( stoppedRes )
    	local name = getResourceName( stoppedRes )
    	loads[name] = nil
    	loadsShadow[name] = nil
    	for id, table in pairs(ownLookup) do
    		for res in pairs(table) do
    			if res == name then
    				table[res] = nil; --May fuck up iteration?
    			end
    		end
    	end
    end
);